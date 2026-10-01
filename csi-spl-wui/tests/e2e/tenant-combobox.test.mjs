// HUM-10 (topic 20a30816): the workspace switcher is a searchable combobox.
//
// "one should be able to type and search and hit enter to switch to another
// workspace with the 'contains' case insensitive function". At 1440 px, with
// four synthetic workspaces (the mock has no hub: a switch re-points the
// local session, useTenantSwitch), proved in a real browser:
//   - a press on the box focuses it, opens the list and selects the name
//   - typing a mixed-case substring ("nItE") lists only the matching names
//   - Enter switches to the one left: the box and the session name it
//   - Up/Down move the highlight; Enter switches to the highlighted row
//   - a click on a row still switches
//   - Esc closes the list and puts the current name back
//   - CONTROL: a query that matches nothing shows no options, and Enter does
//     nothing (the workspace stays as it was)
//
// Run:
//   node tests/e2e/tenant-combobox.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/tenant-combobox.test.mjs
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

/* what the human sees: the box's text, the open list's rows, the highlight,
   and which workspace the session is on */
const state = (p) => p.evaluate((sel) => {
  const box = document.querySelector(sel)
  const list = document.querySelector('[data-testid=tenant-switcher-list]')
  const shown = !!list && getComputedStyle(list).display !== 'none'
  const rows = shown ? [...list.querySelectorAll('[role=option]')] : []
  const activeId = box.getAttribute('aria-activedescendant') || ''
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  return {
    value: box.value,
    expanded: box.getAttribute('aria-expanded'),
    focused: document.activeElement === box,
    selectedText: box.selectionStart === 0 && box.selectionEnd === box.value.length && box.value.length > 0,
    rows: rows.map((r) => r.textContent.trim()),
    active: activeId ? (document.getElementById(activeId)?.textContent || '').trim() : '',
    tenant: session?.claims?.active_tenant || '',
  }
}, BOX)

/* a fresh query: select what the box holds, then type over it */
async function typeQuery(p, text) {
  await p.click(BOX, { clickCount: 3 })
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.type(text)
  await sleep(150)
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${server.base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  const seeded = await p.evaluate((tenants) => {
    const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
    if (!session) return false
    session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', active_tenant: 't1', tenants })
    return true
  }, TENANTS)
  await p.waitForFunction((n) => document.querySelectorAll('[data-testid=tenant-switcher-option]').length === n, { timeout: 15000 }, TENANTS.length).catch(() => null)
  const s0 = await state(p)
  check('four workspaces, the box shows the current one', seeded && s0.value === 'northwind-trading' && s0.expanded === 'false', s0)

  /* a press opens the list, focused, the name selected for a fresh search */
  await p.click(BOX)
  await sleep(150)
  const s1 = await state(p)
  check('a press opens every workspace, the box focused and its name selected', s1.expanded === 'true' && s1.focused && s1.selectedText && s1.rows.length === TENANTS.length && s1.active === 'northwind-trading', s1)

  /* the ask: type a mixed-case substring, see the filtered list, Enter */
  await typeQuery(p, 'nItE')
  const s2 = await state(p)
  check('typing "nItE" lists only initech (case-insensitive contains)', s2.value === 'nItE' && s2.rows.length === 1 && s2.rows[0] === 'initech' && s2.active === 'initech', s2)
  await p.keyboard.press('Enter')
  await sleep(300)
  const s3 = await state(p)
  check('Enter switches to the one left: initech', s3.tenant === 't3' && s3.value === 'initech' && s3.expanded === 'false', s3)

  /* Up/Down move the highlight; Enter takes the highlighted row */
  await typeQuery(p, 'B')
  const s4 = await state(p)
  check('typing "B" lists globex and umbrella, globex highlighted', JSON.stringify(s4.rows) === JSON.stringify(['globex', 'umbrella']) && s4.active === 'globex', s4)
  await p.keyboard.press('ArrowDown')
  const s5 = await state(p)
  await p.keyboard.press('ArrowUp')
  const s6 = await state(p)
  await p.keyboard.press('ArrowDown')
  check('Down moves the highlight to umbrella, Up back to globex', s5.active === 'umbrella' && s6.active === 'globex', { down: s5.active, up: s6.active })
  await p.keyboard.press('Enter')
  await sleep(300)
  const s7 = await state(p)
  check('Enter switches to the highlighted row: umbrella', s7.tenant === 't4' && s7.value === 'umbrella', s7)

  /* CONTROL: nothing matches - no options, Enter does nothing */
  await typeQuery(p, 'zzQ')
  const s8 = await state(p)
  check('CONTROL: "zzQ" matches nothing - no options shown', s8.value === 'zzQ' && s8.rows.length === 0 && s8.active === '', s8)
  await p.keyboard.press('Enter')
  await sleep(300)
  const s9 = await state(p)
  check('CONTROL: Enter with no match does nothing (still umbrella)', s9.tenant === 't4' && s9.rows.length === 0, s9)

  /* Esc closes the list and restores the current name */
  await p.keyboard.press('Escape')
  await sleep(150)
  const s10 = await state(p)
  check('Esc closes the list and puts the current name back', s10.expanded === 'false' && s10.value === 'umbrella' && s10.tenant === 't4', s10)

  /* a click on a row still switches */
  await p.click(BOX)
  await sleep(150)
  await p.click('[data-testid=tenant-switcher-option][data-tenant="t2"]')
  await sleep(300)
  const s11 = await state(p)
  check('a click on globex switches to it', s11.tenant === 't2' && s11.value === 'globex' && s11.expanded === 'false', s11)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntenant-combobox: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
