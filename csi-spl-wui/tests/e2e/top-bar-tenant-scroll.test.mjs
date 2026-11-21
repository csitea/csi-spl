// SPL-6106 (epic SPL-2403, owner HUM-10 t1 b08c3fa8): "There is a bug in the
// scrolling of the workspaces switcher in the mobile interface." - "As soon as
// I scroll, the dropdown list disappears".
//
// On a phone (390 x 844, touch emulated) with enough synthetic workspaces to
// scroll the bottom sheet (TopBarTenantSheet, SPL-995): open the switcher,
// scroll its list with a touch drag, and the sheet is still open, its list
// moved, and a tap on a row further down still picks that workspace. Proved
// at level 1 (`/`) and at a level-2 page (`/lobby`).
//
// Run:
//   node tests/e2e/top-bar-tenant-scroll.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/top-bar-tenant-scroll.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const COUNT = 30
const TENANTS = Array.from({ length: COUNT }, (_, i) => ({ tenant_id: `t${i + 1}`, display_name: `Workspace ${String(i + 1).padStart(2, '0')}` }))
const SHEET = '[data-testid=top-bar-tenant-sheet]'
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

const signIn = (p) => p.evaluate((tenants) => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', active_tenant: 't1', tenants })
  return true
}, TENANTS)

/* the sheet as the human sees it: open, how far its list is scrolled, the session's workspace */
const sheetState = (p) => p.evaluate((sel) => {
  const sheet = document.querySelector(sel)
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  return {
    /* visibility and opacity too: a sheet still in the DOM under a hidden bar is gone for the human */
    open: !!sheet && sheet.getBoundingClientRect().height > 0 && sheet.checkVisibility({ visibilityProperty: true, opacityProperty: true }),
    barsHidden: document.querySelector('.app-frame')?.getAttribute('data-mobile-bars-hidden') === '1',
    scrollTop: sheet ? Math.round(sheet.scrollTop) : -1,
    scrollable: sheet ? sheet.scrollHeight > sheet.clientHeight : false,
    tenant: session?.claims?.active_tenant || '',
  }
}, SHEET)

/* a finger drag up the sheet: the compositor's own touch scroll, as on a phone */
async function touchScroll(p) {
  const r = await p.$eval(SHEET, (el) => { const b = el.getBoundingClientRect(); return { x: Math.round(b.x + b.width / 2), y: Math.round(b.y + b.height * 0.75) } })
  await p.touchscreen.touchStart(r.x, r.y)
  for (let i = 1; i <= 10; i++) {
    await p.touchscreen.touchMove(r.x, r.y - i * 30)
    await sleep(16)
  }
  await p.touchscreen.touchEnd()
  await sleep(500)
}

async function scrollKeepsOpen(p, base, path) {
  const tag = `390px ${path}`
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(`${base}${path}`, { waitUntil: 'load' })
  await p.waitForSelector('[data-test=top-bar]')
  if (!(await signIn(p))) throw new Error('no session store')
  await p.waitForSelector('[data-test=user-menu-trigger]')
  await sleep(400)
  await p.tap('[data-testid=top-bar-tenant-box]')
  await p.waitForSelector(`[data-testid=top-bar-tenant-option][data-tenant=t${COUNT}]`)
  await sleep(300)
  const before = await sheetState(p)
  check(`${tag}: the sheet opens and its ${COUNT} rows overflow it`, before.open && before.scrollable, before)
  await touchScroll(p)
  const after = await sheetState(p)
  check(`${tag}: a touch scroll of the list keeps the sheet open`, after.open, { before, after })
  check(`${tag}: the list scrolled`, after.open && after.scrollTop > before.scrollTop, { before, after })
  if (!after.open) return
  const pick = `t${COUNT - 2}`
  await p.tap(`[data-testid=top-bar-tenant-option][data-tenant=${pick}]`)
  await sleep(500)
  const picked = await sheetState(p)
  check(`${tag}: a row further down can then be picked`, picked.tenant === pick && !picked.open, picked)
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const path of ['/', '/lobby']) {
    const p = await browser.newPage()
    await scrollKeepsOpen(p, server.base, path)
    await p.close()
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntop-bar-tenant-scroll: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
