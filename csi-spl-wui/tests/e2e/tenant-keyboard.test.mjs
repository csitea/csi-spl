// SPL-2268 (owner t1 b21bbf73): "the tenants switching dropbox does not
// accept typical keyboard sequence inputs". The owner's test: "while it is
// selected type 3 letters for it to show the letter insensitive match, and
// when I hit enter the match to get selected and I to be forwarded to the new
// workspace chosen, or to select it with the arrows and hit enter".
//
// Both switchers, four synthetic workspaces (the mock has no hub: a switch
// re-points the local session, useTenantSwitch; live, the same call goes to
// the workspace's host):
//   - 1440 px, the top-bar drop box (TenantDropBox): 3 letters in another
//     case list only the match and Enter switches to it; Down / Up + Enter;
//     Home / End jump to the first / last row; Esc closes, the box keeps
//     the focus
//   - 800 px with a mouse, the top-bar sheet (TopBarTenant): the open sheet
//     focuses its search box; the owner's 3 letters + Enter switch and close
//     the sheet; Down / Home / End move the highlight; Esc closes and gives
//     the focus back to the box (the red before SPL-2268: typing, the arrows
//     and Enter did nothing there)
//   - 390 px touch: the open sheet focuses the current row (no on-screen
//     keyboard); Down moves to the next row; a letter goes to the search box
//
// Run:
//   node tests/e2e/tenant-keyboard.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/tenant-keyboard.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TENANTS = [
  { tenant_id: 't1', name: 'northwind-trading' },
  { tenant_id: 't2', name: 'globex' },
  { tenant_id: 't3', name: 'initech' },
  { tenant_id: 't4', name: 'umbrella' },
]
const BOX = '[data-testid=tenant-switcher-select]'
const TB_BOX = '[data-testid=top-bar-tenant-box]'
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

async function openAt(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: 900, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const seeded = await p.evaluate((tenants) => {
    const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
    if (!session) return false
    session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', active_tenant: 't1', tenants })
    return true
  }, TENANTS)
  await sleep(300)
  return { p, seeded }
}

/* the desktop box: its text, the open list's rows, the highlight, the session */
const desk = (p) => p.evaluate((sel) => {
  const box = document.querySelector(sel)
  const list = document.querySelector('[data-testid=tenant-switcher-list]')
  const shown = !!list && getComputedStyle(list).display !== 'none'
  const activeId = box.getAttribute('aria-activedescendant') || ''
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  return {
    value: box.value,
    expanded: box.getAttribute('aria-expanded'),
    focused: document.activeElement === box,
    rows: shown ? [...list.querySelectorAll('[role=option]')].map((r) => r.textContent.trim()) : [],
    active: activeId ? (document.getElementById(activeId)?.textContent || '').trim() : '',
    tenant: session?.claims?.active_tenant || '',
  }
}, BOX)

/* the top-bar sheet: open, its rows, the highlight, where the focus is */
const sheet = (p) => p.evaluate(() => {
  const search = document.querySelector('[data-testid=top-bar-tenant-search]')
  const activeId = search?.getAttribute('aria-activedescendant') || ''
  const a = document.activeElement
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  return {
    open: !!document.querySelector('[data-testid=top-bar-tenant-sheet]'),
    query: search ? search.value : null,
    role: search?.getAttribute('role') || '',
    rows: [...document.querySelectorAll('[data-testid=top-bar-tenant-option]')].map((r) => r.textContent.trim()),
    active: activeId ? (document.getElementById(activeId)?.textContent || '').trim() : '',
    focus: a === search ? 'search' : (a?.getAttribute('data-testid') === 'top-bar-tenant-option' ? 'row:' + a.getAttribute('data-tenant') : (a?.getAttribute('data-testid') || a?.tagName || '')),
    tenant: session?.claims?.active_tenant || '',
  }
})

async function desktopBox(browser, base) {
  const { p, seeded } = await openAt(browser, base, 1440, false)
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  check('1440px: four workspaces seeded', seeded)

  /* the owner's test: focus, 3 letters in another case, Enter */
  await p.click(BOX)
  await sleep(150)
  await p.keyboard.type('UMB')
  await sleep(150)
  const a = await desk(p)
  check('1440px owner test: "UMB" lists only umbrella, highlighted', JSON.stringify(a.rows) === '["umbrella"]' && a.active === 'umbrella', a)
  await p.keyboard.press('Enter')
  await sleep(300)
  const b = await desk(p)
  check('1440px owner test: Enter switches to umbrella', b.tenant === 't4' && b.value === 'umbrella' && b.expanded === 'false', b)

  /* Down / Up + Enter */
  await p.keyboard.press('ArrowDown')
  await sleep(100)
  const c0 = await desk(p)
  await p.keyboard.press('ArrowDown')
  const c1 = await desk(p)
  await p.keyboard.press('ArrowDown')
  await p.keyboard.press('ArrowUp')
  const c2 = await desk(p)
  check('1440px: Down opens the list on the current row, Down / Up move the highlight', c0.expanded === 'true' && c0.active === 'umbrella' && c1.active === 'northwind-trading' && c2.active === 'northwind-trading', { open: c0.active, down: c1.active, downUp: c2.active })
  await p.keyboard.press('ArrowDown')
  await p.keyboard.press('Enter')
  await sleep(300)
  const c3 = await desk(p)
  check('1440px: arrows + Enter switch to globex', c3.tenant === 't2' && c3.value === 'globex', c3)

  /* Home / End */
  await p.keyboard.press('ArrowDown')
  await p.keyboard.press('End')
  const d1 = await desk(p)
  await p.keyboard.press('Home')
  const d2 = await desk(p)
  check('1440px: End jumps to the last row, Home to the first', d1.active === 'umbrella' && d2.active === 'northwind-trading', { end: d1.active, home: d2.active })

  /* Esc */
  await p.keyboard.press('Escape')
  await sleep(100)
  const e = await desk(p)
  check('1440px: Esc closes the list, the box keeps the focus and the current name', e.expanded === 'false' && e.focused && e.value === 'globex' && e.tenant === 't2', e)
  await p.close()
}

