// Owner (HUM-10, t1 7ef63cfc): the "<new>/<total> >>" count on a topic's first
// message "sometimes works sometimes not", in the channel view, the Topics view
// and the Flow view. A topic with no read mark of its own (t:<id>) got one only
// as the channel OPENED (CLE-77930 seedTopics); a reply that landed while the
// reader stayed in the channel - the count arriving after the first paint -
// left that card a plain total, while topics that had a mark showed "n/total".
//
//   before   the topic's replies are all before the channel mark: plain "1 >>"
//   live     a reply lands after the first paint: "1/2 >>", the 1 bold
//   again    a second one: "2/3 >>"
//
// Per left tab (Channels, Flow - both keep the channel in the middle), RUNS
// fresh browser contexts each (default 2; RUNS=10 for a stability count).
//
// Topics view (the middle is the Topics list; a topic opens in the right
// pane): the pane's first message carries the same count - new counted from
// the topic's read mark before this open read it, on that message only.
//   open     read at 1 of 3 replies: "2/3 >>" on the first message
//   reopen   closed and opened again (it was read): a plain "3 >>"
//   BASE_URL=http://127.0.0.1:3111 RUNS=10 node tests/e2e/topic-unread-live.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 60000)
const RUNS = Math.max(1, Number(process.env.RUNS ?? 2))
const VIEWS = ['channels', 'flow', 'topics']
const TASK = '7e7e7e7e-7e7e-4e7e-8e7e-7e7e7e7e7e7e'
/* the channel mark is after the topic's lines: nothing in it is new at open */
const MARK = '2026-09-18T09:00:00.000Z'
const EXTRA = [
  { v: 1, msg_id: TASK, task_id: TASK, ts: '2026-09-18T08:00:00Z', from: 'GRK-03', from_box: 'box-a', to: '@channel', kind: 'note', body: 'live count topic', channel: 'alerts', parent_task_id: null, is_parent: 1, files: [] },
  { v: 1, msg_id: '7f7f7f7f-7f7f-4f7f-8f7f-7f7f7f7f7f7f', task_id: TASK, ts: '2026-09-18T08:10:00Z', from: 'CLE-07', from_box: 'box-a', to: '@channel', kind: 'note', body: 'an old reply', channel: 'alerts', parent_task_id: null, is_parent: 0, files: [] },
]

/* Topics view: a topic read at 1 reply, with 2 more since */
const PANE_TASK = '7c7c7c7c-7c7c-4c7c-8c7c-7c7c7c7c7c7c'
const paneRow = (i, ts, body) => ({ v: 1, msg_id: i ? `7b7b7b7b-7b7b-4b7b-8b7b-7b7b7b7b7b0${i}` : PANE_TASK, task_id: PANE_TASK, ts, from: i ? 'CLE-07' : 'GRK-03', from_box: 'box-a', to: '@channel', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent: i ? 0 : 1, files: [] })
const PANE_EXTRA = [
  paneRow(0, '2026-09-18T07:00:00Z', 'pane count topic'),
  paneRow(1, '2026-09-18T07:10:00Z', 'read reply'),
  paneRow(2, '2026-09-18T09:10:00Z', 'new reply one'),
  paneRow(3, '2026-09-18T09:20:00Z', 'new reply two'),
]

const results = []
const ok = (name, pass, ev) => {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const CARD = (scope, task = TASK) => `${scope} article.msg[data-msg-id="${task}"] [data-test=topic-replies]`

/** The root card's counter: its text and the bold unread part. */
const counter = (p, scope, task) => p.evaluate((sel) => {
  const btn = document.querySelector(sel)
  const strong = btn && btn.querySelector('[data-test=topic-unread]')
  return {
    text: btn ? btn.textContent.replace(/\s+/g, ' ').trim() : null,
    unread: strong ? strong.textContent.trim() : null,
    bold: Boolean(strong && Number(getComputedStyle(strong).fontWeight) >= 700),
  }
}, CARD(scope, task))

/** Waits for the counter to read `want`; returns what it read last. */
async function reads(p, scope, want, task) {
  await p.waitForFunction((sel, want) => {
    const btn = document.querySelector(sel)
    return btn && btn.textContent.replace(/\s+/g, ' ').trim() === want
  }, { timeout: 4000 }, CARD(scope, task), want).catch(() => {})
  return counter(p, scope, task)
}

/** A reply the hub now holds (the mock's extra lines, read on its 4 s poll),
    delivered by the socket into the open channel's store. */
const liveReply = (p, n) => p.evaluate((task, n) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const ts = new Date().toISOString()
  const row = { v: 1, msg_id: `7d7d7d7d-7d7d-4d7d-8d7d-7d7d7d7d7d0${n}`, task_id: task, ts, received_at: ts, from: 'CLE-07', from_box: 'box-a', to: '@channel', kind: 'note', body: `live reply ${n}`, channel: 'alerts', parent_task_id: null, is_parent: 0, files: [] }
  const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
  localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, row]))
  s.ingestLive(row)
}, TASK, n)

