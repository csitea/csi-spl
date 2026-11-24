// SPL-6413 (owner HUM-10, t1 bedfacca msg 3c421dd7): "the drop down of the
// workspaces MUST NOT BE VISIBLE in the login ... the login would present
// either the workspace name to which the user tries to login, or just the
// spool-hub workspace name".
//
// On /login, at 360 and 390 px (phone) and 1440 px (desktop):
//   - signed out: no tenant drop box (desktop or phone), the bar names
//     spool-hub (this host is no tenant host)
//   - ?tenant=globex: the bar names globex; a later plain /login in the same
//     tab still names it (the tenant the sign-in form sends)
//   - a session with two memberships adopted on the sign-in page: still no
//     drop box, the bar still names the workspace being signed into, and no
//     membership name shows in the bar or the tab title (document.title)
//   - the name is drawn whole (no ellipsis) and clear of the theme and
//     language controls; no horizontal scroll
// The drop box on the other pages of the sign-in frame: login-bar-tenant.test.mjs.
//
// Run:
//   node tests/e2e/login-no-workspace-dropdown.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/login-no-workspace-dropdown.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TENANTS = [{ tenant_id: 't1', name: 'northwind' }, { tenant_id: 't2', name: 'globex-corp' }]
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
  const shown = (sel) => {
    const el = document.querySelector(sel)
    if (!el) return false
    const r = el.getBoundingClientRect()
    const cs = getComputedStyle(el)
    return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
  }
  return {
    tenantWrap: Boolean(document.querySelector('[data-test=login-bar-tenant]')),
    phone: shown('[data-test=login-bar] [data-testid=top-bar-tenant-box]'),
    desk: shown('[data-test=login-bar] [data-testid=tenant-switcher]'),
    label: shown('[data-test=login-bar-workspace]') ? document.querySelector('[data-test=login-bar-workspace]').textContent.trim() : null,
    barText: document.querySelector('[data-test=login-bar]')?.textContent ?? '',
    whole: (() => {
      const el = document.querySelector('[data-test=login-bar-workspace]')
      return Boolean(el) && el.scrollWidth <= el.clientWidth
    })(),
    gap: (() => {
      const el = document.querySelector('[data-test=login-bar-workspace]')
      const end = document.querySelector('[data-test=login-bar-end]')
      return el && end ? Math.round(end.getBoundingClientRect().left - el.getBoundingClientRect().right) : null
    })(),
    xscroll: document.scrollingElement.scrollWidth - window.innerWidth,
    title: document.title,
  }
})

const noBox = (m) => !m.tenantWrap && !m.phone && !m.desk

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [360, 390, 1440]) {
    const tag = `${w}px`
    const touch = w <= 820
    for (const [query, want] of [['', 'spool-hub'], ['?tenant=globex', 'globex']]) {
      const ctx = await browser.createBrowserContext()
      const p = await ctx.newPage()
      await p.setViewport({ width: w, height: 800, isMobile: touch, hasTouch: touch })
      await p.goto(`${server.base}/login${query}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await p.waitForSelector('[data-test=login-bar-workspace]', { timeout: NAV_TIMEOUT }).catch(() => null)
      await adopt(p, null)
      await sleep(300)
      const out = await bar(p)
      check(`${tag} /login${query}: signed out, no workspace drop box`, noBox(out), out)
      check(`${tag} /login${query}: the bar names ${want}`, out.label === want, { label: out.label })
      const seeded = await adopt(p, { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', active_tenant: 't1', tenants: TENANTS })
      /* give the async drop box chunk the time it took on the 404 page */
      await sleep(1500)
      const m = await bar(p)
      check(`${tag} /login${query}: a session with two memberships, still no drop box`, seeded && noBox(m), { seeded, ...m })
      check(`${tag} /login${query}: signed in, the bar still names ${want}`, m.label === want, { label: m.label })
      check(`${tag} /login${query}: no membership name in the bar`, !/northwind|globex-corp/.test(m.barText), { barText: m.barText })
      check(`${tag} /login${query}: no membership name in the tab title`, !/northwind|globex-corp/.test(m.title) && m.title.endsWith(want === 'spool-hub' ? 'spool-hub' : `${want}.spool-hub`), { title: m.title })
      check(`${tag} /login${query}: the name is whole and clear of the controls`, m.whole && m.gap >= 0, { whole: m.whole, gap: m.gap })
      check(`${tag} /login${query}: no horizontal scroll`, m.xscroll <= 0, { xscroll: m.xscroll })
      await ctx.close()
    }
  }
  /* R7 N3: a tab that opened /login?tenant=globex keeps it (sessionStorage)
     and the form sends it on a later plain /login: the bar and tab say so */
  {
    const ctx = await browser.createBrowserContext()
    const p = await ctx.newPage()
    await p.setViewport({ width: 390, height: 800, isMobile: true, hasTouch: true })
    await p.goto(`${server.base}/login?tenant=globex`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.goto(`${server.base}/login`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=login-bar-workspace]', { timeout: NAV_TIMEOUT }).catch(() => null)
    await sleep(300)
    const out = await bar(p)
    check('390px /login after /login?tenant=globex: the bar names the stored globex', out.label === 'globex', { label: out.label })
    check('390px /login after /login?tenant=globex: the tab names globex.spool-hub', out.title.endsWith('globex.spool-hub'), { title: out.title })
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
console.log(`\nlogin-no-workspace-dropdown: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
