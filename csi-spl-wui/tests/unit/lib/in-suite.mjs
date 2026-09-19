// Shared check: will `pnpm test` actually run this test file?
//
// Before B6 each suite answered that by grepping its own filename out of the
// `&&` chain in package.json — 22 near-identical copies of the same block,
// and the check could only ever fail after someone had already forgotten.
//
// The chain is gone: `pnpm test` runs a runner that discovers
// tests/unit/*.test.mjs from disk. So membership now depends on two things,
// which is what this helper verifies:
//   1. the file sits in tests/unit and is named *.test.mjs (the glob finds it)
//   2. package.json test + test:unit still delegate to that runner
//
// Whole-suite coverage is guarded centrally by unit-runner-coverage.test.mjs.
//
// Usage (adapt to the caller's own pass/fail helper):
//   import { runsInUnitSuite } from './lib/in-suite.mjs'
//   const s = runsInUnitSuite(import.meta.url)
//   s.ok ? pass('pnpm test runs this suite') : fail('pnpm test runs this suite', s.why)
import { readFileSync, readdirSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const RUNNER = 'src/node/test/run-unit-tests.mjs'

export function runsInUnitSuite(testFileUrl) {
  const file = basename(fileURLToPath(testFileUrl))
  const unitDir = dirname(fileURLToPath(import.meta.url)) // tests/unit/lib
  const testsUnit = join(unitDir, '..')
  const wui = join(testsUnit, '../..')

  if (!file.endsWith('.test.mjs')) {
    return { ok: false, why: `${file} is not named *.test.mjs, so the runner skips it` }
  }

  const present = readdirSync(testsUnit).includes(file)
  if (!present) {
    return { ok: false, why: `${file} is not in tests/unit, so the runner cannot discover it` }
  }

  let pkg
  try {
    pkg = JSON.parse(readFileSync(join(wui, 'package.json'), 'utf8'))
  } catch (err) {
    return { ok: false, why: `package.json unreadable: ${err.message}` }
  }

  for (const script of ['test', 'test:unit']) {
    const cmd = String(pkg.scripts?.[script] || '')
    if (!cmd.includes(RUNNER)) {
      return { ok: false, why: `package.json scripts["${script}"] does not delegate to ${RUNNER}` }
    }
  }

  return { ok: true, why: '' }
}
