// 081 T006 (FR-006, FR-007, FR-009): F6, the skip link, the focus after a
// route change.
//
// Against the lde mock (no hub), a 1440x900 desktop, no touch:
//   AC5  from load, Tab -> the skip link (the first stop); Enter -> the focus
//        in the middle pane, on a card; at most 3 key presses to the first card
//   AC6  with a topic open, F6 x3 from the left pane -> middle, right,
//        Omnibox in turn; Shift + F6 walks back; F6 is the page's key
//   -    with no topic open, F6 from the middle skips to the Omnibox
//   103  T005: the vim listener mounts after idle; h / l / Esc walk the
//        panels; keys type into the Omnibox; a dialog and the setting off
//        suspend it (a control proves the same key moves without them)
//   AC8  click People in the rail -> document.activeElement is inside
//        .spool-main, and the live region says the page title
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/pane-keys.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

/** which F6 pane holds the focus (the docked Omnibox counts as the Omnibox) */
const paneNow = () => {
  const a = document.activeElement
  if (!a || a === document.body) return ''
  if (a.closest('.top-bar__omnibox')) return 'omnibox'
  if (a.closest('aside.live-pane, aside.operator-pane')) return 'right'
  if (a.closest('.spool-main')) return 'middle'
  if (a.closest('nav.sidebar')) return 'left'
  return 'other:' + a.tagName
}
const inPane = (want) => {
  const a = document.activeElement
  const at = !a || a === document.body ? '' : a.closest('.top-bar__omnibox') ? 'omnibox' : a.closest('aside.live-pane, aside.operator-pane') ? 'right' : a.closest('.spool-main') ? 'middle' : a.closest('nav.sidebar') ? 'left' : ''
  return at === want
}

