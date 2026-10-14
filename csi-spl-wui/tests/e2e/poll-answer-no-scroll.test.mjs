// SPL-1769 (owner HUM-10, t1 26c2a7e2, msg 92149f81): answering a poll must
// not move the reader. "After each answer, the whole screen gets scrolled up
// ... the scroll should stay whatever it is, because there might be a lot of
// questions which one must scroll through manually."
// Follow-ups (msgs 4778f585, e0e4a5ac): desktop has the same bug; "after each
// [answer] it will scroll up till the next question's beginning so that IT
// will be the one of the top of the screen ... the same on mobile".
//
// A 6-question ```poll form, taller than the phone screen, in the open topic
// pane (where the form's answers land as replies). The reader scrolls to
// question 3 and picks an option; after the answer reply is in the feed,
// question 4's start sits at the top of the pane (within a few px), in both
// message orders. The last question (6) answered: it stays where it was. Then
// a checkbox form (lock-in on Send): the form stays put. Desktop the same.
// "live send": the mock store appends the reply as a plain row; the live
// store first shows OUR row pending (the feed follows its own sends to the
// newest end), then the echo replaces it. That case swaps the store's send
// for one that does the same, so the follow is exercised too.
//
// Causes (master 2026-10-14, all three red here before the fix): a
// newest-first thread anchors nothing, so the reply drawn above the form
// pushed it down; newest-last anchored on a poll option (its data-key read
// as a feed row id) and moved scrollTop; a pending own row jumped the feed.
//
// Run:
//   pnpm run test:e2e poll-answer-no-scroll
//   BASE_URL=<generated bundle> pnpm run test:e2e poll-answer-no-scroll   # what CI does
//   SHOTS=<dir> ... also writes a before/after screenshot per case there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/channel/alerts'
/* a pick may shift the form by its own answers line, never by a scroll */
const TOLERANCE_PX = 4

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* the page at rest: `read` answers the same for STILL_FRAMES frames in a
   row, a little more than the app's own hold (parent-section-open.mjs lets
   a card go after 10 still frames) */
const STILL_FRAMES = 12
async function rest(p, read, ...args) {
  const t0 = Date.now()
  let last = ''
  let still = 0
  while (Date.now() - t0 < NAV_TIMEOUT) {
    const now = JSON.stringify(await p.evaluate(read, ...args))
    still = now === last ? still + 1 : 0
    if (still >= STILL_FRAMES) return
    last = now
    await p.evaluate(() => new Promise((r) => requestAnimationFrame(() => r())))
  }
  throw new Error(`the page did not come to rest in ${NAV_TIMEOUT} ms`)
}
/* the feed as drawn: its rows in order, the store's row count, the scroll */
const feedNow = () => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  const ids = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].map((a) => a.dataset.msgId)
  const s = document.querySelector('.spool-main .feed-body')
  return [ids.join(), (pinia.state.value.channel.messages || []).length, s ? s.scrollTop : -1]
}

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const questions = (open, close) => Array.from({ length: 6 }, (_, i) => `Question ${i + 1}: which way for part ${i + 1}?\n${open}A${close} The first way\n${open}B${close} The second way\n${open}C${close} The third way`).join('\n')
const POLL_RADIO = `Six questions\n\n\`\`\`poll\n${questions('(', ')')}\n\`\`\``
const POLL_CHECK = `Six checks\n\n\`\`\`poll\n${questions('[', ']')}\n\`\`\``

async function open(browser, vp, order) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  /* a member with the message order picked (signed out has no view prefs) */
  await p.evaluate((order) => {
    const session = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', message_order: order })
  }, order)
  await rest(p, feedNow)
  return { p, errors }
}

/* the form as a topic with a few replies under it, so the pane scrolls */
function seedPoll(p, body) {
  return p.evaluate((body) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    const id = crypto.randomUUID()
    const task = crypto.randomUUID()
    const t0 = Date.now() - 60e3
    const row = { v: 1, msg_id: id, task_id: task, ts: new Date(t0).toISOString(), from: 'CLE-07', to: '@channel', kind: 'note', body, files: [], channel: channel.active || 'alerts', parent_task_id: null, is_parent: 1 }
    const replies = Array.from({ length: 3 }, (_, i) => ({ ...row, msg_id: crypto.randomUUID(), ts: new Date(t0 + (i + 1) * 1000).toISOString(), body: `earlier reply ${i + 1}\nsecond line\nthird line`, is_parent: 0, parent_task_id: task }))
    try {
      const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, row, ...replies]))
    } catch { /* private mode */ }
    channel.messages = [...channel.messages, row, ...replies]
    return { msg_id: id, task_id: task }
  }, body)
}

