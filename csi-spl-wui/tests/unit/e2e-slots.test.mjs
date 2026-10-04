// The box-wide cap on local e2e runs (src/node/test/e2e-slots.mjs): acquire,
// release, a dead holder's slot reclaimed, a recycled pid not trusted, the
// GitHub Actions bypass, and a clear failure on timeout. Every case uses its
// own temp dir, never the box's real slots.
// Run: node tests/unit/e2e-slots.test.mjs
import { describe, it, after } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { spawn, spawnSync } from 'node:child_process'
import {
  DEFAULT_SLOTS, acquireSlot, holderAlive, procStart, release, selfHolder, slotConfig, tryAcquire,
} from '../../src/node/test/e2e-slots.mjs'

const SLOTS = join(dirname(fileURLToPath(import.meta.url)), '../../src/node/test/e2e-slots.mjs')
const dirs = []
const freshDir = () => {
  const d = mkdtempSync(join(tmpdir(), 'e2e-slots-test-'))
  dirs.push(d)
  return d
}
const sleepers = []
const liveHolder = () => {
  const p = spawn('sleep', ['60'], { stdio: 'ignore' })
  sleepers.push(p)
  return { pid: p.pid, start: procStart(p.pid), user: 'test', cwd: '/', since: 'now' }
}
const deadPid = () => spawnSync('true').pid
const holderIn = (path) => JSON.parse(readFileSync(path, 'utf8'))
after(() => {
  for (const p of sleepers) p.kill('SIGKILL')
  for (const d of dirs) rmSync(d, { recursive: true, force: true })
})

describe('slotConfig', () => {
  it('defaults to 2 slots and no bypass', () => {
    const c = slotConfig({})
    assert.equal(c.n, DEFAULT_SLOTS)
    assert.equal(c.n, 2)
    assert.equal(c.bypass, '')
  })
  it('E2E_LOCAL_SLOTS overrides, 0 means uncapped, junk throws', () => {
    assert.equal(slotConfig({ E2E_LOCAL_SLOTS: '5' }).n, 5)
    assert.equal(slotConfig({ E2E_LOCAL_SLOTS: '0' }).bypass, 'E2E_LOCAL_SLOTS=0')
    assert.throws(() => slotConfig({ E2E_LOCAL_SLOTS: 'two' }), /E2E_LOCAL_SLOTS="two"/)
    assert.throws(() => slotConfig({ E2E_LOCAL_SLOTS: '-1' }), /E2E_LOCAL_SLOTS/)
  })
  it('GitHub Actions bypasses the cap; a bare CI=1 does not', () => {
    assert.equal(slotConfig({ GITHUB_ACTIONS: 'true' }).bypass, 'GITHUB_ACTIONS=true')
    assert.equal(slotConfig({ CI: '1' }).bypass, '')
  })
})

describe('holderAlive', () => {
  it('a live pid with its start time is alive', () => assert.equal(holderAlive(selfHolder()), true))
  it('an exited pid is dead', () => assert.equal(holderAlive({ pid: deadPid(), start: '' }), false))
  it('a live pid with another start time is a recycled pid: dead', () =>
    assert.equal(holderAlive({ pid: process.pid, start: '1' }), false))
  it('junk is dead', () => {
    assert.equal(holderAlive(null), false)
    assert.equal(holderAlive({ pid: 'x' }), false)
  })
})

