// The WUI clean-code gate (CLE-77915, refactor item 5): the same three limits
// the hub's Go gate holds (csi-spl-api internal/cleancode), over every
// function in csi-spl-wui/src (.ts, .mjs, .js and the <script> of .vue).
//
//   • a function longer than MAX_LINES fails, unless LONG lists it
//   • nesting deeper than MAX_DEPTH (if / for / while / switch / try) fails
//   • more than MAX_PARAMS parameters fails, unless WIDE lists it
//
// LONG is what was over the limit when the gate landed. It may only shrink:
// split a function and delete its line; a NEW long function fails. Each entry
// carries a ceiling: a listed function that grows past it fails. A listed
// function that is no longer long, or is under its ceiling, is reported so its
// line can go or its ceiling come down.
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
// r28-02 ratcheted MAX_LINES 80 -> 75; LONG grandfathers what was over 75.
const MAX_LINES = 75
const MAX_DEPTH = 4
// r26-02 ratcheted MAX_PARAMS 6 -> 5; WIDE grandfathers what was at 6.
const MAX_PARAMS = 5
const WIDE_CAP = 6

// `<file> <name>` -> ceiling (an anonymous function takes its variable /
// property name, or `<anon>`; a repeat in one file gets #2, #3). The ceiling is
// its length when listed (r5-06): a listed function may not grow past it.
// Now: the functions over 75 lines when r28-02 lowered MAX_LINES 80 -> 75 (28
// on fba652a18). The list may only shrink: split a function into named steps
// and delete its line; a NEW long one fails.
const LONG = new Map([
  ['src/components/workspace-docs/-doctree-api.ts useDocTree', 79],
  ['src/composables/useCalendarDeepLinks.ts useCalendarDeepLinks', 78],
  ['src/composables/useCardMove.ts useCardMove', 80],
  ['src/composables/useCardReactions.ts useCardReactions', 76],
  ['src/composables/useCardTopicActions.ts useCardMessageActions', 80],
  ['src/composables/useChannelAgentPick.ts useChannelAgentPick', 76],
  ['src/composables/useChannelPersonPick.ts useChannelPersonPick', 76],
  ['src/composables/useDocPictures.ts useDocPictures', 79],
  ['src/composables/useDragReorder.ts useDragReorder', 80],
  ['src/composables/useFileTreeDrag.ts useFileTreeDrag', 80],
  ['src/composables/useOmniboxGripSize.ts useOmniboxGripSize', 79],
  ['src/composables/useSidebarRailNav.ts useSidebarRailNav', 76],
  ['src/composables/useSidebarRowDrag.ts useSidebarRowDrag', 78],
  ['src/composables/useSpoolEvents.ts useSpoolEvents', 80],
  ['src/composables/useTenantSwitch.ts useTenantSwitch', 78],
  ['src/stores/channel.ts liveSendSteps', 77],
  ['src/stores/channel.ts sidebarSteps', 79],
  ['src/stores/repoEdit.ts <anon>#6', 77],
  ['src/stores/repoEdit.ts editLists', 78],
  ['src/stores/roster.ts <anon>', 77],
  ['src/stores/search.ts <anon>#4', 76],
])

// `<file> <name>` keyed as LONG. The functions at 6 parameters when r26-02
// lowered MAX_PARAMS to 5 (17 on a3e94a77b). A listed function may take at
// most WIDE_CAP. The list may only shrink: split a function's parameters into
// the struct / object they belong to and delete its line; a NEW wide one fails.
const WIDE = new Set([
  'src/composables/useCardEdit.ts useCardEdit',
  'src/composables/useCardEdit.ts useEditKeys',
  'src/composables/useCardHeight.ts useCardGrip',
  'src/composables/useCardMove.ts useCardMove',
  'src/composables/useCardSwipe.ts useCardSwipe',
  'src/composables/useCardSwipe.ts useCardSwipeFlags',
  'src/composables/useCardTopicActions.ts useCardMessageActions',
  'src/composables/useCardTopicActions.ts useCardTopicActions',
  'src/composables/useCardTouchLift.ts useCardTouchLift',
  'src/stores/channel.ts send',
  'src/stores/channel.ts sendLive',
  'src/stores/notification.ts alertSteps',
  'src/utils/calendar-events-api.mjs send',
  'src/utils/perf-rum.mjs perfFeedPair',
  'src/utils/spool-client.mjs liveReader',
  'src/utils/spool-client.mjs sessionMethods',
  'src/utils/tenant-costs.mjs mockPart',
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
    console.log(`  ['${f.key}', ${f.lines}],`)
  }
  process.exit(0)
}

let failed = 0
const fail = (m) => { failed++; console.log(`  FAIL ${m}`) }
if (fns.length < 1000) fail(`scanned only ${fns.length} functions under src: the walk is broken, not the code`)

