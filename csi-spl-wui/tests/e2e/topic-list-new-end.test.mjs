// Spec 189 row B5 (owner HUM-10, t1 a48d75d6, msg b548992a: "regardless of
// the current sorting and filtering for the topics in a channel the new story,
// regardless of the default prio 3 should always appear on the top or bottom
// of the list depending on what kind of setting (pre-pend or append the user
// has)"; answers OWN / RLD / YES / BDG, msg fa6d8718).
//
// A mock channel (#alerts) that holds two unread P1 cards and a read P1 card
// with many messages. I create a topic there (a send with no parent task):
//   C1 C2 C3  under each sort x both filters, in both message orders, my card
//             is the first (newest first) / the last (newest last) card
//   C5        a topic root from someone else arriving live is not pinned
//   C7        the "new" badge is on my card, and on no other
//   C6        opening another topic and changing the sort keep it there;
//             leaving the channel and coming back: it sits by the sort, no badge
// Red control (spec row B5): run it without row B3 (LiveFeed's pinEdge and
// MessageFeed's keep): red on Priority and New.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e topic-list-new-end
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 60000)
const CHANNEL = '/channel/alerts'
const SORTS = ['last', 'messages', 'priority']
const FILTERS = ['all', 'new']
const NOW = Date.now()
const iso = (minAgo) => new Date(NOW - minAgo * 60000).toISOString()
/* the channel mark: the read P1 card is before it, the unread ones after it */
const MARK = iso(60)
const id = (n) => `18918918-9189-4189-8189-1891891891${String(n).padStart(2, '0')}`
const row = (task, n, minAgo, from, body, parent = 1) => ({ v: 1, msg_id: n ? id(n) : task, task_id: task, ts: iso(minAgo), from, from_box: 'box-a', to: '@channel', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent: parent, files: [] })
const READ_P1 = id(1)
const UNREAD_A = id(2)
const UNREAD_B = id(3)
const LIVE_ROOT = id(4)
const EXTRA = [
  row(READ_P1, 0, 180, 'CLE-07', 'read P1 topic, many messages'),
  ...[11, 12, 13, 14, 15, 16].map((n, i) => row(READ_P1, n, 170 - i, 'CLE-07', `read reply ${i}`, 0)),
  row(UNREAD_A, 0, 30, 'CLE-07', 'unread P1 topic a'),
  row(UNREAD_B, 0, 20, 'GRK-03', 'unread P1 topic b'),
  row(UNREAD_B, 21, 19, 'CLE-07', 'unread reply b', 0),
]
const PRIORITIES = { [READ_P1]: 1, [UNREAD_A]: 1, [UNREAD_B]: 1 }

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* the drawn topic cards of the middle pane, top first */
function cards() {
  const els = [...document.querySelectorAll('.feed-body article.msg[data-msg-id]')].filter((el) => !el.closest('[data-test=topic-section]'))
  return els.map((el) => ({ id: el.getAttribute('data-msg-id'), badge: Boolean(el.querySelector('[data-test=topic-pinned-new]')), badgeText: el.querySelector('[data-test=topic-pinned-new]')?.textContent?.trim() || '', prio: el.querySelector('[data-testid=topic-priority-badge]')?.getAttribute('data-priority') || '' }))
}

async function choose(p, group, value) {
  const now = await p.$eval('[data-testid=topic-list-control]', (el, g) => el.getAttribute(`data-${g}`), group)
  if (now === value) return
  const open = await p.$(`[data-testid=topic-list-${group}-group]`)
  if (!open) await p.click(`[data-testid=topic-list-${group}]`)
  await p.waitForSelector(`[data-testid=topic-list-${group}-${value}]`, { timeout: 5000 })
  await p.click(`[data-testid=topic-list-${group}-${value}]`)
  await p.keyboard.press('Escape')
  /* the control says what is applied: a click that missed fails here, not as a wrong order */
  await p.waitForFunction((g, v) => document.querySelector('[data-testid=topic-list-control]')?.getAttribute(`data-${g}`) === v, { timeout: 5000 }, group, value)
  await sleep(200)
}

const store = (name) => `document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('${name}')`
const atEdge = (list, mine, last) => (last ? list[list.length - 1]?.id : list[0]?.id) === mine

