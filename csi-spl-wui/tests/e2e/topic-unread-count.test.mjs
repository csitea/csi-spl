// CLE-77804 (topic 35053f95, HUM-10): every topic card in a channel shows its
// own unread reply count as "<unread>/<total> >>" (the unread part bold, per
// reader, from the reader's read position in that topic), cleared to a plain
// "<total> >>" when the thread is opened. Real browser, mock tenant.
//
//   control   a topic the reader has never opened shows a PLAIN total (no "0/…")
//   unread    a topic read at 5 replies, now 7, shows "2/7" with the 2 bold
//   cleared   opening the thread snapshots the total -> the card reads plain "7"
//
// The per-topic read snapshot (t:<task_id> = {..,count}) is seeded into the same
// localStorage the cursors use, before the app boots; the topic row is injected
// through the channel store, as a live frame would.
//   BASE_URL=http://127.0.0.1:3111 node tests/e2e/topic-unread-count.test.mjs
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
const SEEN = 'seen-topic', FRESH = 'fresh-topic'

const signIn = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!s) return false
  s.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

/** Inject a topic-root card into the channel store with a hub reply total. */
const injectTopic = (p, taskId, count) => p.evaluate((taskId, count) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const ts = new Date(Date.parse('2026-09-18T09:00:00.000Z') + count * 1000).toISOString()
  const row = { v: 1, msg_id: `m-${taskId}`, task_id: taskId, topic_row: true, count, is_parent: 1, ts, received_at: ts, from: 'HUM-2', from_box: 'box-wui', to: '@channel', channel: 'alerts', kind: 'note', body: `topic ${taskId}`, files: [] }
  s.messages = [...s.messages, row]
}, taskId, count)

/** The topic-replies counter text + whether it has a bold unread part, for a card. */
const counterOf = (p, taskId) => p.evaluate((taskId) => {
  const card = document.querySelector(`article.msg[data-msg-id="m-${taskId}"]`)
  const btn = card && card.querySelector('[data-test=topic-replies]')
  const strong = btn && btn.querySelector('[data-test=topic-unread]')
  return {
    text: btn ? btn.textContent.replace(/\s+/g, ' ').trim() : null,
    unread: strong ? strong.textContent.trim() : null,
    bold: Boolean(strong && Number(getComputedStyle(strong).fontWeight) >= 700),
  }
}, taskId)

async function run(browser, base) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1200, height: 760, isMobile: false, hasTouch: false })
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => window.__errs.push(String(e.message || ''))) })
  /* the reader last read SEEN when it had 5 replies; FRESH was never opened */
  await p.evaluateOnNewDocument((seen) => { try { localStorage.setItem('spool.read-cursors', JSON.stringify({ [`t:${seen}`]: { ts: '2026-09-18T08:00:00.000Z', id: '', count: 5 } })) } catch { /* */ } }, SEEN)

  await p.goto(`${base}/channel/alerts`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  await signIn(p)
  await p.waitForSelector('.live-rows > article.msg', { timeout: NAV })

  injectTopic(p, FRESH, 3)
  injectTopic(p, SEEN, 7)
  await sleep(800)

  const fresh = await counterOf(p, FRESH)
  check('a never-opened topic shows a plain total (no "0/…")', fresh.text === '3 >>' && fresh.unread === null, fresh)

  const seen = await counterOf(p, SEEN)
  check('a topic read at 5, now 7, reads "2/7 >>"', seen.text === '2/7 >>' && seen.unread === '2', seen)
  check('the unread count is bold', seen.bold, seen)

  /* open the SEEN thread -> its total is snapshotted -> the card clears to plain */
  await p.evaluate((taskId) => document.querySelector(`article.msg[data-msg-id="m-${taskId}"]`).click(), SEEN)
  await sleep(800)
  const after = await counterOf(p, SEEN)
  check('opening the thread clears it to a plain total "7 >>"', after.text === '7 >>' && after.unread === null, after)

  const errs = await p.evaluate(() => window.__errs || [])
  check('no window error', errs.length === 0, { errs })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await run(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-unread-count: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
