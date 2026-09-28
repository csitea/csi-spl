// SPL-1034 (specs/045 §3.8): drag channels to set your own order, kept.
// Runs against the lde mock (no hub): the mock client keeps the order in
// localStorage the way the hub keeps it on the membership, so a reload reads
// it back (utils/spool-client.mjs mockChannelOrder / setChannelOrder).
//
// Desktop 1440x900:
//   1  a real mouse drag (down / move / up) of the LAST channel row onto the
//      top moves it first; the whole list is stored (every displayed id)
//   2  reload: the order is kept, drawn top to bottom in that order
//   3  keyboard: the first row's menu offers Move down and no Move up, the
//      last row's Move up and no Move down; Enter on Move down swaps the first
//      two rows, the focus stays on that row's menu button; reload keeps it
//   4  a channel created after the order was stored appears at the END, and
//      creating it did not write the stored list
//   5  SPL-1024 still works on the same rows: an own topic card dragged onto
//      a channel row lights it up and the drop moves it
//
// Run:
//   node tests/e2e/channel-order.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/channel-order.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const KEY = 'spool.mock.channel-order'
const NEW = 'spl-1034-new'

if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

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

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

const ROWS = '#sidebar-panel-channels .nav-row'
const railRow = (ch) => `#sidebar-panel-channels .nav-row[data-order="${ch}"]`
const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const menuBtn = (ch) => `${railRow(ch)} [data-testid=sidebar-row-menu]`

/** The Channels rows as drawn: ids top to bottom, each visible with its top. */
const drawn = (p) => p.$$eval(ROWS, (els) => els.map((e) => {
  const r = e.getBoundingClientRect()
  return { id: e.getAttribute('data-order'), top: Math.round(r.top), h: Math.round(r.height) }
}))
const order = async (p) => (await drawn(p)).map((r) => r.id)
const stored = (p) => p.evaluate((k) => { try { return JSON.parse(localStorage.getItem(k) || 'null') } catch { return 'unreadable' } }, KEY)

