// CLE-3433 — the two rendering defects that made the deployed WUI read as
// "completely broken", pinned as a browser measurement rather than a look.
//
//   1. the `/` keycap in the top bar sat ON the composer's Send button and
//      clipped the word (dev build 28ec27b, 1440x900: badge x 1089..1110,
//      Send x 1050..1112 — the rectangles intersect);
//   2. at 800px and below the sidebar collapses to a 72px rail, and the
//      "enable alerts" control was NOT given the rail treatment the labels
//      got, so its text wrapped one letter per line — 40x234px at every
//      viewport from 390 to 768.
//
// Both are geometry, so both are asserted as geometry: no rectangle overlap,
// and no control more than 3x taller than it is wide. Run it against a
// deployed host, or against a local `nuxt generate` served statically (then
// only `/` and `/login` exist — everything else needs Firebase's rewrite to
// 200.html, and a 404 page would pass every assertion vacuously, which is why
// MISSING_OK is off by default).
//
//   BASE=https://dev.<domain> OUT=/var/tmp/CLE-3433-proof \
//     [PATHS=/,/lobby,/search] [WIDTHS=390,640,768,800,900,1280,1440] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/top-bar-rail-live.proof.mjs
import { createRequire } from 'node:module'
import { mkdirSync, writeFileSync } from 'node:fs'
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
const OUT = need('OUT')
const PATHS = (process.env.PATHS || '/,/lobby,/search').split(',').filter(Boolean)
const WIDTHS = (process.env.WIDTHS || '390,640,768,800,900,1280,1440').split(',').map(Number)
/* a route the host does not serve is NOT a pass — see the header */
const MISSING_OK = process.env.MISSING_OK === '1'

mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), rows: [] }
res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let failed = 0
try {
  const ctx = await browser.createBrowserContext()
  for (const width of WIDTHS) {
    for (const path of PATHS) {
      const page = await ctx.newPage()
      await page.setViewport({ width, height: 900 })
      const errs = []
      page.on('pageerror', (e) => errs.push(String(e).slice(0, 300)))
      const resp = await page.goto(BASE + path, { waitUntil: 'networkidle2', timeout: 30000 })
      const status = resp ? resp.status() : 0
      await new Promise((r) => setTimeout(r, 1200))
      const m = await page.evaluate(() => {
        const shown = (el) => Boolean(el) && getComputedStyle(el).display !== 'none' && el.getClientRects().length > 0
        const badge = document.querySelector('[data-test="slash-badge"]')
        const submit = [...document.querySelectorAll('button[type="submit"]')]
          .find((b) => shown(b) && b.closest('[data-test="top-bar-omnibox"]'))
        const rb = shown(badge) ? badge.getBoundingClientRect() : null
        const rs = submit ? submit.getBoundingClientRect() : null
        const alerts = document.querySelector('[data-testid="notify-alerts"]')
        const ra = shown(alerts) ? alerts.getBoundingClientRect() : null
        return {
          shell: Boolean(document.querySelector('nav.sidebar')),
          badge: rb && { x: Math.round(rb.x), y: Math.round(rb.y), w: Math.round(rb.width), h: Math.round(rb.height) },
          submit: rs && { x: Math.round(rs.x), y: Math.round(rs.y), w: Math.round(rs.width), h: Math.round(rs.height) },
          overlap: rb && rs ? !(rb.right <= rs.left || rb.left >= rs.right || rb.bottom <= rs.top || rb.top >= rs.bottom) : false,
          alerts: ra && { w: Math.round(ra.width), h: Math.round(ra.height), name: alerts.getAttribute('aria-label') },
          xscroll: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        }
      })
      /* a label laid out one letter per line is many times taller than wide */
      const shredded = m.alerts ? m.alerts.h > m.alerts.w * 3 : false
      /* the alerts control keeps a name wherever the app shell is on screen */
      const unnamed = m.shell && m.alerts ? !m.alerts.name : false
      const served = status > 0 && status < 400 && (m.shell || MISSING_OK)
      const ok = served && !m.overlap && !shredded && !unnamed && m.xscroll <= 0 && errs.length === 0
      if (!ok) failed++
      const row = { width, path, status, ...m, shredded, unnamed, served, errs, ok }
      res.rows.push(row)
      console.log(ok ? 'PASS' : 'FAIL', width, path, JSON.stringify(row))
      await page.screenshot({ path: `${OUT}/rail-${width}${path.replace(/\//g, '_')}.png` })
      await page.close()
    }
  }
} catch (e) {
  failed++
  res.threw = String((e && e.stack) || e)
  console.log('FAIL proof threw', res.threw)
} finally {
  await browser.close().catch(() => {})
}
res.failed = failed
writeFileSync(`${OUT}/top-bar-rail.json`, JSON.stringify(res, null, 2))
console.log(failed === 0 ? `ALL PASS (${res.rows.length} cases)` : `${failed} FAIL of ${res.rows.length}`)
process.exit(failed === 0 ? 0 : 1)
