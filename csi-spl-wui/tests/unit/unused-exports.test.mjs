// The WUI unused-exports ratchet (r13-08): an export that no other file names
// is dead API surface. It reads as shared and tested from outside, and it
// keeps code alive that nothing calls.
//
//   • an export of src/composables/*.{ts,mjs} or src/utils/*.{mjs,ts} whose
//     name appears in no other file under src/, tests/ or nuxt.config.ts
//     fails, unless ALLOW lists it
//   • a listed export that is now used, unexported or gone is reported, so
//     its entry is deleted; ALLOW may only shrink (ALLOW_CAP)
//
// An export = a line `export [async] function|const|class|let|var <name>`.
// "Names it" = the identifier appears as a whole word in the file's text
// (an import, a property access such as `data.MOCK_CLONES`, a Nuxt auto-
// import), so a hit is never missed; a mention in a comment also counts.
//
// Fix a failure: drop the `export` keyword (or delete the dead code), never
// add the name to ALLOW.
//
// Run: node tests/unit/unused-exports.test.mjs
//      UNUSED_EXPORTS_PRINT=1 node tests/unit/unused-exports.test.mjs   # print today's unused set
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const SELF = relative(WUI, fileURLToPath(import.meta.url))

const DEF_DIRS = [['src/composables', /\.(ts|mjs)$/], ['src/utils', /\.(mjs|ts)$/]]

// `<file>` -> its exports with no user outside the file, measured on
// origin/master 2026-10-19 (r13-08) after the top 5 files were cleaned:
// 107 before, 76 then; r14-08 (2026-10-20) cleaned the next 4 files and
// dropped 2 names now used: 54; r15-09 (2026-10-21) cleaned 9 files of 2
// names each: 35. It may only shrink: delete a name when its export goes.
const ALLOW = new Map([
  ['src/composables/useIssueColumns.ts', ['ISSUE_COLUMNS_SAVE_MS']],
  ['src/composables/useLive.ts', ['AS_KEY']],
  ['src/composables/usePaletteItems.ts', ['PALETTE_GROUPS']],
  ['src/composables/useRealmHours.ts', ['useRealmHours']],
  ['src/composables/useSettledQuery.ts', ['firstQueryValue']],
  ['src/utils/auth-client.mjs', ['PROVIDERS_TIMEOUT_MS']],
  ['src/utils/await-reply.mjs', ['DEFAULT_AWAIT_MINUTES']],
  ['src/utils/card-element.mjs', ['CARD_SDK_URL']],
  ['src/utils/code-blocks.mjs', ['wikiRegions']],
  ['src/utils/dm-seed.mjs', ['SEED_WAIT_MS']],
  ['src/utils/doc-path-install.ts', ['installDocPaths']],
  ['src/utils/fleet-load.mjs', ['FLEET_BOX_RE']],
  ['src/utils/highlighter.mjs', ['loadAutodetectGrammars']],
  ['src/utils/hours-calendar.mjs', ['hoursRowCounts']],
  ['src/utils/hours-team-mock.mjs', ['HOURS_TEAM_MOCK_MEMBERS']],
  ['src/utils/human-keys.mjs', ['sshKeyBlob']],
  ['src/utils/id-links.mjs', ['resolveTyped']],
  ['src/utils/join-tokens.mjs', ['normalizeJoinToken']],
  ['src/utils/msg-kind.mjs', ['KIND_ICONS']],
  ['src/utils/perf-mark.mjs', ['perfCache']],
  ['src/utils/perf-summary.mjs', ['PERF_P95_MIN_N']],
  ['src/utils/poll.mjs', ['LOCK_SECONDS_PER_QUESTION']],
  ['src/utils/public-calendar.mjs', ['pubCalMonthOf']],
  ['src/utils/pwa-install.mjs', ['isStandalone']],
  ['src/utils/read-sync.mjs', ['PUSH_MS']],
  ['src/utils/roadmap-rows.mjs', ['ROADMAP_WHEN']],
  ['src/utils/sidebar-row-menu.mjs', ['HIDDEN_PEERS_KEY']],
  ['src/utils/signed-out-redirect.mjs', ['isExemptScreen']],
  ['src/utils/spool-client.mjs', ['PER_TOPIC_MAX']],
  ['src/utils/spool-client-mock.mjs', ['mockPersonName']],
  ['src/utils/tenant-host-boot.mjs', ['PENDING_POLL_MS']],
  ['src/utils/tenant-settings-nav.ts', ['FLEET_LOAD_SECTION']],
  ['src/utils/topic-open.mjs', ['TOPIC_PANE_OWN_CLICK']],
  ['src/utils/tree-drag.ts', ['TREE_DROP_EDGE']],
])
const ALLOW_CAP = 34

function walk(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.name === 'node_modules' || e.name.startsWith('.')) continue
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}

// exportsOf(text) -> the names its export declarations define.
export function exportsOf(text) {
  return [...text.matchAll(/^export\s+(?:async\s+)?(?:function\*?|const|class|let|var)\s+([A-Za-z0-9_$]+)/gm)].map((m) => m[1])
}

// wordsOf(text) -> every identifier-like word in it.
export function wordsOf(text) {
  return new Set(text.match(/[A-Za-z0-9_$]+/g) || [])
}

