// SPL-2506 (owner HUM-10, t1 d8fa6f9c): "the channel has new msg, but no new
// msgs in the topics" - #spool-hub-ui wore a 1 while none of its topic cards
// was marked new. The channel badge is the hub's ch: key, the sum of its
// topics' t: keys (flow-v1 keys); a card read only the reader's local cursor,
// whose count can say "read" while the hub still counts a line (a reply after
// the mark's time, the count taken on another device or before a move).
// A card now shows at least its topic's t: key (topicCounts), so the line the
// badge counts is marked on its card, and opening the card clears both.
//
//   control   on master this reads badge 1, card a plain "2 >>"
//   marked    badge 1 and the card "1/2 >>" (its new count >= the badge)
//   cleared   opening the card: a plain "2 >>" and the channel row's badge gone
//
// Mock bundle: the reader's own topic in #alerts with a reply from HUM-2
// (spool.mock.extra-messages); the t: cursor holds count 1 at a time before
// the reply, the ch: cursor is past it (the mock's cover rule is the hub's).
//   BASE_URL=<generated bundle> pnpm run test:e2e channel-badge-on-card
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const T = 'e2506001-0000-4000-8000-000000000001'
const HEAD = 'e2506002-0000-4000-8000-000000000001'
const REPLY = 'e2506003-0000-4000-8000-000000000001'
const row = (msgId, from, ts, isParent, body) => ({
  v: 1, msg_id: msgId, task_id: T, ts, received_at: ts, from, from_box: 'box-wui', to: '@channel', to_box: 'box-wui',
  kind: 'note', body, files: [], channel: 'alerts', parent_task_id: null, is_parent: isParent,
})
const EXTRA = [row(HEAD, 'HUM-1', '2026-10-18T01:00:00Z', 1, 'my topic'), row(REPLY, 'HUM-2', '2026-10-18T01:10:00Z', 0, 'a reply to it')]

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

/** The #alerts row badge (0 when none) and the topic card's counter text and new number. */
const state = (p) => p.evaluate((head) => {
  const link = [...document.querySelectorAll('a[href]')].find((a) => /\/channel\/alerts$/.test(a.getAttribute('href') || '') && a.querySelector('[data-testid=channel-unread]'))
  const badge = link ? parseInt(link.querySelector('[data-testid=channel-unread]').textContent.trim(), 10) || 0 : 0
  const card = document.querySelector(`article.msg[data-msg-id="${head}"]`)
  const btn = card && card.querySelector('[data-test=topic-replies]')
  const num = btn && btn.querySelector('[data-test=topic-unread]')
  return { badge, card: Boolean(card), counter: btn ? btn.textContent.replace(/\s+/g, ' ').trim() : null, unread: num ? parseInt(num.textContent.trim(), 10) : 0 }
}, HEAD)

async function until(p, pred, ms = 8000) {
  const t0 = Date.now()
  let s = await state(p)
  while (!pred(s) && Date.now() - t0 < ms) {
    await sleep(250)
    s = await state(p)
  }
  return s
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1400, height: 900, isMobile: false, hasTouch: false })
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => window.__errs.push(String(e.message || ''))) })
  await p.evaluateOnNewDocument((rows, t) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows))
      localStorage.setItem('spool.read-cursors', JSON.stringify({
        [`t:${t}`]: { ts: '2026-10-18T01:05:00.000Z', id: '', count: 1 },
        'ch:alerts': { ts: '2026-10-18T01:20:00.000Z', id: '' },
      }))
    } catch { /* about:blank */ }
  }, EXTRA, T)
  await p.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector(`article.msg[data-msg-id="${HEAD}"]`, { timeout: NAV })

  const before = await until(p, (s) => s.badge > 0 && s.unread > 0)
  ok('the channel row counts the reply (the check is not vacuous)', before.badge === 1, before)
  ok('its topic card is marked new: "1/2 >>", new >= the channel badge', before.counter === '1/2 >>' && before.unread >= before.badge, before)

  await p.evaluate((head) => document.querySelector(`article.msg[data-msg-id="${head}"]`).click(), HEAD)
  const after = await until(p, (s) => s.badge === 0 && s.unread === 0)
  ok('opening the card clears it to a plain "2 >>"', after.counter === '2 >>' && after.unread === 0, after)
  ok('and the channel row badge with it', after.badge === 0, after)

  const errs = await p.evaluate(() => window.__errs || [])
  ok('no window error', errs.length === 0, { errs })
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
