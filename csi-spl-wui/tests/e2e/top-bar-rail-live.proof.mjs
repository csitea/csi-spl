// the two rendering defects that made the deployed WUI read as
// "completely broken", pinned as a browser measurement rather than a look.
//
//   1. the decorative `/` keycap is gone from the top bar (it covered Send
//      on dev build 28ec27b, then stayed as a control that did nothing);
//   2. at 800px and below the sidebar collapses to a 72px rail, and the
//      "enable alerts" control was NOT given the rail treatment the labels
//      got, so its text wrapped one letter per line — 40x234px at every
//      viewport from 390 to 768.
//
// The keycap must be absent. The alerts control must not be more than 3x
// taller than it is wide. Run it against a
// deployed host, or against a local `nuxt generate` served statically (then
// only `/` and `/login` exist — everything else needs Firebase's rewrite to
// 200.html, and a 404 page would pass every assertion vacuously, which is why
// MISSING_OK is off by default).
//
//   BASE=https://dev.<domain> OUT=/var/tmp/CLE-3433-proof \
//     [PATHS=/,/lobby,/search] [WIDTHS=390,640,768,800,900,1280,1440] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/top-bar-rail-live.proof.mjs
import { mkdirSync, writeFileSync } from 'node:fs'
import { loadPuppeteer, need } from './lib/proof.mjs'

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
        /* the .notify-box fallback measures a build from BEFORE the testid
           existed too - without it this proof passes the very defect it
           exists to catch, silently, on every older deploy */
        const alerts = document.querySelector('[data-testid="notify-alerts"], .notify-box button')
        const ra = shown(alerts) ? alerts.getBoundingClientRect() : null
        return {
          shell: Boolean(document.querySelector('nav.sidebar')),
          badgePresent: Boolean(badge),
          alerts: ra && { w: Math.round(ra.width), h: Math.round(ra.height), name: alerts.getAttribute('aria-label') },
          xscroll: document.documentElement.scrollWidth - document.documentElement.clientWidth,
        }
      })
      /* a label laid out one letter per line is many times taller than wide */
      const shredded = m.alerts ? m.alerts.h > m.alerts.w * 3 : false
      /* the alerts control keeps a name wherever the app shell is on screen */
      /* with the shell on screen the control must BE there, and be named */
      const unnamed = m.shell ? !m.alerts || !m.alerts.name : false
      const served = status > 0 && status < 400 && (m.shell || MISSING_OK)
      const ok = served && !m.badgePresent && !shredded && !unnamed && m.xscroll <= 0 && errs.length === 0
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
