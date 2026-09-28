// SPL-1096 live proof: a tab whose session ended stops redialling the live
// socket. Native sign-in, /lobby with the socket open, then the session
// cookie is deleted (an expired session) and the open socket is closed from
// the page (a drop, as a hub redeploy does). For WATCH_S seconds afterwards
// it counts the tab's /v1/wui/ws dials and /api/v1/auth/session probes.
//
// Before (prd request log, 2026-09-28 06:00..08:16Z): one refused dial every
// 31 s for as long as the tab stayed open. Expected now: 2 refused dials, 1
// session probe, then silence.
//
//   BASE=https://<host> EMAIL=<member> PW_FILE=<0600 file> [WATCH_S=120]
//     [TENANT=t1] [CHROME_PATH=...] node tests/e2e/live-ws-signed-out-live.proof.mjs
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const WATCH_S = Number(process.env.WATCH_S || 120)
const TENANT = process.env.TENANT || 't1'
const require = createRequire(import.meta.url)
const puppeteer = (await import(pathToFileURL(require.resolve(process.env.PUPPETEER_CORE || 'puppeteer-core')).href)).default
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let ok = false
try {
  const p = await browser.newPage()
  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')
  const dials = [], probes = []
  let t0 = 0
  cdp.on('Network.webSocketCreated', (e) => { if (t0 && e.url.includes('/v1/wui/ws')) dials.push(Date.now() - t0) })
  cdp.on('Network.requestWillBeSent', (e) => { if (t0 && e.request.url.includes('/api/v1/auth/session')) probes.push(Date.now() - t0) })

  // keep a handle on every socket the page opens, to drop the live one later
  await p.evaluateOnNewDocument(() => {
    const Native = window.WebSocket
    window.__sockets = []
    window.WebSocket = function (...a) { const ws = new Native(...a); window.__sockets.push(ws); return ws }
    window.WebSocket.prototype = Native.prototype
    Object.assign(window.WebSocket, { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 })
  })
  await p.goto(BASE + '/login?tenant=' + TENANT + '&redirect=/lobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 })
  await p.type('[data-test=native-auth-email]', need('EMAIL'))
  await p.type('[data-test=native-auth-password]', readFileSync(need('PW_FILE'), 'utf8').trim())
  await p.click('[data-test=native-auth-submit]')
  await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 })
  await sleep(4000)

  // the session ends: every cookie of the tab gone, then the socket drops
  const { cookies } = await cdp.send('Network.getAllCookies')
  for (const c of cookies) await cdp.send('Network.deleteCookies', { name: c.name, domain: c.domain, path: c.path })
  t0 = Date.now()
  const closed = await p.evaluate(() => window.__sockets.filter((w) => w.readyState === 1 && w.url.includes('/v1/wui/ws')).map((w) => { w.close(); return w.url }).length)
  console.log(`open live sockets closed: ${closed}`)
  await sleep(WATCH_S * 1000)

  const build = await fetch(BASE + '/build.json').then((r) => r.json()).catch(() => ({}))
  console.log(`build ${build.version} ${String(build.commit || '').slice(0, 8)}`)
  console.log(`watched ${WATCH_S} s after the session ended: /v1/wui/ws dials=${dials.length} at ${JSON.stringify(dials)} ms; session probes=${probes.length} at ${JSON.stringify(probes)} ms`)
  // the old client: one dial per backoff step, 500 ms doubling to 30 s = ~9 in 2 min and one per 31 s after
  // at least one redial, or the drop never happened and the count proves nothing
  ok = closed > 0 && dials.length >= 1 && dials.length <= 3
  console.log(ok ? 'PASS: the signed-out tab parked its socket' : 'FAIL: the signed-out tab keeps redialling')
} catch (e) {
  console.log('FAIL', String((e && e.message) || e))
} finally {
  await browser.close()
}
process.exit(ok ? 0 : 1)