async function narrowSheet(browser, base) {
  const { p, seeded } = await openAt(browser, base, 800, false)
  await p.waitForSelector(TB_BOX, { visible: true, timeout: NAV_TIMEOUT })
  check('800px: four workspaces seeded', seeded)

  await p.click(TB_BOX)
  await sleep(300)
  const a = await sheet(p)
  check('800px (mouse): the open sheet focuses its search box (a combobox), the current row highlighted', a.open && a.focus === 'search' && a.role === 'combobox' && a.active === 'northwind-trading' && a.rows.length === 4, a)

  /* the owner's test */
  await p.keyboard.type('nIt')
  await sleep(150)
  const b = await sheet(p)
  check('800px owner test: "nIt" lists only initech, highlighted', JSON.stringify(b.rows) === '["initech"]' && b.active === 'initech', b)
  await p.keyboard.press('Enter')
  await sleep(300)
  const c = await sheet(p)
  check('800px owner test: Enter switches to initech, the sheet closes, the box has the focus', c.tenant === 't3' && !c.open && c.focus === 'top-bar-tenant-box', c)

  /* arrows, Home / End, Enter */
  await p.click(TB_BOX)
  await sleep(300)
  const d0 = await sheet(p)
  await p.keyboard.press('ArrowDown')
  const d1 = await sheet(p)
  await p.keyboard.press('End')
  const d2 = await sheet(p)
  await p.keyboard.press('Home')
  const d3 = await sheet(p)
  await p.keyboard.press('ArrowUp')
  const d4 = await sheet(p)
  check('800px: Down / End / Home / Up move the highlight (wrapping)', d0.active === 'initech' && d1.active === 'umbrella' && d2.active === 'umbrella' && d3.active === 'northwind-trading' && d4.active === 'umbrella', [d0.active, d1.active, d2.active, d3.active, d4.active])
  await p.keyboard.press('ArrowDown')
  await p.keyboard.press('ArrowDown')
  await p.keyboard.press('Enter')
  await sleep(300)
  const d5 = await sheet(p)
  check('800px: arrows + Enter switch to globex', d5.tenant === 't2' && !d5.open, d5)

  /* CONTROL: no match, Enter does nothing; Esc closes, focus to the box */
  await p.click(TB_BOX)
  await sleep(300)
  await p.keyboard.type('zzq')
  await p.keyboard.press('Enter')
  await sleep(300)
  const e0 = await sheet(p)
  check('800px CONTROL: "zzq" lists nothing and Enter switches nothing', e0.open && e0.rows.length === 0 && e0.tenant === 't2', e0)
  await p.keyboard.press('Escape')
  await sleep(150)
  const e1 = await sheet(p)
  check('800px: Esc closes the sheet and gives the focus back to the box', !e1.open && e1.focus === 'top-bar-tenant-box' && e1.tenant === 't2', e1)
  await p.close()
}

async function touchSheet(browser, base) {
  const { p, seeded } = await openAt(browser, base, 390, true)
  await p.waitForSelector(TB_BOX, { visible: true, timeout: NAV_TIMEOUT })
  check('390px touch: four workspaces seeded', seeded)
  await p.tap(TB_BOX)
  await sleep(300)
  const a = await sheet(p)
  check('390px touch: the open sheet focuses the current row, not the search box', a.open && a.focus === 'row:t1', a)
  await p.keyboard.press('ArrowDown')
  const b = await sheet(p)
  check('390px touch: Down on a row moves the focus to the next row', b.focus === 'row:t2', b)
  await p.keyboard.type('umb')
  await sleep(150)
  const c = await sheet(p)
  check('390px touch: letters typed on a row go to the search box and filter', c.focus === 'search' && c.query === 'umb' && JSON.stringify(c.rows) === '["umbrella"]', c)
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await desktopBox(browser, server.base)
  await narrowSheet(browser, server.base)
  await touchSheet(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntenant-keyboard: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
