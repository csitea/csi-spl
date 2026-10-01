// WUI browser-e2e runner — runs EVERY listed file, fails at the end.
//
// Why this exists: `test:e2e` used to be one `node a && node b && …` chain of
// ~45 files, so the first red stopped it and every file after it never ran.
// On 2026-10-01 move-by-drag went red and the ~20 files behind it went
// unexercised for hours (CLE-77827): one red hid all the others.
//
// The list stays explicit (it is the CI pick, not every *.test.mjs on disk —
// many e2e files are opt-in or need a live hub), and it stays in package.json.
//
// Contract (`10_ci-quality.yml` / `11_ci-public.yml` run `pnpm run test:e2e`):
//   • every listed file runs, in order, whatever the ones before it did
//   • exit 0 only when every file exits 0
//   • exit 1 when any file fails, when a listed file is missing, or when the
//     list is empty — an empty run must never read as a pass
//   • the last lines name every failed file, so the job log says it once
//
// Usage:
//   node src/node/test/run-e2e-tests.mjs tests/e2e/a.test.mjs tests/e2e/b.test.mjs
//   FAIL_FAST=1 node src/node/test/run-e2e-tests.mjs …   # stop at first failure
import { existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')

const files = process.argv.slice(2)
const failFast = process.env.FAIL_FAST === '1'

if (files.length === 0) {
  console.error('e2e runner: no test files given — refusing to pass')
  process.exit(1)
}

const missing = files.filter((f) => !existsSync(join(WUI, f)))
if (missing.length) {
  console.error(`e2e runner: listed file(s) not found: ${missing.join(', ')}`)
  process.exit(1)
}

console.log(`e2e runner: ${files.length} file(s)\n`)

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
