// SPL-1994 (owner HUM-10, t1 72898ea2 msg def4a52d): "as soon as the system
// receives the prompt, a spinning hourglass must appear" - on the post and on
// its topic row, until the first agent post in that topic after it.
//
// Mock tenant, signed in as HUM-1, #alerts seeded with four topics (times
// relative to the page's clock):
//   A an agent asked, HUM-1 answered 20 s ago      -> row + post spin
//   B HUM-1 alone, no agent in the topic           -> calm wait, not spinning
//   C HUM-1 to an agent 20 min ago (cnf 10 min)    -> calm wait
//   D CONTROL: HUM-1, then an agent answered       -> nothing
//   1 row A spins (role=status, a label), B and C wait, D shows nothing
//   2 topic A open in the right pane: the post spins there too
//   3 reduced motion: the glyph stands still
//   4 an agent's answer arrives live -> gone on the row and on the post
//   5 CONTROL (red): before the answer step 4's check reads the hourglass
//     present, so a selector that matched nothing could not pass 4
// Phone, 390 px (owner addendum 3, t1 72898ea2 msg 7d608ee2: "the same
// animations on mobile too"), with a fake clock that fast-forwards a long timer:
//   6 HUM-1 sends a reply in topic A: once the hub has it, it spins
//   7 the 10 cnf minutes pass (fake clock): the still "waiting" mark
// SPL-2026 (owner msg 8285fce1: "right after i click send"), desktop, the
// mock's answer held (`spool.mock.hold-ack`):
//   8 HUM-1 sends `@CLE-07 ...`: the row is still pending (no ack) and the
//     hourglass already spins on it
//   9 the ack is released: the row is stored and keeps spinning
//
//   node tests/e2e/await-reply.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/await-reply.test.mjs
//   SHOTS=<dir> ... also writes a screenshot per step there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const A = 'a1a1a1a1-0000-4000-8000-00000000000a'
const B = 'b2b2b2b2-0000-4000-8000-00000000000b'
const C = 'c3c3c3c3-0000-4000-8000-00000000000c'
const D = 'd4d4d4d4-0000-4000-8000-00000000000d'
const A_POST = 'a1a1a1a1-0000-4000-8000-0000000000a2'
const A_ANSWER = 'a1a1a1a1-0000-4000-8000-0000000000a3'

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

/* runs in the page before it loads: the session and the seeded topics, timed off the page's clock */
function seed(ids) {
  const now = Date.now()
  const at = (agoMs) => new Date(now - agoMs).toISOString()
  const row = (id, task, ago, from, body, isParent, extra = {}) => ({ v: 1, msg_id: id, task_id: task, ts: at(ago), received_at: at(ago), from, from_box: from.startsWith('HUM') ? 'box-wui' : 'box-a', to: '@channel', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent: isParent, files: [], ...extra })
  const extra = [
    row(ids.A, ids.A, 120000, 'CLE-07', 'which box should I use?', 1),
    row(ids.A_POST, ids.A, 20000, 'HUM-1', 'use box-a please', 0),
    row(ids.B, ids.B, 30000, 'HUM-1', 'a note to myself', 1),
    row(ids.C, ids.C, 20 * 60000, 'HUM-1', 'are you there?', 1, { to: 'CLE-07' }),
    row(ids.D, ids.D, 300000, 'HUM-1', 'done yet?', 1),
    row(ids.D + '-r', ids.D, 240000, 'CLE-07', 'yes, done', 0),
  ]
  try {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
  } catch { /* about:blank */ }
}

/* the hourglass on the channel row of topic `task`, and on post `msgId` in the right pane */
const rowMark = (p, task) => p.evaluate((task) => {
  const el = document.querySelector(`.feed-body article.msg[data-msg-id="${task}"] [data-test=await-reply]`)
  return el ? { state: el.getAttribute('data-state'), role: el.getAttribute('role'), label: el.getAttribute('aria-label') || '', anim: el.getAttribute('data-anim') } : null
}, task)
const paneMark = (p, msgId) => p.evaluate((id) => {
  const el = document.querySelector(`.live-pane article.msg[data-msg-id="${id}"] [data-test=await-reply]`)
  return el ? { state: el.getAttribute('data-state'), label: el.getAttribute('aria-label') || '' } : null
}, msgId)
const spinName = (p) => p.evaluate(() => {
  const g = document.querySelector('[data-test=await-reply][data-state=spin] .await-reply__glyph')
  return g ? getComputedStyle(g).animationName : null
})
/* runs in the page before it loads: Date.now() carries an offset, and once
   window.__ff is set a timer of a minute or more fires at once, moving the
   clock by its delay (the page's own 10-minute spin -> wait timer) */