async function load(p, path) {
  await p.goto(`${srv.base}${path}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* private mode */ }
  })
  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })

  /* ---- AC5: the skip link is the first stop and lands on a card ---- */
  await load(p, '/lobby')
  await p.waitForSelector('.spool-main article.msg', { visible: true, timeout: 15000 })
  await p.evaluate(() => { document.activeElement?.blur?.(); window.focus() })
  let presses = 0
  await p.keyboard.press('Tab'); presses++
  ok('Tab from load lands on the skip link', await until(p, () => document.activeElement?.matches?.('[data-testid=skip-link]'), null, 2000),
    await p.evaluate(() => document.activeElement?.outerHTML?.slice(0, 120)))
  ok('... which is on screen while it holds the focus', await p.evaluate(() => {
    const r = document.querySelector('[data-testid=skip-link]').getBoundingClientRect()
    return r.top >= 0 && r.height > 0
  }))
  await p.keyboard.press('Enter'); presses++
  ok('Enter puts the focus in the middle pane', await until(p, inPane, 'middle', 3000), await p.evaluate(paneNow))
  ok(`... on a card, in ${presses} key presses (<= 3)`, presses <= 3 && await p.evaluate(() => Boolean(document.activeElement?.closest?.('.spool-main article.msg'))),
    await p.evaluate(() => document.activeElement?.tagName + '.' + document.activeElement?.className))

  /* ---- no topic open: F6 skips the right pane ---- */
  await p.keyboard.press('F6')
  ok('with no topic open, F6 from the middle goes to the Omnibox', await until(p, inPane, 'omnibox', 2000), await p.evaluate(paneNow))
  await p.keyboard.down('Shift'); await p.keyboard.press('F6'); await p.keyboard.up('Shift')
  ok('... and Shift + F6 comes back to the middle', await until(p, inPane, 'middle', 2000), await p.evaluate(paneNow))

  /* ---- AC6: a topic open, F6 x3 from the left ---- */
  /* open the first card's topic through the store, as the feed's click does */
  const task = await p.evaluate(() => {
    const id = document.querySelector('.spool-main article.msg[data-task-id]')?.getAttribute('data-task-id') || ''
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    if (id) void pinia._s.get('live-pane').open(id)
    return id
  })
  const opened = await p.waitForSelector('aside.live-pane', { visible: true, timeout: 10000 }).then(() => true, () => false)
  ok('a topic opens on the right', Boolean(task) && opened, task)
  await sleep(400)
  await p.evaluate(() => { window.__f6 = null; window.addEventListener('keydown', (e) => { if (e.key === 'F6') window.__f6 = e.defaultPrevented }) })
  await p.evaluate(() => document.querySelector('nav.sidebar .sidebar-tab[aria-selected="true"], nav.sidebar a[href]')?.focus())
  ok('start: the focus is in the left pane', await until(p, inPane, 'left', 2000), await p.evaluate(paneNow))
  const walk = []
  for (const want of ['middle', 'right', 'omnibox']) {
    await p.keyboard.press('F6')
    walk.push((await until(p, inPane, want, 2000)) ? want : `!${await p.evaluate(paneNow)}`)
  }
  ok('F6 x3 from the left: middle, right, Omnibox', walk.join(',') === 'middle,right,omnibox', walk)
  ok('F6 is the page\'s key (defaultPrevented)', (await p.evaluate(() => window.__f6)) === true)
  const back = []
  for (const want of ['right', 'middle', 'left']) {
    await p.keyboard.down('Shift'); await p.keyboard.press('F6'); await p.keyboard.up('Shift')
    back.push((await until(p, inPane, want, 2000)) ? want : `!${await p.evaluate(paneNow)}`)
  }
  ok('Shift + F6 walks back: right, middle, left', back.join(',') === 'right,middle,left', back)

  /* ---- spec 103 T005: the lazy vim listener (topic still open) ---- */
  ok('vim: the listener mounts after idle', await until(p, () => document.documentElement.getAttribute('data-vim-nav') === 'on', null, 8000))
  const vimPanel = () => {
    const a = document.activeElement
    if (!a || a === document.body) return -1
    if (a.closest('aside.live-pane')) return 3
    if (a.closest('.spool-main')) return 2
    if (a.closest('.sidebar-body')) return 1
    if (a.closest('.sidebar-rail')) return 0
    return -1
  }
  const vimAt = (want) => {
    const a = document.activeElement
    const at = !a || a === document.body ? -1 : a.closest('aside.live-pane') ? 3 : a.closest('.spool-main') ? 2 : a.closest('.sidebar-body') ? 1 : a.closest('.sidebar-rail') ? 0 : -1
    return at === want
  }
  const focusCard = () => p.evaluate(() => document.querySelector('.spool-main article.msg')?.focus())
  await focusCard()
  ok('vim: start on a middle card (panel 2)', await until(p, vimAt, 2, 2000), await p.evaluate(vimPanel))
  const vimWalk = []
  for (const [key, want] of [['h', 1], ['h', 0], ['h', 0], ['l', 1], ['l', 2], ['l', 3], ['Escape', 2]]) {
    await p.keyboard.press(key)
    vimWalk.push((await until(p, vimAt, want, 2000)) ? `${key}:${want}` : `${key}:!${await p.evaluate(vimPanel)}`)
  }
  ok('vim: h h h l l l Esc walks panels 1,0,0,1,2,3,2', vimWalk.join(',') === 'h:1,h:0,h:0,l:1,l:2,l:3,Escape:2', vimWalk)
  ok('vim: the row it landed on carries the one ring (data-vim-selected)', await p.evaluate(() =>
    document.querySelectorAll('[data-vim-selected="true"]').length === 1 && document.activeElement?.getAttribute('data-vim-selected') === 'true'))

  /* a text field gets the letter: the Omnibox keeps the focus and types h */
  await p.focus('.top-bar__omnibox textarea')
  await p.keyboard.type('hjkl')
  ok('vim: h j k l type into the Omnibox, the focus stays', await p.evaluate(() =>
    Boolean(document.activeElement?.closest('.top-bar__omnibox')) && /hjkl/.test(document.querySelector('.top-bar__omnibox textarea')?.value || '')),
  await p.evaluate(() => [document.activeElement?.tagName, document.querySelector('.top-bar__omnibox textarea')?.value]))
  await p.evaluate(() => {
    const ta = document.querySelector('.top-bar__omnibox textarea')
    if (ta) { ta.value = ''; ta.dispatchEvent(new Event('input', { bubbles: true })) }
  })

  /* an open dialog suspends the layer, even for a key on a card under it */
  await p.evaluate(() => {
    const d = document.createElement('div')
    d.setAttribute('role', 'dialog'); d.setAttribute('aria-modal', 'true'); d.id = 'vim-probe-dialog'
    document.body.appendChild(d)
  })
  await focusCard()
  await p.keyboard.press('h')
  await sleep(300)
  ok('vim: with a dialog open, h on a card does nothing', await p.evaluate(vimAt, 2), await p.evaluate(vimPanel))
  /* control (must fail if the layer were dead): the same h with the dialog gone moves */
  await p.evaluate(() => document.getElementById('vim-probe-dialog')?.remove())
  await focusCard()
  await p.keyboard.press('h')
  ok('vim control: the same h with no dialog moves to panel 1', await until(p, vimAt, 1, 2000), await p.evaluate(vimPanel))

  /* Keyboard shortcuts off (Settings -> Behaviour): nothing */
  const claimWas = await p.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    const was = s.claims ? s.claims.keyboard_shortcuts : undefined
    s.claims = { ...(s.claims || {}), keyboard_shortcuts: false }
    return was === undefined ? null : was
  })
  await focusCard()
  await p.keyboard.press('h')
  await sleep(300)
  ok('vim: with Keyboard shortcuts off, h does nothing', await p.evaluate(vimAt, 2), await p.evaluate(vimPanel))
  await p.evaluate((was) => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    const c = { ...(s.claims || {}) }
    if (was === null) delete c.keyboard_shortcuts
    else c.keyboard_shortcuts = was
    s.claims = c
  }, claimWas)

  /* ---- AC8: a click on People moves the focus to the page, and says it ---- */
  await load(p, '/lobby')
  await p.waitForSelector('[data-testid=sidebar-tab-people]', { visible: true, timeout: 10000 })
  await p.click('[data-testid=sidebar-tab-people]')
  ok('People in the rail goes to /people', await until(p, () => /\/people$/.test(location.pathname), null, 8000), await p.evaluate(() => location.pathname))
  ok('document.activeElement is inside .spool-main', await until(p, () => Boolean(document.activeElement?.closest?.('.spool-main')), null, 4000),
    await p.evaluate(() => document.activeElement?.tagName + '.' + document.activeElement?.className))
  ok('the live region says the page title', await until(p, () => {
    const t = document.querySelector('[data-testid=route-announce]')?.textContent?.trim()
    return Boolean(t) && t === document.title
  }, null, 4000), await p.evaluate(() => [document.querySelector('[data-testid=route-announce]')?.textContent, document.title]))
  ok('the live region is polite', await p.evaluate(() => document.querySelector('[data-testid=route-announce]')?.getAttribute('aria-live') === 'polite'))

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\npane-keys: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
