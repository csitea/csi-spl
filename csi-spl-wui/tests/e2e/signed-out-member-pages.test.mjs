// SPL-4513 (round 2 of the console errors, SPL-4509 rows 1-6): a signed-out
// visitor on a member-only page goes to /login and reads nothing. Before it,
// /monitoring and /issues mounted for a visitor: 401 /v1/view/me (twice, the
// session retry) and a hub socket the hub refused.
//
// The mock bundle never signs out (the middleware skips the mock tenant), so
// each document served here is the same bundle with its baked `useMock:1`
// turned to "0": the page then probes the session of its own origin, which
// serve-generated proxies to the signed-out API stub (401). That is the path
// of a real visitor, against this build's own code.
//
// Per page: it ends on /login?redirect=<page>, with 0 /v1/view/me requests
// and 0 Network.webSocketCreated (CDP) over the whole visit. CONTROL: the
// flip is live (the session probe reached the stub, which the mock never
// asks); without it the checks above would pass vacuously.
//
//   BASE_URL=http://127.0.0.1:4321 node tests/e2e/signed-out-member-pages.test.mjs
//
// Needs BASE_URL serving the generated bundle with --api (the CI recipe,
// csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh); puppeteer-core is a
// committed devDependency, so a missing driver is a failure, never a skip.
import puppeteer from 'puppeteer-core'
import { startServer } from './lib/server.mjs'

const CHROME = process.env.CHROME_PATH ?? '/usr/bin/google-chrome'
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 30000)
const PATHS = ['/monitoring', '/issues']

let failed = 0
const ok = (name, cond, ev) => {
  if (!cond) failed++
  console.log(cond ? 'PASS' : 'FAIL', name, ev === undefined ? '' : JSON.stringify(ev))
}

/* the served document with the mock tenant turned off */
async function realTenantDocs(page) {
  await page.setRequestInterception(true)
  page.on('request', async (req) => {
    if (req.resourceType() !== 'document') return req.continue()
    try {
      const res = await fetch(req.url(), { headers: req.headers(), redirect: 'manual' })
      const body = await res.text()
      const headers = Object.fromEntries(res.headers)
      delete headers['content-length']
      delete headers['content-encoding']
      await req.respond({ status: res.status, headers, body: body.replaceAll('useMock:1', 'useMock:"0"') })
    } catch {
      await req.continue()
    }
  })
}

async function visit(browser, base, path) {
  const page = await browser.newPage()
  await page.setViewport({ width: 1280, height: 800 })
  await page.setBypassServiceWorker(true)
  const rec = { me: [], probes: [], sockets: [] }
  page.on('request', (req) => {
    const u = req.url()
    if (/\/v1\/view\/me(?:\?|$)/.test(u)) rec.me.push(u)
    if (/\/api\/v1\/auth\/session(?:\?|$)/.test(u)) rec.probes.push(u)
  })
  const cdp = await page.createCDPSession()
  await cdp.send('Network.enable')
  cdp.on('Network.webSocketCreated', (p) => rec.sockets.push(p.url))
  await realTenantDocs(page)
  await page.goto(base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await page.waitForFunction(() => location.pathname.endsWith('/login'), { timeout: 15000 }).catch(() => {})
  await new Promise((r) => setTimeout(r, 1500))
  const at = new URL(page.url())
  await page.close()
  return { at, ...rec }
}

const server = await startServer()
const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] })
try {
  for (const path of PATHS) {
    const r = await visit(browser, server.base, path)
    ok(`CONTROL ${path}: the real tenant path probed the session (the flip is live)`, r.probes.length > 0, { probes: r.probes.length })
    ok(`signed out ${path} goes to /login?redirect=${path}`, r.at.pathname.endsWith('/login') && r.at.searchParams.get('redirect') === path, r.at.href)
    ok(`signed out ${path}: 0 /v1/view/me reads`, r.me.length === 0, { n: r.me.length })
    ok(`signed out ${path}: 0 webSocketCreated`, r.sockets.length === 0, { n: r.sockets.length, urls: r.sockets.slice(0, 3) })
  }
} catch (e) {
  ok('suite threw', false, String(e && e.stack || e))
} finally {
  await browser.close().catch(() => {})
  await server.stop?.()
}
console.log(failed ? `FAIL ${failed} check(s)` : 'PASS all checks')
process.exit(failed ? 1 : 0)
