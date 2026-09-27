// SPL-990 (epic SPL-988, lane M2): the top bar on phones and small tablets.
//
// At 360 and 820 px (touch emulated) the bar is ONE row of the tenant switcher and the avatar; the logo, the theme picker
// and the language switcher are out of the row. The owner's E (topic
// e0b12a2c): a round GO button floats at the vertical middle of the right
// edge, clear of the bottom dock and the Issues +; it opens a
// full-screen sheet whose composer and GO are on screen, and its close button
// shuts it. The avatar opens a bottom sheet that carries language, theme and
// the notification toggles (the rail's copy is hidden). Every control named
// here is >= 44 px, and the page never scrolls sideways.
// At 1440 px the desktop bar is unchanged: omnibox, logo, theme, language
// in the row, no search icon, no tenant label, and no phone rows in the menu.
//
// Run:
//   node tests/e2e/top-bar-mobile.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/top-bar-mobile.test.mjs
// Starts `nuxi dev` with the mock tenant when BASE_URL is unset. The mock
// has no session, so the test signs a member in through the session store
// (adopt), the same call a native sign-in makes.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const TAP = 44
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

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

/** rect + computed display of each selector, null when absent */
const probe = (p, sels) => p.evaluate((sels) => Object.fromEntries(sels.map((s) => {
  const el = document.querySelector(s)
  if (!el) return [s, null]
  const r = el.getBoundingClientRect()
  const cs = getComputedStyle(el)
  const shown = cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
  return [s, { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), b: Math.round(r.bottom), shown }]
})), sels)

const noXScroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function open(p, base, width, height, touch) {
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}/lobby`, { waitUntil: 'load' })
  await p.waitForSelector('[data-test=top-bar]')
  if (!(await signIn(p))) throw new Error('no session store')
  await p.waitForSelector('[data-test=user-menu-trigger]')
  await sleep(400)
}

async function phone(p, base, width) {
  const tag = `${width}px`
  await open(p, base, width, 800, true)
  const bar = await probe(p, [
    '[data-test=top-bar]', '[data-test=top-bar-tenant]', '[data-test=top-bar-search-toggle]',
    '[data-test=user-menu-trigger]', '.top-bar__brand', '[data-test=theme-picker]', '[data-test=lang-switcher]',
    '[data-testid=notify-box-rail]',
  ])
  const row = bar['[data-test=top-bar]']
  check(`${tag}: the bar is one row of --top-bar-h`, row && row.h <= 58, row)
  check(`${tag}: tenant name shown`, bar['[data-test=top-bar-tenant]']?.shown === true, bar['[data-test=top-bar-tenant]'])
  for (const s of ['[data-test=top-bar-search-toggle]', '[data-test=user-menu-trigger]']) {
    const r = bar[s]
    check(`${tag}: ${s} shown, >= ${TAP} px`, r?.shown && r.w >= TAP && r.h >= TAP, r)
  }
  const av = bar['[data-test=user-menu-trigger]']
  check(`${tag}: the avatar inside the bar`, av && av.y >= 0 && av.b <= row.b, av)
  const fab = bar['[data-test=top-bar-search-toggle]']
  const view = await p.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight }))
  const dockTop = await p.evaluate(() => {
    const d = document.querySelector('.composer--dock')
    return d ? Math.round(d.getBoundingClientRect().top) : window.innerHeight
  })
  check(`${tag}: GO floats at the middle of the right edge, round, labelled`, fab && fab.x + fab.w <= view.w && view.w - (fab.x + fab.w) <= 16
    && Math.abs(fab.y + fab.h / 2 - view.h / 2) <= 2 && fab.b < dockTop && fab.y > row.b
    && await p.evaluate(() => {
      const b = document.querySelector('[data-test=top-bar-search-toggle]')
      return getComputedStyle(b).borderRadius === '50%' && b.getAttribute('aria-label') === b.title && b.title.length > 0
    }), { fab, view, dockTop })
  for (const s of ['.top-bar__brand', '[data-test=theme-picker]', '[data-test=lang-switcher]', '[data-testid=notify-box-rail]']) {
    check(`${tag}: ${s} is out of the row`, !bar[s]?.shown, bar[s])
  }
  check(`${tag}: no horizontal scroll`, await noXScroll(p))

  // the search sheet
  await p.click('[data-test=top-bar-search-toggle]')
  await sleep(300)
  const sheet = await probe(p, ['[data-test=top-bar-omnibox]', '[data-test=top-bar-omnibox] textarea', '[data-test=top-bar-omnibox] .composer-go', '[data-test=top-bar-search-close]'])
  const vp = await p.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight }))
  const s0 = sheet['[data-test=top-bar-omnibox]']
  check(`${tag}: search opens a full-screen sheet`, s0?.shown && s0.x === 0 && s0.y === 0 && s0.w === vp.w && s0.h === vp.h, { s0, vp })
  const ta = sheet['[data-test=top-bar-omnibox] textarea']
  check(`${tag}: the sheet's box is on screen and focused`, ta?.shown && ta.b <= vp.h
    && await p.evaluate(() => document.activeElement?.closest('[data-test=top-bar-omnibox]') !== null), ta)
  const go = sheet['[data-test=top-bar-omnibox] .composer-go']
  check(`${tag}: GO reachable in the sheet`, go?.shown && go.x + go.w <= vp.w && go.b <= vp.h, go)
  const close = sheet['[data-test=top-bar-search-close]']
  check(`${tag}: close >= ${TAP} px`, close?.shown && close.w >= TAP && close.h >= TAP, close)
  check(`${tag}: no horizontal scroll with the sheet open`, await noXScroll(p))
  await p.click('[data-test=top-bar-search-close]')
  await sleep(200)
  const shut = await probe(p, ['[data-test=top-bar-omnibox] textarea'])
  check(`${tag}: close shuts the sheet`, !shut['[data-test=top-bar-omnibox] textarea']?.shown || (shut['[data-test=top-bar-omnibox] textarea'].y > 100), shut)

  // the avatar bottom sheet
  await p.click('[data-test=user-menu-trigger]')
  await p.waitForSelector('[data-test=user-menu-prefs]', { timeout: 10000 }).catch(() => {})
  await p.waitForSelector('[data-test=user-menu-prefs] [data-test=lang-switcher]', { timeout: 10000 }).catch(() => {})
  await sleep(300)
  const menu = await probe(p, [
    '[data-test=user-menu-panel]', '[data-test=user-menu-scrim]', '[data-test=user-menu-language]', '[data-test=user-menu-theme]',
    '[data-test=user-menu-notify]', '[data-test=user-menu-prefs] [data-test=lang-switcher]', '[data-test=user-menu-prefs] [data-test=theme-picker]',
    '[data-test=user-menu-prefs] [data-testid=notify-alerts]', '[data-test=user-menu-prefs] [data-testid=notify-chime]',
    '[data-test=user-menu-settings]', '[data-test=user-menu-signout]',
  ])
  const panel = menu['[data-test=user-menu-panel]']
  check(`${tag}: the avatar menu is a bottom sheet (full width, on the bottom edge)`, panel?.shown && panel.x === 0 && panel.w === vp.w && panel.b === vp.h, panel)
  check(`${tag}: a scrim sits behind it`, menu['[data-test=user-menu-scrim]']?.shown === true)
  for (const s of ['[data-test=user-menu-language]', '[data-test=user-menu-theme]', '[data-test=user-menu-notify]', '[data-test=user-menu-settings]', '[data-test=user-menu-signout]']) {
    const r = menu[s]
    check(`${tag}: ${s} row shown, >= ${TAP} px tall`, r?.shown && r.h >= TAP, r)
  }
  for (const s of ['[data-test=user-menu-prefs] [data-test=lang-switcher]', '[data-test=user-menu-prefs] [data-test=theme-picker]', '[data-test=user-menu-prefs] [data-testid=notify-alerts]', '[data-test=user-menu-prefs] [data-testid=notify-chime]']) {
    const r = menu[s]
    check(`${tag}: ${s} in the sheet, >= ${TAP} px tall`, r?.shown && r.h >= TAP && r.x >= 0 && r.x + r.w <= vp.w, r)
  }
  check(`${tag}: no horizontal scroll with the menu open`, await noXScroll(p))
  await p.click('[data-test=user-menu-scrim]', { offset: { x: 10, y: 10 } })
  await sleep(200)
  const gone = await probe(p, ['[data-test=user-menu-panel]'])
  check(`${tag}: a tap on the scrim closes the sheet`, !gone['[data-test=user-menu-panel]']?.shown, gone)

  // the owner's E: GO -> the sheet -> `/search x` -> the results
  await p.click('[data-test=top-bar-search-toggle]')
  await sleep(300)
  await p.keyboard.type('/search hello')
  await p.keyboard.press('Enter')
  await p.waitForFunction(() => /\/search/.test(location.pathname), { timeout: 10000 }).catch(() => {})
  await sleep(400)
  const q = await p.evaluate(() => ({ path: location.pathname, q: new URLSearchParams(location.search).get('q') }))
  const after = await probe(p, ['[data-test=top-bar-search-close]'])
  check(`${tag}: GO -> /search hello opens the results, the sheet closes`, /\/search$/.test(q.path) && q.q === 'hello' && !after['[data-test=top-bar-search-close]']?.shown, { q, after })
}

