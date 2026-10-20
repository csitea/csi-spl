// 081 T004 (FR-001, FR-002, FR-005): Ctrl + K opens the command palette.
//
// Against the lde mock (no hub), a 1440x900 desktop, no touch:
//   AC1  on /lobby, Ctrl + K, type "fee", Enter -> /channel/feedback, the
//        palette closed, the focus in the middle pane
//   -    the input is a combobox over a listbox; ↓ moves aria-activedescendant
//   AC2  focus the composer, type "abc", Ctrl + K -> the palette opens;
//        Esc -> the focus is back in the composer, "abc" intact
//   -    Ctrl + K is the page's key (defaultPrevented), and with the palette
//        open it closes it
//   -    SPL-2142: closed by a backdrop click, the focus is back in the
//        composer; opened from an element that has left the page, or from
//        nothing, Esc / Ctrl + K leave it in the middle pane
//   -    on a phone (390 px) Ctrl + K opens nothing
//   -    SPL-2148, a phone (390 px, touch): a one-finger swipe right still
//        goes Back (level 2 -> 1) and opens no palette; a two-finger swipe
//        up opens the palette, and Back closes it; a two-finger pinch (the
//        browser's zoom) opens nothing
//   -    over Settings (a routed dialog, /settings) Ctrl + K opens the
//        palette and is the page's key; Esc leaves Settings open and the page
//        still locked; "fee" + Enter leaves Settings for #feedback and the
//        page scrolls again (owner bug: "nothing happens with Ctrl + K")
//   AC4  (T005) select a topic card, Ctrl + K, type ">arch" -> an Archive
//        row with "⇧A"; Enter archives it (Archived · Undo shows). '>' alone
//        lists the page's actions too (new topic, a theme) and no go-to row
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/command-palette.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* AC4's topic card, seeded into the mock's #alerts */
const ARCH = '081a4c40-0005-4b8f-bfba-52e153b30a01'
const EXTRA = [{
  v: 1, msg_id: ARCH, task_id: ARCH, ts: '2026-10-05T10:00:00Z', from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body: 'palette archive me', channel: 'alerts', parent_task_id: null, is_parent: 1, files: [],
}]

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

const PALETTE = '[data-testid=command-palette]'
const INPUT = '[data-testid=command-palette-input]'
const COMPOSER = 'form.omnibox--global textarea'
const shown = (sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length))
const gone = (sel) => !document.querySelector(sel)
const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const rowIds = () => [...document.querySelectorAll('[data-testid=command-palette-row]')].map((r) => r.getAttribute('data-item'))

/** Select a card the way a click does: the row takes the focus. */
const select = (p, sel) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  if (!el) return false
  el.scrollIntoView({ block: 'center' })
  el.focus({ preventScroll: true })
  return document.activeElement === el
}, sel)

async function ctrlK(p) {
  await p.keyboard.down('Control')
  await p.keyboard.press('k')
  await p.keyboard.up('Control')
}

