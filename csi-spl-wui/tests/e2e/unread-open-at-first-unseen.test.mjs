// SPL-2430 (owner HUM-10, t1 89010926: "always the newest msgs ( which are
// not seen should be displayed first ) or last depending on how the user
// wants them"). A channel and a topic open where the reader's unseen
// messages start, in both message orders, with a "new" divider:
//
//   channel  #alerts holds 10 seen topics and 8 unseen. Opened from a
//            channel scrolled to its end, it shows the divider and opens
//            at the unseen block: newest-last at the first unseen (the
//            divider at the top), newest-first at the top of the block
//            (the newest unseen card at the top)
//   topic    a topic of 12 seen and 8 unseen replies (its t: mark is
//            older than them) opens with the divider before the first
//            unseen reply, at the same place per order
//   pill     the "N new" jump pill is hidden while the block is on screen
//   control  a topic with nothing unseen shows no divider
//
// Desktop (1440 px) and phone (390 px). Real browser, mock tenant; the read
// marks and the rows are seeded in localStorage before the app reads them.
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/unread-open-at-first-unseen.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

/** Read until want() holds on the SAME value for `hold` ms, or `max` runs out. */
async function until(read, want = () => true, hold = 400, max = 8000) {
  const end = Date.now() + max
  let key = ''
  let since = 0
  let v = await read()
  while (Date.now() < end) {
    const k = want(v) ? JSON.stringify(v) ?? 'undefined' : ''
    if (!k) { key = ''; since = 0 } else if (k !== key) { key = k; since = Date.now() } else if (Date.now() - since >= hold) return v
    await sleep(100)
    v = await read()
  }
  return v
}

const BOUNDARY = '2026-09-18T10:00:00.000Z'
const TOPIC = 'c2430000-0000-4000-8000-000000000000'
const ROOT = 'c2430000-0000-4000-8000-0000000000a0'
const SEEN_TOPIC = 'c2430000-0000-4000-8000-000000000001'
const SEEN_ROOT = 'c2430000-0000-4000-8000-0000000000b0'
const N_OLD = 12
const N_NEW = 8
/* the channel draws its newest 20 cards: the two topics above + 8 seen + 8 unseen */
const N_OLD_TOPICS = 8
const at = (h, m) => `2026-09-18T${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:00.000Z`
const row = (id, task, ts, body, isParent) => ({ v: 1, msg_id: id, task_id: task, ts, received_at: ts, from: 'GRK-03', from_box: 'box-b', to: '@channel', kind: 'note', body, channel: 'alerts', is_parent: isParent, files: [] })
const hex = (n) => String(n).padStart(12, '0')
function fixture() {
  const out = []
  for (let i = 0; i < N_OLD; i++) out.push(row(`c2430000-0000-4000-8001-${hex(i)}`, TOPIC, at(8, i), `seen reply ${i}\nline two\nline three`, 0))
  for (let i = 0; i < N_NEW; i++) out.push(row(`c2430000-0000-4000-8002-${hex(i)}`, TOPIC, at(11, i), `unseen reply ${i}\nline two\nline three`, 0))
  for (let i = 0; i < 3; i++) out.push(row(`c2430000-0000-4000-8005-${hex(i)}`, SEEN_TOPIC, at(8, 30 + i), `old reply ${i}`, 0))
  /* the mock lists a channel's LAST rows in this order: the cards go last */
  out.push(row(ROOT, TOPIC, at(7, 0), 'topic with unseen replies\nsecond line', 1), row(SEEN_ROOT, SEEN_TOPIC, at(7, 1), 'topic read to its end', 1))
  for (let i = 0; i < N_OLD_TOPICS; i++) { const id = `c2430000-0000-4000-8003-${hex(i)}`; out.push(row(id, id, at(9, i), `seen topic ${i}\nline two\nline three`, 1)) }
  for (let i = 0; i < N_NEW; i++) { const id = `c2430000-0000-4000-8004-${hex(i)}`; out.push(row(id, id, at(12, i), `unseen topic ${i}\nline two\nline three`, 1)) }
  return out
}
const UNSEEN_REPLIES = Array.from({ length: N_NEW }, (_, i) => `c2430000-0000-4000-8002-${hex(i)}`)
const UNSEEN_TOPICS = Array.from({ length: N_NEW }, (_, i) => `c2430000-0000-4000-8004-${hex(i)}`)

