// SPL-2146: a long channel feed draws only the rows near the viewport. In a
// real browser (mock tenant), #alerts holds 2000 messages and the reader has
// pressed Load more until every one is shown (the store's own loadOlder, as
// the button does). Before SPL-2146 all 2000 cards were in the DOM (72005
// nodes under .feed-body, master c65a1e9a4); now a few dozen are, the
// spacers stand for the rest, scrolling to the end draws the oldest row, and
// a reveal (a ?topic= link, parent-section-open) draws a row far from view.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'

const TOTAL = 2000
/* the rows a 800 px viewport and its overscan need, with plenty of room */
const MAX_DRAWN = 200

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const fails = []
const ok = (name, pass, ev) => { console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name} ${JSON.stringify(ev)}`); if (!pass) fails.push(name) }
const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  /* the mock tenant re-reads #alerts every 4 s (useSpoolEvents), which puts
     the first page back and drops the rows injected below mid-check: that
     one timer does not start here */
  await p.evaluateOnNewDocument(() => {
    const every = window.setInterval
    window.setInterval = (fn, ms, ...rest) => (ms === 4000 ? 0 : every(fn, ms, ...rest))
  })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.feed-body article.msg', { timeout: 60000 })
  await new Promise((r) => setTimeout(r, 1000))
  const filled = await p.evaluate(async (total) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const c = pinia._s.get('channel')
    const like = c.messages[0]
    const T = Date.parse(like.ts)
    const older = Array.from({ length: total - c.messages.length }, (_, i) => ({
      ...like, msg_id: `vr-m-${i}`, task_id: `vr-t-${i}`, reply_to: undefined, body: `older row ${i}`, ts: new Date(T - (i + 1) * 60e3).toISOString(),
    }))
    c.messages = [...c.messages, ...older]
    let clicks = 0
    while (c.newestFirst.length < c.messages.length && clicks < 200) { await c.loadOlder(); clicks++ }
    const ids = c.newestFirst.map((m) => String(m.msg_id))
    return { held: c.messages.length, shown: c.newestFirst.length, clicks, oldest: ids[ids.length - 1], middle: ids[1000], middleTask: String(c.newestFirst[1000].task_id) }
  }, TOTAL)
  await new Promise((r) => setTimeout(r, 1500))
  const count = () => p.evaluate(() => ({
    rows: document.querySelectorAll('.feed-body article.msg').length,
    nodes: document.querySelectorAll('.feed-body *').length,
    spacers: document.querySelectorAll('.feed-body [data-testid="feed-spacer"]').length,
  }))
  const open = await count()
  ok(`all ${TOTAL} rows shown, at most ${MAX_DRAWN} drawn`, filled.shown === TOTAL && open.rows > 0 && open.rows <= MAX_DRAWN && open.spacers === 2, { filled, open })

  /* scroll to the end in steps, as a reader drags to the bottom: the
     content grows while rows drawn for the first time replace their
     estimate, so the end is where the pane stays at the bottom for two
     frames. There the oldest row is drawn and on screen, the count stays low. */
  const end = await p.evaluate(async (oldest) => {
    const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
    const s = document.querySelector('.feed-body')
    let worst = 0
    let still = 0
    for (let i = 0; i < 60 && still < 2; i++) {
      s.scrollTop = s.scrollHeight
      await frame()
      worst = Math.max(worst, document.querySelectorAll('.feed-body article.msg').length)
      const end = s.scrollTop + s.clientHeight >= s.scrollHeight - 2
      still = end && document.querySelector(`[data-msg-id="${oldest}"]`) ? still + 1 : 0
    }
    await frame()
    const el = document.querySelector(`[data-msg-id="${oldest}"]`)
    const r = el?.getBoundingClientRect()
    const v = s.getBoundingClientRect()
    return { drawn: !!el, onScreen: !!r && r.bottom > v.top && r.top < v.bottom, worst }
  }, filled.oldest)
  ok('scrolled to the end, the oldest row is drawn and on screen', end.drawn && end.onScreen && end.worst <= MAX_DRAWN, end)

  /* back to the top: the newest row is drawn again */
  const top = await p.evaluate(async () => {
    const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
    const s = document.querySelector('.feed-body')
    for (let i = 0; i < 20 && s.scrollTop > 0; i++) { s.scrollTop = 0; await frame() }
    const first = document.querySelector('.feed-body .live-rows > article.msg')
    return { scrollTop: s.scrollTop, first: first?.getAttribute('data-msg-id') || '', rows: document.querySelectorAll('.feed-body article.msg').length }
  })
  const newest = await p.evaluate(() => String(document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel').newestFirst[0]?.msg_id || ''))
  ok('back at the top, the newest row is the first drawn', top.scrollTop === 0 && top.first === newest, { top, newest })

  /* a reveal (what a ?topic= link sends when its card is not drawn) draws a row far from view */
  const shown = await p.evaluate(async (id, task) => {
    const frame = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
    const before = !!document.querySelector(`[data-msg-id="${id}"]`)
    document.dispatchEvent(new CustomEvent('spool:feed-reveal', { detail: { taskId: task } }))
    await frame()
    await frame()
    return { before, after: !!document.querySelector(`[data-msg-id="${id}"]`), rows: document.querySelectorAll('.feed-body article.msg').length }
  }, filled.middle, filled.middleTask)
  ok('a reveal draws a row far from the viewport', !shown.before && shown.after && shown.rows <= MAX_DRAWN, shown)
} finally {
  await browser.close()
  await srv.stop?.()
}
if (fails.length) {
  console.error(`feed-virtual-rows: ${fails.length} failed`)
  process.exit(1)
}
console.log('feed-virtual-rows: all checks passed')
