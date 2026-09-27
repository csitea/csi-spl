// SPL-1006: does an open tab pick up a new WUI deploy?
//
// Opens BASE/login in a headless tab, records what the tab RUNS (its entry
// script, window.__BUILD__ when the build bakes one in) and what is LIVE
// (/build.json, no-store), then waits - without touching the tab - until
// /build.json names a different commit (the next deploy), and records both
// again after a settle time.
//
//   before the fix: the tab still runs build X (same entry script, no
//                   navigation) while build Y is live  -> "stale": true
//   after the fix:  the tab reloaded itself onto Y     -> "stale": false,
//                   navigations >= 2, __BUILD__ == live commit
//
// The tab is idle (nothing typed), so the fix is expected to reload it
// silently. It only needs the signed-out /login page: the same bundle runs.
//
// Run (waits for the next deploy, up to WAIT_MIN minutes):
//   BASE_URL=https://e2e.spool-hub.ai node tests/e2e/stale-tab-live.proof.mjs
//   BASE_URL=... WAIT_MIN=40 SETTLE_S=330 OUT=/path/result.json node tests/e2e/stale-tab-live.proof.mjs
import { createRequire } from 'node:module'
import { writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const BASE = (process.env.BASE_URL || '').replace(/\/+$/, '')
if (!BASE) { console.error('BASE_URL is required'); process.exit(2) }
const WAIT_MIN = Number(process.env.WAIT_MIN || 40)
const SETTLE_S = Number(process.env.SETTLE_S || 330)
const POLL_S = Number(process.env.POLL_S || 20)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const live = async () => {
  try {
    const r = await fetch(`${BASE}/build.json?t=${Date.now()}`, { cache: 'no-store' })
    return (await r.json()).commit || ''
  } catch { return '' }
}
const liveEntry = async () => {
  try {
    const html = await (await fetch(`${BASE}/login?t=${Date.now()}`, { cache: 'no-store' })).text()
    return (html.match(/<script type="module"[^>]*src="([^"]+)"/) || [])[1] || ''
  } catch { return '' }
}
const tabState = (p) => p.evaluate(() => ({
  entry: document.querySelector('script[type=module][src]')?.getAttribute('src') || '',
  build: (window.__BUILD__ && window.__BUILD__.commit) || '',
  url: location.pathname + location.search,
}))

const res = { base: BASE, started: new Date().toISOString() }
const browser = await launch()
let code = 0
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  let navigations = 0
  p.on('framenavigated', (f) => { if (f === p.mainFrame()) navigations++ })
  await p.goto(`${BASE}/login`, { waitUntil: 'load' })
  res.opened = { at: new Date().toISOString(), live: await live(), liveEntry: await liveEntry(), tab: await tabState(p) }
  console.log('opened', JSON.stringify(res.opened))
  const deadline = Date.now() + WAIT_MIN * 60000
  let next = ''
  while (Date.now() < deadline) {
    await sleep(POLL_S * 1000)
    const c = await live()
    if (c && c !== res.opened.live) { next = c; break }
  }
  if (!next) throw new Error(`no deploy within ${WAIT_MIN} min (live still ${res.opened.live.slice(0, 8)})`)
  res.deployed = { at: new Date().toISOString(), live: next }
  console.log('deploy seen', JSON.stringify(res.deployed))
  // the fix checks on focus/visible and every 5 min; a headless tab stays
  // visible, so the 5-minute timer is what fires here
  await sleep(SETTLE_S * 1000)
  res.after = { at: new Date().toISOString(), live: await live(), liveEntry: await liveEntry(), tab: await tabState(p), navigations }
  res.stale = res.after.tab.entry !== res.after.liveEntry
  console.log('after', JSON.stringify(res.after))
  console.log(res.stale ? 'STALE: the tab still runs the build it opened on' : 'CURRENT: the tab runs the live build')
} catch (e) {
  res.error = String(e && e.message || e)
  console.error(res.error)
  code = 1
} finally {
  await browser.close()
}
if (process.env.OUT) writeFileSync(process.env.OUT, JSON.stringify(res, null, 2))
process.exit(code)
