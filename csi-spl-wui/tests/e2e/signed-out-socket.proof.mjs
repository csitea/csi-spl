// W5: signed-out pages must not open the hub WUI socket.
// Signed out on /, /lobby, /search → 0 ws(s)://…/v1/wui/ws attempts and no
// "WebSocket connection … failed" console error. Optional signed-in path
// (EMAIL + PW_FILE) checks the socket comes up once and the live feed still
// paints.
//
//   BASE=https://dev.<domain> OUT=/var/tmp/GRK-3377-proof \
//     [EMAIL=<member> PW_FILE=<0600 file> TENANT=t1] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/signed-out-socket.proof.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = process.env.TENANT || 't1'
const WAIT_MS = Number(process.env.WAIT_MS || 4000)
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [], pages: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const isWuiWs = (u) => /\/v1\/wui\/ws(?:\?|$)/.test(String(u || ''))
const isWsErr = (t) => /WebSocket connection to .*\/v1\/wui\/ws/i.test(String(t || '')) || /HTTP Authentication failed; no valid credentials available/i.test(String(t || ''))

async function attach(page) {
  const rec = { sockets: [], console: [] }
  page.on('console', (msg) => {
    const text = msg.text()
    rec.console.push({ type: msg.type(), text })
  })
  page.on('pageerror', (e) => rec.console.push({ type: 'pageerror', text: String(e) }))
  const cdp = await page.createCDPSession()
  await cdp.send('Network.enable')
  cdp.on('Network.webSocketCreated', (p) => rec.sockets.push({ when: Date.now(), url: p.url, requestId: p.requestId }))
  await page.evaluateOnNewDocument(() => {
    window.__wuiWs = []
    const Orig = window.WebSocket
    window.WebSocket = function (url, proto) {
      try { window.__wuiWs.push(String(url)) } catch { /* */ }
      return proto !== undefined ? new Orig(url, proto) : new Orig(url)
    }
    window.WebSocket.prototype = Orig.prototype
    window.WebSocket.CONNECTING = Orig.CONNECTING
    window.WebSocket.OPEN = Orig.OPEN
    window.WebSocket.CLOSING = Orig.CLOSING
    window.WebSocket.CLOSED = Orig.CLOSED
  })
  return rec
}

async function hookedUrls(page) {
  return page.evaluate(() => Array.isArray(window.__wuiWs) ? window.__wuiWs.slice() : [])
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let failed = 0
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  const ctx = await browser.createBrowserContext()
  const paths = ['/', '/lobby', '/search', '/channel/lobby']
  for (const path of paths) {
    const p = await ctx.newPage()
    await p.setViewport({ width: 1280, height: 800 })
    const rec = await attach(p)
    await p.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 30000 })
    await p.waitForSelector('[data-test=top-bar]', { timeout: 20000 }).catch(() => null)
    await sleep(WAIT_MS)
    const hooked = await hookedUrls(p)
    const sockets = rec.sockets.filter((s) => isWuiWs(s.url))
    const hookedWs = hooked.filter(isWuiWs)
    const err = rec.console.filter((c) => isWsErr(c.text) || (c.type === 'error' && /WebSocket/i.test(c.text)))
    const row = {
      path,
      url: p.url(),
      sockets: sockets.map((s) => s.url),
      hooked: hookedWs,
      wsErrors: err.map((c) => c.text).slice(0, 8),
    }
    res.pages.push(row)
    const n = sockets.length + hookedWs.length
    step(`signed out ${path}: 0 /v1/wui/ws`, n === 0 && err.length === 0, { n, sockets: row.sockets, hooked: row.hooked, wsErrors: row.wsErrors })
    const shot = path.replace(/[^\w]+/g, '_') || 'root'
    await p.screenshot({ path: `${OUT}/signed-out-${shot}.png` })
    await p.close()
  }

  if (process.env.EMAIL && process.env.PW_FILE) {
    const pw = readFileSync(process.env.PW_FILE, 'utf8').trim()
    const p = await ctx.newPage()
    await p.setViewport({ width: 1280, height: 800 })
    const rec = await attach(p)
    await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=native-auth-email]', { timeout: 20000 })
    await p.type('[data-test=native-auth-email]', process.env.EMAIL)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
    step('native sign-in', !!trig, { url: p.url().replace(/\?.*/, '') })
    await sleep(WAIT_MS)
    const hooked = (await hookedUrls(p)).filter(isWuiWs)
    const sockets = rec.sockets.filter((s) => isWuiWs(s.url))
    const urls = [...new Set([...sockets.map((s) => s.url), ...hooked])]
    step('signed in: hub socket opens (exactly one url)', urls.length === 1, { n: urls.length, urls, attempts: sockets.length + hooked.length })
    const feed = await p.$('.live-feed, [role=feed], .feed-body')
    step('signed in: live feed still present', !!feed, { url: p.url().replace(/\?.*/, '') })
    await p.screenshot({ path: `${OUT}/signed-in-lobby.png` })
    await p.close()
  } else {
    step('signed-in socket (skipped, no EMAIL/PW_FILE)', true, { skipped: true })
  }
} catch (e) {
  step('proof threw', false, { err: String(e && e.stack || e) })
} finally {
  await browser.close().catch(() => {})
  failed = res.steps.filter((s) => !s.ok).length
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed} step(s)` : `PASS ${res.steps.length}/${res.steps.length}`)
  process.exit(failed ? 1 : 0)
}
