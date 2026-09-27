// SPL-995 (epic SPL-988): the tenant switcher in the phone top bar.
//
// At 360, 390 and 820 px (touch emulated) the switcher is a bordered drop box
// first in the top bar (the owner's E: [tenant ▾] ... [avatar]), a >= 44 px target; the
// level-1 section strip no longer shows it (never twice). A long tenant name
// ends in an ellipsis inside the box. A press opens a bottom sheet (full
// width, on the bottom edge, over a scrim) listing every tenant; the scrim
// closes it. At 1440 px the top-bar box takes no space and the sidebar's
// drop box is where it was.
//
// The mock has no session: the test adopts one with two tenant memberships
// (the claims a native sign-in carries), one of them with a long name.
//
// Run:
//   node tests/e2e/top-bar-tenant.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/top-bar-tenant.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const TAP = 44
const LONG = 'A tenant with a very long display name that cannot fit in the bar'
const results = []
function check(name, pass, ev) {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const signIn = (p, long) => p.evaluate((long) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({
    hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', active_tenant: 't1',
    tenants: [{ tenant_id: 't1', display_name: long }, { tenant_id: 't2', display_name: 'Second' }],
  })
  return true
}, long)

const probe = (p, sels) => p.evaluate((sels) => Object.fromEntries(sels.map((s) => {
  const el = document.querySelector(s)
  if (!el) return [s, null]
  const r = el.getBoundingClientRect()
  const cs = getComputedStyle(el)
  const shown = cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
  return [s, { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), r: Math.round(r.right), b: Math.round(r.bottom), shown }]
})), sels)

const noXScroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function open(p, base, width, height, touch, path) {
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}${path}`, { waitUntil: 'load' })
  await p.waitForSelector('[data-test=top-bar]')
  if (!(await signIn(p, LONG))) throw new Error('no session store')
  await p.waitForSelector('[data-test=user-menu-trigger]')
  await sleep(400)
}

async function phone(p, base, width) {
  const tag = `${width}px`
  /* `/` is level 1 on a phone (SPL-989): the section strip is on screen */
  await open(p, base, width, 800, true, '/')
  const m = await probe(p, [
    '[data-test=top-bar]', '[data-testid=top-bar-tenant-box]', '[data-testid=top-bar-tenant-name]',
    '[data-test=top-bar-search-toggle]', '[data-test=user-menu-trigger]', '[data-testid=tenant-switcher]',
  ])
  const bar = m['[data-test=top-bar]']
  const box = m['[data-testid=top-bar-tenant-box]']
  const search = m['[data-test=top-bar-search-toggle]']
  check(`${tag}: the tenant box is in the bar, >= ${TAP} px`, box?.shown && box.w >= TAP && box.h >= TAP && box.y >= bar.y && box.b <= bar.b, { box, bar })
  check(`${tag}: first in the row, at the start edge`, box && box.x <= 16, { box, search })
  check(`${tag}: the sidebar strip does not show it (not twice)`, !m['[data-testid=tenant-switcher]']?.shown, m['[data-testid=tenant-switcher]'])
  const ell = await p.evaluate(() => {
    const el = document.querySelector('[data-testid=top-bar-tenant-name]')
    if (!(el instanceof HTMLElement)) return null
    const cs = getComputedStyle(el)
    return { clipped: el.scrollWidth > el.clientWidth, overflow: cs.textOverflow, pad: [cs.paddingInlineStart, cs.paddingInlineEnd] }
  })
  check(`${tag}: a long name ends in an ellipsis`, ell?.clipped === true && ell.overflow === 'ellipsis', ell)
  check(`${tag}: SPL-980 2px before and after the name`, ell?.pad?.[0] === '2px' && ell?.pad?.[1] === '2px', ell)
  /* owner 2026-09-27 (topic 72773b61): the control 4 px wider, all of it between the name and the arrow (4px -> 8px) */
  const gap = await p.evaluate(() => {
    const name = document.querySelector('[data-testid=top-bar-tenant-name]')
    const arrow = document.querySelector('[data-testid=top-bar-tenant-box] .tb-tenant__arrow')
    if (!name || !arrow) return null
    return arrow.getBoundingClientRect().left - (name.getBoundingClientRect().right - parseFloat(getComputedStyle(name).paddingInlineEnd))
  })
  check(`${tag}: the arrow sits 8px after the name (SPL-980, +4 px)`, gap !== null && Math.abs(gap - 8) <= 0.5, { gap })
  check(`${tag}: no horizontal scroll`, await noXScroll(p))

  await p.click('[data-testid=top-bar-tenant-box]')
  await sleep(300)
  const s = await probe(p, ['[data-testid=top-bar-tenant-sheet]', '[data-testid=top-bar-tenant-scrim]'])
  const vp = await p.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight }))
  const sheet = s['[data-testid=top-bar-tenant-sheet]']
  check(`${tag}: the list opens as a bottom sheet`, sheet?.shown && sheet.x === 0 && sheet.w === vp.w && sheet.b === vp.h, { sheet, vp })
  const rows = await p.$$eval('[data-testid=top-bar-tenant-option]', (els) => els.map((e) => ({
    id: e.getAttribute('data-tenant'), sel: e.getAttribute('aria-selected'), h: Math.round(e.getBoundingClientRect().height),
  })))
  check(`${tag}: it lists every tenant, the active one selected, rows >= ${TAP} px`,
    rows.length === 2 && rows[0].id === 't1' && rows[0].sel === 'true' && rows[1].sel === 'false' && rows.every((r) => r.h >= TAP), rows)
  check(`${tag}: the sheet takes the focus`, await p.evaluate(() => document.activeElement?.getAttribute('data-testid') === 'top-bar-tenant-option'))
  const url = p.url()
  await p.click('[data-testid=top-bar-tenant-option][data-tenant=t1]')
  await sleep(200)
  const after = await probe(p, ['[data-testid=top-bar-tenant-sheet]'])
  check(`${tag}: picking the current tenant closes the sheet, no navigation`, !after['[data-testid=top-bar-tenant-sheet]'] && p.url() === url, { url: p.url() })
  await p.click('[data-testid=top-bar-tenant-box]')
  await sleep(200)
  await p.click('[data-testid=top-bar-tenant-scrim]', { offset: { x: 10, y: 10 } })
  await sleep(200)
  const gone = await probe(p, ['[data-testid=top-bar-tenant-sheet]'])
  check(`${tag}: a tap on the scrim closes the sheet`, !gone['[data-testid=top-bar-tenant-sheet]'], gone)
}

async function desktop(p, base) {
  const tag = '1440px'
  await open(p, base, 1440, 900, false, '/lobby')
  const m = await probe(p, ['[data-test=top-bar-tenant]', '[data-testid=top-bar-tenant-box]', '[data-testid=tenant-switcher]', '[data-testid=tenant-switcher-select]'])
  check(`${tag}: the top-bar box takes no space`, !m['[data-test=top-bar-tenant]']?.shown && !m['[data-testid=top-bar-tenant-box]']?.shown, m)
  check(`${tag}: the sidebar drop box is the switcher`, m['[data-testid=tenant-switcher]']?.shown === true && m['[data-testid=tenant-switcher-select]']?.shown === true, m)
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  const p = await browser.newPage()
  for (const w of [360, 390, 820]) await phone(p, server.base, w)
  await desktop(p, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntop-bar-tenant: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
