// The WUI clean-code gate (CLE-77915, refactor item 5): the same three limits
// the hub's Go gate holds (csi-spl-api internal/cleancode), over every
// function in csi-spl-wui/src (.ts, .mjs, .js and the <script> of .vue).
//
//   • a function longer than MAX_LINES fails, unless LONG lists it
//   • nesting deeper than MAX_DEPTH (if / for / while / switch / try) fails
//   • more than MAX_PARAMS parameters fails: pass the object they belong to
//
// LONG is what was over the limit when the gate landed. It may only shrink:
// split a function and delete its line; a NEW long function fails. A listed
// function that is no longer long is reported so its line can go.
//
// Run: node tests/unit/cleancode.test.mjs
//      CLEANCODE_PRINT=1 node tests/unit/cleancode.test.mjs   # print today's long set
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const SRC = join(WUI, 'src')

// Measured on trunk 2026-10-02: 4676 functions, max depth 4, max params 5.
const MAX_LINES = 80
const MAX_DEPTH = 4
const MAX_PARAMS = 6

// `<file> <name>` (an anonymous function takes its variable / property name,
// or `<anon>`; a repeat in one file gets #2, #3). Lines at landing in the comment.
const LONG = new Set([
  'src/composables/useLive.ts ensure', // 85
  'src/composables/useLive.ts useLive', // 169
  'src/composables/useMentionPicker.ts useMentionPicker', // 130
  'src/composables/useMessageEdit.ts useMessageEdit', // 98
  'src/composables/useMove.ts useMove', // 182
  'src/composables/usePaneWidths.ts usePaneWidths', // 167
  'src/composables/useScrollAnchor.ts useScrollAnchor', // 208
  'src/composables/useTopicRowActions.ts useTopicRowActions', // 89
  'src/stores/channel.ts <anon>', // 468
  'src/stores/flow.ts <anon>', // 128
  'src/stores/live.ts setup', // 262
  'src/stores/notification.ts <anon>', // 362
  'src/stores/search.ts <anon>', // 98
  'src/stores/session.ts <anon>', // 138
  'src/stores/topic.ts <anon>', // 117
  'src/stores/viewer.ts <anon>', // 143
  'src/utils/auth-client.mjs createAuthClient', // 297
  'src/utils/error-snackbar.mjs createSnackbarQueue', // 107
  'src/utils/event-log.mjs createEventShipper', // 98
  'src/utils/issues.mjs createMockIssues', // 159
  'src/utils/live-ws.mjs createLiveClient', // 475
  'src/utils/live-ws.mjs handle', // 105
  'src/utils/move-drag.mjs createHandleDrag', // 96
  'src/utils/spool-client.mjs createSpoolClient', // 1415
])

const NEST = new Set([
  ts.SyntaxKind.IfStatement, ts.SyntaxKind.ForStatement, ts.SyntaxKind.ForOfStatement,
  ts.SyntaxKind.ForInStatement, ts.SyntaxKind.WhileStatement, ts.SyntaxKind.DoStatement,
  ts.SyntaxKind.SwitchStatement, ts.SyntaxKind.TryStatement,
])

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (/\.(ts|mjs|js|vue)$/.test(e.name) && !e.name.endsWith('.d.ts')) out.push(p)
  }
  return out
}

// `else if` is one level, as in Go's gate; a nested function starts at 0.
function depthOf(node, d) {
  let max = d
  ts.forEachChild(node, (c) => {
    if (ts.isFunctionLike(c)) return
    const elseIf = c.kind === ts.SyntaxKind.IfStatement && ts.isIfStatement(c.parent) && c.parent.elseStatement === c
    max = Math.max(max, depthOf(c, d + (NEST.has(c.kind) && !elseIf ? 1 : 0)))
  })
  return max
}

function nameOf(n) {
  if (n.name) return n.name.getText()
  const p = n.parent
  if (p && (ts.isVariableDeclaration(p) || ts.isPropertyAssignment(p) || ts.isPropertyDeclaration(p)) && p.name) return p.name.getText()
  return '<anon>'
}

export function scan() {
  const fns = []
  for (const file of walk(SRC)) {
    const rel = relative(WUI, file)
    let text = readFileSync(file, 'utf8')
    const blocks = []
    if (file.endsWith('.vue')) {
      for (const m of text.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)) blocks.push(m[1])
    } else blocks.push(text)
    const seen = new Map()
    for (const src of blocks) {
      const sf = ts.createSourceFile(rel, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
      const visit = (n) => {
        if (ts.isFunctionLike(n) && n.body) {
          const lines = sf.getLineAndCharacterOfPosition(n.end).line - sf.getLineAndCharacterOfPosition(n.getStart()).line + 1
          let key = `${rel} ${nameOf(n)}`
          const k = (seen.get(key) || 0) + 1
          seen.set(key, k)
          if (k > 1) key += `#${k}`
          fns.push({ key, lines, params: n.parameters.length, depth: depthOf(n.body, 0) })
        }
        ts.forEachChild(n, visit)
      }
      visit(sf)
    }
  }
  return fns
}

const fns = scan()
if (process.env.CLEANCODE_PRINT) {
  for (const f of fns.filter((x) => x.lines > MAX_LINES).sort((a, b) => a.key.localeCompare(b.key))) {
    console.log(`  '${f.key}', // ${f.lines}`)
  }
  process.exit(0)
}

let failed = 0
const fail = (m) => { failed++; console.log(`  FAIL ${m}`) }
if (fns.length < 1000) fail(`scanned only ${fns.length} functions under src: the walk is broken, not the code`)

const long = new Set()
for (const f of fns) {
  if (f.lines > MAX_LINES) {
    long.add(f.key)
    if (!LONG.has(f.key)) fail(`${f.key} is ${f.lines} lines (> ${MAX_LINES}): split it into named steps (or add it to LONG with a reason in the commit)`)
  }
  if (f.depth > MAX_DEPTH) fail(`${f.key} nests ${f.depth} levels (> ${MAX_DEPTH}): extract the inner body`)
  if (f.params > MAX_PARAMS) fail(`${f.key} takes ${f.params} parameters (> ${MAX_PARAMS}): pass the object they belong to`)
}
for (const k of LONG) if (!long.has(k)) console.log(`  NOTE LONG: '${k}' is no longer over ${MAX_LINES} lines - delete its line`)

// Controls: the measures must see what they claim to.
const probe = ts.createSourceFile('p.ts', 'function f(a,b){ if(a){ for(;;){ while(b){ switch(a){ case 1: try{}catch{} } } } } }', ts.ScriptTarget.Latest, true)
const pf = probe.statements[0]
if (depthOf(pf.body, 0) !== 5 || pf.parameters.length !== 2) fail(`control: depth/params of a known function read ${depthOf(pf.body, 0)}/${pf.parameters.length}, want 5/2`)

console.log(failed
  ? `\ncleancode: ${failed} FAILED`
  : `cleancode: ${fns.length} functions, ${long.size} listed long, none deeper than ${MAX_DEPTH} or wider than ${MAX_PARAMS}`)
process.exit(failed ? 1 : 0)
