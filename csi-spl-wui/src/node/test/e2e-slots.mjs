// Box-wide cap on concurrent LOCAL e2e runs (`pnpm run test:e2e`).
//
// Why: every lane on a box ran its own e2e at once. One ps snapshot (n=1,
// 2026-10-04) showed load5 ~50 on 16 cpus with 15 agent windows: 35 chrome
// and 16 node processes from lanes' local e2e, not the agent CLIs. The box
// picker then saw >300% of cores and held every new lane.
//
// Mechanism: N slot files `slot-<i>` in one box-wide dir. A run claims a slot
// by link()ing a fully written temp file onto the slot name — atomic, fails
// with EEXIST when taken, and never exposes a half-written holder. The
// holder records its pid and that pid's kernel start time, so a slot whose
// holder died (crash, SIGKILL, OOM) is reclaimed by the next waiter, and a
// recycled pid does not keep a dead claim alive. A normal exit or a
// terminating signal removes the slot file.
//
// Knobs (all env):
//   E2E_LOCAL_SLOTS=<n>          slots per box, default 2; 0 = no cap
//   E2E_LOCAL_SLOTS_DIR=<dir>    default /var/tmp/csi-spl-e2e-slots (mode 0777)
//   E2E_LOCAL_SLOT_TIMEOUT_S=<s> how long to wait for a slot, default 3600
// GitHub Actions (GITHUB_ACTIONS=true, hosted and self-hosted runners alike)
// is never capped. Plain CI=1 is NOT a bypass: local recipes set it too.
import { existsSync, linkSync, mkdirSync, chmodSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { userInfo } from 'node:os'

export const DEFAULT_SLOTS = 2
export const DEFAULT_DIR = '/var/tmp/csi-spl-e2e-slots'
export const DEFAULT_TIMEOUT_S = 3600

export function slotConfig(env = process.env) {
  const raw = env.E2E_LOCAL_SLOTS
  const n = raw === undefined || raw === '' ? DEFAULT_SLOTS : Number(raw)
  if (!Number.isInteger(n) || n < 0) throw new Error(`E2E_LOCAL_SLOTS="${raw}" is not an integer >= 0`)
  const rawT = env.E2E_LOCAL_SLOT_TIMEOUT_S
  const t = rawT === undefined || rawT === '' ? DEFAULT_TIMEOUT_S : Number(rawT)
  if (!Number.isFinite(t) || t < 0) throw new Error(`E2E_LOCAL_SLOT_TIMEOUT_S="${rawT}" is not a number >= 0`)
  const bypass = env.GITHUB_ACTIONS === 'true' ? 'GITHUB_ACTIONS=true' : n === 0 ? 'E2E_LOCAL_SLOTS=0' : ''
  return { n, dir: env.E2E_LOCAL_SLOTS_DIR || DEFAULT_DIR, timeoutMs: t * 1000, bypass }
}

// Field 22 of /proc/<pid>/stat, read after the parenthesised comm (which may
// hold spaces). '' when the pid is gone or there is no /proc.
export function procStart(pid) {
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8')
    return stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19] || ''
  } catch {
    return ''
  }
}

export function holderAlive(h) {
  if (!h || !Number.isInteger(h.pid) || h.pid <= 0) return false
  try {
    process.kill(h.pid, 0)
  } catch (e) {
    if (e.code !== 'EPERM') return false // EPERM: alive, another user's
  }
  const start = procStart(h.pid)
  return !(h.start && start && start !== h.start) // a recycled pid is a dead holder
}

const readHolder = (path) => {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return null
  }
}

function ensureDir(dir) {
  if (existsSync(dir)) return
  mkdirSync(dir, { recursive: true })
  try {
    chmodSync(dir, 0o777) // box-wide, not sticky: any user's run claims and reclaims here
  } catch {}
}

export function listHolders({ dir, n }) {
  const out = []
  for (let i = 1; i <= n; i++) {
    const h = readHolder(join(dir, `slot-${i}`))
    if (h) out.push({ slot: i, ...h, alive: holderAlive(h) })
  }
  return out
}

// One pass over the slots: claim a free one or reclaim a dead one. Returns
// the claimed slot path, or null when every slot has a live holder.
export function tryAcquire({ dir, n }, me = selfHolder()) {
  ensureDir(dir)
  const tmp = join(dir, `.claim-${me.pid}-${process.hrtime.bigint()}`)
  writeFileSync(tmp, JSON.stringify(me) + '\n', { mode: 0o644 })
  try {
    for (let i = 1; i <= n; i++) {
      const path = join(dir, `slot-${i}`)
      try {
        linkSync(tmp, path)
        return path
      } catch (e) {
        if (e.code !== 'EEXIST') throw e
      }
      if (holderAlive(readHolder(path))) continue
      // Dead holder: move it aside first, so two waiters reclaiming the same
      // slot cannot delete each other's fresh claim; put back a live one.
      const aside = `${tmp}.stale-${i}`
      try {
        renameSync(path, aside)
      } catch {
        continue
      }
      if (holderAlive(readHolder(aside))) {
        try { linkSync(aside, path) } catch {}
        try { unlinkSync(aside) } catch {}
        continue
      }
      try { unlinkSync(aside) } catch {}
      try {
        linkSync(tmp, path)
        return path
      } catch (e) {
        if (e.code !== 'EEXIST') throw e
      }
    }
    return null
  } finally {
    try { unlinkSync(tmp) } catch {}
  }
}

// Removes the slot only while it still names this holder.
export function release(path, me = selfHolder()) {
  const h = readHolder(path)
  if (h && h.pid === me.pid && h.start === me.start) {
    try { unlinkSync(path) } catch {}
  }
}

export function selfHolder() {
  let user = ''
  try { user = userInfo().username } catch {}
  return { pid: process.pid, start: procStart(process.pid), user, cwd: process.cwd(), since: new Date().toISOString() }
}

const describeHolders = (hs) =>
  hs.map((h) => `slot-${h.slot}: pid ${h.pid} ${h.user || '?'} since ${h.since} in ${h.cwd}${h.alive ? '' : ' (dead)'}`).join('\n  ')

// Waits for a slot, then frees it on exit or a terminating signal. Resolves
// to the slot path, or '' when the cap is bypassed. Throws on timeout.
export async function acquireSlot({ env = process.env, log = console.log, pollMs = 2000, now = Date.now } = {}) {
  const cfg = slotConfig(env)
  if (cfg.bypass) return ''
  const me = selfHolder()
  const t0 = now()
  let shown = ''
  let path
  while (!(path = tryAcquire(cfg, me))) {
    const desc = describeHolders(listHolders(cfg))
    if (desc !== shown) {
      log(`e2e runner: all ${cfg.n} local e2e slot(s) in ${cfg.dir} are taken (E2E_LOCAL_SLOTS=${cfg.n}), waiting:\n  ${desc}`)
      shown = desc
    }
    if (now() - t0 >= cfg.timeoutMs) {
      throw new Error(`no local e2e slot free after ${Math.round(cfg.timeoutMs / 1000)}s (E2E_LOCAL_SLOT_TIMEOUT_S); holders:\n  ${desc}`)
    }
    await new Promise((r) => setTimeout(r, pollMs))
  }
  const free = () => release(path, me)
  process.on('exit', free)
  for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) {
    process.on(sig, () => {
      free()
      process.exit(code)
    })
  }
  log(`e2e runner: holding local e2e slot ${path} (of ${cfg.n})`)
  return path
}