// checkExports(defs, words, allow) -> { fails, notes, unused }.
// defs: [{ file, names }]; words: Map file -> Set of words (every file that
// may name an export, the defining files included).
export function checkExports(defs, words, allow) {
  const fails = []
  const notes = []
  const unused = new Map()
  for (const { file, names } of defs) {
    for (const name of names) {
      let used = false
      for (const [f, w] of words) if (f !== file && w.has(name)) { used = true; break }
      if (used) continue
      if (!unused.has(file)) unused.set(file, [])
      unused.get(file).push(name)
      if (!(allow.get(file) || []).includes(name)) fails.push(`${file}: export '${name}' has no user outside its file: drop the export keyword or delete it`)
    }
  }
  for (const [file, names] of allow) {
    for (const name of names) {
      if (!(unused.get(file) || []).includes(name)) notes.push(`NOTE ALLOW: '${file}' '${name}' is no longer an unused export - delete it from ALLOW and lower ALLOW_CAP`)
    }
  }
  return { fails, notes, unused }
}

export function scan() {
  const defs = []
  for (const [dir, ext] of DEF_DIRS) {
    for (const f of readdirSync(join(WUI, dir)).filter((n) => ext.test(n)).sort()) {
      const file = `${dir}/${f}`
      defs.push({ file, names: exportsOf(readFileSync(join(WUI, file), 'utf8')) })
    }
  }
  const words = new Map()
  for (const p of [...walk(join(WUI, 'src')), ...walk(join(WUI, 'tests')), join(WUI, 'nuxt.config.ts')]) {
    const file = relative(WUI, p)
    // ALLOW below names every listed export: this file must not count as a user.
    if (file !== SELF) words.set(file, wordsOf(readFileSync(p, 'utf8')))
  }
  return { defs, words }
}

const { defs, words } = scan()
const { fails, notes, unused } = checkExports(defs, words, ALLOW)
const nUnused = [...unused.values()].reduce((n, a) => n + a.length, 0)
if (process.env.UNUSED_EXPORTS_PRINT) {
  for (const [file, names] of [...unused].sort()) console.log(`  ['${file}', [${names.map((n) => `'${n}'`).join(', ')}]],`)
  console.log(`  -- ${nUnused} unused exports in ${unused.size} files`)
  process.exit(0)
}

let failed = 0
const fail = (m) => { failed++; console.log(`  FAIL ${m}`) }
const nDefs = defs.reduce((n, d) => n + d.names.length, 0)
if (defs.length < 300) fail(`scanned only ${defs.length} composable/util files: the walk is broken, not the code`)
if (nDefs < 2000) fail(`read only ${nDefs} exports: the export regex is broken, not the code`)
if (words.size < 800) fail(`read only ${words.size} files for users: the walk is broken, not the code`)
const nAllow = [...ALLOW.values()].reduce((n, a) => n + a.length, 0)
if (nAllow > ALLOW_CAP) fail(`ALLOW lists ${nAllow} exports, over ALLOW_CAP ${ALLOW_CAP}: it may only shrink`)

for (const m of fails) fail(m)
for (const m of notes) console.log(`  ${m}`)

// Controls: the measure sees what it claims to.
const src = 'export const A = 1\nexport async function b() {}\nexport function* c() {}\nexport class D {}\nconst e = 2\n  export const f = 3\nexport { A as g }\n'
if (exportsOf(src).join(',') !== 'A,b,c,D') fail(`control: exportsOf read [${exportsOf(src)}], not [A,b,c,D]`)
if (!wordsOf('x = m.MOCK_A;').has('MOCK_A')) fail('control: a property access did not count as a word')
if (wordsOf('const MOCK_AB = 1').has('MOCK_A')) fail('control: a longer name counted as the shorter one')

// Red control (r13-08): a new unused `export const` fails; named in another
// file it passes; listed it passes; listed but now used prints the NOTE.
const run = (other, allow = new Map()) => checkExports(
  [{ file: 'src/utils/n.mjs', names: ['NEW_UNUSED'] }],
  new Map([['src/utils/n.mjs', wordsOf('export const NEW_UNUSED = 1')], ['src/x.vue', wordsOf(other)]]),
  allow,
)
if (run('nothing here').fails.length !== 1) fail('control: a new unused export const did not fail')
if (run("import { NEW_UNUSED } from '~/utils/n.mjs'").fails.length) fail('control: an export imported by another file did not pass')
const listed = new Map([['src/utils/n.mjs', ['NEW_UNUSED']]])
if (run('nothing here', listed).fails.length || run('nothing here', listed).notes.length) fail('control: a listed unused export did not pass clean')
if (!run('NEW_UNUSED()', listed).notes.some((n) => n.includes("'NEW_UNUSED' is no longer"))) fail('control: a listed export now used printed no NOTE')

console.log(failed
  ? `\nunused-exports: ${failed} FAILED`
  : `unused-exports: ${nDefs} exports in ${defs.length} files, ${nUnused} unused, all listed in ALLOW (${nAllow} <= cap ${ALLOW_CAP})`)
process.exit(failed ? 1 : 0)
