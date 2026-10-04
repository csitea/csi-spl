// HUM-10 (owner, t1 topic c13e8023): "when I hide a card in the reply msgs
// panel, the focus after hitting Shift + H goes to the second panel, when it
// should stay in the 3rd panel", then "on every keyboard shortcut ... the
// focus should go back to this panel" and "if the shortcut is applied to the
// center panel the same, and if on the left most panel the same". After a
// shortcut the focus stays in the panel it was pressed in
// (composables/useMsgShortcuts.ts holdPanel); a card that left hands it to
// its neighbour in the same feed.
//
// Against the lde mock (no hub), a 1280x800 desktop, three panels, a topic
// with three replies:
//   right  - Shift + H on a reply with a card after it: hidden, the focus is
//            on that next reply, inside the topic pane
//          - Shift + H on the last card (newest last): the card before it
//          - the Delete key on a reply (gone at once, with Undo): the next card
//   centre - Shift + A on a list card: archived, the focus is on a card of
//            the list (.spool-main), not in the topic pane
//   left   - Shift + ? on a rail tab opens the list; Esc closes it and the
//            focus is back in the rail (nav.sidebar)
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/hide-keeps-pane-focus.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'c13e8023-68c7-4a2c-bbb9-1539a164a000'
const R1 = 'c13e8023-68c7-4a2c-bbb9-1539a164a001'
const R2 = 'c13e8023-68c7-4a2c-bbb9-1539a164a002'
const R3 = 'c13e8023-68c7-4a2c-bbb9-1539a164a003'
const row = (msg_id, min, body, is_parent) => ({
  v: 1, msg_id, task_id: TASK, ts: `2026-10-04T10:0${min}:00Z`, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent, files: [],
})
const EXTRA = [
  row(TASK, 0, 'keep-focus topic starter', 1),
  row(R1, 1, 'keep-focus reply one', 0),
  row(R2, 2, 'keep-focus reply two', 0),
  row(R3, 3, 'keep-focus reply three', 0),
]
const T2 = 'c13e8023-68c7-4a2c-bbb9-1539a164a010'
EXTRA.push({ ...row(T2, 4, 'keep-focus archive me', 1), task_id: T2 })
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
const line = '[data-testid=hidden-cards-line]'
const gone = (sel) => ![...document.querySelectorAll(sel)].some((e) => e.getClientRects().length)
const visible = (sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length))

/** Where the focus is: the card's msg_id and which panel it sits in. */
const focusAt = (p) => p.evaluate(() => {
  const a = document.activeElement
  const row = a?.closest?.('article.msg')
  return {
    id: row?.getAttribute('data-msg-id') || '',
    topic: Boolean(a?.closest?.('aside.live-pane')),
    main: Boolean(a?.closest?.('.spool-main')),
    rail: Boolean(a?.closest?.('nav.sidebar')),
    tag: a?.tagName || '',
  }
})

/** The visible cards of the third panel's feed, in DOM (reading) order. */
const topicOrder = (p) => p.evaluate(() => [...document.querySelectorAll('aside.live-pane [role="feed"] article.msg')]
  .filter((e) => e.getClientRects().length).map((e) => e.getAttribute('data-msg-id')))

/** Select a card the way a click does: the row takes the focus. */
const select = (p, sel) => p.evaluate((sel) => {
  const el = document.querySelector(sel)
  if (!el) return false
  el.scrollIntoView({ block: 'center' })
  el.focus({ preventScroll: true })
  return document.activeElement === el
}, sel)

async function shiftKey(p, key) {
  await p.keyboard.down('Shift')
  await p.keyboard.press(key)
  await p.keyboard.up('Shift')
}

/** Wait for the focus to settle after the card left (the hide slides out first). */
async function settledFocus(p, sel) {
  await until(p, gone, sel, 4000)
  await sleep(300)
  return focusAt(p)
}

