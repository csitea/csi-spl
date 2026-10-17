// SPL-2286 (c-635, dev t1 #live-proof, topic a0dbc16b): a topic card under-
// counted its new replies when the topic's read mark carried no `count`. A
// mark of a topic opened at 0 replies goes to the hub as {ts, id} (count 0 is
// left off on the wire), so every other browser pulled a mark the card could
// not read: the channel row read 2 (the hub counts replies after the mark's
// ts) and the card a plain "2 >>". Real browser, mock tenant.
//
//   countless  a t: mark {ts} with no count, 2 replies after its ts -> the
//              card reads "2/2 >>", as the row does
//   deep link  c-311 (msg 9b718269): /channel/alerts?topic=<id> loaded cold
//              marked the thread at the reply total the store held BEFORE the
//              feed loaded (0), so the card stayed "2/2 >>" with the pane
//              open on it. Now it reads a plain "2 >>", the mark at 2
//
// The replies are GRK-03's, never the reader's.
//   BASE_URL=http://127.0.0.1:3111 node tests/e2e/topic-card-countless-mark.test.mjs
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

const TASK = 'c2286000-0000-4000-8000-000000000000'
const ROOT = 'c2286000-0000-4000-8000-0000000000c0'
const line = (id, ts, body) => ({ msg_id: id, task_id: TASK, ts, received_at: ts, from: 'GRK-03', from_box: 'box-b', to: '@channel', kind: 'note', body, channel: 'alerts', files: [] })
const LINES = [
  line(ROOT, '2026-09-18T10:07:00Z', 'topic made by a move'),
  line('c2286000-0000-4000-8000-0000000000c1', '2026-09-18T10:08:00Z', 'first reply'),
  line('c2286000-0000-4000-8000-0000000000c2', '2026-09-18T10:09:00Z', 'second reply'),
]

const counterOf = (p) => p.evaluate((msgId) => {
  const card = document.querySelector(`article.msg[data-msg-id="${msgId}"]`)
  const btn = card && card.querySelector('[data-test=topic-replies]')
  const strong = btn && btn.querySelector('[data-test=topic-unread]')
  return { text: btn ? btn.textContent.replace(/\s+/g, ' ').trim() : null, unread: strong ? strong.textContent.trim() : null }
}, ROOT)

async function waitCounter(p, want, ms = 8000) {
  const end = Date.now() + ms
  let got = null
  while (Date.now() < end) {
    got = await counterOf(p)
    if (got.text === want) return got
    await sleep(200)
  }
  return got
}

const markOf = (p) => p.evaluate((t) => JSON.parse(localStorage.getItem('spool.read-cursors') || '{}')[`t:${t}`] || null, TASK)

/** A fresh page whose browser holds `cursors` and the topic's lines, then `path` loaded cold. */
async function openWith(browser, base, cursors, path) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1200, height: 760, isMobile: false, hasTouch: false })
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => window.__errs.push(String(e.message || ''))) })
  await p.goto(`${base}/channel/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.evaluate((lines, cursors) => {
    localStorage.clear()
    localStorage.setItem('spool.mock.extra-messages', JSON.stringify(lines))
    localStorage.setItem('spool.read-cursors', JSON.stringify(cursors))
  }, LINES, cursors)
  await p.goto(`${base}${path}`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector(`article.msg[data-msg-id="${ROOT}"]`, { timeout: NAV })
  return p
}

async function noErrors(p, name) {
  const errs = await p.evaluate(() => window.__errs || [])
  check(`${name}: no window error`, errs.length === 0, { errs })
}

async function runCountless(browser, base) {
  /* the hub's mark as another browser pulls it: a ts after the root, no count */
  const p = await openWith(browser, base, {
    'ch:alerts': { ts: '2026-09-18T10:06:00.000Z', id: '' },
    [`t:${TASK}`]: { ts: '2026-09-18T10:07:30.000Z', id: '' },
  }, '/channel/alerts')
  const got = await waitCounter(p, '2/2 >>')
  check('a t: mark with no count and 2 replies after its ts: the card reads "2/2 >>"', got.text === '2/2 >>' && got.unread === '2', got)
  const mark = await markOf(p)
  check('the mark keeps its ts and now counts the 0 replies seen at it', Boolean(mark) && mark.ts === '2026-09-18T10:07:30.000Z' && mark.count === 0, mark)
  await noErrors(p, 'countless')
  await p.close()
}

async function runDeepLink(browser, base) {
  const p = await openWith(browser, base, { 'ch:alerts': { ts: '2026-09-18T10:06:00.000Z', id: '' } }, `/channel/alerts?topic=${TASK}`)
  await waitCounter(p, '2 >>')
  /* c-311 saw "2/2 >>" stay for 30 s: hold for 3 and read again */
  await sleep(3000)
  const got = await counterOf(p)
  check('a cold /channel/alerts?topic=<id> leaves the card a plain "2 >>"', got.text === '2 >>' && got.unread === null, got)
  const mark = await markOf(p)
  check('the open marked the thread at its 2 replies', Boolean(mark) && mark.count === 2, mark)
  await noErrors(p, 'deep link')
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await runCountless(browser, server.base)
  await runDeepLink(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-card-countless-mark: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
