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
// SPL-2027 (owner msgs c4aae6fc, 1689b768, f7779032): more animations, a
// per-person pick, 20% bigger:
//   R1 Settings -> Appearance lists hourglass, robot, brain; pick robot
//   R2 send a post in topic A: once the hub has it, the ROBOT runs on it
//   R3 the mark's box is still 16 px, the drawing 16.8 px (20% over 14), and
//      the post's header row is as tall as one with no mark (no shift)
//   R4 reduced motion: the robot stands still
//   R5 pick brain: the brain swells; a reload keeps the pick
//   R6 phone 390 px: the brain, same box, same size
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

/* the mark on post `id` in the right pane: its box, its drawing, the header row, every animation in it */
const markLook = (p, id) => p.evaluate((id) => {
  const el = id
    ? document.querySelector(`.live-pane article.msg[data-msg-id="${id}"] [data-test=await-reply]`)
    : document.querySelector('[data-test=await-reply][data-state=spin]')
  if (!el) return null
  const g = el.querySelector('.await-reply__glyph')
  const box = el.getBoundingClientRect()
  const gl = g.getBoundingClientRect()
  /* scoped keyframes carry a hash suffix (await-robot-4504b6f2): keep the base name */
  const names = [...new Set([g, ...g.querySelectorAll('*')].map((n) => getComputedStyle(n).animationName).filter((n) => n && n !== 'none').map((n) => n.replace(/-[0-9a-f]{8}$/, '')))]
  const r1 = (x) => Math.round(x * 10) / 10
  return { anim: el.getAttribute('data-anim'), state: el.getAttribute('data-state'), boxW: r1(box.width), boxH: r1(box.height), glyphW: r1(gl.width), rowH: r1(el.parentElement.getBoundingClientRect().height), names }
}, id)
/* the header row height of a post with no mark, for the no-shift check */
const plainRowH = (p) => p.evaluate(() => {
  const t = [...document.querySelectorAll('.live-pane article.msg .msg-time')].find((e) => !e.parentElement.querySelector('[data-test=await-reply]'))
  return t ? Math.round(t.parentElement.getBoundingClientRect().height * 10) / 10 : null
})

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
  /* SPL-2027: the person picks the robot in Settings, then sends */
  const r = await ctx.newPage()
  r.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await r.evaluateOnNewDocument(seed, { A, A_POST, B, C, D })
  await r.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  await r.goto(`${server.base}/channel/alerts?settings=appearance`, { waitUntil: 'networkidle2', timeout: NAV })
  await r.waitForSelector('[data-test=await-anim-setting] [data-test=await-anim-robot]', { timeout: NAV })
  const opts = await r.evaluate(() => [...document.querySelectorAll('[data-test=await-anim-setting] input[type=radio]')].map((i) => ({ v: i.value, on: i.checked })))
  ok('R1 Settings -> Appearance lists hourglass (picked), robot, brain', JSON.stringify(opts) === JSON.stringify([{ v: 'hourglass', on: true }, { v: 'robot', on: false }, { v: 'brain', on: false }]), opts)
  await r.click('[data-test=await-anim-robot]')
  await sleep(200)
  const stored = await r.evaluate(() => localStorage.getItem('spool-await-anim:t1:HUM-1'))
  ok('R1 ... robot picked, kept for HUM-1 in this browser', stored === 'robot', stored)
  await shot(r, 'R1-settings')
  await r.keyboard.press('Escape')
  await r.waitForFunction(() => !document.querySelector('[data-test=await-anim-setting]'), { timeout: 5000 }).catch(() => {})
  await r.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"] [data-test=topic-replies]`, { timeout: NAV })
  await r.click(`.feed-body article.msg[data-msg-id="${A}"] [data-test=topic-replies]`)
  await r.waitForSelector(`.live-pane article.msg[data-msg-id="${A_POST}"]`, { timeout: NAV })
  const SENT = `robot ${Date.now().toString(36)}`
  await r.focus('form.omnibox--global textarea')
  await r.keyboard.type(SENT)
  await r.keyboard.press('Enter')
  const sentId = async () => r.evaluate((t) => {
    const el = [...document.querySelectorAll('.live-pane article.msg[data-msg-id]')].find((e) => (e.querySelector('.msg-body')?.textContent || '').trim() === t)
    return el && el.querySelector('[data-test=await-reply]') ? el.getAttribute('data-msg-id') : null
  }, SENT)
  let rid = null
  for (let i = 0; i < 30 && !rid; i++) { await sleep(150); rid = await sentId() }
  const robot = rid ? await markLook(r, rid) : null
  ok('R2 the just-sent post shows the ROBOT, running', robot?.anim === 'robot' && robot.state === 'spin' && robot.names.includes('await-robot') && robot.names.includes('await-robot-limb'), robot)
  await shot(r, 'R2-robot')
  const plain = await plainRowH(r)
  ok('R3 box unchanged 16x16, drawing 16.8 px (20% over 14), header row as tall as a post with no mark', robot?.boxW === 16 && robot.boxH === 16 && robot.glyphW >= 16.5 && robot.glyphW <= 17.1 && plain !== null && Math.abs(robot.rowH - plain) < 0.5, { robot, plain })
  await r.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  await sleep(200)
  const robotStill = rid ? await markLook(r, rid) : null
  ok('R4 reduced motion: the robot stands still', robotStill?.anim === 'robot' && robotStill.names.length === 0, robotStill)
  await r.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }])

  await r.evaluate(() => localStorage.setItem('spool-await-anim:t1:HUM-1', 'brain'))
  await r.goto(`${server.base}/channel/alerts?settings=appearance`, { waitUntil: 'networkidle2', timeout: NAV })
  await r.waitForSelector('[data-test=await-anim-brain]', { timeout: NAV })
  const brainOn = await r.evaluate(() => document.querySelector('[data-test=await-anim-brain]').checked)
  ok('R5 a reload keeps the pick (brain checked)', brainOn === true, brainOn)
  await r.keyboard.press('Escape')
  await r.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})
  await r.click(`.feed-body article.msg[data-msg-id="${A}"] [data-test=topic-replies]`)
  await r.waitForSelector(`.live-pane article.msg[data-msg-id="${A_POST}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})
  const brain = await markLook(r, A_POST)
  ok('R5 the brain swells and pops on the waiting post', brain?.anim === 'brain' && brain.names.includes('await-brain') && brain.names.includes('await-brain-burst') && brain.boxW === 16, brain)
  await shot(r, 'R5-brain')
  await r.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  await sleep(200)
  const brainStill = await markLook(r, A_POST)
  ok('R4 reduced motion: the brain stands still', brainStill?.names.length === 0, brainStill)
  await r.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }])

  const rp = await ctx.newPage()
  rp.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await rp.evaluateOnNewDocument(seed, { A, A_POST, B, C, D })
  await rp.setViewport({ width: 390, height: 844 })
  await rp.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await rp.waitForSelector('.spool-shell', { timeout: NAV })
  await applyViewport(rp, { name: '390', width: 390, height: 844 })
  await rp.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})
  const phone = await markLook(rp, null)
  ok('R6 phone 390 px: the brain, 16 px box, 16.8 px drawing', phone?.anim === 'brain' && phone.boxW === 16 && phone.glyphW >= 16.5 && phone.names.includes('await-brain'), phone)
  await shot(rp, 'R6-phone-brain')

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
