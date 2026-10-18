// SPL-2506 (owner HUM-10, t1 43a1030f msgs 1c869ea9 + bfd1838c): "in any
// listing whenever there are new msgs, they should be at the top or at the
// bottom (depending on the settings of the user for pre or appending)", the
// item with the most unread at the very edge. Two listings, both directions:
//
//   topic cards, newest last    #alerts: an older topic with 2 unread replies
//                               sits BELOW a newer read one (control on
//                               master: above it)
//   Issues, newest first        the two issues a teammate assigned me, never
//                               opened (beside 3 opened), sit at the TOP
//                               (control on master: at the bottom)
//
// Mock bundle (spool.mock.extra-messages, spool.mock.issues-new / -seed); the Message
// order is the session claim, switched in the page's session store.
//   BASE_URL=<generated bundle> pnpm run test:e2e unread-first-order
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const SHOTS = process.env.SHOT_DIR || ''
const OLD = 'e2506101-0000-4000-8000-000000000001'
const NEW = 'e2506102-0000-4000-8000-000000000001'
const OLD_HEAD = 'e2506111-0000-4000-8000-000000000001'
const NEW_HEAD = 'e2506112-0000-4000-8000-000000000001'
const row = (msgId, task, from, ts, isParent, body) => ({
  v: 1, msg_id: msgId, task_id: task, ts, received_at: ts, from, from_box: 'box-wui', to: '@channel', to_box: 'box-wui',
  kind: 'note', body, files: [], channel: 'alerts', parent_task_id: null, is_parent: isParent,
})
const EXTRA = [
  row(OLD_HEAD, OLD, 'HUM-1', '2026-10-18T00:00:00Z', 1, 'an older topic of mine'),
  row('e2506121-0000-4000-8000-000000000001', OLD, 'HUM-2', '2026-10-18T00:10:00Z', 0, 'first unread reply'),
  row('e2506122-0000-4000-8000-000000000001', OLD, 'HUM-2', '2026-10-18T00:20:00Z', 0, 'second unread reply'),
  row(NEW_HEAD, NEW, 'HUM-1', '2026-10-18T01:00:00Z', 1, 'a newer topic, all read'),
]

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function poll(fn, pred, ms = 10000) {
  const t0 = Date.now()
  let s = await fn()
  while (!pred(s) && Date.now() - t0 < ms) {
    await sleep(250)
    s = await fn()
  }
  return s
}

async function page(browser, order) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1400, height: 900, isMobile: false, hasTouch: false })
  /* ResizeObserver's loop notice is the browser's, not the page's */
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => { if (!/ResizeObserver loop/.test(String(e.message))) window.__errs.push(String(e.message || '')) }) })
  await p.evaluateOnNewDocument((rows, oldT, newT) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows))
      localStorage.setItem('spool.mock.issues-new', '2')
      localStorage.setItem('spool.mock.issues-seed', '3')
      localStorage.setItem('spool.read-cursors', JSON.stringify({
        [`t:${oldT}`]: { ts: '2026-10-18T00:05:00.000Z', id: '', count: 0 },
        [`t:${newT}`]: { ts: '2026-10-18T01:30:00.000Z', id: '', count: 0 },
      }))
    } catch { /* about:blank */ }
  }, EXTRA, OLD, NEW)
  p.order = order
  return p
}

async function setOrder(p) {
  await p.evaluate((order) => {
    document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session').setViewPref('message_order', order)
  }, p.order)
}

const server = await startServer()
const browser = await launch()
try {
  /* 1. topic cards, newest last: the unread older topic below the newer read one */
  const p = await page(browser, 'newest-last')
  await p.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector(`article.msg[data-msg-id="${OLD_HEAD}"]`, { timeout: NAV })
  await setOrder(p)
  const cards = () => p.evaluate((a, b) => {
    const ids = [...document.querySelectorAll('article.msg[data-msg-id]')].map((el) => el.getAttribute('data-msg-id'))
    const unread = (id) => {
      const n = document.querySelector(`article.msg[data-msg-id="${id}"] [data-test=topic-unread]`)
      return n ? parseInt(n.textContent.trim(), 10) || 0 : 0
    }
    return { old: ids.indexOf(a), new: ids.indexOf(b), oldUnread: unread(a), newUnread: unread(b) }
  }, OLD_HEAD, NEW_HEAD)
  const c = await poll(cards, (s) => s.oldUnread > 0 && s.old >= 0 && s.new >= 0 && s.old > s.new)
  ok('the older topic carries unread, the newer none (the check is not vacuous)', c.oldUnread === 2 && c.newUnread === 0, c)
  ok('newest last: the topic with unread sits below the newer read one', c.old >= 0 && c.new >= 0 && c.old > c.new, c)
  if (SHOTS) await p.screenshot({ path: `${SHOTS}/topic-cards-newest-last.png` })

  /* 2. Issues, newest first: the never-opened issues at the top */
  const q = await page(browser, 'newest-first')
  await q.goto(`${server.base}/issues`, { waitUntil: 'networkidle2', timeout: NAV })
  await q.waitForSelector('[data-unopened]', { timeout: NAV })
  await setOrder(q)
  const rows = () => q.evaluate(() => {
    const els = [...document.querySelectorAll('.issues-row[data-key], .issues-row')].filter((el) => el.offsetParent !== null)
    return els.map((el) => (el.hasAttribute('data-unopened') ? 'U' : 'r')).join('')
  })
  const r = await poll(rows, (s) => /^U+r+$/.test(s))
  ok('the list has opened and never-opened rows (the check is not vacuous)', r.includes('U') && r.includes('r'), { r })
  ok('newest first: every never-opened issue sits above every opened one', /^U+r+$/.test(r), { r })
  if (SHOTS) await q.screenshot({ path: `${SHOTS}/issues-newest-first.png` })

  const errs = [...await p.evaluate(() => window.__errs || []), ...await q.evaluate(() => window.__errs || [])]
  ok('no window error', errs.length === 0, { errs })
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
