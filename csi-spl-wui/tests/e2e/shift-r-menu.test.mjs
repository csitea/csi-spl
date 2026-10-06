// HUM-10 (t1 4c5161e3): Shift + R opens the right-click menu of the selected
// message in the panel that has the focus. The menu is anchored on that row,
// its first item is focused, arrows move, Enter runs an item, Esc closes and
// returns the focus to the row. A submenu (Move to channel) is reached and
// run the same way.
//
// Against the lde mock, 1280x800 desktop:
//   - middle panel: Shift + R opens msg-menu, ArrowDown moves, Esc returns
//   - topic panel: the same, on the selected reply
//   - the help list names R "Open menu"
//   - Enter on Hide from flow hides the selected reply
//   - Enter on Move to channel, then ArrowDown + Enter in the picker, moves it
//
// Run:
//   node tests/e2e/shift-r-menu.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = '4c5161e3-dc88-4ee1-a80d-951e08c112bb'
const R1 = '4c5161e3-dc88-4ee1-a80d-951e08c112b2'
const T2 = '4c5161e3-dc88-4ee1-a80d-951e08c112b3'
const row = (msg_id, task_id, min, body, is_parent) => ({
  v: 1, msg_id, task_id, ts: `2026-10-06T10:0${min}:00Z`, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent, files: [],
})
const EXTRA = [
  row(TASK, TASK, 0, 'shift-r topic starter', 1),
  row(R1, TASK, 1, 'shift-r reply one', 0),
  row(T2, T2, 2, 'shift-r move me', 1),
]

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
  let last = null
  while (Date.now() - t0 < ms) {
    last = await p.evaluate(fn, arg).catch(() => null)
    if (last) return last
    await sleep(100)
  }
  return last
}

const card = (id) => `.topic article.msg[data-msg-id="${id}"]`
const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const visible = (sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length))

const select = (p, sel) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  if (!el) return false
  el.scrollIntoView({ block: 'center' })
  el.focus({ preventScroll: true })
  return document.activeElement === el
}, sel)

async function shiftR(p) {
  await p.keyboard.down('Shift')
  await p.keyboard.press('R')
  await p.keyboard.up('Shift')
}

async function openByShiftR(p, sel) {
  if (!(await select(p, sel))) return null
  await shiftR(p)
  const st = await until(p, () => {
    const s = (function menuState() {
      const menu = document.querySelector('[data-testid=msg-menu]')
      const a = document.activeElement
      const shown = Boolean(menu && menu.getClientRects().length)
      return {
        shown,
        item: shown && menu.contains(a) ? (a.getAttribute('data-testid') || '') : '',
        role: shown && menu.contains(a) ? (a.getAttribute('role') || '') : '',
        ids: shown ? [...menu.querySelectorAll('[role=menuitem]')].map((e) => e.getAttribute('data-testid') + (e.getAttribute('aria-disabled') === 'true' ? ':off' : '')) : [],
      }
    })()
    return s.shown && s.role === 'menuitem' ? s : null
  }, null, 5000)
  return st
}