async function openChannels(p, path = '/channel/alerts', reload = false) {
  if (reload) await p.reload({ waitUntil: 'networkidle2' })
  else await p.goto(`${p.base}${path}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await p.waitForSelector(ROWS, { visible: true, timeout: NAV_TIMEOUT })
  await sleep(400)
}

/** A real mouse drag of row `id` so it lands before the row now at `toIndex`. */
async function mouseDrag(p, id, toIndex) {
  const rows = await drawn(p)
  const from = rows.find((r) => r.id === id)
  const to = rows[toIndex]
  const x = await p.$eval(`${railRow(id)} .nav-item .label`, (e) => { const r = e.getBoundingClientRect(); return Math.round(r.left + Math.min(20, r.width / 2)) })
  await p.mouse.move(x, from.top + from.h / 2)
  await p.mouse.down()
  await p.mouse.move(x, from.top + from.h / 2 - 10, { steps: 3 })
  await p.mouse.move(x, to.top + 3, { steps: 8 })
  await sleep(80)
  const marked = await p.$eval(railRow(to.id), (e) => e.classList.contains('nav-row--drop'))
  await p.mouse.up()
  return marked
}

/** Menu items of a channel row, opened from the keyboard (focus + Enter). */
async function keyboardMenu(p, id) {
  await p.focus(menuBtn(id))
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-testid=sidebar-row-menu-panel]', { visible: true, timeout: 4000 })
  await sleep(150)
  return p.$$eval('[data-testid=sidebar-row-menu-panel] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-testid').replace('sidebar-row-menu-', '')))
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  p.base = srv.base
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await openChannels(p)

  const before = await order(p)
  ok('seed: the mock tenant draws at least three channels and nothing is stored yet', before.length >= 3 && (await stored(p)) === null, before)

  /* ---- 1. real mouse drag: the last row onto the top ------------------------ */
  const last = before[before.length - 1]
  const marked = await mouseDrag(p, last, 0)
  ok('1 while dragging, the row under the pointer shows the drop line', marked)
  const want1 = [last, ...before.slice(0, -1)]
  const moved = await until(p, ({ sel, want }) => JSON.stringify([...document.querySelectorAll(sel)].map((e) => e.getAttribute('data-order'))) === JSON.stringify(want), { sel: ROWS, want: want1 })
  ok('1 the dragged channel is first now', moved, await order(p))
  ok('1 the pointer-up did not open the dragged channel (click swallowed)', await p.evaluate(() => location.pathname.endsWith('/channel/alerts')), await p.evaluate(() => location.pathname))
  await until(p, (k) => localStorage.getItem(k) !== null, KEY)
  ok('1 the WHOLE displayed order is stored, not just the moved id', same(await stored(p), want1), await stored(p))
  await shot(p, '1-dragged')

  /* ---- 2. reload keeps it ---------------------------------------------------- */
  await openChannels(p, '', true)
  const rows2 = await drawn(p)
  ok('2 after a reload the order is kept', same(rows2.map((r) => r.id), want1), rows2.map((r) => r.id))
  ok('2 ... and drawn top to bottom in that order, every row visible', rows2.every((r, i) => r.h > 0 && (i === 0 || r.top > rows2[i - 1].top)), rows2)

  /* ---- 3. keyboard: Move up / Move down --------------------------------------- */
  const firstMenu = await keyboardMenu(p, want1[0])
  ok('3 the first row\'s menu offers Move down and no Move up', firstMenu.includes('move-down') && !firstMenu.includes('move-up'), firstMenu)
  await p.keyboard.press('Escape')
  await sleep(200)
  const lastMenu = await keyboardMenu(p, want1[want1.length - 1])
  ok('3 the last row\'s menu offers Move up and no Move down', lastMenu.includes('move-up') && !lastMenu.includes('move-down'), lastMenu)
  await p.keyboard.press('Escape')
  await sleep(200)
  const midMenu = await keyboardMenu(p, want1[1])
  ok('3 a middle row offers both', midMenu.includes('move-up') && midMenu.includes('move-down'), midMenu)
  await p.keyboard.press('Escape')
  await sleep(200)

  const items = await keyboardMenu(p, want1[0])
  for (let i = 0; i < items.indexOf('move-down'); i++) await p.keyboard.press('ArrowDown')
  const focused = await p.evaluate(() => document.activeElement?.getAttribute('data-testid'))
  ok('3 arrow keys reach Move down', focused === 'sidebar-row-menu-move-down', focused)
  await p.keyboard.press('Enter')
  const want3 = [want1[1], want1[0], ...want1.slice(2)]
  const swapped = await until(p, ({ sel, want }) => JSON.stringify([...document.querySelectorAll(sel)].map((e) => e.getAttribute('data-order'))) === JSON.stringify(want), { sel: ROWS, want: want3 })
  ok('3 Move down swaps the first two rows', swapped, await order(p))
  const focusAfter = await p.evaluate(() => document.activeElement?.getAttribute('data-menu-id'))
  ok('3 the focus stays on the moved row\'s menu button', focusAfter === 'ch:' + want1[0], focusAfter)
  await until(p, ({ k, want }) => localStorage.getItem(k) === JSON.stringify(want), { k: KEY, want: want3 })
  ok('3 the whole new order is stored', same(await stored(p), want3), await stored(p))
  await shot(p, '3-moved-down')
  await openChannels(p, '', true)
  ok('3 after a reload the Move down is kept', same(await order(p), want3), await order(p))

  /* ---- 4. a channel created later goes to the END ------------------------------ */
  await p.evaluate(async (NEW) => {
    const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    await ch.createChannel(NEW)
  }, NEW)
  const gotNew = await until(p, (sel) => Boolean(document.querySelector(sel)), railRow(NEW))
  const rows4 = await order(p)
  ok('4 the new channel is drawn at the END', gotNew && rows4[rows4.length - 1] === NEW && same(rows4.slice(0, -1), want3), rows4)
  await sleep(500)
  ok('4 creating it did not write it into the stored list', same(await stored(p), want3), await stored(p))
  await shot(p, '4-new-at-end')

  /* ---- 5. SPL-1024 topic drop onto a channel row still works --------------------- */
  const card = await p.evaluate(async (NEW) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    const ch = app.config.globalProperties.$pinia._s.get('channel')
    await app.config.globalProperties.$router.push('/channel/' + NEW)
    await new Promise((r) => setTimeout(r, 500))
    const one = await ch.send('SPL-1034 a topic to move', undefined, undefined, undefined, 1)
    return one.msg_id
  }, NEW)
  await p.waitForSelector(midCard(card), { timeout: 10000 })
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await sleep(400)
  const drop = await p.evaluate(async ({ source, target }) => {
    const src = document.querySelector(source)
    const dst = document.querySelector(target)
    if (!src || !dst) return { error: 'missing' }
    const meta = src.querySelector('.msg-meta') || src
    const r = meta.getBoundingClientRect()
    meta.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, pointerType: 'mouse', button: 0, isPrimary: true, clientX: r.left + 4, clientY: r.top + 4 }))
    meta.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, cancelable: true, pointerType: 'mouse', button: 0, isPrimary: true }))
    await new Promise((res) => setTimeout(res, 50))
    const dt = new DataTransfer()
    src.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: dt }))
    await new Promise((res) => setTimeout(res, 50))
    const lit = dst.getAttribute('data-move-target')
    dst.dispatchEvent(new DragEvent('dragenter', { bubbles: true, cancelable: true, dataTransfer: dt }))
    const over = new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt })
    dst.dispatchEvent(over)
    await new Promise((res) => setTimeout(res, 30))
    const overClass = dst.className
    const ev = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt })
    dst.dispatchEvent(ev)
    if (src.isConnected) src.dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true, dataTransfer: dt }))
    return { lit, accepted: over.defaultPrevented, dropped: ev.defaultPrevented, overClass }
  }, { source: midCard(card), target: railRow('alerts') })
  ok('5 a topic card dragged onto a channel row lights it up and it takes the drop',
    drop.lit === 'true' && drop.accepted && drop.dropped && /nav-row--move-over/.test(drop.overClass), drop)
  const gone = await until(p, (sel) => !document.querySelector(sel), midCard(card))
  ok('5 the card left its channel', gone)
  ok('5 the topic drop did not reorder the channels', same(await order(p), [...want3, NEW]), await order(p))

  ok('no page errors', errors.length === 0, errors)
  await p.close()
} catch (e) {
  console.error(e)
  results.push({ name: 'threw', ok: false })
} finally {
  await browser.close()
  await srv.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nchannel-order: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