/** A touch gesture through CDP: each finger from its `from` to its `to`. */
async function touchSwipe(p, fingers, steps = 10) {
  const cdp = await p.createCDPSession()
  const at = (i) => fingers.map((f, id) => ({ x: Math.round(f.from.x + ((f.to.x - f.from.x) * i) / steps), y: Math.round(f.from.y + ((f.to.y - f.from.y) * i) / steps), id: id + 1 }))
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: at(0) })
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: at(i) })
    await sleep(16)
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach()
  await sleep(400)
}
const mobileLevel = () => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level')

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
  await p.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
      localStorage.removeItem('spool.palette-recent')
    } catch { /* private mode */ }
  }, EXTRA)
  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })

  /* ---- AC1: Ctrl + K, "fee", Enter -> #feedback ---- */
  await load(p, '/lobby')
  /* the chord is the page's: a listener after ours sees it prevented */
  await p.evaluate(() => {
    window.__ctrlK = null
    window.addEventListener('keydown', (e) => { if (e.key === 'k' && e.ctrlKey) window.__ctrlK = e.defaultPrevented })
  })
  await ctrlK(p)
  ok('Ctrl + K opens the command palette', await until(p, shown, PALETTE, 8000))
  ok('... and takes the key from the browser (preventDefault)', (await p.evaluate(() => window.__ctrlK)) === true)
  ok('the input has the focus', await until(p, (s) => document.activeElement?.matches?.(s), INPUT, 3000))
  const aria = await p.$eval(INPUT, (e) => ({ role: e.getAttribute('role'), controls: e.getAttribute('aria-controls'), list: document.getElementById(e.getAttribute('aria-controls') || '')?.getAttribute('role') }))
  ok('the input is a combobox controlling a listbox', aria.role === 'combobox' && aria.list === 'listbox', aria)
  await p.type(INPUT, 'fee')
  ok('"fee" lists #feedback first', await until(p, () => document.querySelector('[data-testid=command-palette-row]')?.getAttribute('data-item') === 'channel:feedback', null, 4000))
  const ad0 = await p.$eval(INPUT, (e) => ({ ad: e.getAttribute('aria-activedescendant'), first: document.querySelector('[data-testid=command-palette-row]')?.id, n: document.querySelectorAll('[data-testid=command-palette-row]').length }))
  ok('the first row is the active descendant', ad0.ad && ad0.ad === ad0.first, ad0)
  if (ad0.n > 1) {
    await p.keyboard.press('ArrowDown')
    const ad1 = await p.$eval(INPUT, (e) => ({ ad: e.getAttribute('aria-activedescendant'), second: document.querySelectorAll('[data-testid=command-palette-row]')[1]?.id }))
    ok('↓ moves the active descendant to the next row', ad1.ad === ad1.second, ad1)
    await p.keyboard.press('ArrowUp')
  }
  await p.keyboard.press('Enter')
  ok('Enter goes to /channel/feedback', await until(p, () => /\/channel\/feedback$/.test(location.pathname), null, 8000), await p.evaluate(() => location.pathname))
  ok('the palette is closed', await until(p, gone, PALETTE, 4000))
  ok('the focus is in the middle pane', await until(p, () => Boolean(document.activeElement?.closest?.('.spool-main')), null, 4000),
    await p.evaluate(() => document.activeElement?.tagName + '.' + document.activeElement?.className))
  ok('#feedback is remembered as recent', await p.evaluate(() => JSON.parse(localStorage.getItem('spool.palette-recent') || '[]')[0] === 'channel:feedback'))

  /* ---- AC2: from the composer, and Esc gives the focus back ---- */
  await p.waitForSelector(COMPOSER, { visible: true, timeout: 8000 })
  await p.focus(COMPOSER)
  await p.keyboard.type('abc')
  await ctrlK(p)
  ok('Ctrl + K from the composer opens the palette', await until(p, shown, PALETTE, 4000))
  ok('the composer took no K', (await p.$eval(COMPOSER, (t) => t.value)) === 'abc')
  await p.keyboard.press('Escape')
  ok('Esc closes the palette', await until(p, gone, PALETTE, 4000))
  ok('the focus is back in the composer', await until(p, (s) => document.activeElement?.matches?.(s), COMPOSER, 3000))
  ok('... with "abc" intact', (await p.$eval(COMPOSER, (t) => t.value)) === 'abc')
  await p.$eval(COMPOSER, (b) => { b.value = ''; b.dispatchEvent(new Event('input', { bubbles: true })); b.blur() })
  /* "nothing focused" is this case's precondition. The palette Esc just closed
     gives the focus back to its opener (the composer) from a 0 ms timer
     (CommandPalette restoreFocus); a blur that lands before that timer is
     undone, and the next palette opens from the composer (wf 10 39051249409:
     "TEXTAREA", twice in one job). Let that timer run, then blur. */
  await p.evaluate(() => new Promise((r) => setTimeout(r, 0)))
  await p.evaluate(() => document.activeElement?.blur?.())
  ok('nothing is focused before the Ctrl + K', await p.evaluate(() => document.activeElement === document.body),
    await p.evaluate(() => document.activeElement?.tagName))

  /* ---- Ctrl + K again closes it ---- */
  await ctrlK(p)
  await until(p, shown, PALETTE, 4000)
  await ctrlK(p)
  ok('Ctrl + K with the palette open closes it', await until(p, gone, PALETTE, 4000))
  ok('... and, opened with nothing focused, it leaves the focus in the middle pane', await until(p, () => Boolean(document.activeElement?.closest?.('.spool-main')), null, 3000),
    await p.evaluate(() => document.activeElement?.tagName))

  /* ---- SPL-2142: the focus goes back to where it was, however the palette closes ---- */
  await p.focus(COMPOSER)
  await ctrlK(p)
  await until(p, shown, PALETTE, 4000)
  ok('the backdrop is what a click at the page corner hits', await p.evaluate(() => Boolean(document.elementFromPoint(10, 10)?.matches?.('[data-testid=ui-dialog-backdrop]'))))
  await p.mouse.click(10, 10)
  ok('a backdrop click closes the palette', await until(p, gone, PALETTE, 4000))
  ok('... and gives the focus back to the composer', await until(p, (s) => document.activeElement?.matches?.(s), COMPOSER, 3000),
    await p.evaluate(() => document.activeElement?.tagName))
  await p.evaluate(() => {
    const b = document.createElement('button')
    b.id = 'spl-2142-opener'
    document.querySelector('.spool-main')?.appendChild(b)
    b.focus()
  })
  await ctrlK(p)
  await until(p, shown, PALETTE, 4000)
  await p.evaluate(() => document.getElementById('spl-2142-opener')?.remove())
  await p.keyboard.press('Escape')
  ok('an opener gone from the page: Esc puts the focus in the middle pane', await until(p, () => Boolean(document.activeElement?.closest?.('.spool-main')), null, 3000),
    await p.evaluate(() => document.activeElement?.tagName))

  /* ---- over Settings: a routed dialog is a page, the palette opens over it ---- */
  const SETTINGS = '.ui-dialog.routed'
  await load(p, '/settings')
  ok('Settings is open (a routed dialog)', await until(p, shown, SETTINGS, 8000))
  await p.evaluate(() => {
    window.__ctrlK = null
    window.addEventListener('keydown', (e) => { if (e.key === 'k' && e.ctrlKey) window.__ctrlK = e.defaultPrevented })
  })
  await ctrlK(p)
  ok('Ctrl + K over Settings opens the palette', await until(p, shown, PALETTE, 4000))
  ok('... and takes the key from the browser (preventDefault)', (await p.evaluate(() => window.__ctrlK)) === true)
  ok('... with the input focused', await until(p, (s) => document.activeElement?.matches?.(s), INPUT, 3000))
  await p.keyboard.press('Escape')
  ok('Esc closes the palette', await until(p, gone, PALETTE, 4000))
  ok('... and Settings stays open', await p.evaluate(shown, SETTINGS))
  ok('... with the page still locked behind it', (await p.evaluate(() => document.documentElement.style.overflow)) === 'hidden')
  await ctrlK(p)
  await until(p, shown, PALETTE, 4000)
  await p.type(INPUT, 'fee')
  await until(p, () => document.querySelector('[data-testid=command-palette-row]')?.getAttribute('data-item') === 'channel:feedback', null, 4000)
  await p.keyboard.press('Enter')
  ok('"fee" + Enter over Settings goes to /channel/feedback', await until(p, () => /\/channel\/feedback$/.test(location.pathname), null, 8000), await p.evaluate(() => location.pathname))
  ok('... Settings and the palette are closed', await until(p, (s) => !document.querySelector(s), `${SETTINGS}, ${PALETTE}`, 4000))
  ok('... and the page scrolls again', await until(p, () => document.documentElement.style.overflow === '', null, 3000))

  /* ---- AC4: '>' runs the selected card's menu items ---- */
  await load(p, '/channel/alerts')
  ok('the topic card to archive is there', await until(p, shown, midCard(ARCH), 8000))
  ok('the topic card is selected', await select(p, midCard(ARCH)))
  await ctrlK(p)
  ok('Ctrl + K on a selected card opens the palette', await until(p, shown, PALETTE, 4000))
  await p.type(INPUT, '>')
  const all = await (until(p, () => document.querySelectorAll('[data-testid=command-palette-row]').length > 0, null, 3000)).then(() => p.evaluate(rowIds))
  ok('">" lists the card\'s menu items, new topic and the themes, and no go-to row',
    all.includes('msg:archive') && all.includes('msg:copy') && all.includes('action:new-topic') && all.some((id) => id.startsWith('theme:')) && !all.some((id) => /^(channel|tab|page):/.test(id)), all)
  await p.type(INPUT, 'arch')
  ok('">arch" lists Archive first', await until(p, () => document.querySelector('[data-testid=command-palette-row]')?.getAttribute('data-item') === 'msg:archive', null, 3000), await p.evaluate(rowIds))
  const arch = await p.$eval('[data-testid=command-palette-row]', (r) => ({ label: r.querySelector('.palette__label')?.textContent.trim(), key: r.querySelector('[data-testid=command-palette-key]')?.textContent.trim() }))
  ok('... named Archive, with its key ⇧A', /archive/i.test(arch.label || '') && arch.key === '⇧A', arch)
  await p.keyboard.press('Enter')
  ok('Enter closes the palette', await until(p, gone, PALETTE, 4000))
  ok('... and archives the card: it leaves the feed', await until(p, (s) => !document.querySelector(s), midCard(ARCH), 6000))
  ok('... and Archived · Undo is offered', await until(p, (s) => Boolean(document.querySelector(s)), '[data-testid=archive-toast]', 3000))

  /* ---- a phone: no palette ---- */
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 1 })
  await load(p, '/lobby')
  await ctrlK(p)
  await sleep(800)
  ok('on a phone Ctrl + K opens nothing', !(await p.evaluate(shown, PALETTE)))

  /* ---- SPL-2148: a phone's two-finger swipe up opens the palette; swipe-to-back stays ---- */
  await load(p, '/')
  await p.click('[data-testid=sidebar-tab-channels]')
  await p.waitForSelector('#sidebar-panel-channels .nav-item')
  const doc = await p.evaluate(() => performance.timeOrigin)
  await p.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
  ok('a phone: a channel tap pushes level 2', await until(p, (lv) => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') === lv, '2', 6000), await p.evaluate(mobileLevel))
  await touchSwipe(p, [{ from: { x: 20, y: 420 }, to: { x: 200, y: 425 } }], 6)
  ok('a one-finger swipe right still goes Back to level 1', await until(p, (lv) => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') === lv, '1', 4000), await p.evaluate(mobileLevel))
  ok('... in the same document', (await p.evaluate(() => performance.timeOrigin)) === doc)
  ok('... and opens no palette', !(await p.evaluate(shown, PALETTE)))
  await touchSwipe(p, [{ from: { x: 150, y: 600 }, to: { x: 150, y: 440 } }, { from: { x: 240, y: 600 }, to: { x: 240, y: 440 } }])
  ok('a two-finger swipe up opens the command palette', await until(p, shown, PALETTE, 6000))
  await p.evaluate(() => history.back())
  ok('... and Back closes it', await until(p, gone, PALETTE, 4000))
  /* a fresh page: the pinch zooms it (the browser's gesture), and a zoomed page pans */
  await load(p, '/')
  await touchSwipe(p, [{ from: { x: 180, y: 600 }, to: { x: 140, y: 460 } }, { from: { x: 210, y: 600 }, to: { x: 250, y: 460 } }])
  await sleep(800)
  ok('a two-finger pinch opens nothing', !(await p.evaluate(shown, PALETTE)))

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncommand-palette: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