async function openPoll(p, seeded, touch) {
  const sel = `.spool-main article.msg[data-msg-id="${seeded.msg_id}"]`
  await p.waitForSelector(`${sel} [data-testid=poll-form]`, { timeout: 15000 })
  const form = `aside.live-pane article.msg[data-msg-id="${seeded.msg_id}"] [data-testid=poll-form]`
  /* cards off screen are laid out at a 72 px estimate (content-visibility)
     and take their real height once scrolled in, so the spot is read only
     after it holds still for two frames; a tap that lands while the feed
     still moves is repeated */
  for (let attempt = 0; attempt < 3; attempt++) {
    const spot = await p.evaluate(async (sel) => {
      const frame = () => new Promise((r) => requestAnimationFrame(() => r()))
      /* the card is taller than the screen: bring its first line, not its middle, into view */
      const para = () => { const el = document.querySelector(sel); return el.querySelector('.msg-para') || el }
      let last = ''
      for (let i = 0; i < 40; i++) {
        para().scrollIntoView({ block: 'center' })
        await frame(); await frame()
        const r = para().getBoundingClientRect()
        const now = `${Math.round(r.left)},${Math.round(r.top)}`
        if (now === last) return { x: Math.round(r.left + Math.min(20, r.width / 2)), y: Math.round(r.top + r.height / 2) }
        last = now
      }
      const r = para().getBoundingClientRect()
      return { x: Math.round(r.left + Math.min(20, r.width / 2)), y: Math.round(r.top + r.height / 2) }
    }, sel)
    if (touch) await p.touchscreen.tap(spot.x, spot.y)
    else await p.mouse.click(spot.x, spot.y)
    if (await p.waitForSelector(form, { timeout: 10000 }).then(() => true, () => false)) break
  }
  await p.waitForSelector(form, { timeout: 5000 })
  await rest(p, (form) => { const r = document.querySelector(form).getBoundingClientRect(); return [r.top, r.height] }, form)
  return form
}

/* scroll the form's own scroller (the reader's finger) so question `qi`
   sits at viewport y `at` */
function placeQuestion(p, form, qi, at) {
  return p.evaluate((form, qi, at) => {
    const q = document.querySelectorAll(`${form} [data-testid=poll-question]`)[qi]
    let s = q.parentElement
    while (s && !/(auto|scroll)/.test(getComputedStyle(s).overflowY)) s = s.parentElement
    s = s || document.scrollingElement
    s.scrollTop += q.getBoundingClientRect().top - at
    return true
  }, form, qi, at)
}

function where(p, form, qi) {
  return p.evaluate(whereNow, form, qi)
}

/* question `qi`'s top, the pane's top and scroll, the page's scroll */
function whereNow(form, qi) {
  const q = document.querySelectorAll(`${form} [data-testid=poll-question]`)[qi]
  if (!q) return null
  let s = q.parentElement
  while (s && !/(auto|scroll)/.test(getComputedStyle(s).overflowY)) s = s.parentElement
  const paneTop = s && s !== document.scrollingElement ? s.getBoundingClientRect().top : 0
  const atEnd = Boolean(s && s.scrollHeight - s.clientHeight - s.scrollTop <= 2)
  return { qTop: Math.round(q.getBoundingClientRect().top), paneTop: Math.round(paneTop), scrollTop: Math.round(s ? s.scrollTop : -1), atEnd, windowY: Math.round(window.scrollY) }
}

function replies(p, id) {
  return p.evaluate((id) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    return (pinia.state.value.channel.messages || []).filter((m) => String(m.body || '').includes(`Poll: ${id}`)).length
  }, id)
}

/* a tap where the option is now: no scrollIntoView, the reader's view stays */
async function tapOption(p, form, qi, key, touch) {
  const spot = await p.evaluate((form, qi, key) => {
    const q = document.querySelectorAll(`${form} [data-testid=poll-question]`)[qi]
    const r = q.querySelector(`[data-testid=poll-option][data-poll-key=${key}]`).getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(10, r.width / 2)), y: Math.round(r.top + r.height / 2) }
  }, form, qi, key)
  if (touch) await p.touchscreen.tap(spot.x, spot.y)
  else await p.mouse.click(spot.x, spot.y)
}

/* the next question's start at the top of the pane (8 px gap), the page
   itself unmoved; a pane already scrolled to its end (newest-first: the
   thread's root is the last row) takes it as high as it can: never above
   the top, and lower than before only by what the form's own answers line
   gives back below it (no room left to scroll) */
const NEXT_GAP_PX = 8
const END_SLACK_PX = 32
const atTop = (a, b) => Boolean(a && b && b.windowY === a.windowY && (Math.abs(b.qTop - b.paneTop - NEXT_GAP_PX) <= TOLERANCE_PX
  || (b.atEnd && b.qTop - b.paneTop >= NEXT_GAP_PX - TOLERANCE_PX && b.qTop <= a.qTop + END_SLACK_PX)))
const still = (a, b) => Boolean(a && b && Math.abs(a.qTop - b.qTop) <= TOLERANCE_PX && b.windowY === a.windowY)
/* the same at the pane's end: with no room left to scroll, a shorter answers
   line below the question (a wider font wraps "6: none" on two lines and
   "6: A" on one: 61 -> 41 px on the hosted runners' DejaVu Sans) lets the
   question down by what it gives back, never up and never more */
const stillOrEnd = (a, b) => still(a, b) || Boolean(a && b && a.atEnd && b.atEnd && b.windowY === a.windowY
  && b.qTop >= a.qTop && b.qTop - a.qTop <= END_SLACK_PX)

