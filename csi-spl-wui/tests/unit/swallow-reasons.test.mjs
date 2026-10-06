// Refactor round 3, row 20: every bare `.catch(() => {})` in csi-spl-wui/src
// says why the swallow is safe, so a deliberate swallow does not read like a
// forgotten error path. A swallow passes when a comment sits on its own line,
// or on the line above the run of swallow lines it belongs to (two warm-up
// imports under one comment pass together).
//
// Do NOT fix a site by reporting the error instead: chunk-reload.client.ts and
// error-journal.client.ts listen to `unhandledrejection` and would see new
// events. Write the reason.
//
// UNCOMMENTED is what had no reason when the gate landed: `<file>` -> how many
// such swallows it may still hold. It may only shrink: give one a reason and
// lower its number; a NEW bare swallow fails. A number above today's count is
// reported so it can come down.
//
// Run: node tests/unit/swallow-reasons.test.mjs
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const SRC = join(WUI, 'src')
const SWALLOW = '.catch(() => {})'

// Measured on trunk 2026-10-06 after round 4 row 06 gave its five files a reason.
const UNCOMMENTED = new Map([
  ['src/composables/usePaneWidths.ts', 1],
  ['src/plugins/pwa.client.ts', 1],
  ['src/public/sw.js', 1],
  ['src/utils/move-apply.mjs', 3],
])

// The reasoned sites of round 3 row 20 and round 4 row 06: they must stay
// reasoned (never re-enter the list).
const REASONED = [
  'src/composables/useArchiveUndo.ts',
  'src/utils/read-sync-boot.ts',
  'src/plugins/0.boot-early.client.ts',
  'src/utils/flow-badge.mjs',
  'src/utils/early-session.mjs',
  // round 4 row 06
  'src/utils/notify.mjs',
  'src/composables/useChannelOrder.ts',
  'src/components/DeadlinePicker.vue',
  'src/composables/useMobileStack.ts',
  'src/stores/notification.ts',
]

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (/\.(ts|mjs|js|vue)$/.test(e.name) && !e.name.endsWith('.d.ts')) out.push(p)
  }
  return out
}

const isComment = (line) => {
  const t = line.trim()
  return t.startsWith('//') || t.startsWith('/*') || t.startsWith('*') || t.endsWith('*/')
}
const hasTrailingComment = (line) => {
  const at = line.indexOf(SWALLOW)
  const rest = line.slice(at + SWALLOW.length)
  return rest.includes('//') || rest.includes('/*')
}

/** The swallows in `text` with no reason: their 1-based line numbers. */
function bareSwallows(text) {
  const lines = text.split('\n')
  const bare = []
  lines.forEach((line, i) => {
    if (!line.includes(SWALLOW) || hasTrailingComment(line)) return
    let j = i - 1
    while (j >= 0 && lines[j].includes(SWALLOW) && !isComment(lines[j])) j--
    if (j < 0 || !isComment(lines[j])) bare.push(i + 1)
  })
  return bare
}

let failed = 0
const pass = (n) => console.log('  OK  ', n)
const fail = (n, m) => { failed++; console.log('  FAIL', n + ':', m) }

// The rule itself, on fixtures.
const cases = [
  ['// why\nx.catch(() => {})', 0, 'a comment on the line above'],
  ['x.catch(() => {}) // why', 0, 'a comment on the same line'],
  ['/* why\n   more */\nx.catch(() => {})', 0, 'a block comment ending above'],
  ['// why\na.catch(() => {})\nb.catch(() => {})', 0, 'a run of swallows under one comment'],
  ['x.catch(() => {})', 1, 'no comment'],
  ['// why\nfoo()\nx.catch(() => {})', 1, 'a comment two lines up is not its reason'],
  ['x.catch((e) => log(e))', 0, 'a handler that does something is not a swallow'],
]
for (const [text, want, name] of cases) {
  const got = bareSwallows(text).length
  got === want ? pass(name) : fail(name, `got ${got} bare, want ${want}`)
}

// The tree.
const seen = new Map()
let total = 0
for (const p of walk(SRC)) {
  const text = readFileSync(p, 'utf8')
  if (!text.includes(SWALLOW)) continue
  const rel = relative(WUI, p)
  total += text.split(SWALLOW).length - 1
  const bare = bareSwallows(text)
  if (bare.length) seen.set(rel, bare)
}
if (total > 0) pass(`found ${total} swallow(s) in src/`)
else fail('found swallows', 'none: the walk or the pattern is broken')

for (const [rel, bare] of seen) {
  const allowed = UNCOMMENTED.get(rel) || 0
  if (bare.length > allowed) fail(rel, `line(s) ${bare.join(', ')} swallow with no reason (allowed ${allowed}): add a one-line comment saying why`)
}
for (const [rel, allowed] of UNCOMMENTED) {
  const n = (seen.get(rel) || []).length
  if (n < allowed) fail(rel, `UNCOMMENTED says ${allowed}, the file holds ${n}: lower its number`)
}
for (const rel of REASONED) {
  if (UNCOMMENTED.has(rel)) fail(rel, 'a reasoned site is back on the allow-list')
  const text = readFileSync(join(WUI, rel), 'utf8')
  text.includes(SWALLOW) ? pass(`${rel} keeps its reasoned swallow`) : fail(rel, 'the swallow is gone: was it replaced by reporting?')
}
if (!failed) pass('every new swallow says why')

if (failed) {
  console.log(`\n${failed} failed`)
  process.exit(1)
}
console.log('\nall passed')
