// SPL-2149 (owner HUM-10, t1 1061f05f msg 4d63f24c, UI suggestion 8):
// recently read channels stay readable offline.
//
//   mock tenant, signed in as HUM-1 (spool.mock.session), 1280x800:
//     O1 #lobby read online: its cards render, the page is under the
//        service worker, and the worker and the store kept what they need
//     O2 the network goes away (CDP offline on the page AND on the worker:
//        a never-loaded /_nuxt path fails, so nothing reaches the server),
//        then a reload: the shell is painted, the SAME cards are back, and
//        the offline strip says the feed is the copy saved on this device
//     O3 back online: the strip goes away by itself
//   CONTROL (same browser, offline): #alerts was never opened, so there is
//        no copy of it: no card of it is invented, and the strip says only
//        that the tab is offline.
//   Red on master f54dded26: after the offline reload the page is blank
//   (every /_nuxt chunk ERR_INTERNET_DISCONNECTED: the worker kept the
//   document, never the bundle).
//
// Needs a generated bundle: `nuxt dev` registers no service worker
// (plugins/pwa.client.ts). The chunk-reload path is not driven here (one
// tab never mixes CDP offline with a chunk-reload, wui-e2e rule).
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e offline-read   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const MOCK_SESSION = JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(fn, ms, step = 250) {
  const t0 = Date.now()
  let v
  while (Date.now() - t0 < ms) {
    v = await fn().catch(() => undefined)
    if (v) return v
    await sleep(step)
  }
  return v
}

const cardIds = (p) => p.evaluate(() => [...document.querySelectorAll('[data-msg-id]')].map((e) => e.getAttribute('data-msg-id')).sort())
const banner = (p) => p.evaluate(() => {
  const b = document.querySelector('[data-test=offline-banner]')
  return b ? { kept: b.getAttribute('data-kept') === 'true', hint: (b.querySelector('[data-test=offline-banner-hint]')?.textContent || '').trim() } : null
})

/* CDP offline on the page and on every service worker of this browser */
async function setOffline(browser, page, offline) {
  await page.setOfflineMode(offline)
  for (const t of browser.targets().filter((x) => x.type() === 'service_worker')) {
    const s = await t.createCDPSession()
    await s.send('Network.enable')
    await s.send('Network.emulateNetworkConditions', { offline, latency: 0, downloadThroughput: -1, uploadThroughput: -1 })
  }
}

async function run(browser, base) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(`${base}/login`, { waitUntil: 'load', timeout: NAV_TIMEOUT })
  await p.evaluate((s) => localStorage.setItem('spool.mock.session', s), MOCK_SESSION)
  await p.goto(`${base}/channel/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })

  // O1: online
  const ctl = await until(() => p.evaluate(() => navigator.serviceWorker && navigator.serviceWorker.ready.then(() => true)), 20000)
  if (!ctl) {
    ok('O1 the service worker is ready (needs a generated bundle: BASE_URL)', false)
    return
  }
  /* the first load ran before the worker claimed the page: load it once under the worker */
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const controlled = await until(() => p.evaluate(() => Boolean(navigator.serviceWorker.controller)), 10000)
  ok('O1 the page is under the service worker', Boolean(controlled))
  const online = await until(async () => { const ids = await cardIds(p); return ids.length ? ids : null }, 20000)
  ok('O1 #lobby shows its cards online', Boolean(online && online.length), online)
  const kept = await until(() => p.evaluate(() => {
    const all = JSON.parse(localStorage.getItem('spool.offline-feeds') || 'null')
    return Boolean(all && all.feeds && Object.keys(all.feeds).some((k) => k.endsWith('|ch:lobby')))
  }), 10000)
  ok('O1 the store kept #lobby for offline reading (spool.offline-feeds)', Boolean(kept))
  const chunks = await until(() => p.evaluate(async () => {
    const c = await caches.open('spool-chunks-v1')
    const keys = (await c.keys()).map((r) => new URL(r.url).pathname)
    /* the strip's chunk too (plugins/pwa.client.ts loads it online) */
    return keys.length > 5 && keys.some((k) => /OfflineBanner/.test(k)) ? keys.length : 0
  }), 15000)
  ok('O1 the worker kept the bundle files, the offline strip included', Boolean(chunks), chunks)
  ok('O1 online: no offline strip', (await banner(p)) === null)

  // O2: offline, reload
  await setOffline(browser, p, true)
  const probe = await p.evaluate(() => fetch(`/_nuxt/never-loaded-${Date.now()}.js`).then((r) => `HTTP ${r.status}`, (e) => `failed: ${e.message}`))
  ok('O2 offline is real: a path nobody loaded does not reach the server', probe.startsWith('failed'), probe)
  await p.reload({ waitUntil: 'load', timeout: NAV_TIMEOUT }).catch(() => {})
  const painted = await until(() => p.evaluate(() => Boolean(document.querySelector('[data-test=top-bar]')) && document.body.innerText.trim().length > 20), 20000)
  ok('O2 after an offline reload the shell is painted, not a blank page', Boolean(painted))
  const offlineIds = await until(async () => { const ids = await cardIds(p); return ids.length ? ids : null }, 20000)
  ok('O2 ... the same #lobby cards are back', JSON.stringify(offlineIds) === JSON.stringify(online), { online, offline: offlineIds })
  const strip = await until(async () => { const b = await banner(p); return b && b.kept ? b : null }, 20000)
  ok('O2 ... the strip says it is the copy saved on this device, with its time', Boolean(strip && /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(strip.hint)), strip)

  // CONTROL: a channel never opened online has no copy
  await p.evaluate(() => {
    const a = document.querySelector('a[href$="/channel/alerts"]')
    if (a) a.click()
  })
  const onAlerts = await until(() => p.evaluate(() => location.pathname.endsWith('/channel/alerts')), 10000)
  await sleep(1500)
  const alertIds = await cardIds(p)
  const ctlStrip = await banner(p)
  ok('CONTROL #alerts (never opened online): no card invented from another feed', Boolean(onAlerts) && alertIds.every((id) => !(online || []).includes(id)), { onAlerts, alertIds })
  ok('CONTROL ... the strip says offline, not "saved"', Boolean(ctlStrip) && !ctlStrip.kept, ctlStrip)

  // O3: back online
  await setOffline(browser, p, false)
  const gone = await until(async () => ((await banner(p)) === null ? true : null), 15000)
  ok('O3 back online: the strip goes away', Boolean(gone))
  await ctx.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await run(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length || !results.length) code = 1
process.exit(code)
