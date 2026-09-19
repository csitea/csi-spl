// Guards the WUI unit gate itself: every tests/unit/*.test.mjs on disk must be
// executed by `pnpm test`.
//
// Ported from the donor WUI. The runner discovers files, and this test makes
// sure nobody quietly reintroduces a hardcoded list — a green gate that runs
// a subset is worse than a red one.
//
// Run: node tests/unit/unit-runner-coverage.test.mjs
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const REPO = join(WUI, '..')

let failed = 0
const pass = (n) => console.log(`  OK   ${n}`)
const fail = (n, m) => { failed++; console.log(`  FAIL ${n}: ${m}`) }

console.log('unit-runner-coverage (the gate that guards the gate)')

const RUNNER_REL = 'src/node/test/run-unit-tests.mjs'
const runnerPath = join(WUI, RUNNER_REL)

if (!existsSync(runnerPath)) {
  fail('runner exists', RUNNER_REL)
} else {
  pass('runner exists')

  const src = readFileSync(runnerPath, 'utf8')

  // The whole point: discovery, not a list.
  if (/readdirSync/.test(src)) pass('runner discovers files from disk')
  else fail('runner discovers files from disk', 'no readdirSync in the runner')

  // An empty discovery must fail loudly — a glob that matches nothing is the
  // one way a discovering runner can turn into a green no-op.
  if (/length === 0/.test(src) && /process\.exit\(1\)/.test(src)) {
    pass('runner refuses to pass on an empty discovery')
  } else {
    fail('runner refuses to pass on an empty discovery', 'no empty-set guard found')
  }
}

// --- package.json must delegate to the runner, both scripts -----------------
const pkg = JSON.parse(readFileSync(join(WUI, 'package.json'), 'utf8'))

for (const script of ['test', 'test:unit']) {
  const cmd = pkg.scripts?.[script] ?? ''
  if (!cmd) { fail(`scripts.${script} exists`, 'missing'); continue }

  if (cmd.includes(RUNNER_REL)) pass(`scripts.${script} delegates to the runner`)
  else fail(`scripts.${script} delegates to the runner`, `got: ${cmd.slice(0, 120)}`)

  // No creeping back to a hand-maintained chain.
  if (/tests\/unit\/[\w.-]+\.test\.mjs/.test(cmd)) {
    fail(`scripts.${script} names no individual test`, 'hardcoded test path found — use discovery')
  } else {
    pass(`scripts.${script} names no individual test`)
  }
}

// --- the runner really does see every file on disk --------------------------
const onDisk = readdirSync(join(WUI, 'tests/unit'))
  .filter((f) => f.endsWith('.test.mjs'))
  .sort()

const listed = spawnSync(process.execPath, [runnerPath, '--list'], {
  cwd: WUI,
  encoding: 'utf8',
})

if (listed.status !== 0) {
  fail('runner --list succeeds', `exit ${listed.status}: ${(listed.stderr || '').trim()}`)
} else {
  pass('runner --list succeeds')

  const discovered = (listed.stdout || '')
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => l.split('/').pop())
    .sort()

  const missed = onDisk.filter((f) => !discovered.includes(f))
  if (missed.length) fail('every test file on disk is discovered', `not run: ${missed.join(', ')}`)
  else pass(`every test file on disk is discovered (${onDisk.length})`)

  const ghosts = discovered.filter((f) => !onDisk.includes(f))
  if (ghosts.length) fail('runner lists nothing that is absent', ghosts.join(', '))
  else pass('runner lists nothing that is absent')

  // This very file must be in the set, or the guard is guarding nothing.
  if (discovered.includes('unit-runner-coverage.test.mjs')) pass('the guard itself is in the suite')
  else fail('the guard itself is in the suite', 'unit-runner-coverage.test.mjs not discovered')
}

// --- CI must keep calling the script, not the files -------------------------
const wf = join(REPO, '.github/workflows/10_ci-quality.yml')
if (!existsSync(wf)) {
  fail('10_ci-quality.yml exists', wf)
} else {
  pass('10_ci-quality.yml exists')
  const y = readFileSync(wf, 'utf8')
  // Match the INVOCATION, anchored per line, so prose that merely mentions
  // the command cannot keep this green after the gate is deleted.
  const invokesUnitSuite = /^[ \t]*(?:-[ \t]*)?(?:run:[ \t]*)?pnpm (?:run )?test(?::unit)?\b/m.test(y)
  if (invokesUnitSuite) pass('CI unit gate still runs the unit suite')
  else fail('CI unit gate still runs the unit suite', 'the quality workflow no longer calls pnpm test:unit')
}

console.log('')
if (failed) {
  console.log(`unit-runner-coverage: ${failed} check(s) FAILED`)
  process.exit(1)
}
console.log('All unit-runner-coverage checks passed.')
