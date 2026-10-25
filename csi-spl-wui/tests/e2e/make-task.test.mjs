// SPL-3344 (owner HUM-10, t1 2a9e18c7 msgs 3e7fc3b7, 0c510ff7: "we need a new
// shortcut converting a blocker msg to a task ... I am doing this quite
// often"): a blocker becomes a task in one step.
//
// Against the lde mock (the viewer is HUM-1, the author of every row here, so
// Kind -> Task is offered on each):
//   - desktop 1280x800: a right-click on a blocker offers "Make it a task"
//     with its ⇧X hint; choosing it turns the row's badge into Task
//   - Shift + X on a selected blocker does the same
//   - a task message and a note offer neither: no menu item, and Shift + X
//     leaves the kind as it was
//   - Shift + ? names Shift + X "Make it a task"
//   - phone 390x844: the ⋯ sheet of a blocker has the item and it works
// SHOT_DIR=<dir> saves a desktop and a 390 px screenshot of the menu.
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/make-task.test.mjs
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const id = (n) => `3344aaaa-0000-4000-8000-00000000000${n}`
const B1 = id(1)
const B2 = id(2)
const B3 = id(3)
const TK = id(4)
const NT = id(5)
const row = (msg_id, min, kind, body) => ({
  v: 1, msg_id, task_id: msg_id, ts: `2026-10-25T10:0${min}:00Z`, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind, body, channel: 'alerts', parent_task_id: null, is_parent: 1, files: [],
})
const EXTRA = [
  row(B1, 1, 'blocker', 'make-task blocker one'),
  row(B2, 2, 'blocker', 'make-task blocker two'),
  row(B3, 3, 'blocker', 'make-task blocker three'),
  row(TK, 4, 'task', 'make-task already a task'),
  row(NT, 5, 'note', 'make-task a note'),
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

const card = (msgId) => `.spool-main article.msg[data-msg-id="${msgId}"]`
const visible = (sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length))
const kindOf = (p, msgId) => p.evaluate((sel) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.getAttribute('data-kind') || '', card(msgId))
const becomes = (p, msgId, kind) => until(p, ([sel, k]) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.getAttribute('data-kind') === k, [card(msgId), kind], 5000)
const MENU = '[data-testid=msg-menu]'
const ITEM = '[data-testid=msg-menu-make-task]'

/** Select a card the way a click does: a pointerdown, then the row takes the focus. */
const select = async (p, sel) => {
  await p.keyboard.press('Shift')
  return p.evaluate((sel) => {
    const el = document.querySelector(sel)
    if (!el) return false
    el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, composed: true }))
    el.scrollIntoView({ block: 'center' })
    el.focus({ preventScroll: true })
    return document.activeElement === el
  }, sel)
}

async function shiftKey(p, key) {
  await p.keyboard.down('Shift')
  await p.keyboard.press(key)
  await p.keyboard.up('Shift')
}

/** Right-click a card's body; the menu's item ids, [] when it did not open. */
async function rightClick(p, msgId) {
  await p.evaluate((sel) => document.querySelector(sel)?.scrollIntoView({ block: 'center' }), card(msgId))
  const box = await (await p.$(card(msgId)))?.boundingBox()
  if (!box) return []
  await p.mouse.click(box.x + box.width / 2, box.y + 12, { button: 'right' })
  return (await until(p, (sel) => {
    const m = document.querySelector(sel)
    return m && m.getClientRects().length ? [...m.querySelectorAll('[role=menuitem]')].map((e) => e.getAttribute('data-testid')) : null
  }, MENU, 4000)) || []
}

async function closeMenu(p) {
  await p.keyboard.press('Escape')
  await until(p, (sel) => !document.querySelector(sel), MENU, 3000)
}

