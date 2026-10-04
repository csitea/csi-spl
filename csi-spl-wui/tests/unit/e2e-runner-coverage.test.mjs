// Guards the WUI browser-e2e gate itself (CLE-77915): every
// tests/e2e/*.test.mjs on disk runs in `pnpm test:e2e` unless
// tests/e2e/ci-skip.txt names it with a reason, and nobody brings back a
// hand-kept list (48 lanes edited package.json in 72 h to add one line each,
// and two files nobody listed never ran).
//
// Run: node tests/unit/e2e-runner-coverage.test.mjs
import { readFileSync, readdirSync, writeFileSync, mkdtempSync, mkdirSync, cpSync, rmSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const REPO = join(WUI, '..')
const RUNNER_REL = 'src/node/test/run-e2e-tests.mjs'
const SLOTS_REL = 'src/node/test/e2e-slots.mjs'
// The throwaway runs below must not take (or wait for) the box's real slots.
process.env.E2E_LOCAL_SLOTS_DIR = mkdtempSync(join(tmpdir(), 'e2e-slots-'))

let failed = 0
const pass = (n) => console.log(`  OK   ${n}`)
const fail = (n, m) => { failed++; console.log(`  FAIL ${n}: ${m}`) }
const check = (n, ok, m) => (ok ? pass(n) : fail(n, m))

console.log('e2e-runner-coverage (the gate that guards the e2e gate)')

// --- package.json: one script, no list, no per-file scripts ------------------
const scripts = JSON.parse(readFileSync(join(WUI, 'package.json'), 'utf8')).scripts ?? {}
check('scripts.test:e2e is the discovering runner', scripts['test:e2e'] === `node ${RUNNER_REL}`, `got: ${scripts['test:e2e']}`)
const perFile = Object.keys(scripts).filter((k) => k.startsWith('test:e2e:'))
check('no per-file test:e2e:<name> scripts (use `pnpm test:e2e <name>`)', perFile.length === 0, perFile.join(', '))
const listed = Object.entries(scripts).filter(([k, v]) => k !== 'test:live' && /tests\/e2e\/[\w.-]+\.test\.mjs/.test(v))
check('no script names an e2e file', listed.length === 0, listed.map(([k]) => k).join(', '))

// --- workflow 10 runs the runner, not a script loop; 11 calls 10 (072 A35) ----
{
  const src = readFileSync(join(REPO, '.github/workflows/11_ci-public.yml'), 'utf8')
  check('11_ci-public.yml calls 10_ci-quality.yml', /^\s*uses: \.\/\.github\/workflows\/10_ci-quality\.yml\s*$/m.test(src), 'no call of workflow 10')
  check('11_ci-public.yml names no test:e2e:<name> script', !/test:e2e:[a-z0-9-]/.test(src), 'a per-file script is back')
}
for (const wf of ['10_ci-quality.yml']) {
  const src = readFileSync(join(REPO, '.github/workflows', wf), 'utf8')
  check(`${wf} runs pnpm run test:e2e`, /pnpm run test:e2e\s*\n/.test(src), 'no bare `pnpm run test:e2e` line')
  check(`${wf} names no test:e2e:<name> script`, !/test:e2e:[a-z0-9-]/.test(src), 'a per-file script is back')
}

// --- the real selection: every file on disk minus ci-skip.txt ----------------
const run = (cwd, ...args) => spawnSync(process.execPath, [join(cwd, RUNNER_REL), ...args], { cwd, encoding: 'utf8' })
const onDisk = readdirSync(join(WUI, 'tests/e2e')).filter((f) => f.endsWith('.test.mjs'))
const skipLines = readFileSync(join(WUI, 'tests/e2e/ci-skip.txt'), 'utf8').split('\n').map((l) => l.replace(/#.*/, '').trim()).filter(Boolean)
const list = run(WUI, '--list')
const selected = list.stdout.trim().split('\n').filter(Boolean)
check('--list exits 0', list.status === 0, list.stderr)
check('selection = on disk - ci-skip.txt', selected.length === onDisk.length - skipLines.length,
  `${selected.length} selected, ${onDisk.length} on disk, ${skipLines.length} skipped`)
check('no .proof.mjs is selected', !selected.some((f) => f.endsWith('.proof.mjs')), 'a proof file was discovered')
check('a filter reaches a skipped file', run(WUI, '--list', 'csp-violations').stdout.includes('csp-violations.test.mjs'), 'filter ignored skipped files')

// --- refusals, on a throwaway copy of the runner ------------------------------
const tmp = mkdtempSync(join(tmpdir(), 'e2e-runner-'))
try {
  mkdirSync(join(tmp, 'src/node/test'), { recursive: true })
  mkdirSync(join(tmp, 'tests/e2e'), { recursive: true })
  cpSync(join(WUI, RUNNER_REL), join(tmp, RUNNER_REL))
  cpSync(join(WUI, SLOTS_REL), join(tmp, SLOTS_REL))

  let r = run(tmp)
  check('empty tests/e2e refuses to pass', r.status === 1 && /refusing to pass/.test(r.stderr), `status ${r.status}`)

  writeFileSync(join(tmp, 'tests/e2e/a.test.mjs'), 'process.exit(0)\n')
  writeFileSync(join(tmp, 'tests/e2e/b.test.mjs'), 'process.exit(3)\n')
  writeFileSync(join(tmp, 'tests/e2e/c.test.mjs'), 'process.exit(0)\n')
  r = run(tmp)
  check('a red file fails the run and the files after it still run',
    r.status === 1 && /1 of 3 file\(s\) FAILED/.test(r.stdout) && /\[3\/3\] tests\/e2e\/c\.test\.mjs/.test(r.stdout), r.stdout)

  writeFileSync(join(tmp, 'tests/e2e/ci-skip.txt'), 'b.test.mjs  reason here\n')
  r = run(tmp)
  check('a skipped red file is not run', r.status === 0 && /all 2 file\(s\) passed/.test(r.stdout), r.stdout + r.stderr)

  writeFileSync(join(tmp, 'tests/e2e/ci-skip.txt'), 'b.test.mjs\n')
  r = run(tmp)
  check('a skip line without a reason fails', r.status === 1 && /gives no reason/.test(r.stderr), r.stderr)

  writeFileSync(join(tmp, 'tests/e2e/ci-skip.txt'), 'gone.test.mjs  renamed long ago\n')
  r = run(tmp)
  check('a stale skip line fails', r.status === 1 && /is not a file/.test(r.stderr), r.stderr)

  writeFileSync(join(tmp, 'tests/e2e/ci-skip.txt'), 'a.test.mjs r\nb.test.mjs r\nc.test.mjs r\n')
  r = run(tmp)
  check('skipping everything refuses to pass', r.status === 1 && /refusing to pass/.test(r.stderr), r.stderr)

  writeFileSync(join(tmp, 'tests/e2e/ci-skip.txt'), '')
  r = spawnSync(process.execPath, [join(tmp, RUNNER_REL)], { cwd: tmp, encoding: 'utf8', env: { ...process.env, E2E_SKIP: 'b.test.mjs' } })
  check('E2E_SKIP leaves a file out of this run', r.status === 0 && /all 2 file\(s\) passed/.test(r.stdout), r.stdout + r.stderr)
  r = spawnSync(process.execPath, [join(tmp, RUNNER_REL)], { cwd: tmp, encoding: 'utf8', env: { ...process.env, E2E_SKIP: 'gone.test.mjs' } })
  check('a stale E2E_SKIP name fails', r.status === 1 && /E2E_SKIP: "gone\.test\.mjs" is not a file/.test(r.stderr), r.stderr)

  const shardRun = (v) => spawnSync(process.execPath, [join(tmp, RUNNER_REL), '--list'], { cwd: tmp, encoding: 'utf8', env: { ...process.env, E2E_SHARD: v } })
  const shards = ['1/2', '2/2'].map((v) => shardRun(v).stdout.trim().split('\n').filter(Boolean))
  check('E2E_SHARD 1/2 + 2/2 = the whole selection, round-robin, disjoint',
    shards[0].join() === 'tests/e2e/a.test.mjs,tests/e2e/c.test.mjs' && shards[1].join() === 'tests/e2e/b.test.mjs', JSON.stringify(shards))
  for (const bad of ['0/2', '3/2', '1/0', 'x']) {
    r = shardRun(bad)
    check(`E2E_SHARD="${bad}" fails`, r.status === 1 && /E2E_SHARD/.test(r.stderr), r.stderr)
  }
  r = shardRun('4/4')
  check('a shard that selects nothing refuses to pass', r.status === 1 && /selects no file/.test(r.stderr), r.stderr)

  r = run(tmp, 'nomatch')
  check('a filter that matches nothing fails', r.status === 1 && /matched none/.test(r.stderr), r.stderr)
} finally {
  rmSync(tmp, { recursive: true, force: true })
  rmSync(process.env.E2E_LOCAL_SLOTS_DIR, { recursive: true, force: true })
}

console.log(failed ? `\ne2e-runner-coverage: ${failed} FAILED` : '\ne2e-runner-coverage: all passed')
process.exit(failed ? 1 : 0)
