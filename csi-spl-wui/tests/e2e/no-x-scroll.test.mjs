// Runtime guard: document must not scroll horizontally.
// Loads /login, / (threads), /t/<id> and /channel/general at 390x844 (mobile) and 1280x800 (desktop)
// and asserts document.scrollingElement.scrollWidth <= innerWidth.
//
// Run:
//   pnpm test:e2e
//   BASE_URL=http://127.0.0.1:3000 pnpm test:e2e
//
// Starts `nuxi dev` with NUXT_PUBLIC_USE_MOCK=1 when BASE_URL is unset.
// Uses puppeteer-core when resolvable (PUPPETEER_CORE or node_modules);
// otherwise Chrome DevTools Protocol against CHROME_PATH.
import { spawn } from 'node:child_process'
import { createConnection, createServer } from 'node:net'
import { createHash, randomBytes } from 'node:crypto'
import { mkdtemp, rm } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { pathToFileURL, fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const CHROME = process.env.CHROME_PATH ?? '/usr/bin/google-chrome'
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 30000)
const SERVER_TIMEOUT = Number(process.env.SERVER_TIMEOUT ?? 90000)

const VIEWPORTS = [
  { name: '390x844', width: 390, height: 844 },
  { name: '1280x800', width: 1280, height: 800 },
]

const PATHS = [
  { path: '/login', wait: '.login-card' },
  { path: '/', wait: '.spool-shell' },
  { path: '/t/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', wait: '.spool-shell' },
  { path: '/channel/general', wait: '.spool-shell' },
]

const results = []
const ok = (name) => {
  results.push({ name, ok: true })
  console.log(`  OK   ${name}`)
}
const fail = (name, msg) => {
  results.push({ name, ok: false, msg })
  console.log(`  FAIL ${name}: ${msg}`)
}

function freePort() {
  return new Promise((resolve, reject) => {
    const s = createServer()
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address()
      s.close((err) => (err ? reject(err) : resolve(port)))
    })
    s.on('error', reject)
  })
}