async function desktop(p, base) {
  const tag = '1440px'
  await open(p, base, 1440, 900, false)
  const bar = await probe(p, [
    '[data-test=top-bar]', '[data-test=top-bar-omnibox] textarea', '.top-bar__brand', '[data-test=theme-picker]', '[data-test=lang-switcher]',
    '[data-test=top-bar-search-toggle]', '[data-test=top-bar-tenant]', '[data-testid=notify-box-rail]',
  ])
  check(`${tag}: bar height unchanged (58)`, bar['[data-test=top-bar]']?.h === 58, bar['[data-test=top-bar]'])
  for (const s of ['[data-test=top-bar-omnibox] textarea', '.top-bar__brand', '[data-test=theme-picker]', '[data-test=lang-switcher]', '[data-testid=notify-box-rail]']) {
    check(`${tag}: ${s} in place`, bar[s]?.shown === true, bar[s])
  }
  for (const s of ['[data-test=top-bar-search-toggle]', '[data-test=top-bar-tenant]']) {
    check(`${tag}: ${s} takes no space`, !bar[s]?.shown, bar[s])
  }
  await p.click('[data-test=user-menu-trigger]')
  await sleep(300)
  const menu = await probe(p, ['[data-test=user-menu-panel]', '[data-test=user-menu-prefs]', '[data-test=user-menu-scrim]'])
  const panel = menu['[data-test=user-menu-panel]']
  check(`${tag}: the menu is the 272 px dropdown`, panel?.shown && panel.w === 272 && panel.y < 80, panel)
  check(`${tag}: no phone rows, no scrim`, !menu['[data-test=user-menu-prefs]']?.shown && !menu['[data-test=user-menu-scrim]']?.shown, menu)
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
console.log(`\ntop-bar-mobile: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
