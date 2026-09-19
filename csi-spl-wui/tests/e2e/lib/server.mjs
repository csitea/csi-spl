// Shared e2e server helpers (lifted out of no-x-scroll.test.mjs so every e2e
// gate boots the WUI the same way, the donor WUI's tests/e2e/lib pattern).
//
// startServer(): BASE_URL when set (waits for /login), otherwise `nuxi dev`
// on a free 127.0.0.1 port with the mock tenant (NUXT_PUBLIC_USE_MOCK=1).
import { spawn } from 'node:child_process'
import { createServer } from 'node:net'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../../..')
const SERVER_TIMEOUT = Number(process.env.SERVER_TIMEOUT ?? 90000)

export function freePort() {
  return new Promise((resolve, reject) => {
    const s = createServer()
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address()
      s.close((err) => (err ? reject(err) : resolve(port)))
    })
    s.on('error', reject)
  })
}

export async function waitHttp(url, timeoutMs) {
  const t0 = Date.now()
  let last = ''
  while (Date.now() - t0 < timeoutMs) {
    try {
      const res = await fetch(url, { redirect: 'manual' })
      if (res.status > 0 && res.status < 500) return
      last = `HTTP ${res.status}`
    } catch (e) {
      last = e.message
    }
    await new Promise((r) => setTimeout(r, 250))
  }
  throw new Error(`server not ready at ${url}: ${last}`)
}

export async function startServer() {
  const given = (process.env.BASE_URL || '').replace(/\/+$/, '')
  if (given) {
    await waitHttp(`${given}/login`, SERVER_TIMEOUT)
    return { base: given, started: false, stop: async () => {} }
  }
  const port = await freePort()
  const nuxi = join(WUI, 'node_modules/.bin/nuxi')
  const logs = []
  const child = spawn(nuxi, ['dev', '--host', '127.0.0.1', '--port', String(port)], {
    cwd: WUI,
    env: { ...process.env, NUXT_PUBLIC_USE_MOCK: '1' },
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true,
  })
  const onLog = (buf) => {
    const s = String(buf)
    logs.push(s)
    if (process.env.E2E_VERBOSE) process.stderr.write(s)
  }
  child.stdout?.on('data', onLog)
  child.stderr?.on('data', onLog)
  const base = `http://127.0.0.1:${port}`
  try {
    await waitHttp(`${base}/login`, SERVER_TIMEOUT)
  } catch (e) {
    stopProcessGroup(child)
    throw new Error(`${e.message}\n--- nuxi ---\n${logs.join('').slice(-4000)}`)
  }
  return {
    base,
    started: true,
    stop: async () => stopProcessGroup(child),
  }
}

export function stopProcessGroup(child) {
  if (!child.pid) return
  try {
    process.kill(-child.pid, 'SIGTERM')
  } catch {
    try {
      child.kill('SIGTERM')
    } catch {
      /* already gone */
    }
  }
}