async function waitHttp(url, timeoutMs) {
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

async function startServer() {
  const given = (process.env.BASE_URL || '').replace(/\/+$/, '')
  if (given) {
    await waitHttp(`${given}/login`, SERVER_TIMEOUT)
    return { base: given, stop: async () => {} }
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
    stop: async () => stopProcessGroup(child),
  }
}

function stopProcessGroup(child) {
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

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  const specs = []
  if (process.env.PUPPETEER_CORE) specs.push(process.env.PUPPETEER_CORE)
  specs.push('puppeteer-core')
  for (const spec of specs) {
    try {
      let href = spec
      if (!spec.startsWith('file:') && !spec.includes('://')) {
        try {
          href = pathToFileURL(require.resolve(spec)).href
        } catch {
          if (spec.startsWith('/')) href = pathToFileURL(spec).href
        }
      }
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      if (typeof puppeteer.launch === 'function') return puppeteer
    } catch {
      /* try next */
    }
  }
  return null
}

function encodeWsFrame(payload) {
  const data = Buffer.from(payload)
  const mask = randomBytes(4)
  const len = data.length
  let header
  if (len < 126) {
    header = Buffer.alloc(2)
    header[0] = 0x81
    header[1] = 0x80 | len
  } else if (len < 65536) {
    header = Buffer.alloc(4)
    header[0] = 0x81
    header[1] = 0x80 | 126
    header.writeUInt16BE(len, 2)
  } else {
    header = Buffer.alloc(10)
    header[0] = 0x81
    header[1] = 0x80 | 127
    header.writeBigUInt64BE(BigInt(len), 2)
  }
  const masked = Buffer.alloc(len)
  for (let i = 0; i < len; i++) masked[i] = data[i] ^ mask[i % 4]
  return Buffer.concat([header, mask, masked])
}

function encodeWsPong(payload) {
  const data = Buffer.from(payload)
  const mask = randomBytes(4)
  const header = Buffer.alloc(2)
  header[0] = 0x8a
  header[1] = 0x80 | data.length
  const masked = Buffer.alloc(data.length)
  for (let i = 0; i < data.length; i++) masked[i] = data[i] ^ mask[i % 4]
  return Buffer.concat([header, mask, masked])
}

function readWsFrames(buf) {
  const frames = []
  let offset = 0
  while (offset + 2 <= buf.length) {
    const b0 = buf[offset]
    const b1 = buf[offset + 1]
    const opcode = b0 & 0x0f
    const masked = (b1 & 0x80) !== 0
    let len = b1 & 0x7f
    let hdr = 2
    if (len === 126) {
      if (offset + 4 > buf.length) break
      len = buf.readUInt16BE(offset + 2)
      hdr = 4
    } else if (len === 127) {
      if (offset + 10 > buf.length) break
      const big = buf.readBigUInt64BE(offset + 2)
      len = Number(big)
      hdr = 10
    }
    const maskLen = masked ? 4 : 0
    if (offset + hdr + maskLen + len > buf.length) break
    let payload = buf.subarray(offset + hdr + maskLen, offset + hdr + maskLen + len)
    if (masked) {
      const mask = buf.subarray(offset + hdr, offset + hdr + 4)
      const out = Buffer.alloc(len)
      for (let i = 0; i < len; i++) out[i] = payload[i] ^ mask[i % 4]
      payload = out
    }
    frames.push({ opcode, payload })
    offset += hdr + maskLen + len
  }
  return { frames, rest: buf.subarray(offset) }
}

function wsConnect(wsUrl) {
  const u = new URL(wsUrl)
  const key = randomBytes(16).toString('base64')
  const expect = createHash('sha1')
    .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64')
  return new Promise((resolve, reject) => {
    const port = Number(u.port) || (u.protocol === 'wss:' ? 443 : 80)
    const sock = createConnection({ host: u.hostname, port }, () => {
      sock.write(
        `GET ${u.pathname}${u.search} HTTP/1.1\r\n` +
          `Host: ${u.host}\r\n` +
          `Upgrade: websocket\r\n` +
          `Connection: Upgrade\r\n` +
          `Sec-WebSocket-Key: ${key}\r\n` +
          `Sec-WebSocket-Version: 13\r\n\r\n`,
      )
    })
    let buf = Buffer.alloc(0)
    let open = false
    let nextId = 1
    const pending = new Map()
    const events = new Map()
    sock.setNoDelay(true)
    sock.on('error', (err) => {
      if (!open) reject(err)
      for (const p of pending.values()) p.reject(err)
      pending.clear()
    })
    sock.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk])
      if (!open) {
        const idx = buf.indexOf('\r\n\r\n')
        if (idx < 0) return
        const head = buf.subarray(0, idx).toString()
        buf = buf.subarray(idx + 4)
        if (!head.includes(expect) && !/101/.test(head.split('\r\n')[0] || '')) {
          reject(new Error(`websocket handshake failed: ${head.split('\r\n')[0]}`))
          sock.end()
          return
        }
        open = true
        resolve({
          send(method, params = {}) {
            const id = nextId++
            const payload = JSON.stringify({ id, method, params })
            sock.write(encodeWsFrame(payload))
            return new Promise((res, rej) => {
              const t = setTimeout(() => {
                pending.delete(id)
                rej(new Error(`CDP timeout ${method}`))
              }, NAV_TIMEOUT)
              pending.set(id, {
                resolve: (v) => {
                  clearTimeout(t)
                  res(v)
                },
                reject: (e) => {
                  clearTimeout(t)
                  rej(e)
                },
              })
            })
          },
          on(method, fn) {
            events.set(method, fn)
          },
          close() {
            try {
              sock.end()
            } catch {
              /* ignore */
            }
          },
        })
      }
      const decoded = readWsFrames(buf)
      buf = decoded.rest
      for (const fr of decoded.frames) {
        if (fr.opcode === 0x9) {
          sock.write(encodeWsPong(fr.payload))
          continue
        }
        if (fr.opcode === 0x8) {
          sock.end()
          continue
        }
        if (fr.opcode !== 0x1 && fr.opcode !== 0x0) continue
        let msg
        try {
          msg = JSON.parse(String(fr.payload))
        } catch {
          continue
        }
        if (msg.id && pending.has(msg.id)) {
          const p = pending.get(msg.id)
          pending.delete(msg.id)
          if (msg.error) p.reject(new Error(msg.error.message || JSON.stringify(msg.error)))
          else p.resolve(msg.result)
        } else if (msg.method && events.has(msg.method)) {
          events.get(msg.method)(msg.params || {})
        }
      }
    })
  })
}

async function launchChrome() {
  const port = await freePort()
  const dir = await mkdtemp(join(tmpdir(), 'spl-wui-e2e-'))
  const logs = []
  const child = spawn(
    CHROME,
    [
      '--headless=new',
      '--no-sandbox',
      '--disable-gpu',
      '--disable-dev-shm-usage',
      '--disable-extensions',
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${dir}`,
      'about:blank',
    ],
    { stdio: ['ignore', 'pipe', 'pipe'] },
  )
  const onLog = (buf) => logs.push(String(buf))
  child.stdout?.on('data', onLog)
  child.stderr?.on('data', onLog)
  const t0 = Date.now()
  let version
  while (Date.now() - t0 < 20000) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`)
      if (res.ok) {
        version = await res.json()
        break
      }
    } catch {
      /* wait */
    }
    await new Promise((r) => setTimeout(r, 100))
  }
  if (!version) {
    child.kill('SIGTERM')
    await rm(dir, { recursive: true, force: true })
    throw new Error(`chrome DevTools not ready\n${logs.join('').slice(-2000)}`)
  }
  return {
    port,
    async newPage() {
      const res = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })
      if (!res.ok) throw new Error(`json/new HTTP ${res.status}`)
      const tab = await res.json()
      const cdp = await wsConnect(tab.webSocketDebuggerUrl)
      await cdp.send('Page.enable')
      await cdp.send('Runtime.enable')
      return { id: tab.id, cdp }
    },
    async closePage(page) {
      try {
        page.cdp.close()
      } catch {
        /* ignore */
      }
      await fetch(`http://127.0.0.1:${port}/json/close/${page.id}`).catch(() => {})
    },
    async close() {
      child.kill('SIGTERM')
      await new Promise((r) => setTimeout(r, 200))
      try {
        child.kill('SIGKILL')
      } catch {
        /* ignore */
      }
      await rm(dir, { recursive: true, force: true })
    },
  }
}