const app = (p, fn, ...a) => p.evaluate(fn, ...a)
const signIn = (p) => app(p, () => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!s) return false
  s.adopt({ hum: 'HUM-2', email: 'member2@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const setOrder = (p, order) => app(p, (order) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session').setViewPref('message_order', order), order)
const go = (p, path) => app(p, (path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
/* the mock re-reads the channel every 4 s, replacing its rows: freeze it once loaded */
const freezeMockPoll = (p) => app(p, () => { document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel').refresh = async () => {} })

/** Where a feed stands: the divider, the unseen rows, which are at the top of its scroller. */
const where = (p, scope, unseen) => p.evaluate((scope, unseen) => {
  const host = document.querySelector(scope)
  const sc = host && (host.matches('.feed-body') ? host : host.querySelector('.feed-body'))
  if (!sc || !sc.getClientRects().length) return { ok: false }
  const sr = sc.getBoundingClientRect()
  const items = [...sc.querySelectorAll('.live-rows > *')]
  const seq = items.map((el) => (el.matches('[data-testid=new-divider]') ? 'divider' : (el.getAttribute('data-key') || '')))
  const div = sc.querySelector('[data-testid=new-divider]')
  const top = (el) => (el ? Math.round(el.getBoundingClientRect().top - sr.top) : null)
  const unseenIdx = seq.map((k, i) => (unseen.includes(k) ? i : -1)).filter((i) => i >= 0)
  /* the newest unseen (the top of the block in newest-first) */
  const newest = sc.querySelector(`[data-key="${unseen[unseen.length - 1]}"]`)
  const oldest = sc.querySelector(`[data-key="${unseen[0]}"]`)
  return { ok: true, scrollTop: Math.round(sc.scrollTop), height: Math.round(sc.clientHeight), max: Math.round(sc.scrollHeight - sc.clientHeight), dividerIdx: seq.indexOf('divider'), unseenIdx, dividerTop: top(div), newestTop: top(newest), oldestTop: top(oldest) }
}, scope, unseen)

/* a row "at the top" of its scroller: its top edge within a card's slack of the top */
const atTop = (y, h) => y !== null && y >= -40 && y <= Math.max(120, h * 0.25)

function judge(tag, order, w, unseen) {
  const n = unseen.length
  const placed = order === 'newest-last'
    ? w.dividerIdx >= 0 && w.unseenIdx.length === n && w.dividerIdx < Math.min(...w.unseenIdx)
    : w.dividerIdx >= 0 && w.unseenIdx.length === n && w.dividerIdx > Math.max(...w.unseenIdx)
  check(`${tag} ${order}: a "new" divider marks the unseen block`, placed, { dividerIdx: w.dividerIdx, unseenIdx: w.unseenIdx })
  const opened = order === 'newest-last' ? atTop(w.dividerTop, w.height) : atTop(w.newestTop, w.height)
  check(`${tag} ${order}: opens at the ${order === 'newest-last' ? 'first unseen (the divider at the top)' : 'top of the unseen block (the newest unseen at the top)'}`, opened, w)
}

/* the "N new" jump pill points at the unseen block: hidden once the reader is at it */
const pill = (p, scope) => p.evaluate((scope) => Boolean(document.querySelector(scope)?.querySelector('[data-testid=unread-jump]')), scope)
async function noPill(p, tag, order, scope) {
  const shown = await until(() => pill(p, scope), (v) => v === false, 400, 3000)
  check(`${tag} ${order}: no "new" jump pill while the unseen block is on screen`, shown === false, { shown })
}

async function page(browser, base, width, order) {
  const p = await browser.newPage()
  const phone = width <= 480
  await p.setViewport({ width, height: phone ? 800 : 720, isMobile: phone, hasTouch: phone })
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => window.__errs.push(String(e.message || ''))) })
  await p.goto(`${base}/channel/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.evaluate((rows, b, topic, seenTopic, nOld) => {
    localStorage.clear()
    localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows))
    localStorage.setItem('spool.read-cursors', JSON.stringify({
      'ch:alerts': { ts: b, id: '' },
      [`t:${topic}`]: { ts: b, id: '', count: nOld },
      [`t:${seenTopic}`]: { ts: b, id: '', count: 3 },
    }))
  }, fixture(), BOUNDARY, TOPIC, SEEN_TOPIC, N_OLD)
  await p.reload({ waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  await signIn(p)
  await setOrder(p, order)
  await p.waitForSelector('.live-rows > article.msg', { timeout: NAV })
  /* the reader was elsewhere, scrolled to the far end of that feed */
  await p.evaluate(() => { const sc = document.querySelector('.live-feed')?.closest('.feed-body'); if (sc) sc.scrollTop = sc.scrollHeight })
  return p
}

async function run(browser, base, width, order) {
  const tag = `${width}px`
  const p = await page(browser, base, width, order)

  await go(p, '/channel/alerts')
  await p.waitForSelector(`article.msg[data-msg-id="${ROOT}"]`, { timeout: NAV })
  await freezeMockPoll(p)
  const ch = await until(() => where(p, 'main .feed-body, .feed-body', UNSEEN_TOPICS), (v) => v.ok && v.dividerIdx >= 0)
  judge(`${tag} channel`, order, ch, UNSEEN_TOPICS)
  await noPill(p, `${tag} channel`, order, 'main')
  if (process.env.OUT) await p.screenshot({ path: `${process.env.OUT}/open-unseen-channel-${order}-${width}.png` })

  /* the topic: its card opens the topic pane */
  await p.evaluate((id) => { const c = document.querySelector(`article.msg[data-msg-id="${id}"]`); c.scrollIntoView(); c.click() }, ROOT)
  await p.waitForSelector(`[data-test=topic-root] [data-key="${UNSEEN_REPLIES[0]}"]`, { timeout: NAV })
  const tp = await until(() => where(p, '[data-test=topic-root]', UNSEEN_REPLIES), (v) => v.ok && v.dividerIdx >= 0)
  judge(`${tag} topic`, order, tp, UNSEEN_REPLIES)
  await noPill(p, `${tag} topic`, order, '[data-test=topic-root]')
  if (process.env.OUT) await p.screenshot({ path: `${process.env.OUT}/open-unseen-topic-${order}-${width}.png` })

  const errs = await p.evaluate(() => window.__errs || [])
  check(`${tag} ${order}: no window error`, errs.length === 0, { errs })
  await p.close()
}

/* control: a topic read to its end draws no divider */
async function control(browser, base) {
  const p = await page(browser, base, 1440, 'newest-last')
  await go(p, '/channel/alerts')
  await p.waitForSelector(`article.msg[data-msg-id="${SEEN_ROOT}"]`, { timeout: NAV })
  await freezeMockPoll(p)
  await p.evaluate((id) => { const c = document.querySelector(`article.msg[data-msg-id="${id}"]`); c.scrollIntoView(); c.click() }, SEEN_ROOT)
  await p.waitForSelector('[data-test=topic-root] .live-rows > article.msg', { timeout: NAV })
  await sleep(800)
  const div = await p.evaluate(() => Boolean(document.querySelector('[data-test=topic-root] [data-testid=new-divider]')))
  check('control: a topic with nothing unseen shows no divider', !div, { div })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [1440, 390]) for (const o of ['newest-last', 'newest-first']) await run(browser, server.base, w, o)
  await control(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nunread-open-at-first-unseen: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
