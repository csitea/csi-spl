// SPL-990 (epic SPL-988, lane M2): the top bar on phones and small tablets.
//
// At 360 and 820 px (touch emulated) the bar is ONE row of the tenant switcher and the avatar; the logo, the theme picker
// and the language switcher are out of the row. SPL-1005 (owner, topic
// 9b58a27b) retired E's floating GO at the middle of the right edge and its
// full-screen sheet: the docked composer's bottom-right Send is the GO, and
// `/search hello` typed there opens the results. The avatar opens a bottom sheet that carries language, theme and
// the notification toggles (the rail's copy is hidden). Every control named
// here is >= 44 px, and the page never scrolls sideways.
// At 1440 px the desktop bar: omnibox, logo, theme in the row, no floating
// GO, no tenant label. Spec 109 FR-008: no language switcher in the bar; the
// avatar dropdown has it (its one desktop pref row, no other phone row).
// FR-009: the dropdown offers Workspace settings only while the channels
// rail (and its gear) is collapsed - one entry on screen either way.
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
    '.composer--dock [data-testid=send]', '[data-test=user-menu-trigger]', '[data-testid=tenant-switcher]', '[data-test=theme-picker]', '[data-test=lang-switcher]',
    '[data-testid=notify-box-rail]',
  ])
  const row = bar['[data-test=top-bar]']
  check(`${tag}: the bar is one row of --top-bar-h`, row && row.h <= 58, row)
  check(`${tag}: tenant name shown`, bar['[data-test=top-bar-tenant]']?.shown === true, bar['[data-test=top-bar-tenant]'])
  for (const s of ['.composer--dock [data-testid=send]', '[data-test=user-menu-trigger]']) {
    const r = bar[s]
    check(`${tag}: ${s} shown, >= ${TAP} px`, r?.shown && r.w >= TAP && r.h >= TAP, r)
  }
  const av = bar['[data-test=user-menu-trigger]']
  check(`${tag}: the avatar inside the bar`, av && av.y >= 0 && av.b <= row.b, av)
  const go = bar['.composer--dock [data-testid=send]']
  /* CLE-77888: the dock sits on the ~5 mm bottom status strip - its top is the floor */
  const view = await p.evaluate(() => ({ w: window.innerWidth, h: window.innerHeight }))
  const floor = view.h - await p.evaluate(() => document.querySelector('[data-test=status-strip]')?.getBoundingClientRect().height || 0)
  check(`${tag}: no floating GO (SPL-1005); the GO is the dock's bottom-right button`, !bar['[data-test=top-bar-search-toggle]']
    && go && view.w - (go.x + go.w) <= 24 && floor - go.b <= 24
    && await p.evaluate(() => {
      const b = document.querySelector('.composer--dock [data-testid=send]')
      return getComputedStyle(b).borderRadius === '50%' && b.querySelector('svg')?.getAttribute('data-icon') === 'go'
    }), { go, view, floor })
  for (const s of ['[data-testid=tenant-switcher]', '[data-test=theme-picker]', '[data-test=lang-switcher]', '[data-testid=notify-box-rail]']) {
    check(`${tag}: ${s} is out of the row`, !bar[s]?.shown, bar[s])
  }
  check(`${tag}: no horizontal scroll`, await noXScroll(p))
  /* owner 2026-09-27 (topic 86a570ea): the start screen shows no connection
     dot (nor bell / note) on a phone - they live in the avatar sheet.
     CLE-77888 (t1 1701ae89 + 3c298fd9): nor the version - the sidebar's
     footer row is gone on a phone; dot, bell, note and version are the
     bottom status strip */
  /* `/` is level 1 on a phone (SPL-989): the sidebar is the screen */
  await p.goto(`${base}/`, { waitUntil: 'load' })
  await p.waitForSelector('[data-test=status-strip-version]', { visible: true, timeout: 20000 }).catch(() => {})
  await sleep(300)
  const foot = await probe(p, ['[data-testid=connection-health]', '[data-test=app-version]', '[data-test=status-strip-version]'])
  check(`${tag}: level 1 shows no footer row (no version, no dot); the version is the strip's`, !foot['[data-test=app-version]']?.shown && !foot['[data-testid=connection-health]']?.shown && foot['[data-test=status-strip-version]']?.shown === true, foot)
  await open(p, base, width, 800, true)

  const vp = view
  // the avatar bottom sheet
  await p.click('[data-test=user-menu-trigger]')
  await p.waitForSelector('[data-test=user-menu-prefs]', { timeout: 10000 }).catch(() => {})
  await p.waitForSelector('[data-test=user-menu-prefs] [data-test=lang-switcher]', { timeout: 10000 }).catch(() => {})
  await sleep(300)
  const menu = await probe(p, [
    '[data-test=user-menu-panel]', '[data-test=user-menu-scrim]', '[data-test=user-menu-language]', '[data-test=user-menu-theme]',
    '[data-test=user-menu-notify]', '[data-test=user-menu-prefs] [data-test=lang-switcher]', '[data-test=user-menu-prefs] [data-test=theme-picker]',
    '[data-test=user-menu-prefs] [data-testid=notify-alerts]', '[data-test=user-menu-prefs] [data-testid=notify-chime]',
    '[data-test=user-menu-settings]', '[data-test=user-menu-signout]', '[data-test=user-menu-connection]',
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
  /* topic 86a570ea: the hub connection, next to the bell and the note */
  const conn = menu['[data-test=user-menu-connection]']
  const notifyRow = menu['[data-test=user-menu-notify]']
  const connText = await p.evaluate(() => ({
    label: document.querySelector('[data-test=user-menu-connection-label]')?.textContent?.trim() || '',
    dot: document.querySelector('[data-test=user-menu-connection-dot]')?.className || '',
    role: document.querySelector('[data-test=user-menu-connection]')?.getAttribute('role') || '',
  }))
  check(`${tag}: the connection row sits right under the bell / note row, >= ${TAP} px`, conn?.shown && conn.h >= TAP && notifyRow && conn.y >= notifyRow.b - 1 && conn.y - notifyRow.b <= 8, { conn, notifyRow })
  check(`${tag}: it names the state beside a coloured dot (a status)`, /connect|offline/i.test(connText.label) && /\b(ok|warn|down)\b/.test(connText.dot) && connText.role === 'status', connText)
  check(`${tag}: no horizontal scroll with the menu open`, await noXScroll(p))
  await p.click('[data-test=user-menu-scrim]', { offset: { x: 10, y: 10 } })
  await sleep(200)
  const gone = await probe(p, ['[data-test=user-menu-panel]'])
  check(`${tag}: a tap on the scrim closes the sheet`, !gone['[data-test=user-menu-panel]']?.shown, gone)

  // SPL-1005: `/search x` typed in the dock -> the results
  await p.focus('.composer--dock textarea')
  await p.keyboard.type('/search hello')
  await p.keyboard.press('Enter')
  await p.waitForFunction(() => /\/search/.test(location.pathname), { timeout: 10000 }).catch(() => {})
  await sleep(400)
  const q = await p.evaluate(() => ({ path: location.pathname, q: new URLSearchParams(location.search).get('q') }))
  check(`${tag}: /search hello in the dock opens the results`, /\/search$/.test(q.path) && q.q === 'hello', q)
}

async function desktop(p, base) {
  const tag = '1440px'
  await open(p, base, 1440, 900, false)
  const bar = await probe(p, [
    '[data-test=top-bar]', '[data-test=top-bar-omnibox] textarea', '[data-testid=tenant-switcher]', '[data-test=theme-picker]',
    '[data-test=top-bar-search-toggle]', '[data-test=top-bar-tenant]', '[data-testid=notify-box-rail]',
  ])
  check(`${tag}: bar height unchanged (58)`, bar['[data-test=top-bar]']?.h === 58, bar['[data-test=top-bar]'])
  for (const s of ['[data-test=top-bar-omnibox] textarea', '[data-testid=tenant-switcher]', '[data-test=theme-picker]', '[data-testid=notify-box-rail]']) {
    check(`${tag}: ${s} in place`, bar[s]?.shown === true, bar[s])
  }
  const barLang = await p.evaluate(() => [...document.querySelectorAll('[data-test=top-bar] [data-test=lang-switcher], .top-bar__lang')]
    .filter((el) => !el.closest('[data-test=user-menu]')).length)
  check(`${tag}: spec 109 FR-008: no language switcher in the top bar`, barLang === 0, barLang)
  for (const s of ['[data-test=top-bar-search-toggle]', '[data-test=top-bar-tenant]']) {
    check(`${tag}: ${s} takes no space`, !bar[s]?.shown, bar[s])
  }
  const gear = '[data-testid=tenant-settings-open]'
  const entry = '[data-test=user-menu-tenant-settings]'
  await p.click('[data-test=user-menu-trigger]')
  await p.waitForSelector('[data-test=user-menu-language] [data-test=lang-switcher]', { visible: true, timeout: 10000 }).catch(() => {})
  const menu = await probe(p, ['[data-test=user-menu-panel]', '[data-test=user-menu-scrim]', '[data-test=user-menu-language] [data-test=lang-switcher]',
    '[data-test=user-menu-theme]', '[data-test=user-menu-notify]', '[data-test=user-menu-connection]', gear, entry])
  const panel = menu['[data-test=user-menu-panel]']
  check(`${tag}: the menu is the 272 px dropdown`, panel?.shown && panel.w === 272 && panel.y < 80, panel)
  check(`${tag}: spec 109 FR-008: the dropdown has the language switcher`, menu['[data-test=user-menu-language] [data-test=lang-switcher]']?.shown === true, menu)
  check(`${tag}: no other phone row, no scrim`, ['[data-test=user-menu-theme]', '[data-test=user-menu-notify]', '[data-test=user-menu-connection]', '[data-test=user-menu-scrim]'].every((s) => !menu[s]?.shown), menu)
  check(`${tag}: spec 109 FR-009: rail open -> the gear only, not the menu`, menu[gear]?.shown === true && !menu[entry]?.shown, { gear: menu[gear], entry: menu[entry] })
  await p.keyboard.press('Escape')
  await p.click('[data-test=pane-collapse-channels]')
  await sleep(300)
  await p.click('[data-test=user-menu-trigger]')
  await sleep(300)
  const shut = await probe(p, [gear, entry])
  check(`${tag}: spec 109 FR-009: rail collapsed -> the menu entry only`, !shut[gear]?.shown && shut[entry]?.shown === true, shut)
  await p.keyboard.press('Escape')
  await p.click('[data-test=pane-collapse-channels]')
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
