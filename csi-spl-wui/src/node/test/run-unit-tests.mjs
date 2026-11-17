// WUI unit-suite runner — discovers tests instead of hardcoding them.
//
// Why this exists: `package.json` used to carry the whole suite twice as a
// ~10 000-character `node a.test.mjs && node b.test.mjs && …` chain, once for
// `test` and once for `test:unit`. Adding a test meant hand-editing both
// lists, and forgetting was silent — the file sat on disk and the CI gate
// never ran it.
//
// Discovery removes the failure mode by construction: every
// tests/unit/*.test.mjs on disk runs, the moment it lands.
//
// Contract (`10_ci-quality.yml` runs `pnpm run test:unit`):
//   • exit 0 only when every discovered file exits 0
//   • exit 1 when any file fails, when none is discovered, or when the
//     directory is missing — an empty run must never read as a pass
//
// The files run N at a time (p14-01: 524 files took ~550 s one by one and
// ~125 s four at a time). Each file's stdout and stderr are buffered and
// printed whole, in the sorted order, under its `──[i/n] file` header, so the
// log reads as the serial run's. WUI_UNIT_JOBS=1 is the serial loop, output
// streamed live as before.
//
// Usage:
//   node src/node/test/run-unit-tests.mjs              # whole suite
//   node src/node/test/run-unit-tests.mjs admin order  # only matching names
//   node src/node/test/run-unit-tests.mjs --list       # print paths, run none
//   FAIL_FAST=1 node src/node/test/run-unit-tests.mjs  # start no file after the first failure
//   WUI_UNIT_JOBS=<n>                                  # files at once; default min(4, cpus)
//   WUI_UNIT_DIR=<dir>                                 # test dir; default tests/unit (for the runner's own test)
import { readdirSync, existsSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn, spawnSync } from 'node:child_process'
import { availableParallelism } from 'node:os'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
const UNIT_DIR = process.env.WUI_UNIT_DIR || join(WUI, 'tests/unit')

const argv = process.argv.slice(2)
const listOnly = argv.includes('--list')
const filters = argv.filter((a) => !a.startsWith('--'))
const failFast = process.env.FAIL_FAST === '1'

// A value that is not a whole number >= 1 is refused, never read as a default.
function unitJobs() {
  const raw = process.env.WUI_UNIT_JOBS
  if (raw === undefined || raw === '') return Math.min(4, availableParallelism())
  if (!/^[1-9][0-9]*$/.test(raw)) {
    console.error(`unit runner: WUI_UNIT_JOBS must be a whole number >= 1, got "${raw}"`)
    process.exit(1)
  }
  return Number(raw)
}
const jobs = unitJobs()

if (!existsSync(UNIT_DIR)) {
  console.error(`unit runner: tests directory not found: ${UNIT_DIR}`)
  process.exit(1)
}

// Sorted so a failure is reproducible in the same order on every machine.
const discovered = readdirSync(UNIT_DIR)
  .filter((f) => f.endsWith('.test.mjs'))
  .sort()

if (discovered.length === 0) {
  console.error(`unit runner: no *.test.mjs found in ${UNIT_DIR} — refusing to pass`)
  process.exit(1)
}

const selected = filters.length
  ? discovered.filter((f) => filters.some((s) => f.includes(s)))
  : discovered

if (selected.length === 0) {
  console.error(`unit runner: filter [${filters.join(', ')}] matched none of ${discovered.length} files`)
  process.exit(1)
}

// One write, and exit only once it is out: exit right after one console.log
// per file dropped the async-queued tail for a reader slow to drain (the
// same defect as run-e2e-tests.mjs --list, e2e-shard-pack.test.mjs).
if (listOnly) {
  await new Promise((resolve) => process.stdout.write(selected.map((f) => `${relative(WUI, join(UNIT_DIR, f))}\n`).join(''), resolve))
  process.exit(0)
}

const header = (i, file) => `──[${i + 1}/${selected.length}] ${file}`

// The serial loop (WUI_UNIT_JOBS=1): each file streams to the terminal live.
function runSerial() {
  const results = []
  for (const [i, file] of selected.entries()) {
    console.log(header(i, file))
    const res = spawnSync(process.execPath, [join(UNIT_DIR, file)], {
      cwd: WUI,
      stdio: 'inherit',
    })
    results.push({ i, file, status: res.status, signal: res.signal })
    console.log('')
    if (res.status !== 0 && failFast) break
  }
  return results
}

// One file in the pool: stdout and stderr land in one buffer in arrival order,
// the way `stdio: 'inherit'` interleaved them on the terminal.
function runBuffered(i, file) {
  return new Promise((resolve) => {
    const chunks = []
    const child = spawn(process.execPath, [join(UNIT_DIR, file)], {
      cwd: WUI,
      stdio: ['inherit', 'pipe', 'pipe'],
    })
    child.stdout.on('data', (c) => chunks.push(c))
    child.stderr.on('data', (c) => chunks.push(c))
    child.on('error', (err) => chunks.push(Buffer.from(`unit runner: spawn failed: ${err.message}\n`)))
    child.on('close', (status, signal) => {
      resolve({ i, file, status, signal, output: Buffer.concat(chunks) })
    })
  })
}

function printResult(r) {
  console.log(header(r.i, r.file))
  if (r.output.length) process.stdout.write(r.output)
  console.log('')
}

// The pool: `jobs` files at once, the next one starts when one ends. Results
// print in the sorted order as soon as every file before them is done. With
// FAIL_FAST=1 no file starts after the first failure; those already running
// finish and are reported.
async function runPool() {
  const done = new Array(selected.length)
  let next = 0
  let printed = 0
  let stop = false
  const flush = () => {
    while (printed < selected.length && done[printed]) printResult(done[printed++])
  }
  async function worker() {
    while (!stop && next < selected.length) {
      const i = next++
      const r = await runBuffered(i, selected[i])
      done[i] = r
      if (r.status !== 0 && failFast) stop = true
      flush()
    }
  }
  await Promise.all(Array.from({ length: Math.min(jobs, selected.length) }, worker))
  // FAIL_FAST can leave a gap (a file never started): print what ran after it.
  for (let i = printed; i < selected.length; i++) if (done[i]) printResult(done[i])
  return done.filter(Boolean)
}

console.log(`unit runner: ${selected.length} of ${discovered.length} discovered test file(s), ${jobs} at a time\n`)

const results = jobs === 1 ? runSerial() : await runPool()
// A killing signal (OOM, timeout) leaves status null — that is a failure too.
const failures = results.filter((r) => r.status !== 0)

if (failures.length) {
  console.log(`\nunit runner: ${failures.length} of ${selected.length} file(s) FAILED`)
  for (const f of failures) {
    console.log(`  FAIL ${f.file}${f.signal ? ` (signal ${f.signal})` : ` (exit ${f.status})`}`)
  }
  process.exit(1)
}

console.log(`\nunit runner: all ${selected.length} file(s) passed`)