describe('tryAcquire / release', () => {
  it('fills N slots, refuses the N+1th, and a release frees one', () => {
    const cfg = { dir: freshDir(), n: 2 }
    const a = liveHolder()
    const b = liveHolder()
    const c = liveHolder()
    assert.equal(tryAcquire(cfg, a), join(cfg.dir, 'slot-1'))
    assert.equal(tryAcquire(cfg, b), join(cfg.dir, 'slot-2'))
    assert.equal(tryAcquire(cfg, c), null)
    assert.equal(holderIn(join(cfg.dir, 'slot-2')).pid, b.pid)
    release(join(cfg.dir, 'slot-1'), a)
    assert.equal(tryAcquire(cfg, c), join(cfg.dir, 'slot-1'))
    assert.equal(holderIn(join(cfg.dir, 'slot-1')).pid, c.pid)
  })
  it('release leaves a slot another holder owns', () => {
    const cfg = { dir: freshDir(), n: 1 }
    const a = liveHolder()
    const path = tryAcquire(cfg, a)
    release(path, liveHolder())
    assert.equal(holderIn(path).pid, a.pid)
  })
  it("a dead holder's slot is reclaimed", () => {
    const cfg = { dir: freshDir(), n: 1 }
    writeFileSync(join(cfg.dir, 'slot-1'), JSON.stringify({ pid: deadPid(), start: '' }))
    const me = liveHolder()
    assert.equal(tryAcquire(cfg, me), join(cfg.dir, 'slot-1'))
    assert.equal(holderIn(join(cfg.dir, 'slot-1')).pid, me.pid)
  })
  it('an unreadable slot file is reclaimed too', () => {
    const cfg = { dir: freshDir(), n: 1 }
    writeFileSync(join(cfg.dir, 'slot-1'), '')
    assert.equal(tryAcquire(cfg, liveHolder()), join(cfg.dir, 'slot-1'))
  })
  it('leaves no temp claim files behind', () => {
    const cfg = { dir: freshDir(), n: 1 }
    tryAcquire(cfg, liveHolder())
    tryAcquire(cfg, liveHolder())
    assert.deepEqual(spawnSync('ls', ['-A', cfg.dir], { encoding: 'utf8' }).stdout.trim(), 'slot-1')
  })
})

describe('acquireSlot', () => {
  it('bypassed under GitHub Actions: takes no slot', async () => {
    const dir = freshDir()
    assert.equal(await acquireSlot({ env: { GITHUB_ACTIONS: 'true', E2E_LOCAL_SLOTS_DIR: dir }, log: () => {} }), '')
    assert.equal(existsSync(join(dir, 'slot-1')), false)
  })
  it('waits, names the holders, and fails clearly on timeout', async () => {
    const dir = freshDir()
    const h = liveHolder()
    tryAcquire({ dir, n: 1 }, h)
    const lines = []
    await assert.rejects(
      acquireSlot({ env: { E2E_LOCAL_SLOTS: '1', E2E_LOCAL_SLOTS_DIR: dir, E2E_LOCAL_SLOT_TIMEOUT_S: '0.05' }, log: (l) => lines.push(l), pollMs: 10 }),
      (e) => /no local e2e slot free after/.test(e.message) && e.message.includes(`pid ${h.pid}`),
    )
    assert.equal(lines.length, 1, 'the holder list prints once while it does not change')
    assert.match(lines[0], new RegExp(`waiting:\\n  slot-1: pid ${h.pid} test`))
  })
  it('a child holding a slot frees it on SIGTERM; a SIGKILLed one is reclaimed', async () => {
    const dir = freshDir()
    const env = { ...process.env, GITHUB_ACTIONS: '', E2E_LOCAL_SLOTS: '1', E2E_LOCAL_SLOTS_DIR: dir }
    const holdingChild = () =>
      new Promise((resolve) => {
        const p = spawn(process.execPath, ['-e', `import(${JSON.stringify(SLOTS)}).then((m) => m.acquireSlot()).then(() => { console.log('held'); setInterval(() => {}, 1000) })`], { env })
        p.stdout.on('data', (d) => d.toString().includes('held') && resolve(p))
      })
    const exited = (p) => new Promise((r) => p.on('exit', r))

    let p = await holdingChild()
    assert.equal(holderIn(join(dir, 'slot-1')).pid, p.pid)
    p.kill('SIGTERM')
    await exited(p)
    assert.equal(existsSync(join(dir, 'slot-1')), false, 'SIGTERM released the slot')

    p = await holdingChild()
    p.kill('SIGKILL')
    await exited(p)
    assert.equal(existsSync(join(dir, 'slot-1')), true, 'SIGKILL leaves the file')
    const me = liveHolder()
    assert.equal(tryAcquire({ dir, n: 1 }, me), join(dir, 'slot-1'))
    assert.equal(holderIn(join(dir, 'slot-1')).pid, me.pid)
  })
})