function fakeClock() {
  const realNow = Date.now.bind(Date)
  const realSet = window.setTimeout.bind(window)
  let offset = 0
  Date.now = () => realNow() + offset
  window.setTimeout = (fn, ms, ...rest) => (window.__ff && Number(ms) >= 60000
    ? realSet(() => { offset += Number(ms); fn(...rest) }, 300)
    : realSet(fn, ms, ...rest))
}

async function shot(p, name) {
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `await-reply-${name}.png`) })
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument(seed, { A, A_POST, B, C, D })
  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  await p.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"]`, { timeout: NAV })
  /* the label waits for the second catalogue (idle); give it the time it takes */
  await p.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})

  const a = await rowMark(p, A)
  ok('1 row A (an agent asked, HUM-1 answered 20 s ago) spins', a?.state === 'spin', a)
  ok('1 ... as a status with a label, the default hourglass', a?.role === 'status' && a.label.length > 0 && a.anim === 'hourglass', a)
  const b = await rowMark(p, B)
  ok('1 row B (no agent in the topic) waits calmly, not spinning', b?.state === 'wait', b)
  const c = await rowMark(p, C)
  ok('1 row C (20 min, past the 10 cnf minutes) waits calmly', c?.state === 'wait', c)
  const d = await rowMark(p, D)
  ok('1 CONTROL row D (an agent answered) shows nothing', d === null, d)
  const name = await spinName(p)
  ok('1 the spinning glyph is animated', typeof name === 'string' && name.startsWith('await-hourglass'), name)
  await shot(p, '1-row-spins')

  await p.click(`.feed-body article.msg[data-msg-id="${A}"] [data-test=topic-replies]`)
  await p.waitForSelector(`.live-pane article.msg[data-msg-id="${A_POST}"]`, { timeout: NAV })
  await sleep(400)
  const post = await paneMark(p, A_POST)
  ok('2 topic A open: the post itself spins in the right pane', post?.state === 'spin' && post.label.length > 0, post)
  const root = await paneMark(p, A)
  ok('2 ... and only the waiting post (the agent\'s opener has none)', root === null, root)
  await shot(p, '2-post-spins')

  await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  await sleep(200)
  const still = await spinName(p)
  ok('3 reduced motion: the hourglass stands still', still === 'none', still)
  await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }])

  const before = { row: await rowMark(p, A), post: await paneMark(p, A_POST) }
  ok('5 CONTROL (red): right before the answer both marks are there', Boolean(before.row && before.post), before)

  /* the agent's answer arrives live: the channel store's and the pane's socket paths */
  await p.evaluate((m) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const ts = new Date().toISOString()
    const msg = { v: 1, msg_id: m.id, task_id: m.task, ts, received_at: ts, from: 'CLE-07', from_box: 'box-a', to: '@channel', kind: 'note', body: 'box-a it is', channel: 'alerts', parent_task_id: null, is_parent: 0, files: [] }
    pinia._s.get('channel').ingestLive(msg)
    pinia._s.get('live-pane').admit([msg])
  }, { id: A_ANSWER, task: A })
  await sleep(500)
  const after = { row: await rowMark(p, A), post: await paneMark(p, A_POST) }
  ok('4 an agent answered: the hourglass is gone from the row and the post', after.row === null && after.post === null, after)
  const bAfter = await rowMark(p, B)
  ok('4 ... the other topics keep theirs (B still waits)', bAfter?.state === 'wait', bAfter)
  await shot(p, '4-gone')

  /* phone, 390 px: a just-sent post, then the wait (fake clock) */
  const ph = await ctx.newPage()
  ph.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await ph.evaluateOnNewDocument(fakeClock)
  await ph.setViewport({ width: 390, height: 844 })
  await ph.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await ph.waitForSelector('.spool-shell', { timeout: NAV })
  await applyViewport(ph, { name: '390', width: 390, height: 844 })
  await ph.waitForFunction(() => document.querySelector('#__nuxt')?.__vue_app__, { timeout: NAV })
  await ph.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"]`, { timeout: NAV })
  await ph.evaluate((a) => document.querySelector(`.feed-body article.msg[data-msg-id="${a}"] [data-test=topic-replies]`)?.click(), A)
  await ph.waitForSelector(`.live-pane article.msg[data-msg-id="${A_POST}"]`, { timeout: NAV })
  const TEXT = `phone ${Date.now().toString(36)}`
  await ph.evaluate(() => { window.__ff = true })
  await ph.focus('form.omnibox--global textarea')
  await ph.keyboard.type(TEXT)
  await ph.keyboard.press('Enter')
  const sent = () => ph.evaluate((t) => {
    const el = [...document.querySelectorAll('.live-pane article.msg[data-msg-id]')].find((e) => (e.querySelector('.msg-body')?.textContent || '').trim() === t)
    const mark = el && el.querySelector('[data-test=await-reply]')
    const g = mark && mark.querySelector('.await-reply__glyph')
    return el ? { width: innerWidth, pending: el.getAttribute('data-pending') === 'true', state: mark ? mark.getAttribute('data-state') : null, anim: g ? getComputedStyle(g).animationName : null } : null
  }, TEXT)
  let s6 = null
  for (let i = 0; i < 20 && !(s6 && s6.state); i++) { await sleep(150); s6 = await sent() }
  ok('6 phone 390 px: the just-sent post spins once the hub has it', s6?.width === 390 && !s6.pending && s6.state === 'spin' && String(s6.anim).startsWith('await-hourglass'), s6)
  await shot(ph, '6-phone-spins')
  let s7 = s6
  for (let i = 0; i < 20 && s7?.state === 'spin'; i++) { await sleep(200); s7 = await sent() }
  ok('7 phone: after the 10 minutes (fake clock) the still waiting mark', s7?.state === 'wait' && s7.anim === 'none', s7)
  await shot(ph, '7-phone-waits')

  /* desktop, the mock's answer held: the hourglass before the ack */
  const hctx = await browser.createBrowserContext()
  const hp = await hctx.newPage()
  hp.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await hp.evaluateOnNewDocument(seed, { A, A_POST, B, C, D })
  await hp.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.mock.hold-ack', '1') } catch { /* about:blank */ } })
  await hp.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  await hp.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await hp.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"]`, { timeout: NAV })
  /* the rule and the label load on demand; the seeded row A spinning says both are in */
  await hp.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})
  const HTEXT = `held ${Date.now().toString(36)}`
  await hp.focus('form.omnibox--global textarea')
  await hp.keyboard.type(`@CLE-07 ${HTEXT}`)
  await hp.keyboard.press('Enter')
  const own = () => hp.evaluate((t) => {
    const el = [...document.querySelectorAll('.feed-body article.msg[data-msg-id]')].find((e) => (e.querySelector('.msg-body')?.textContent || '').includes(t))
    const mark = el && el.querySelector('[data-test=await-reply]')
    return el ? { pending: el.getAttribute('data-pending') === 'true', sending: Boolean(el.querySelector('[data-test=msg-sending]')), state: mark ? mark.getAttribute('data-state') : null } : null
  }, HTEXT)
  let s8 = null
  for (let i = 0; i < 30 && !(s8 && s8.state); i++) { await sleep(100); s8 = await own() }
  ok('8 send clicked, ack held: the pending row already spins', Boolean(s8 && s8.pending && s8.sending && s8.state === 'spin'), s8)
  await shot(hp, '8-pending-spins')
  await hp.evaluate(() => localStorage.removeItem('spool.mock.hold-ack'))
  let s9 = s8
  for (let i = 0; i < 30 && (!s9 || s9.pending); i++) { await sleep(100); s9 = await own() }
  ok('9 ack released: the stored row keeps spinning', Boolean(s9 && !s9.pending && s9.state === 'spin'), s9)
  await hctx.close()

  ok('no page errors', errors.length === 0, errors)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nawait-reply: ${results.length - failed.length}/${results.length} ok`)
process.exit(code || (failed.length ? 1 : 0))
