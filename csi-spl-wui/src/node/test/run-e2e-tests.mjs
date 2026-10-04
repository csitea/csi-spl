// WUI browser-e2e runner — discovers tests instead of hardcoding them.
//
// Why this exists, twice over:
//   • `test:e2e` used to be one `node a && node b && …` chain, so the first
//     red stopped it and every file after it never ran (CLE-77827).
//   • Then it was an explicit list in package.json, plus ~95
//     `test:e2e:<name>` scripts, plus a script loop in workflows 10 and 11.
//     48 lanes edited package.json in the 72 h before 2026-10-01 to add one
//     line each, and a file nobody listed never ran: local-time and
//     open-parent-section sat on disk unexercised, and the script
//     `node a.test.mjs b.test.mjs` only ever ran a (CLE-77915).
//
// Discovery removes that failure mode by construction: every
// tests/e2e/*.test.mjs on disk runs, the moment it lands, unless
// tests/e2e/ci-skip.txt names it with a reason (live hub, credentials,
// Hosting headers). *.proof.mjs files are never discovered — they drive live
// sites.
//
// Contract (`10_ci-quality.yml` / `11_ci-public.yml` run `pnpm run test:e2e`):
//   • every selected file runs, in sorted order, whatever the ones before did
//   • exit 0 only when every file exits 0
//   • exit 1 when any file fails, when nothing is selected, when a path given
//     is missing, or when a ci-skip.txt line names no file on disk or gives
//     no reason — an empty run must never read as a pass
//   • the last lines name every failed file, so the job log says it once
//
// Usage:
//   node src/node/test/run-e2e-tests.mjs                     # the CI suite
//   node src/node/test/run-e2e-tests.mjs msg-edit csp        # names containing these (skipped ones too)
//   node src/node/test/run-e2e-tests.mjs tests/e2e/a.test.mjs # exact paths
//   node src/node/test/run-e2e-tests.mjs --list              # print the selection, run none
//   FAIL_FAST=1 node src/node/test/run-e2e-tests.mjs         # stop at first failure
//   E2E_SHARD=2/3 node src/node/test/run-e2e-tests.mjs       # the 2nd of 3 round-robin shards
//   E2E_LOCAL_SLOTS=1 node src/node/test/run-e2e-tests.mjs   # box-wide cap on local runs (default 2, e2e-slots.mjs)
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { acquireSlot } from './e2e-slots.mjs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
const E2E_REL = 'tests/e2e'
const SKIP_REL = `${E2E_REL}/ci-skip.txt`

const argv = process.argv.slice(2)
const listOnly = argv.includes('--list')
const args = argv.filter((a) => !a.startsWith('--'))
const paths = args.filter((a) => a.includes('/'))
const filters = args.filter((a) => !a.includes('/'))
const failFast = process.env.FAIL_FAST === '1'

const die = (msg) => {
  console.error(`e2e runner: ${msg}`)
  process.exit(1)
}

// Sorted so a failure is reproducible in the same order on every machine.
const discovered = existsSync(join(WUI, E2E_REL))
  ? readdirSync(join(WUI, E2E_REL)).filter((f) => f.endsWith('.test.mjs')).sort().map((f) => `${E2E_REL}/${f}`)
  : []
if (discovered.length === 0) die(`no *.test.mjs found in ${E2E_REL} — refusing to pass`)