/** ArrowDown until the focused item is `id` (not :off). */
async function arrowTo(p, id) {
  for (let i = 0; i < 16; i++) {
    const cur = await p.evaluate(() => document.activeElement?.getAttribute?.('data-testid') || '')
    const off = await p.evaluate(() => document.activeElement?.getAttribute?.('aria-disabled') === 'true')
    if (cur === id && !off) return true
    await p.keyboard.press('ArrowDown')
    await sleep(40)
  }
  return false
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
    } catch { /* private mode */ }
  }, EXTRA)
  await p.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  await p.goto(`${srv.base}/channel/alerts?topic=${TASK}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector(card(R1), { visible: true, timeout: 15000 }).catch(() => {})
  await sleep(400)

  /* ---- help list ---- */
  ok('the reply is selected', await select(p, card(R1)))
  await p.keyboard.down('Shift')
  await p.keyboard.press('?')
  await p.keyboard.up('Shift')
  const helpR = await until(p, (sel) => {
    const el = document.querySelector(sel)
    return el && el.getClientRects().length ? el.textContent.trim() : ''
  }, '[data-testid=msg-shortcuts-help-R]', 4000)
  ok('the help list names Shift + R Open menu', helpR === 'Open menu', helpR)
  await p.keyboard.press('Escape')
  await until(p, (sel) => !document.querySelector(sel), '[data-testid=msg-shortcuts-help]', 4000)

  /* ---- middle panel ---- */
  ok('the middle card is there', await until(p, visible, midCard(T2), 6000))
  const mid = await openByShiftR(p, midCard(T2))
  ok('middle: Shift + R opens the menu on its first item', Boolean(mid && mid.shown && mid.role === 'menuitem' && mid.ids[0] && mid.item === mid.ids[0].replace(':off', '')), mid)
  const first = mid && mid.item
  await p.keyboard.press('ArrowDown')
  await sleep(80)
  const second = await p.evaluate(() => document.activeElement?.getAttribute?.('data-testid') || '')
  ok('middle: ArrowDown moves to the next item', Boolean(first && second && second !== first), { first, second })
  await p.keyboard.press('Escape')
  const backMid = await until(p, (id) => {
    const menu = document.querySelector('[data-testid=msg-menu]')
    const on = document.activeElement?.closest?.('article.msg')?.getAttribute('data-msg-id') || ''
    return (!menu || !menu.getClientRects().length) && on === id ? on : ''
  }, T2, 4000)
  ok('middle: Esc closes the menu and returns focus to the row', backMid === T2, backMid)

  /* ---- topic panel ---- */
  const topic = await openByShiftR(p, card(R1))
  ok('topic: Shift + R opens the menu on its first item', Boolean(topic && topic.shown && topic.role === 'menuitem' && topic.item), topic)
  await p.keyboard.press('Escape')
  const backTopic = await until(p, (id) => {
    const menu = document.querySelector('[data-testid=msg-menu]')
    const on = document.activeElement?.closest?.('article.msg')?.getAttribute('data-msg-id') || ''
    return (!menu || !menu.getClientRects().length) && on === id ? on : ''
  }, R1, 4000)
  ok('topic: Esc closes the menu and returns focus to the row', backTopic === R1, backTopic)

  /* ---- run one item: Hide from flow ---- */
  const hideMenu = await openByShiftR(p, card(R1))
  ok('topic menu offers Hide from flow', Boolean(hideMenu && hideMenu.ids.includes('msg-menu-hide-flow')), hideMenu && hideMenu.ids)
  ok('arrows reach Hide from flow', await arrowTo(p, 'msg-menu-hide-flow'))
  await p.keyboard.press('Enter')
  ok('Enter hides the selected reply', await until(p, (sel) => {
    const els = [...document.querySelectorAll(sel)]
    return els.length === 0 || els.every((e) => !e.getClientRects().length)
  }, card(R1), 4000))

  /* ---- run a submenu: Move to channel ---- */
  const moveMenu = await openByShiftR(p, midCard(T2))
  ok('middle menu offers Move to channel', Boolean(moveMenu && moveMenu.ids.includes('msg-menu-move-channel')), moveMenu && moveMenu.ids)
  ok('arrows reach Move to channel', await arrowTo(p, 'msg-menu-move-channel'))
  await p.keyboard.press('Enter')
  const picker = await until(p, (sel) => Boolean(document.querySelector(sel)), '[data-testid=move-picker-channel]', 5000)
  ok('Enter opens the Move to channel picker', picker === true, picker)
  const rowReady = await until(p, (sel) => Boolean(document.querySelector(sel)), '[data-testid=move-picker-channel] [data-testid=move-picker-row]', 5000)
  ok('the picker lists a channel', rowReady === true, rowReady)
  const inFilter = await p.evaluate(() => document.activeElement?.getAttribute?.('data-testid') || '')
  ok('the picker focus starts in its filter', inFilter === 'move-picker-filter', inFilter)
  await p.keyboard.press('ArrowDown')
  await sleep(80)
  const onRow = await p.evaluate(() => document.activeElement?.getAttribute?.('data-testid') || '')
  ok('ArrowDown in the picker focuses a channel row', onRow === 'move-picker-row', onRow)
  await p.keyboard.press('Enter')
  const moved = await until(p, (sel) => {
    const toast = document.querySelector('[data-testid=move-toast]')
    const still = document.querySelector(sel)
    return Boolean(toast) || !still
  }, midCard(T2), 6000)
  ok('Enter runs the move', moved === true, moved)

  /* ---- topic-list row on /t, and the home topics list ---- */
  const LIST = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
  const listRow = `[data-test=topic-browse-list] a.topic-row[data-key="${LIST}"]`
  await p.goto(`${srv.base}/t/${LIST}`, { waitUntil: 'domcontentloaded' })
  ok('the topic-list row is there', await until(p, visible, listRow, 8000))
  ok('the topic thread has a card, so the shortcut listener is up', await until(p, visible, '.topic-browse__thread article.msg', 8000))
  await sleep(200)
  const listMenu = await openByShiftR(p, listRow)
  ok('topic row: Shift + R opens the menu on its first item', Boolean(listMenu && listMenu.shown && listMenu.role === 'menuitem' && listMenu.item), listMenu)
  await p.keyboard.press('Escape')
  const backList = await until(p, (sel) => {
    const menu = document.querySelector('[data-testid=msg-menu]')
    const on = document.activeElement
    return (!menu || !menu.getClientRects().length) && on && on.matches && on.matches(sel) ? 'row' : ''
  }, listRow, 4000)
  ok('topic row: Esc closes the menu and returns focus to the row', backList === 'row', backList)

  const homeRow = `.spool-main a.topic-row[data-key="${LIST}"]`
  await p.goto(`${srv.base}/?topic=${LIST}`, { waitUntil: 'domcontentloaded' })
  ok('the home topic row is there', await until(p, visible, homeRow, 8000))
  ok('an open topic mounts a card, so the shortcut listener is up', await until(p, visible, 'article.msg', 8000))
  await sleep(200)
  const homeFocused = await select(p, homeRow)
  ok('home: the topic row takes the focus', homeFocused)
  let homeMenu = null
  if (homeFocused) {
    await shiftR(p)
    homeMenu = await until(p, () => {
      const panel = document.querySelector('[data-testid=sidebar-row-menu-panel]')
      const a = document.activeElement
      const shown = Boolean(panel && panel.getClientRects().length)
      const item = Boolean(shown && panel.contains(a) && a && a.getAttribute('role') === 'menuitem')
      return item ? (a.getAttribute('data-testid') || 'item') : null
    }, null, 5000)
  }
  ok('home topic row: Shift + R opens the menu on its first item', Boolean(homeMenu), homeMenu)
  if (homeMenu) {
    await p.keyboard.press('Escape')
    const backHome = await until(p, (key) => {
      const panel = document.querySelector('[data-testid=sidebar-row-menu-panel]')
      const wrap = document.activeElement && document.activeElement.closest && document.activeElement.closest('.topic-row-wrap')
      const on = wrap ? (wrap.querySelector('a.topic-row') && wrap.querySelector('a.topic-row').getAttribute('data-key') || '') : ''
      return (!panel || !panel.getClientRects().length) && on === key ? on : ''
    }, LIST, 4000)
    ok('home topic row: Esc closes the menu and leaves focus on that row', backHome === LIST, backHome)
  } else {
    ok('home topic row: Esc closes the menu and leaves focus on that row', false, 'menu did not open')
  }

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nshift-r-menu: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