async function fresh(browser, extra = EXTRA, cursors = { 'ch:alerts': { ts: MARK, id: '' } }) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((extra, mark) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
      localStorage.setItem('spool.read-cursors', JSON.stringify(mark))
    } catch { /* about:blank */ }
  }, extra, cursors)
  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  return { ctx, p, errors }
}

const shot = async (p, name) => {
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/topic-unread-live-${name}.png` })
}

/** Channels / Flow: the channel stays in the middle; replies land live. */
async function feedRun(browser, base, view, run) {
  const { ctx, p, errors } = await fresh(browser)
  const tag = `${view} #${run}`
  try {
    await p.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
    await p.waitForSelector(CARD('.feed-body'), { timeout: NAV })
    if (view !== 'channels') {
      await p.click(`[data-testid=sidebar-tab-${view}]`)
      await p.waitForSelector(`#sidebar-panel-${view}`, { visible: true, timeout: NAV })
    }
    const before = await reads(p, '.feed-body', '1 >>')
    ok(`${tag}: nothing new at open reads a plain "1 >>"`, before.text === '1 >>' && before.unread === null, before)
    await liveReply(p, 1)
    const live = await reads(p, '.feed-body', '1/2 >>')
    ok(`${tag}: a reply after the first paint reads "1/2 >>", the 1 bold`, live.text === '1/2 >>' && live.unread === '1' && live.bold, live)
    await new Promise((r) => setTimeout(r, 4500))
    const polled = await counter(p, '.feed-body')
    ok(`${tag}: it still reads "1/2 >>" after the next feed read`, polled.text === '1/2 >>', polled)
    if (run === 1) await shot(p, view)
    await liveReply(p, 2)
    const again = await reads(p, '.feed-body', '2/3 >>')
    ok(`${tag}: a second one reads "2/3 >>"`, again.text === '2/3 >>' && again.unread === '2', again)
    ok(`${tag}: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
  } finally {
    await ctx.close()
  }
}

/** Topics view: open the topic from the Topics list into the right pane. */
async function paneRun(browser, base, run) {
  const { ctx, p, errors } = await fresh(browser, PANE_EXTRA, { [`t:${PANE_TASK}`]: { ts: MARK, id: '', count: 1 } })
  const tag = `topics #${run}`
  const row = `#sidebar-panel-topics .nav-item[data-key="${PANE_TASK}"]`
  const pane = '[data-test=topic-root]'
  try {
    await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
    await p.click('[data-testid=sidebar-tab-topics]')
    await p.waitForSelector(row, { visible: true, timeout: NAV })
    await p.click(row)
    await p.waitForSelector(`${pane} article.msg[data-msg-id="${PANE_TASK}"]`, { timeout: NAV })
    const open = await reads(p, pane, '2/3 >>', PANE_TASK)
    ok(`${tag}: the pane's first message reads "2/3 >>", the 2 bold`, open.text === '2/3 >>' && open.unread === '2' && open.bold, open)
    const others = await p.$$eval(`${pane} article.msg [data-test=topic-replies]`, (b) => b.length)
    ok(`${tag}: only the first message carries the count`, others === 1, { others })
    if (run === 1) await shot(p, 'topics')
    await p.click('[data-test=live-topic-close]')
    await p.click(row)
    const again = await reads(p, pane, '3 >>', PANE_TASK)
    ok(`${tag}: opened again (read), it reads a plain "3 >>"`, again.text === '3 >>' && again.unread === null, again)
    ok(`${tag}: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
  } finally {
    await ctx.close()
  }
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const view of VIEWS) {
    for (let run = 1; run <= RUNS; run++) await (view === 'topics' ? paneRun(browser, server.base, run) : feedRun(browser, server.base, view, run))
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-unread-live: ${results.length - failed.length}/${results.length} passed (RUNS=${RUNS} per view)`)
process.exit(code || (failed.length ? 1 : 0))
