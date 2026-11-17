// The unit runner runs its files N at a time (p14-01) and the log still reads
// as the serial run's.
//
// The runner is pointed (WUI_UNIT_DIR) at a temp dir of 4 stub files. Each
// stub writes `<name>.start`, waits on a file event until as many stubs have
// started as the pool can hold (WUI_UNIT_JOBS, capped at 4), records how many
// stubs are running at that moment, then writes `<name>.end`. The peak of
// those counts is how many files the runner had in flight at once.
//
// Red control: the serial runner with WUI_UNIT_JOBS=4 -> each stub waits out
// its timeout alone, peak 1.
//
// Run: node tests/unit/unit-runner-pool.test.mjs
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../..')
const RUNNER = join(WUI, 'src/node/test/run-unit-tests.mjs')

let failed = 0
const pass = (n) => console.log(`  OK   ${n}`)
const fail = (n, m) => { failed++; console.log(`  FAIL ${n}: ${m}`) }
const check = (n, ok, m) => (ok ? pass(n) : fail(n, m))

console.log('unit-runner-pool (the runner runs its files N at a time, the log reads as serial)')

// A stub: start marker, wait for `want` starts (fs.watch, 5 s cap), count the
// running stubs, end marker. STUB_FAIL names a stub that exits 1.
const STUB = `
import { writeFileSync, readdirSync, watch } from 'node:fs'
import { join, basename } from 'node:path'
const me = basename(process.argv[1], '.test.mjs')
const dir = process.env.STUB_RUN_DIR
const want = Math.min(4, Number(process.env.WUI_UNIT_JOBS || 4))
const names = () => readdirSync(dir)
const started = () => names().filter((f) => f.endsWith('.start')).length
writeFileSync(join(dir, me + '.start'), '')
await new Promise((resolve) => {
  if (started() >= want) return resolve()
  const w = watch(dir, () => { if (started() >= want) { w.close(); clearTimeout(t); resolve() } })
  const t = setTimeout(() => { w.close(); resolve() }, 5000)
})
const ended = new Set(names().filter((f) => f.endsWith('.end')).map((f) => f.slice(0, -4)))
const running = names().filter((f) => f.endsWith('.start') && !ended.has(f.slice(0, -6))).length
writeFileSync(join(dir, me + '.running'), String(running))
console.log('stub ' + me + ' out')
console.error('stub ' + me + ' err')
writeFileSync(join(dir, me + '.end'), '')
process.exit(process.env.STUB_FAIL === me ? 1 : 0)
`

const STUBS = ['a', 'b', 'c', 'd']

function runPool(jobs, env = {}) {
  const root = mkdtempSync(join(tmpdir(), 'unit-runner-pool-'))
  const unitDir = join(root, 'unit')
  const runDir = join(root, 'run')
  mkdirSync(unitDir)
  mkdirSync(runDir)
  for (const s of STUBS) writeFileSync(join(unitDir, `${s}.test.mjs`), STUB)
  const res = spawnSync(process.execPath, [RUNNER], {
    cwd: WUI,
    encoding: 'utf8',
    env: { ...process.env, FAIL_FAST: '', ...env, WUI_UNIT_DIR: unitDir, WUI_UNIT_JOBS: String(jobs), STUB_RUN_DIR: runDir },
  })
  const peak = Math.max(0, ...STUBS.map((s) => {
    try { return Number(readFileSync(join(runDir, `${s}.running`), 'utf8')) } catch { return 0 }
  }))
  rmSync(root, { recursive: true, force: true })
  return { status: res.status, out: res.stdout || '', err: res.stderr || '', peak }
}

// Every header in the sorted order, each followed by its own stub's output.
function inOrder(out) {
  let at = 0
  for (const [i, s] of STUBS.entries()) {
    const h = out.indexOf(`──[${i + 1}/${STUBS.length}] ${s}.test.mjs`, at)
    if (h < 0) return `header ${i + 1} (${s}) missing or out of order`
    const next = i + 1 < STUBS.length ? out.indexOf(`──[${i + 2}/`, h) : out.length
    const body = out.slice(h, next < 0 ? out.length : next)
    if (!body.includes(`stub ${s} out`) || !body.includes(`stub ${s} err`)) return `${s}'s output is not under its header`
    at = h + 1
  }
  return ''
}

const four = runPool(4)
check('WUI_UNIT_JOBS=4 exits 0', four.status === 0, `exit ${four.status}\n${four.out}${four.err}`)
check('WUI_UNIT_JOBS=4 runs 4 files at once', four.peak === 4, `peak ${four.peak}`)
const order4 = inOrder(four.out)
check('WUI_UNIT_JOBS=4 prints each file whole, in the sorted order', !order4, order4)

const one = runPool(1)
check('WUI_UNIT_JOBS=1 exits 0', one.status === 0, `exit ${one.status}`)
check('WUI_UNIT_JOBS=1 runs 1 file at a time', one.peak === 1, `peak ${one.peak}`)
// The serial loop streams its children's stdio (inherit), so only the order of
// stdout is checked there: the headers.
check('WUI_UNIT_JOBS=1 prints the headers in the sorted order',
  STUBS.every((s, i) => one.out.includes(`──[${i + 1}/${STUBS.length}] ${s}.test.mjs`)), one.out)

const bad = runPool(4, { STUB_FAIL: 'b' })
check('a failing file exits 1', bad.status === 1, `exit ${bad.status}`)
check('a failing file is named in the failure list', /FAIL b\.test\.mjs \(exit 1\)/.test(bad.out), bad.out)
check('the other files still pass', !/FAIL [acd]\.test\.mjs/.test(bad.out), bad.out)

const badJobs = spawnSync(process.execPath, [RUNNER, '--list'], {
  cwd: WUI, encoding: 'utf8', env: { ...process.env, WUI_UNIT_JOBS: 'four' },
})
check('WUI_UNIT_JOBS that is not a number is refused', badJobs.status === 1 && /WUI_UNIT_JOBS/.test(badJobs.stderr), `exit ${badJobs.status}`)

if (failed) {
  console.log(`\nunit-runner-pool: ${failed} check(s) FAILED`)
  process.exit(1)
}
console.log('\nunit-runner-pool: all checks passed')
