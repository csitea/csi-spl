// HUM-10 (owner, t1 topic e47e0e7e): "Shift + K on a reply msg, shows the
// popup, but it does not focus on it, thus it is unusable with the keyboard",
// then "the focus should be on the context menu so that one could quickly
// switch the kind of the msg and hit enter" and the whole loop: arrows to a
// reply, Shift + K, pick the kind, Enter, up to the next message, Shift + K...
//
// Ctrl + K stays the command palette (081 T004); Shift + K is the kind key.
// The kind menu (KindPicker) is teleported to <body>, outside every panel, so
// the shortcut's focus hold (useMsgShortcuts.ts holdPanel) must wait for it
// rather than pull the focus back to the card; Enter or Esc puts the focus
// back on the same message row (KindBadge).
//
// Against the lde mock (no hub), a 1280x800 desktop, a topic with three
// replies open in the third panel:
//   - Shift + K on a reply: the focus is inside the kind menu, on the current kind
//   - ArrowDown moves to the next kind; Enter sets it, closes the menu, and
//     the focus is back on the same reply
//   - ArrowUp then moves the focus to the message before it
//   - Shift + K, ArrowDown, Esc: closed, kind unchanged, focus on the same row
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/kind-key-focus.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'e47e0e7e-0bed-4de5-a362-b8349f3e0000'
const R1 = 'e47e0e7e-0bed-4de5-a362-b8349f3e0001'
const R2 = 'e47e0e7e-0bed-4de5-a362-b8349f3e0002'
const R3 = 'e47e0e7e-0bed-4de5-a362-b8349f3e0003'
const row = (msg_id, min, body, is_parent) => ({
  v: 1, msg_id, task_id: TASK, ts: `2026-10-05T10:0${min}:00Z`, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent, files: [],
})
const EXTRA = [
  row(TASK, 0, 'kind-key topic starter', 1),
  row(R1, 1, 'kind-key reply one', 0),
  row(R2, 2, 'kind-key reply two', 0),
  row(R3, 3, 'kind-key reply three', 0),
]
const REPLIES = [R1, R2, R3]

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

const card = (id) => `aside.live-pane article.msg[data-msg-id="${id}"]`
const visible = (sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length))

/** Where the focus is: a kind menu item (its kind), or a card (its msg_id). */
const focusAt = (p) => p.evaluate(() => {
  const a = document.activeElement
  return {
    menuKind: a?.closest?.('[data-testid="kind-picker"]') ? (a.getAttribute('data-kind') || '?') : '',
    id: a?.closest?.('article.msg')?.getAttribute('data-msg-id') || '',
    row: Boolean(a?.matches?.('article.msg')),
    topic: Boolean(a?.closest?.('aside.live-pane')),
    tag: a?.tagName || '',
  }
})

/** The kind a card's badge shows. */
const kindOf = (p, id) => p.evaluate((sel) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.getAttribute('data-kind') || '', card(id))

/** The visible cards of the third panel's feed, in DOM (reading) order. */
const topicOrder = (p) => p.evaluate(() => [...document.querySelectorAll('aside.live-pane [role="feed"] article.msg')]
  .filter((e) => e.getClientRects().length).map((e) => e.getAttribute('data-msg-id')))

/** Select a card the way a click does: a pointerdown, then the row takes the focus. */
const select = (p, sel) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  if (!el) return false
  el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, composed: true }))
  el.scrollIntoView({ block: 'center' })
  el.focus({ preventScroll: true })
  return document.activeElement === el
}, sel)

async function shiftKey(p, key) {
  await p.keyboard.down('Shift')
  await p.keyboard.press(key)
  await p.keyboard.up('Shift')
}

const menuOpen = '[data-testid="kind-picker"]'

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
  const opened = await p.waitForSelector(card(R3), { visible: true, timeout: 15000 }).then(() => true, () => false)
  ok('the topic opens in the third panel with its three replies', opened && (await until(p, (ids) => ids.every((id) => document.querySelector(`aside.live-pane article.msg[data-msg-id="${id}"]`)), REPLIES, 8000)))
  await sleep(400)

  /* ---- Shift + K on a reply with a message before it: the focus is in the menu ---- */
  const order = await topicOrder(p)
  const target = order.find((id, i) => REPLIES.includes(id) && i > 0 && REPLIES.includes(order[i - 1]))
  const prev = order[order.indexOf(target) - 1]
  ok('a reply with a reply before it is selected', Boolean(target) && (await select(p, card(target))), { order, target })
  const before = await kindOf(p, target)
  ok('its kind badge is settable and shows note', before === 'note', before)
  await shiftKey(p, 'K')
  ok('Shift + K opens the kind menu', await until(p, visible, menuOpen, 4000))
  /* past several of the shortcut's 50 ms focus-hold ticks: the focus must stay put */
  await sleep(500)
  const f1 = await focusAt(p)
  ok('the focus is inside the kind menu, on the current kind', f1.menuKind === 'note', f1)

  await p.keyboard.press('ArrowDown')
  await sleep(100)
  const f2 = await focusAt(p)
  ok('ArrowDown moves to the next kind (task)', f2.menuKind === 'task', f2)

  await p.keyboard.press('Enter')
  ok('Enter closes the menu', await until(p, (s) => !document.querySelector(s), menuOpen, 4000))
  ok('Enter set the kind to task', await until(p, (sel) => document.querySelector(`${sel} [data-testid="kind-badge-btn"]`)?.getAttribute('data-kind') === 'task', card(target), 4000))
  await sleep(300)
  const f3 = await focusAt(p)
  ok('the focus is back on the same message row', f3.row && f3.id === target && f3.topic, { want: target, got: f3 })

  await p.keyboard.press('ArrowUp')
  await sleep(200)
  const f4 = await focusAt(p)
  ok('ArrowUp moves to the message before it', f4.row && f4.id === prev, { want: prev, got: f4 })

  /* ---- Esc: closed, nothing changed, focus on the same row ---- */
  await shiftKey(p, 'K')
  ok('Shift + K on that message opens the menu again', await until(p, visible, menuOpen, 4000))
  await sleep(300)
  const f5 = await focusAt(p)
  ok('the focus is in the menu again', Boolean(f5.menuKind), f5)
  const prevKind = await kindOf(p, prev)
  await p.keyboard.press('ArrowDown')
  await p.keyboard.press('Escape')
  ok('Esc closes the menu', await until(p, (s) => !document.querySelector(s), menuOpen, 4000))
  await sleep(300)
  ok('Esc leaves the kind unchanged', (await kindOf(p, prev)) === prevKind, { prevKind })
  const f6 = await focusAt(p)
  ok('the focus is back on the same message row after Esc', f6.row && f6.id === prev, { want: prev, got: f6 })

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nkind-key-focus: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
