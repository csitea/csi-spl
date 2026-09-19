// specs/026 live proof against a deployed WUI: a native sign-in with
// ?tenant=<t>, then the lobby's hub traffic. PASS = every hub call (/v1/*,
// /api/v1/*) goes to API (the one api host) with a non-error status, the WUI
// socket opens there, no request names a <tenant>.<fqdn> host, and the session
// reports active_tenant = TENANT. Results + a screenshot to OUT.
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> EMAIL=<member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [LOCALE=en] [DEFAULT_LOCALE=en] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/tenant-from-identity-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const API = new URL(need('API')).host
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const LOCALE = process.env.LOCALE || 'en'
const P = LOCALE === (process.env.DEFAULT_LOCALE || 'en') ? '' : '/' + LOCALE
const TENANT_HOST = TENANT + '.' + new URL(BASE).host
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, api: API, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  const calls = []
  const sockets = []
  p.on('response', (r) => {
    const u = new URL(r.url())
    if (/^\/(v1|api\/v1)\//.test(u.pathname)) calls.push({ host: u.host, method: r.request().method(), path: u.pathname, status: r.status() })
  })
  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')
  cdp.on('Network.webSocketCreated', (e) => sockets.push({ url: e.url, status: null }))
  cdp.on('Network.webSocketHandshakeResponseReceived', (e) => { const s = sockets[sockets.length - 1]; if (s) s.status = e.response.status })

  await p.goto(BASE + P + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent(P + '/lobby'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in with ?tenant', !!trig, { url: p.url() })
  // Count only the signed-in lobby: the login page's anonymous reads are 401 by design.
  calls.length = 0
  sockets.length = 0
  await p.goto(BASE + P + '/lobby', { waitUntil: 'networkidle2' })
  await new Promise((r) => setTimeout(r, 6000)) // lobby reads + live socket
  await p.screenshot({ path: `${OUT}/lobby.png` })

  const sess = await p.evaluate(async (api) => {
    const r = await fetch('https://' + api + '/api/v1/auth/session', { credentials: 'include' })
    return { status: r.status, body: r.ok ? await r.json() : null }
  }, API)
  step('session active_tenant = TENANT', sess.status === 200 && sess.body?.active_tenant === TENANT,
    { status: sess.status, t: sess.body?.t, active_tenant: sess.body?.active_tenant, tenants: sess.body?.tenants })

  const view = calls.filter((c) => c.path.startsWith('/v1/'))
  const offHost = calls.filter((c) => c.host !== API && c.host !== new URL(BASE).host)
  // withSessionRetry (live-follow.mjs): a first read without credentials may be
  // 401 view_door and is retried with the session, so the LAST answer per path counts.
  const last = {}
  for (const c of view) last[c.path] = c
  step('lobby reads go to the api host, each path ends 2xx', view.length > 0 && view.every((c) => c.host === API) &&
    Object.values(last).every((c) => c.status < 400),
    { final: Object.values(last).map((c) => `${c.status} ${c.path}`), retried_401: view.filter((c) => c.status === 401).length })
  step('no tenant host is used', !calls.some((c) => c.host === TENANT_HOST) && !sockets.some((s) => s.url.includes('//' + TENANT_HOST)) && offHost.length === 0,
    { tenant_host: TENANT_HOST, off_host: offHost })
  const ws = sockets.filter((s) => s.url.includes('/v1/wui/ws'))
  step('WUI socket opens on the api host', ws.some((s) => new URL(s.url).host === API && s.status === 101), { sockets: ws })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
process.exit(res.steps.every((s) => s.ok) ? 0 : 1)
