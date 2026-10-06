// HUM-10 (t1 ffc3b83c): Shift + K opens the kind menu of the selected
// message in the middle panel of every view, and Enter or Esc puts the
// focus back on that row.
//
//   channel  — focus is the feed heading; the menu is the middle card's
//   topic    — the thread card in /t/<id>
//   topics   — a topic row on / and on the /t list
//   flow     — the active flow entry
//   issues   — the selected issue's discussion
//
// Run: node tests/e2e/shift-k-middle.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TOPIC = 'e47e0e7e-0bed-4de5-a362-b8349f3e0100'
const CARD = 'e47e0e7e-0bed-4de5-a362-b8349f3e0101'
/* SPL-2 is the first issue this test creates. The mock epic SPL-1 is not a sheet row: the list asks for kind=issue. */
const ISSUE_TASK = '00000000-0000-4000-8000-000000000002'
const ISSUE_MSG = 'e47e0e7e-0bed-4de5-a362-b8349f3e0102'
const row = (msg_id, task_id, body, channel) => ({
  v: 1, msg_id, task_id, ts: '2026-12-01T10:00:00Z', from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel, parent_task_id: null,
  is_parent: 1, files: [],
})
const EXTRA = [
  row(CARD, TOPIC, 'shift-k channel card', 'alerts'),
  row(ISSUE_MSG, ISSUE_TASK, 'shift-k issue note', 'issues'),
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
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const menu = '[data-testid="kind-picker"]'
const menuOpen = () => Boolean(document.querySelector('[data-testid="kind-picker"]')?.getClientRects().length)
const menuShut = () => !document.querySelector('[data-testid="kind-picker"]')
const inMenu = () => Boolean(document.activeElement?.closest?.('[data-testid="kind-picker"]'))

async function shiftK(p) {
  await p.keyboard.down('Shift')
  await p.keyboard.press('K')
  await p.keyboard.up('Shift')
}

/** Shift + K, Esc back, Shift + K, Enter back. `onRow(arg)` runs in the page. */
async function prove(p, name, focus, onRow, rowArg) {
  const focused = await focus()
  ok(`${name}: the row is focused`, focused)
  if (!focused) return
  const arg = () => (typeof rowArg === 'function' ? rowArg() : rowArg)
  await shiftK(p)
  const opened = await until(p, menuOpen, null, 5000)
  ok(`${name}: Shift + K opens the kind menu`, opened)
  if (!opened) {
    ok(`${name}: (no menu, skip the rest)`, false, await p.evaluate(() => ({
      tag: document.activeElement?.tagName || '',
      id: document.activeElement?.getAttribute?.('data-testid') || String(document.activeElement?.className || ''),
    })))
    return
  }
  ok(`${name}: the focus is in the kind menu`, await until(p, inMenu, null, 3000))
  await sleep(500)
  ok(`${name}: the focus stays in the menu`, await p.evaluate(inMenu))
  await p.keyboard.press('Escape')
  ok(`${name}: Esc closes the menu`, await until(p, menuShut, null, 4000))
  await sleep(200)
  ok(`${name}: Esc returns the focus to the row`, await until(p, onRow, arg(), 3000))
  await shiftK(p)
  ok(`${name}: Shift + K opens the menu again`, await until(p, menuOpen, null, 5000))
  ok(`${name}: the focus is in the menu again`, await until(p, inMenu, null, 3000))
  await p.keyboard.press('Enter')
  ok(`${name}: Enter closes the menu`, await until(p, menuShut, null, 4000))
  await sleep(200)
  ok(`${name}: Enter returns the focus to the row`, await until(p, onRow, arg(), 3000))
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 240)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
      localStorage.setItem('spool.mock.archive_policy', 'everyone')
      localStorage.setItem('spool.mock.role', 'admin')
      localStorage.setItem('spool.flow-scope', 'all')
    } catch { /* private mode */ }
  }, EXTRA)
  await p.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })

  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await until(p, () => Boolean(document.querySelector('[data-testid="kind-key-host"]')), null, 15000)
  const cardThere = await until(p, (id) => Boolean(document.querySelector(`.spool-main article.msg[data-msg-id="${id}"]`)), CARD, 15000)
  ok('the channel middle shows the card', cardThere)
  ok('an admin can set another author\'s kind', await until(p, () => Boolean(document.querySelector('article.msg[data-msg-id="66666666-6666-4666-8666-666666666666"] [data-testid="kind-badge-btn"]')), null, 8000))

  await prove(p, 'channel', async () => p.evaluate(() => {
    const h = document.querySelector('.spool-main h2')
    if (!h) return false
    if (!h.hasAttribute('tabindex')) h.setAttribute('tabindex', '-1')
    h.focus()
    return document.activeElement === h
  }), () => {
    const id = document.querySelector('[data-testid="kind-badge-btn"][aria-expanded="true"]')?.closest('article.msg')?.getAttribute('data-msg-id')
      || document.activeElement?.closest?.('article.msg')?.getAttribute('data-msg-id')
      || ''
    if (id && document.activeElement?.closest?.('.spool-main') && !document.activeElement?.closest?.('aside.live-pane')) {
      return id
    }
    return ''
  })
  await p.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
  const homeRow = `a.topic-row[data-key="${TOPIC}"]`
  ok('topics: the row is listed', await until(p, (sel) => Boolean(document.querySelector(sel)), homeRow, 15000))
  await prove(p, 'topics', () => p.evaluate((sel) => {
    const el = document.querySelector(sel)
    el?.focus()
    return document.activeElement === el
  }, homeRow), (sel) => Boolean(document.activeElement?.matches?.(sel)), homeRow)

  await p.goto(`${srv.base}/t/${TOPIC}`, { waitUntil: 'networkidle2' })
  const listRow = `a.topic-row[data-key="${TOPIC}"]`
  ok('topic list: the row is listed', await until(p, (sel) => Boolean(document.querySelector(sel)), listRow, 15000))
  await prove(p, 'topic list', () => p.evaluate((sel) => {
    const el = document.querySelector(sel)
    el?.focus()
    return document.activeElement === el
  }, listRow), (sel) => Boolean(document.activeElement?.matches?.(sel)), listRow)

  const thread = `.topic-browse__thread article.msg[data-msg-id="${CARD}"]`
  ok('topic thread: the card is shown', await until(p, (sel) => Boolean(document.querySelector(sel)), thread, 15000))
  await prove(p, 'topic thread', () => p.evaluate((sel) => {
    const el = document.querySelector(sel)
    if (!el) return false
    el.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))
    el.focus()
    return document.activeElement === el
  }, thread), (sel) => Boolean(document.activeElement?.matches?.(sel) || document.activeElement?.closest?.(sel)), thread)

  /* /t hides the shell sidebar. Open Flow from a channel page, where the tab is on screen. */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('#sidebar-tab-flow', { visible: true, timeout: NAV_TIMEOUT })
  await p.click('#sidebar-tab-flow')
  const flowList = '[data-testid="left-list"][data-mode="flow"]'
  ok('flow: the list is shown', await until(p, (sel) => Boolean(document.querySelector(sel)), flowList, 15000))
  let flowId = ''
  await prove(p, 'flow', async () => {
    const ready = await p.evaluate((sel) => {
      const list = document.querySelector(sel)
      list?.focus()
      return Boolean(list && document.activeElement === list)
    }, flowList)
    if (!ready) return false
    const got = await until(p, () => Boolean(document.querySelector('[data-testid="left-list"] .side-hit.active, [data-testid="left-list"] .side-hit[aria-selected="true"]')), null, 4000)
    flowId = await p.evaluate(() => document.querySelector('[data-testid="left-list"] .side-hit.active, [data-testid="left-list"] .side-hit[aria-selected="true"]')?.getAttribute('data-msg-id') || '')
    return got && Boolean(flowId)
  }, (want) => {
    const list = document.activeElement?.matches?.('[data-testid="left-list"][data-mode="flow"]')
    const id = document.querySelector('[data-testid="left-list"] .side-hit.active, [data-testid="left-list"] .side-hit[aria-selected="true"]')?.getAttribute('data-msg-id') || ''
    return Boolean(list && id && id === want)
  }, () => flowId)

  await p.goto(`${srv.base}/issues`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test="issues-new"]', { visible: true, timeout: NAV_TIMEOUT })
  await p.click('[data-test="issues-new"]')
  await p.waitForSelector('[data-test="issues-newrow-title"]', { visible: true, timeout: 8000 })
  await p.type('[data-test="issues-newrow-title"]', 'shift-k issue')
  await p.keyboard.press('Enter')
  const issueRow = 'tr.issues-row[data-key="SPL-2"]'
  ok('issues: the row is listed', await until(p, (sel) => Boolean(document.querySelector(sel)), issueRow, 15000))
  await prove(p, 'issues', () => p.evaluate((sel) => {
    const el = document.querySelector(sel)
    el?.focus()
    return document.activeElement === el
  }, issueRow), (sel) => Boolean(document.activeElement?.closest?.(sel) || document.activeElement?.matches?.(sel)), issueRow)

  const benign = (e) => /Failed to fetch dynamically imported module|ResizeObserver/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nshift-k-middle: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