async function boot(p, width, height, phone) {
  await p.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
    } catch { /* private mode */ }
  }, EXTRA)
  await p.setViewport({ width, height, isMobile: phone, hasTouch: phone, deviceScaleFactor: 1 })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await until(p, visible, card(NT), 15000)
  await sleep(400)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await boot(p, 1280, 800, false)
  ok('desktop: the five rows are in the middle panel', await until(p, (ids) => ids.every((i) => document.querySelector(`.spool-main article.msg[data-msg-id="${i}"]`)), [B1, B2, B3, TK, NT], 8000))
  ok('B1 shows as a blocker', (await kindOf(p, B1)) === 'blocker')

  /* ---- right-click a blocker -> Make it a task ---- */
  const ids = await rightClick(p, B1)
  ok('right-click on a blocker offers Make it a task', ids.includes('msg-menu-make-task'), ids)
  const label = await p.evaluate((sel) => {
    const el = document.querySelector(sel)
    return el ? { text: el.textContent.replace(/\s+/g, ' ').trim(), aria: el.getAttribute('aria-keyshortcuts'), hint: el.querySelector('[data-testid=msg-menu-key-make-task]')?.getAttribute('data-key') } : null
  }, ITEM)
  ok('the item reads Make it a task, with its ⇧X hint', label && label.text === 'Make it a task' && label.hint === '⇧X' && label.aria === 'Shift+X', label)
  if (SHOT_DIR) await p.screenshot({ path: join(SHOT_DIR, 'make-task-desktop.png') })
  const pick = await p.$(ITEM)
  if (pick) await pick.click()
  ok('choosing it turns the row into a task', await becomes(p, B1, 'task'), await kindOf(p, B1))
  ok('the menu closed', await until(p, (sel) => !document.querySelector(sel), MENU, 3000))

  /* ---- Shift + X on a selected blocker ---- */
  ok('B2 is selected', await select(p, card(B2)))
  await shiftKey(p, 'X')
  ok('Shift + X turns the selected blocker into a task', await becomes(p, B2, 'task'), await kindOf(p, B2))

  /* ---- a task and a note offer neither ---- */
  for (const [name, msgId, kind] of [['a task message', TK, 'task'], ['a note', NT, 'note'], ['the blocker just made a task', B1, 'task']]) {
    const menu = await rightClick(p, msgId)
    ok(`${name}: the menu opens without Make it a task`, menu.length > 0 && !menu.includes('msg-menu-make-task'), menu)
    await closeMenu(p)
    ok(`${name}: selected`, await select(p, card(msgId)))
    await shiftKey(p, 'X')
    await sleep(600)
    ok(`${name}: Shift + X leaves its kind ${kind}`, (await kindOf(p, msgId)) === kind, await kindOf(p, msgId))
  }

  /* ---- Shift + ? names it ---- */
  ok('a card is selected for the help', await select(p, card(NT)))
  await shiftKey(p, '?')
  const help = await until(p, (sel) => {
    const el = document.querySelector(sel)
    return el && el.getClientRects().length ? el.textContent.trim() : ''
  }, '[data-testid=msg-shortcuts-help-X]', 4000)
  ok('the help list names Shift + X Make it a task', help === 'Make it a task', help)
  await p.keyboard.press('Escape')

  ok('desktop: no unexpected page errors', errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e)).length === 0, errors)

  /* ---- phone 390 px: the ⋯ sheet ---- */
  const ph = await browser.newPage()
  const phErrors = []
  ph.on('pageerror', (e) => phErrors.push(String(e).slice(0, 200)))
  ph.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await boot(ph, 390, 844, true)
  ok('phone: B3 shows as a blocker', (await kindOf(ph, B3)) === 'blocker')
  await ph.evaluate((sel) => document.querySelector(sel)?.scrollIntoView({ block: 'center' }), card(B3))
  const btn = await ph.$(`${card(B3)} [data-testid="msg-menu-btn"]`)
  if (btn) await btn.tap()
  const sheet = (await until(ph, (sel) => {
    const m = document.querySelector(sel)
    return m && m.getClientRects().length ? [...m.querySelectorAll('[role=menuitem]')].map((e) => e.getAttribute('data-testid')) : null
  }, MENU, 5000)) || []
  ok('phone: the blocker\'s sheet has Make it a task', sheet.includes('msg-menu-make-task'), sheet)
  await sleep(400)
  if (SHOT_DIR) await ph.screenshot({ path: join(SHOT_DIR, 'make-task-390.png') })
  const item = await ph.$(ITEM)
  if (item) await item.tap()
  ok('phone: tapping it turns the row into a task', await becomes(ph, B3, 'task'), await kindOf(ph, B3))
  ok('phone: no unexpected page errors', phErrors.filter((e) => !/Failed to fetch dynamically imported module/.test(e)).length === 0, phErrors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmake-task: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