/* the live store's send: our row at once, pending, then the echo */
function liveSend(p) {
  return p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    channel.send = async (text, parentTaskId, files, channelId, isParent) => {
      const id = crypto.randomUUID()
      const now = new Date().toISOString()
      const row = { v: 1, msg_id: id, task_id: parentTaskId, ts: now, received_at: now, from: 'HUM-1', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body: text, files: [], channel: channelId || channel.active, parent_task_id: parentTaskId, is_parent: isParent, pending: true }
      channel.messages = [...channel.messages, row]
      await new Promise((r) => setTimeout(r, 400))
      const echo = { ...row, pending: false }
      /* the mock re-reads its feed: the echo rides its test hook, as seedPoll's rows do */
      try {
        const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
        localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, echo]))
      } catch { /* private mode */ }
      channel.messages = channel.messages.some((m) => m.msg_id === id) ? channel.messages.map((m) => (m.msg_id === id ? echo : m)) : [...channel.messages, echo]
      return echo
    }
  })
}

async function radioCase(browser, vp, tag, order, live = false) {
  const touch = Boolean(vp.hasTouch)
  const { p, errors } = await open(browser, vp, order)
  if (live) {
    await liveSend(p)
    tag += ' live send'
  }
  const seeded = await seedPoll(p, POLL_RADIO)
  const form = await openPoll(p, seeded, touch)
  /* taller than the pane it scrolls in: the reader must scroll to question 3 */
  const tall = await p.evaluate((form) => {
    const f = document.querySelector(form)
    return { form: Math.round(f.getBoundingClientRect().height), pane: f.closest('.feed-body')?.clientHeight || innerHeight }
  }, form)
  await placeQuestion(p, form, 2, Math.round(vp.height * 0.4))
  await rest(p, whereNow, form, 3)
  const before = await where(p, form, 3)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `poll-no-scroll-${tag}-${order}-radio-before.png`) })
  const n0 = await replies(p, seeded.msg_id)
  await tapOption(p, form, 2, 'B', touch)
  await sleep(1500)
  const after = await where(p, form, 3)
  const n1 = await replies(p, seeded.msg_id)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `poll-no-scroll-${tag}-${order}-radio-after.png`) })
  ok(`${tag} ${order} radio: the form is taller than its pane and the answer reply landed`, tall.form > tall.pane && n1 === n0 + 1, { tall, n0, n1 })
  ok(`${tag} ${order} radio: after answering question 3, question 4 starts at the top of the pane (<= ${TOLERANCE_PX} px)`, atTop(before, after), { before, after })
  /* the next answer, to question 4: question 5 comes up the same way */
  const before2 = await where(p, form, 4)
  await tapOption(p, form, 3, 'C', touch)
  await sleep(1500)
  const after2 = await where(p, form, 4)
  ok(`${tag} ${order} radio: the next answer (question 4) brings question 5 to the top too`, atTop(before2, after2), { before2, after2 })
  /* the last question: nothing below it, the reader stays where they are */
  await placeQuestion(p, form, 5, Math.round(vp.height * 0.4))
  await rest(p, whereNow, form, 5)
  const before3 = await where(p, form, 5)
  await tapOption(p, form, 5, 'A', touch)
  await sleep(1500)
  const after3 = await where(p, form, 5)
  ok(`${tag} ${order} radio: answering the last question (6) does not move the reader (<= ${TOLERANCE_PX} px; at the pane's end <= ${END_SLACK_PX} px down)`, stillOrEnd(before3, after3), { before3, after3 })
  ok(`${tag} ${order} radio: no page error`, errors.length === 0, errors)
  await p.close()
}

async function checkCase(browser, vp, tag, order) {
  const touch = Boolean(vp.hasTouch)
  const { p, errors } = await open(browser, vp, order)
  const seeded = await seedPoll(p, POLL_CHECK)
  const form = await openPoll(p, seeded, touch)
  await placeQuestion(p, form, 2, Math.round(vp.height * 0.3))
  await rest(p, whereNow, form, 2)
  await tapOption(p, form, 2, 'A', touch)
  await rest(p, whereNow, form, 2)
  const before = await where(p, form, 2)
  /* Send locks the picks in at once (the 45 s lock-in posts the same reply) */
  await p.evaluate((form) => document.querySelector(`${form} [data-testid=poll-send]`).click(), form)
  await sleep(1500)
  const after = await where(p, form, 2)
  const n = await replies(p, seeded.msg_id)
  ok(`${tag} ${order} checkbox: Send posts the answer and question 3 stays where it was (<= ${TOLERANCE_PX} px)`, n === 1 && still(before, after), { n, before, after })
  ok(`${tag} ${order} checkbox: no page error`, errors.length === 0, errors)
  await p.close()
}

const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const DESKTOP = { width: 1440, height: 900 }
const server = await startServer()
const browser = await launch()
try {
  for (const order of ['newest-first', 'newest-last']) {
    await radioCase(browser, PHONE, '390px', order)
    await checkCase(browser, PHONE, '390px', order)
    await radioCase(browser, DESKTOP, '1440px', order)
    await radioCase(browser, PHONE, '390px', order, true)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