async function openChannel(browser, order) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((extra, prio, mark) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
      localStorage.setItem('spool.mock.priorities', JSON.stringify(prio))
      localStorage.setItem('spool.read-cursors', JSON.stringify({ 'ch:alerts': { ts: mark, id: '' } }))
    } catch { /* about:blank */ }
  }, EXTRA, PRIORITIES, MARK)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + CHANNEL, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector(`.feed-body article.msg[data-msg-id="${UNREAD_A}"]`, { timeout: NAV })
  await p.waitForSelector('[data-testid=topic-list-control]', { timeout: 10000 })
  await p.evaluate(`${store('session')}.setViewPref('message_order', '${order}')`)
  await sleep(200)
  return { ctx, p, errors }
}

async function orderRun(browser, order) {
  const last = order === 'newest-last'
  const { ctx, p, errors } = await openChannel(browser, order)
  try {
    const sent = await p.evaluate(`${store('channel')}.send('my new topic, ${order}').then((r) => String(r.msg_id || ''))`)
    await p.waitForSelector(`.feed-body article.msg[data-msg-id="${sent}"]`, { timeout: 10000 })
    /* C5: a topic root from someone else lands live and is not pinned */
    await p.evaluate((r) => {
      const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, r]))
      document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel').ingestLive(r)
    }, { ...row(LIVE_ROOT, 0, 0, 'CLE-07', 'a live topic from someone else'), ts: new Date().toISOString() })
    await p.waitForSelector(`.feed-body article.msg[data-msg-id="${LIVE_ROOT}"]`, { timeout: 10000 })
    for (const sort of SORTS) {
      for (const filter of FILTERS) {
        await choose(p, 'sort', sort)
        await choose(p, 'filter', filter)
        const list = await p.evaluate(cards)
        const badges = list.filter((c) => c.badge).map((c) => c.id)
        const p1 = list.filter((c) => c.prio === '1').length
        ok(`${order}, ${sort}, ${filter}: my new topic is the ${last ? 'last' : 'first'} card, beside ${p1} P1 card(s)`, atEdge(list, sent, last) && p1 >= 2, { list: list.map((c) => c.id.slice(-4)), sent: sent.slice(-4) })
        ok(`${order}, ${sort}, ${filter}: the "new" badge on my card only`, badges.length === 1 && badges[0] === sent && list.find((c) => c.id === sent)?.badgeText === 'new', { badges })
      }
    }
    /* C6: opening another topic and changing the sort keep it at the edge */
    await choose(p, 'sort', 'priority')
    await choose(p, 'filter', 'new')
    await p.click(`.feed-body article.msg[data-msg-id="${UNREAD_A}"]`)
    await p.waitForFunction(() => /[?&]topic=/.test(location.search), { timeout: 10000 })
    await sleep(300)
    const opened = await p.evaluate(cards)
    ok(`${order}: another topic opened, my card stays at the edge with its badge`, atEdge(opened, sent, last) && opened.find((c) => c.id === sent)?.badge, { list: opened.map((c) => c.id.slice(-4)) })
    await choose(p, 'sort', 'messages')
    const resorted = await p.evaluate(cards)
    ok(`${order}: the sort changed, my card stays at the edge`, atEdge(resorted, sent, last), { list: resorted.map((c) => c.id.slice(-4)) })
    /* C6: leaving the channel ends the pin; back in it, my card sits by the sort, no badge */
    await p.evaluate(`document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/issues')`)
    await p.waitForFunction(() => location.pathname === '/issues', { timeout: 10000 })
    await sleep(300)
    await p.evaluate(`document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('${CHANNEL}')`)
    await p.waitForFunction((path) => location.pathname === path, { timeout: 10000 }, CHANNEL)
    await p.waitForSelector('[data-testid=topic-list-control]', { timeout: NAV })
    await sleep(500)
    await choose(p, 'filter', 'all')
    await p.waitForSelector(`.feed-body article.msg[data-msg-id="${sent}"]`, { timeout: 10000 })
    await choose(p, 'sort', 'priority')
    const back = await p.evaluate(cards)
    ok(`${order}: back in the channel, my P3 card sits by Priority (not at the edge) and has no badge`, !atEdge(back, sent, last) && !back.some((c) => c.badge), { list: back.map((c) => c.id.slice(-4)), sent: sent.slice(-4) })
    ok(`${order}: no page error`, errors.length === 0, errors)
  } finally {
    await ctx.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  await orderRun(browser, 'newest-first')
  await orderRun(browser, 'newest-last')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