async function measureCdp(chrome, vp, route, url) {
  const page = await chrome.newPage()
  try {
    await page.cdp.send('Emulation.setDeviceMetricsOverride', {
      width: vp.width,
      height: vp.height,
      deviceScaleFactor: 1,
      mobile: vp.width < 800,
    })
    const nav = page.cdp.send('Page.navigate', { url })
    const loaded = new Promise((resolve) => {
      page.cdp.on('Page.loadEventFired', resolve)
      setTimeout(resolve, NAV_TIMEOUT)
    })
    const navResult = await nav
    if (navResult.errorText) throw new Error(navResult.errorText)
    await loaded
    const t0 = Date.now()
    let metrics
    while (Date.now() - t0 < NAV_TIMEOUT) {
      const ev = await page.cdp.send('Runtime.evaluate', {
        expression: `(() => {
          const ready = !!document.querySelector(${JSON.stringify(route.wait)});
          const root = document.scrollingElement || document.documentElement;
          return {
            ready,
            href: location.href,
            scrollWidth: root.scrollWidth,
            innerWidth: window.innerWidth,
          };
        })()`,
        returnByValue: true,
      })
      metrics = ev.result?.value
      if (metrics?.ready) break
      await new Promise((r) => setTimeout(r, 150))
    }
    if (!metrics?.ready) {
      throw new Error(`selector ${route.wait} not found at ${metrics?.href || url}`)
    }
    await new Promise((r) => setTimeout(r, 150))
    const ev = await page.cdp.send('Runtime.evaluate', {
      expression: `(() => {
        const root = document.scrollingElement || document.documentElement;
        return { scrollWidth: root.scrollWidth, innerWidth: window.innerWidth };
      })()`,
      returnByValue: true,
    })
    return ev.result.value
  } finally {
    await chrome.closePage(page)
  }
}

async function measurePuppeteer(browser, vp, route, url) {
  const page = await browser.newPage()
  try {
    await page.setViewport({
      width: vp.width,
      height: vp.height,
      deviceScaleFactor: 1,
      isMobile: vp.width < 800,
      hasTouch: vp.width < 800,
    })
    const resp = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    if (!resp) throw new Error('no response')
    await page.waitForSelector(route.wait, { timeout: NAV_TIMEOUT })
    await new Promise((r) => setTimeout(r, 150))
    return page.evaluate(() => {
      const root = document.scrollingElement || document.documentElement
      return { scrollWidth: root.scrollWidth, innerWidth: window.innerWidth }
    })
  } finally {
    await page.close().catch(() => {})
  }
}

function assertNoX(name, dims) {
  if (dims.scrollWidth <= dims.innerWidth) {
    ok(`${name} no document x-scroll (scrollWidth=${dims.scrollWidth} innerWidth=${dims.innerWidth})`)
  } else {
    fail(name, `scrollWidth=${dims.scrollWidth} innerWidth=${dims.innerWidth}`)
  }
}

;(async () => {
  const server = await startServer()
  const puppeteer = await loadPuppeteer()
  let browser
  let chrome
  console.log(`no-x-scroll E2E against ${server.base}`)
  console.log(`  driver: ${puppeteer ? 'puppeteer-core' : 'chrome-cdp'}`)
  console.log(`  viewports: ${VIEWPORTS.map((v) => v.name).join(', ')}`)
  console.log(`  paths: ${PATHS.map((p) => p.path).join(', ')}`)
  try {
    if (puppeteer) {
      browser = await puppeteer.launch({
        executablePath: CHROME,
        headless: true,
        args: ['--no-sandbox', '--disable-dev-shm-usage'],
      })
    } else {
      chrome = await launchChrome()
    }
    for (const vp of VIEWPORTS) {
      for (const route of PATHS) {
        const label = `${vp.name} ${route.path}`
        const url = `${server.base}${route.path}`
        try {
          const dims = puppeteer
            ? await measurePuppeteer(browser, vp, route, url)
            : await measureCdp(chrome, vp, route, url)
          assertNoX(label, dims)
        } catch (e) {
          fail(label, e.message)
        }
      }
    }
  } finally {
    if (browser) await browser.close().catch(() => {})
    if (chrome) await chrome.close().catch(() => {})
    await server.stop()
  }

  const failed = results.filter((r) => !r.ok).length
  console.log(`\n${results.length - failed}/${results.length} checks passed (${failed} failed)`)
  process.exit(failed === 0 ? 0 : 1)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