// ci-skip.txt: `<file name> <reason>` per line, `#` comments. A stale line is
// an error, not a no-op: it would hide the file that replaced it.
const skipped = new Set()
if (existsSync(join(WUI, SKIP_REL))) {
  for (const raw of readFileSync(join(WUI, SKIP_REL), 'utf8').split('\n')) {
    const line = raw.replace(/#.*/, '').trim()
    if (!line) continue
    const [name, ...reason] = line.split(/\s+/)
    if (!reason.length) die(`${SKIP_REL}: "${name}" gives no reason`)
    if (!discovered.includes(`${E2E_REL}/${name}`)) die(`${SKIP_REL}: "${name}" is not a file in ${E2E_REL}`)
    skipped.add(`${E2E_REL}/${name}`)
  }
}

// E2E_SKIP: more names to leave out of THIS run only, space-separated, same
// rule as a ci-skip.txt line (must exist). Workflow 11 sets it for a check
// whose verdict depends on the hosted runner's fonts; the workflow carries
// the reason next to it.
for (const name of (process.env.E2E_SKIP || '').split(/\s+/).filter(Boolean)) {
  if (!discovered.includes(`${E2E_REL}/${name}`)) die(`E2E_SKIP: "${name}" is not a file in ${E2E_REL}`)
  skipped.add(`${E2E_REL}/${name}`)
}

let files
if (paths.length) {
  const missing = paths.filter((f) => !existsSync(join(WUI, f)))
  if (missing.length) die(`file(s) not found: ${missing.join(', ')}`)
  files = paths
} else if (filters.length) {
  files = discovered.filter((f) => filters.some((s) => f.slice(E2E_REL.length + 1).includes(s)))
  if (files.length === 0) die(`filter [${filters.join(', ')}] matched none of ${discovered.length} files`)
} else {
  files = discovered.filter((f) => !skipped.has(f))
  if (files.length === 0) die('every discovered file is in ci-skip.txt — refusing to pass')
}

// E2E_SHARD=<i>/<n>: run only every n-th file of the selection, starting at
// the i-th (1-based), so workflow 10 splits the suite across n parallel jobs.
// One serial job took 35 min green and hit its 45 min timeout under load,
// so the gate finished once per ~45 min and every push in between was
// cancelled while pending (CLE-77945, 2026-10-02). Round-robin over the
// sorted list keeps the slow mobile-* files spread across shards; the union
// of shards 1..n is exactly the unsharded selection.
const shard = process.env.E2E_SHARD || ''
if (shard) {
  const m = /^(\d+)\/(\d+)$/.exec(shard)
  const [i, n] = m ? [Number(m[1]), Number(m[2])] : [0, 0]
  if (!m || n < 1 || i < 1 || i > n) die(`E2E_SHARD="${shard}" is not <i>/<n> with 1 <= i <= n`)
  files = files.filter((_, k) => k % n === i - 1)
  if (files.length === 0) die(`E2E_SHARD=${shard} selects no file — refusing to pass`)
}

if (listOnly) {
  for (const f of files) console.log(f)
  process.exit(0)
}

// One of E2E_LOCAL_SLOTS box-wide slots before any browser starts: lanes'
// parallel local runs drove a 16-cpu box to load 50. GitHub Actions is not
// capped. Waiting prints the holders; the slot frees on exit, signal or crash.
try {
  await acquireSlot()
} catch (e) {
  die(e.message)
}

const scope = paths.length || filters.length ? '' : ` (${skipped.size} skipped by ${SKIP_REL}${process.env.E2E_SKIP ? ' + E2E_SKIP' : ''})`
console.log(`e2e runner: ${files.length} file(s)${scope}${shard ? `, shard ${shard}` : ''}\n`)

const failures = []
for (const [i, file] of files.entries()) {
  console.log(`──[${i + 1}/${files.length}] ${file}`)
  const started = Date.now()
  const res = spawnSync(process.execPath, [join(WUI, file)], {
    cwd: WUI,
    stdio: 'inherit',
  })
  const secs = Math.round((Date.now() - started) / 1000)
  // A killing signal (OOM, timeout) leaves status null — that is a failure too.
  if (res.status !== 0) {
    failures.push({ file, status: res.status, signal: res.signal })
    console.log(`──[${i + 1}/${files.length}] FAIL ${file} (${secs}s)`)
    if (failFast) break
  }
  console.log('')
}

if (failures.length) {
  console.log(`\ne2e runner: ${failures.length} of ${files.length} file(s) FAILED`)
  for (const f of failures) {
    console.log(`  FAIL ${f.file}${f.signal ? ` (signal ${f.signal})` : ` (exit ${f.status})`}`)
  }
  process.exit(1)
}

console.log(`\ne2e runner: all ${files.length} file(s) passed`)
