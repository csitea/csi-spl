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
// Usage:
//   node src/node/test/run-unit-tests.mjs              # whole suite
//   node src/node/test/run-unit-tests.mjs admin order  # only matching names
//   node src/node/test/run-unit-tests.mjs --list       # print paths, run none
//   FAIL_FAST=1 node src/node/test/run-unit-tests.mjs  # stop at first failure
import { readdirSync, existsSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
const UNIT_DIR = join(WUI, 'tests/unit')

const argv = process.argv.slice(2)
const listOnly = argv.includes('--list')
const filters = argv.filter((a) => !a.startsWith('--'))
const failFast = process.env.FAIL_FAST === '1'

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

if (listOnly) {
  for (const f of selected) console.log(relative(WUI, join(UNIT_DIR, f)))
  process.exit(0)
}

console.log(`unit runner: ${selected.length} of ${discovered.length} discovered test file(s)\n`)

const failures = []
for (const [i, file] of selected.entries()) {
  console.log(`──[${i + 1}/${selected.length}] ${file}`)
  const res = spawnSync(process.execPath, [join(UNIT_DIR, file)], {
    cwd: WUI,
    stdio: 'inherit',
  })
  // A killing signal (OOM, timeout) leaves status null — that is a failure too.
  const ok = res.status === 0
  if (!ok) {
    failures.push({ file, status: res.status, signal: res.signal })
    if (failFast) break
  }
  console.log('')
}

if (failures.length) {
  console.log(`\nunit runner: ${failures.length} of ${selected.length} file(s) FAILED`)
  for (const f of failures) {
    console.log(`  FAIL ${f.file}${f.signal ? ` (signal ${f.signal})` : ` (exit ${f.status})`}`)
  }
  process.exit(1)
}

console.log(`\nunit runner: all ${selected.length} file(s) passed`)
