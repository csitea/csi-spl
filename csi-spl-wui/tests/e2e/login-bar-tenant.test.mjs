// SPL-1025 (owner 2026-09-27, topic f8950b7f): "On mobile too the tenants
// drop box should replace the top left spool-hub title".
//
// The app's own top bar already starts with the tenant box on phones; the
// top-left "SPOOL-HUB" title left is the bar of the `login` layout (sign-in,
// verify-email, checkout, the error / 404 page). On the 404 page, at 360,
// 390, 820 and 1440 px:
//   - the logo stands where the SPOOL-HUB text was, at the start edge (a
//     44 px target on phones), no SPOOL-HUB text; a click opens the logo dialog
//   - signed out: no tenant box
//   - signed in: the tenant box right after the logo; exactly one box shows
//     (the phone box at <= 820 px, >= 44 px, the desktop drop box above);
//     no page scroll
//   - at 390 px a tap on the phone box opens the tenant sheet
//
// Run:
//   node tests/e2e/login-bar-tenant.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/login-bar-tenant.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TAP = 44
const TENANTS = [{ tenant_id: 't1', name: 'northwind' }, { tenant_id: 't2', name: 'globex' }]
const results = []
function check(name, pass, ev) {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const adopt = (p, claims) => p.evaluate((c) => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt(c)
  return true
}, claims)

const bar = (p) => p.evaluate(() => {
  const box = (sel) => {
    const el = document.querySelector(sel)
    if (!el) return null
    const r = el.getBoundingClientRect()
    const cs = getComputedStyle(el)
    return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height), b: Math.round(r.bottom), shown: cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0 }
  }
  return {
    bar: box('[data-test=login-bar]'),
    title: box('[data-test=login-bar-title]'),
    logo: box('[data-test=login-bar-logo]'),
    /* what is painted: the sr-only name is for screen readers */
    text: (() => {
      const el = document.querySelector('[data-test=login-bar-title]')?.cloneNode(true)
      if (!el) return ''
      el.querySelectorAll('.sr-only').forEach((n) => n.remove())
      return el.textContent.trim()
    })(),
    phone: box('[data-test=login-bar] [data-testid=top-bar-tenant-box]'),
    desk: box('[data-test=login-bar] [data-testid=tenant-switcher]'),
    xscroll: document.scrollingElement.scrollWidth - window.innerWidth,
  }
})

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [360, 390, 820, 1440]) {
    const tag = `${w}px`
    const touch = w <= 820
    const ctx = await browser.createBrowserContext()
    const p = await ctx.newPage()
    await p.setViewport({ width: w, height: 800, isMobile: touch, hasTouch: touch })
    await p.goto(`${server.base}/no-such-page-spl-1025`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=login-bar]', { timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=error-page]', { timeout: NAV_TIMEOUT })
    await adopt(p, null)
    await sleep(300)
    const out = await bar(p)
    check(`${tag}: the logo stands where SPOOL-HUB was, at the start edge`, out.logo?.shown === true && out.logo.x <= 16 && (!touch || (out.logo.w >= TAP && out.logo.h >= TAP)), out.logo)
    check(`${tag}: no SPOOL-HUB text beside it (a local dev build names its env only)`, !/spool-hub/i.test(out.text) && /^(|dev)$/i.test(out.text), { text: out.text })
    check(`${tag}: signed out, no tenant box`, !out.phone?.shown && !out.desk?.shown, out)
    const seeded = await adopt(p, { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', active_tenant: 't1', tenants: TENANTS })
    await p.waitForSelector(touch ? '[data-test=login-bar] [data-testid=top-bar-tenant-box]' : '[data-test=login-bar] [data-testid=tenant-switcher]', { timeout: 20000 }).catch(() => null)
    await sleep(600)
    const m = await bar(p)
    const shown = touch ? m.phone : m.desk
    const lead = m.title
    check(`${tag}: signed in, the tenant box right after the logo`, seeded && shown?.shown === true && lead && shown.x >= lead.x + lead.w && shown.x - (lead.x + lead.w) <= 12 && shown.y >= m.bar.y && shown.b <= m.bar.b, { seeded, shown, lead, bar: m.bar })
    check(`${tag}: exactly one tenant box shows (${touch ? 'the phone box' : 'the desktop drop box'})`, touch ? (m.phone?.shown && !m.desk?.shown) : (m.desk?.shown && !m.phone?.shown), { phone: m.phone, desk: m.desk })
    if (touch) check(`${tag}: the phone box is a ${TAP} px target`, m.phone?.w >= TAP && m.phone?.h >= TAP, m.phone)
    check(`${tag}: no horizontal scroll`, m.xscroll <= 0, { xscroll: m.xscroll })
    if (w === 390) {
      await p.tap('[data-test=login-bar] [data-testid=top-bar-tenant-box]')
      await sleep(500)
      const rows = await p.$$eval('[data-testid=top-bar-tenant-option]', (els) => els.map((e) => e.getAttribute('data-tenant')))
      check(`${tag}: a tap opens the tenant sheet`, rows.length === TENANTS.length, rows)
    }
    if (w === 1440) {
      await p.click('[data-test=login-bar-logo]')
      const dlg = await p.waitForSelector('[role=dialog]', { timeout: 10000 }).catch(() => null)
      check(`${tag}: a click on the logo opens it at true size`, Boolean(dlg))
    }
    await ctx.close()
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nlogin-bar-tenant: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