async function showAll(p) {
  while (await p.evaluate(visible, `aside.live-pane ${line}`)) {
    await p.click(`aside.live-pane ${line}`)
    await sleep(300)
  }
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
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.evaluate(() => { try { localStorage.removeItem('spool.hidden-cards') } catch { /* */ } })

  await p.goto(`${srv.base}/channel/alerts?topic=${TASK}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  const opened = await p.waitForSelector(card(R3), { visible: true, timeout: 15000 }).then(() => true, () => false)
  ok('the topic opens in the third panel with its three replies', opened && (await until(p, (ids) => ids.every((id) => document.querySelector(`.topic article.msg[data-msg-id="${id}"]`)), REPLIES, 8000)))
  ok('the second panel is open beside it', await p.evaluate(visible, '.spool-main article.msg'))
  await sleep(400)

  /* ---- Shift + H on a reply with a card after it: the focus goes to that next card ---- */
  const order = await topicOrder(p)
  const mid = order.find((id, i) => REPLIES.includes(id) && i + 1 < order.length)
  const after = order[order.indexOf(mid) + 1]
  ok('a reply with a neighbour after it is selected', Boolean(mid) && (await select(p, card(mid))), { order, mid })
  await shiftKey(p, 'H')
  const f1 = await settledFocus(p, card(mid))
  ok('Shift + H hides it', await p.evaluate(gone, card(mid)))
  ok('right: the focus stays in the topic pane, on the next reply', f1.topic && f1.id === after, { want: after, got: f1 })
  await showAll(p)
  await until(p, visible, card(mid), 4000)

  /* ---- Shift + H on the last card: the focus goes to the card before it.
     Newest last (the owner's own view), so the last card is a reply ---- */
  await p.evaluate(() => {
    document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session').setViewPref('message_order', 'newest-last')
  })
  await until(p, (s) => { const o = [...document.querySelectorAll('aside.live-pane [role="feed"] article.msg')]; return o.length > 1 && o[0].getAttribute('data-msg-id') === s }, TASK, 4000)
  const order2 = await topicOrder(p)
  const last = order2[order2.length - 1]
  const before = order2[order2.length - 2]
  ok('the last card is a reply and is selected', REPLIES.includes(last) && (await select(p, card(last))), { order2 })
  await shiftKey(p, 'H')
  const f2 = await settledFocus(p, card(last))
  ok('right: the focus stays in the topic pane, on the card before it', f2.topic && f2.id === before, { want: before, got: f2 })
  await showAll(p)
  await until(p, visible, card(last), 4000)

  /* ---- the Delete key on a reply (gone at once, Undo offered): same rule ---- */
  const order3 = await topicOrder(p)
  const del = order3.find((id, i) => REPLIES.includes(id) && i + 1 < order3.length)
  const delNext = order3[order3.indexOf(del) + 1]
  ok('a reply to delete is selected', Boolean(del) && (await select(p, card(del))), { order3, del })
  await p.keyboard.press('Delete')
  const f3 = await settledFocus(p, card(del))
  ok('right: Delete removes it and the focus stays in the topic pane, on the next card', f3.topic && f3.id === delNext, { want: delNext, got: f3 })

  /* ---- centre: Shift + A on a list card, the focus stays in the list ---- */
  const mid2 = `.spool-main article.msg[data-msg-id="${T2}"]`
  ok('the list card to archive is there and selected', (await until(p, visible, mid2, 6000)) && (await select(p, mid2)))
  await shiftKey(p, 'A')
  const f4 = await settledFocus(p, mid2)
  ok('Shift + A archives it and the focus stays in the centre panel, on a card', f4.main && !f4.topic && Boolean(f4.id) && f4.id !== T2, f4)
  await until(p, (s) => !document.querySelector(s), '[data-testid=archive-toast]', 4000)

  /* ---- left: Shift + ? on a rail tab, Esc, the focus is back in the rail ---- */
  const tab = await p.evaluate(() => {
    const t = [...document.querySelectorAll('nav.sidebar [id^="sidebar-tab-"]')].find((e) => e.getClientRects().length)
    if (!t) return ''
    t.focus()
    return document.activeElement === t ? t.id : ''
  })
  ok('a rail tab in the left panel is focused', Boolean(tab), tab)
  await shiftKey(p, '?')
  ok('Shift + ? opens the shortcuts list', await until(p, visible, '[data-testid=msg-shortcuts-help]', 4000))
  await p.keyboard.press('Escape')
  await until(p, (s) => !document.querySelector(s), '[data-testid=msg-shortcuts-help]', 4000)
  await sleep(300)
  const f5 = await focusAt(p)
  ok('Esc closes it and the focus is back in the left panel', f5.rail, f5)

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nhide-keeps-pane-focus: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