// checkLong(fns, ceilings) -> { fails, notes, long }: a function over MAX_LINES
// fails unless `ceilings` lists it, and fails above its ceiling.
export function checkLong(fns, ceilings) {
  const fails = []
  const notes = []
  const long = new Map()
  for (const f of fns) {
    if (f.lines <= MAX_LINES) continue
    long.set(f.key, f.lines)
    const cap = ceilings.get(f.key)
    if (cap === undefined) fails.push(`${f.key} is ${f.lines} lines (> ${MAX_LINES}): split it into named steps (or add it to LONG with a reason in the commit)`)
    else if (f.lines > cap) fails.push(`${f.key} is ${f.lines} lines, over its LONG ceiling ${cap}: split it into named steps, never raise the ceiling`)
  }
  for (const [k, cap] of ceilings) {
    const lines = long.get(k)
    if (lines === undefined) notes.push(`NOTE LONG: '${k}' is no longer over ${MAX_LINES} lines - delete its line`)
    else if (lines < cap) notes.push(`NOTE LONG: '${k}' is ${lines} lines, under its ceiling ${cap} - lower the ceiling to ${lines}`)
  }
  return { fails, notes, long }
}

// checkWide(fns, wide) -> { fails, notes }: a function over MAX_PARAMS fails
// unless `wide` lists it, and a listed one fails above WIDE_CAP.
export function checkWide(fns, wide) {
  const fails = []
  const notes = []
  const over = new Set()
  for (const f of fns) {
    if (f.params <= MAX_PARAMS) continue
    over.add(f.key)
    if (!wide.has(f.key)) fails.push(`${f.key} takes ${f.params} parameters (> ${MAX_PARAMS}): pass the object they belong to`)
    else if (f.params > WIDE_CAP) fails.push(`${f.key} takes ${f.params} parameters, over its WIDE cap ${WIDE_CAP}: pass the object they belong to`)
  }
  for (const k of wide) {
    if (!over.has(k)) notes.push(`NOTE WIDE: '${k}' no longer takes more than ${MAX_PARAMS} parameters - delete its line`)
  }
  return { fails, notes }
}

const { fails: longFails, notes, long } = checkLong(fns, LONG)
for (const m of longFails) fail(m)
for (const m of notes) console.log(`  ${m}`)
const { fails: wideFails, notes: wideNotes } = checkWide(fns, WIDE)
for (const m of wideFails) fail(m)
for (const m of wideNotes) console.log(`  ${m}`)
for (const f of fns) {
  if (f.depth > MAX_DEPTH) fail(`${f.key} nests ${f.depth} levels (> ${MAX_DEPTH}): extract the inner body`)
}

// Controls: the measures must see what they claim to.
const probe = ts.createSourceFile('p.ts', 'function f(a,b){ if(a){ for(;;){ while(b){ switch(a){ case 1: try{}catch{} } } } } }', ts.ScriptTarget.Latest, true)
const pf = probe.statements[0]
if (depthOf(pf.body, 0) !== 5 || pf.parameters.length !== 2) fail(`control: depth/params of a known function read ${depthOf(pf.body, 0)}/${pf.parameters.length}, want 5/2`)

// Red control (r5-06): a listed function one line over its ceiling fails, at the
// ceiling passes, one line under prints the NOTE to lower it.
const grown = (lines) => checkLong([{ key: 'g.ts g', lines }], new Map([['g.ts g', 90]]))
if (grown(91).fails.length !== 1) fail('control: a listed function grown 1 line past its ceiling did not fail')
if (grown(90).fails.length || grown(90).notes.length) fail('control: a listed function at its ceiling did not pass clean')
if (grown(89).fails.length || !grown(89).notes.some((n) => n.includes('lower the ceiling to 89'))) fail('control: a listed function under its ceiling printed no NOTE')

// Red control (r26-02): an unlisted function over MAX_PARAMS fails, a listed one
// passes up to WIDE_CAP and fails past it, a stale entry prints the NOTE.
const wide = (params, list) => checkWide([{ key: 'w.ts w', params }], new Set(list))
if (wide(MAX_PARAMS + 1, []).fails.length !== 1) fail('control: an unlisted function over MAX_PARAMS did not fail')
if (wide(WIDE_CAP, ['w.ts w']).fails.length || wide(WIDE_CAP, ['w.ts w']).notes.length) fail('control: a listed function at WIDE_CAP did not pass clean')
if (wide(WIDE_CAP + 1, ['w.ts w']).fails.length !== 1) fail('control: a listed function past WIDE_CAP did not fail')
if (!wide(MAX_PARAMS, ['w.ts w']).notes.some((n) => n.includes('delete its line'))) fail('control: a stale WIDE entry printed no NOTE')

console.log(failed
  ? `\ncleancode: ${failed} FAILED`
  : `cleancode: ${fns.length} functions, ${long.size} listed long, ${WIDE.size} listed wide, none deeper than ${MAX_DEPTH} or wider than ${MAX_PARAMS}`)
process.exit(failed ? 1 : 0)
