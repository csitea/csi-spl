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
// SPL-2043 (owner msgs c48092cf, 19feedf8): the drawings take turns, ~3 s
// each, and draw another 20% bigger (20.16 px in the 16 px box):
//   T1 default pick = rotate: a waiting post shows the hourglass, then the
//      robot ~3 s later, then the brain, then the hourglass again
//   T2 every rotating mark on screen (row + post) shows the same drawing
//   T3 reduced motion: no cycling, the still hourglass for longer than a step
// SPL-2113 (owner HUM-10, t1 3aa9fac2 msgs d45ec26e, c33a028e): 17
// drawings in a vertical checkbox list, the ticked ones take turns, kept in
// the account (PUT /preferences await_anims, answered here as the hub would):
//   S1 Settings -> Appearance: 17 checkboxes, the dancing robot among them,
//      the default three ticked; every row's sample runs
//   S2 tick dancing-robot + rocket, untick the three: the account gets
//      exactly those two; one left ticked cannot be unticked
//   S3 desktop: on the waiting post and its row ONLY those two alternate,
//      ~3 s each, and each one's drawing runs
//   S4 the box is still 16 px, the drawing 20.16 px, no row shift
//   S5 reduced motion: the still hourglass for longer than a step
//   S6 a refused save puts the tick back and says so
//   P1 a fresh phone (390 px) whose account holds the two: the list shows
//      them ticked, only those two alternate; reduced motion = still hourglass
//   M1 an old browser pick (robot) and no pick in the account: it is saved
//      to the account once, the old key removed
//   T4 a single pick (robot) stays fixed over more than a step
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
    const claims = { hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }
    if (ids.anims) claims.await_anims = ids.anims
    localStorage.setItem('spool.mock.session', JSON.stringify(claims))
    localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
    if (ids.legacy && !sessionStorage.getItem('legacy-seeded')) {
      localStorage.setItem('spool-await-anim:t1:HUM-1', ids.legacy)
      sessionStorage.setItem('legacy-seeded', '1')
    }
  } catch { /* about:blank */ }
}

/* the hourglass on the channel row of topic `task`, and on post `msgId` in the right pane */
const rowMark = (p, task) => p.evaluate((task) => {
  const el = document.querySelector(`.feed-body article.msg[data-msg-id="${task}"] [data-test=await-reply]`)
  return el ? { state: el.getAttribute('data-state'), role: el.getAttribute('role'), label: el.getAttribute('aria-label') || '', anim: el.getAttribute('data-anim'), pick: el.getAttribute('data-pick') } : null
}, task)
const paneMark = (p, msgId) => p.evaluate((id) => {
  const el = document.querySelector(`.live-pane article.msg[data-msg-id="${id}"] [data-test=await-reply]`)
  return el ? { state: el.getAttribute('data-state'), label: el.getAttribute('aria-label') || '' } : null
}, msgId)
/* the running animations of the first spinning drawing and its parts; [] = still */
const spinName = (p) => p.evaluate(() => {
  const g = document.querySelector('[data-test=await-reply][data-state=spin] .await-reply__glyph')
  return g ? [g, ...g.querySelectorAll('*')].map((n) => getComputedStyle(n).animationName).filter((n) => n && n !== 'none') : null
})
const ROTATION = ['hourglass', 'robot', 'brain']
/* SPL-2043: the drawing of every spinning mark, sampled every `every` ms for `ms` */
const sampleAnims = async (p, ms, every = 200) => {
  const out = []
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    out.push({ t: Date.now() - t0, anims: await p.evaluate(() => [...document.querySelectorAll('[data-test=await-reply][data-state=spin]')].map((e) => e.getAttribute('data-anim'))) })
    await sleep(every)
  }
  return out
}
/* runs of one drawing: [{ anim, from, to }] off the first mark's samples */
const runsOf = (samples) => {
  const runs = []
  for (const s of samples) {
    const a = s.anims[0] || null
    if (runs.length && runs[runs.length - 1].anim === a) runs[runs.length - 1].to = s.t
    else runs.push({ anim: a, from: s.t, to: s.t })
  }
  return runs
}
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
  ok('1 ... as a status with a label, the default three in turn (one of its drawings)', a?.role === 'status' && a.label.length > 0 && a.pick === 'hourglass robot brain' && ROTATION.includes(a.anim), a)
  const b = await rowMark(p, B)
  ok('1 row B (no agent in the topic) waits calmly, not spinning', b?.state === 'wait', b)
  const c = await rowMark(p, C)
  ok('1 row C (20 min, past the 10 cnf minutes) waits calmly', c?.state === 'wait', c)
  const d = await rowMark(p, D)
  ok('1 CONTROL row D (an agent answered) shows nothing', d === null, d)
  const name = await spinName(p)
  ok('1 the spinning glyph is animated', Array.isArray(name) && name.some((n) => /^await-(hourglass|robot|brain)/.test(n)), name)
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
  const stillMark = await paneMark(p, A_POST)
  ok('3 reduced motion: the hourglass stands still', Array.isArray(still) && still.length === 0, { still, stillMark })
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
    const names = g ? [g, ...g.querySelectorAll('*')].map((n) => getComputedStyle(n).animationName).filter((n) => n && n !== 'none') : null
    return el ? { width: innerWidth, pending: el.getAttribute('data-pending') === 'true', state: mark ? mark.getAttribute('data-state') : null, drawing: mark ? mark.getAttribute('data-anim') : null, anim: names } : null
  }, TEXT)
  let s6 = null
  for (let i = 0; i < 20 && !(s6 && s6.state); i++) { await sleep(150); s6 = await sent() }
  ok('6 phone 390 px: the just-sent post spins once the hub has it', s6?.width === 390 && !s6.pending && s6.state === 'spin' && s6.anim?.some((n) => /^await-(hourglass|robot|brain)/.test(n)), s6)
  await shot(ph, '6-phone-spins')
  let s7 = s6
  for (let i = 0; i < 20 && s7?.state === 'spin'; i++) { await sleep(200); s7 = await sent() }
  ok('7 phone: after the 10 minutes (fake clock) the still waiting mark, the hourglass', s7?.state === 'wait' && s7.anim?.length === 0 && s7.drawing === 'hourglass', s7)
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
  /* SPL-2043: the default rotate takes the drawings in turn, ~3 s each */
  const t = await ctx.newPage()
  t.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await t.evaluateOnNewDocument(seed, { A, A_POST, B, C, D })
  await t.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  await t.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await t.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})
  await t.click(`.feed-body article.msg[data-msg-id="${A}"] [data-test=topic-replies]`)
  await t.waitForSelector(`.live-pane article.msg[data-msg-id="${A_POST}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})
  /* start right after a step so the first run is a whole one; the step is
     the page's wall clock (every mark in step, T2), so the cycle may begin on
     any drawing: expect it from the page clock, never always the hourglass */
  const step = await t.evaluate(() => new Promise((resolve) => {
    const poll = () => (Date.now() % 3000 < 300 ? resolve(Math.floor(Date.now() / 3000)) : setTimeout(poll, 50))
    poll()
  }))
  const first = ROTATION[step % 3]
  const samples = await sampleAnims(t, 10000)
  const runs = runsOf(samples)
  const order = runs.map((r) => r.anim)
  const want = [0, 1, 2, 3].map((k) => ROTATION[(ROTATION.indexOf(first) + k) % 3]).join('>')
  ok('T1 rotate: hourglass, then robot ~3 s later, then brain, then the hourglass again (from the wall-clock step)', order.slice(0, 4).join('>') === want, { want, runs })
  const inner = runs.slice(1, -1)
  ok('T1 ... each drawing shows ~3 s', inner.length > 0 && inner.every((r) => r.to - r.from >= 2400 && r.to - r.from <= 3200), inner)
  await shot(t, 'T1-rotate')
  const marks = samples.map((x) => x.anims)
  ok('T2 every rotating mark on screen (row + post) shows the same drawing', marks.every((m) => m.length >= 2 && m.every((a) => a === m[0])), marks.slice(0, 3))
  await t.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  await sleep(200)
  const reducedRuns = runsOf(await sampleAnims(t, 4000))
  const reducedNames = await spinName(t)
  ok('T3 reduced motion: no cycling, the still hourglass for longer than a step', reducedRuns.length === 1 && reducedRuns[0].anim === 'hourglass' && reducedNames?.length === 0, { reducedRuns, reducedNames })
  await t.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }])
  await t.close()

  /* SPL-2113: the checkbox list, kept in the account */
  const TWO = ['dancing-robot', 'rocket']
  const ALL = ['hourglass', 'robot', 'brain', 'dancing-robot', 'dots', 'spinner', 'radar', 'gears', 'bulb', 'coffee', 'orbit', 'pendulum', 'bars', 'pencil', 'rocket', 'clock', 'wave']
  /* a page whose PUT /preferences is answered as the hub would (or refused, `fail.on`); bodies kept in `saved` */
  const openPage = async (c, vp, extra = {}) => {
    const pg = await c.newPage()
    const saved = []
    const fail = { on: false }
    pg.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    await pg.setRequestInterception(true)
    pg.on('request', (q) => {
      if (q.isInterceptResolutionHandled()) return
      if (q.method() === 'PUT' && /\/preferences$/.test(new URL(q.url()).pathname)) {
        saved.push(q.postData() || '')
        return fail.on
          ? q.respond({ status: 500, contentType: 'application/json', body: '{"error":"internal","detail":"settings not stored"}' })
          : q.respond({ status: 200, contentType: 'application/json', body: q.postData() || '{}' })
      }
      return q.continue()
    })
    await pg.evaluateOnNewDocument(seed, { A, A_POST, B, C, D, ...extra })
    await pg.setViewport({ width: vp, height: vp < 500 ? 844 : 900, isMobile: false, hasTouch: false })
    return { pg, saved, fail }
  }
  const boxes = (pg) => pg.evaluate(() => [...document.querySelectorAll('[data-test=await-anim-setting] input[type=checkbox]')].map((i) => ({ v: i.value, on: i.checked, off: i.disabled })))
  const ticked = (list) => list.filter((x) => x.on).map((x) => x.v)
  /* click one box once the last save is done (the boxes are disabled while saving) */
  const tick = async (pg, id) => {
    await pg.waitForFunction((id) => { const i = document.querySelector(`[data-test=await-anim-${id}]`); return i && !i.disabled }, { timeout: 5000 }, id).catch(() => {})
    await pg.click(`[data-test=await-anim-${id}]`)
    await sleep(150)
  }
  const lastSaved = (saved) => { try { return JSON.parse(saved[saved.length - 1] || 'null') } catch { return null } }
  /* only `want` show, both of them, one after the other, each ~3 s */
  const alternates = (runs, want) => {
    const seen = new Set(runs.map((r) => r.anim))
    const inner = runs.slice(1, -1)
    return [...seen].every((x) => want.includes(x)) && want.every((x) => seen.has(x))
      && runs.every((r, k) => k === 0 || r.anim !== runs[k - 1].anim)
      && inner.length > 0 && inner.every((r) => r.to - r.from >= 2400 && r.to - r.from <= 3200)
  }
  const openTopicA = async (pg) => {
    await pg.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"] [data-test=topic-replies]`, { timeout: NAV })
    await pg.evaluate((a) => document.querySelector(`.feed-body article.msg[data-msg-id="${a}"] [data-test=topic-replies]`)?.click(), A)
    await pg.waitForSelector(`.live-pane article.msg[data-msg-id="${A_POST}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})
  }

  const { pg: r, saved, fail } = await openPage(ctx, 1440)
  await r.goto(`${server.base}/channel/alerts?settings=appearance`, { waitUntil: 'networkidle2', timeout: NAV })
  await r.waitForSelector('[data-test=await-anim-setting] [data-test=await-anim-dancing-robot]', { timeout: NAV })
  const list0 = await boxes(r)
  ok('S1 Settings -> Appearance: 17 checkboxes, one under the other, the dancing robot among them', JSON.stringify(list0.map((x) => x.v)) === JSON.stringify(ALL), list0.map((x) => x.v))
  ok('S1 ... the default three ticked', JSON.stringify(ticked(list0)) === JSON.stringify(['hourglass', 'robot', 'brain']), ticked(list0))
  const vertical = await r.evaluate(() => {
    const xs = [...document.querySelectorAll('[data-test=await-anim-setting] li')].map((li) => li.getBoundingClientRect())
    return xs.length > 1 && xs.every((b, k) => k === 0 || (Math.abs(b.left - xs[0].left) < 1 && b.top >= xs[k - 1].bottom - 1))
  })
  ok('S1 ... a vertical list', vertical === true, vertical)
  await r.waitForFunction(() => document.querySelectorAll('[data-test=await-anim-setting] [data-test=await-reply-preview] .await-reply__glyph').length === 17, { timeout: 20000 }).catch(() => {})
  const samples0 = await r.evaluate(() => [...document.querySelectorAll('[data-test=await-anim-setting] [data-test=await-reply-preview]')].map((el) => {
    const g = el.querySelector('.await-reply__glyph')
    const names = g ? [g, ...g.querySelectorAll('*')].map((n) => getComputedStyle(n).animationName).filter((n) => n && n !== 'none').map((n) => n.replace(/-[0-9a-f]{8}$/, '')) : []
    return { anim: el.getAttribute('data-anim'), runs: names.some((n) => n.startsWith(`await-${el.getAttribute('data-anim')}`)) }
  }))
  ok('S1 ... every row shows its own running sample (17 drawings, each animated)', samples0.length === 17 && samples0.every((x, k) => x.anim === ALL[k] && x.runs), samples0.filter((x) => !x.runs))
  await shot(r, 'S1-settings')

  for (const id of TWO) await tick(r, id)
  for (const id of ['hourglass', 'robot', 'brain']) await tick(r, id)
  await sleep(300)
  const list2 = await boxes(r)
  ok('S2 tick dancing-robot + rocket, untick the three: those two ticked', JSON.stringify(ticked(list2)) === JSON.stringify(TWO), ticked(list2))
  ok('S2 ... the account gets exactly those two (PUT /preferences await_anims)', JSON.stringify(lastSaved(saved)) === JSON.stringify({ await_anims: TWO }), saved.slice(-2))
  await tick(r, 'rocket')
  const list1 = await boxes(r)
  const lone = list1.find((x) => x.v === 'dancing-robot')
  ok('S2 one left ticked: its box cannot be unticked (at least one stays)', JSON.stringify(ticked(list1)) === '["dancing-robot"]' && lone?.off === true, list1.filter((x) => x.on || x.off))
  await tick(r, 'rocket')
  ok('S2 ... ticked again: both kept', JSON.stringify(lastSaved(saved)) === JSON.stringify({ await_anims: TWO }), lastSaved(saved))
  await shot(r, 'S2-two-ticked')

  fail.on = true
  await tick(r, 'wave')
  await r.waitForSelector('[data-test=await-anim-status]', { timeout: 5000 }).catch(() => {})
  const refused = { boxes: ticked(await boxes(r)), status: await r.$eval('[data-test=await-anim-status]', (e) => e.textContent.trim()).catch(() => '') }
  ok('S6 a refused save puts the tick back and says so', JSON.stringify(refused.boxes) === JSON.stringify(TWO) && refused.status.length > 0, refused)
  fail.on = false

  await r.keyboard.press('Escape')
  await r.waitForFunction(() => !document.querySelector('[data-test=await-anim-setting]'), { timeout: 5000 }).catch(() => {})
  await openTopicA(r)
  const deskRuns = runsOf(await sampleAnims(r, 7500))
  ok('S3 desktop: only the two ticked ones alternate on the waiting post and its row, ~3 s each', alternates(deskRuns, TWO), deskRuns)
  const deskNames = await r.evaluate(() => [...document.querySelectorAll('[data-test=await-reply][data-state=spin]')].map((el) => {
    const g = el.querySelector('.await-reply__glyph')
    return { anim: el.getAttribute('data-anim'), names: g ? [g, ...g.querySelectorAll('*')].map((n) => getComputedStyle(n).animationName).filter((n) => n && n !== 'none').map((n) => n.replace(/-[0-9a-f]{8}$/, '')) : [] }
  }))
  ok('S3 ... the drawing on screen runs (its own keyframes)', deskNames.length >= 2 && deskNames.every((m) => TWO.includes(m.anim) && m.names.some((n) => n.startsWith(`await-${m.anim}`))), deskNames)
  await shot(r, 'S3-two-alternate')
  const look2 = await markLook(r, A_POST)
  const plain = await plainRowH(r)
  ok('S4 box unchanged 16x16, drawing 20.16 px, header row as tall as a post with no mark', look2?.boxW === 16 && look2.boxH === 16 && look2.glyphW >= 19.9 && look2.glyphW <= 20.4 && plain !== null && Math.abs(look2.rowH - plain) < 0.5, { look2, plain })
  await r.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  await sleep(200)
  const stillRuns = runsOf(await sampleAnims(r, 4000))
  const stillNames = await spinName(r)
  ok('S5 reduced motion: the still hourglass for longer than a step', stillRuns.length === 1 && stillRuns[0].anim === 'hourglass' && stillNames?.length === 0, { stillRuns, stillNames })
  await r.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }])
  await r.close()

  /* a fresh phone: the account (the session answer) already holds the two */
  const pctx = await browser.createBrowserContext()
  const { pg: ph2 } = await openPage(pctx, 390, { anims: TWO })
  await ph2.goto(`${server.base}/channel/alerts?settings=appearance`, { waitUntil: 'networkidle2', timeout: NAV })
  await ph2.waitForSelector('.spool-shell', { timeout: NAV })
  await applyViewport(ph2, { name: '390', width: 390, height: 844 })
  await ph2.waitForSelector('[data-test=await-anim-setting] [data-test=await-anim-rocket]', { timeout: NAV })
  const phoneList = await boxes(ph2)
  const fits = await ph2.evaluate(() => document.documentElement.scrollWidth <= innerWidth)
  ok('P1 phone 390 px, a fresh device: the list shows the account\'s two ticked, no sideways scroll', JSON.stringify(ticked(phoneList)) === JSON.stringify(TWO) && fits === true, { ticked: ticked(phoneList), fits })
  await shot(ph2, 'P1-phone-settings')
  await ph2.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await applyViewport(ph2, { name: '390', width: 390, height: 844 })
  await ph2.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})
  const phoneRuns = runsOf(await sampleAnims(ph2, 7500))
  const phoneLook = await markLook(ph2, null)
  ok('P1 phone: only the two ticked ones alternate, 16 px box, 20.16 px drawing', alternates(phoneRuns, TWO) && phoneLook?.boxW === 16 && phoneLook.glyphW >= 19.9, { phoneRuns, phoneLook })
  await shot(ph2, 'P1-phone-row')
  await ph2.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  await sleep(200)
  const phoneStill = runsOf(await sampleAnims(ph2, 4000))
  ok('P1 phone, reduced motion: the still hourglass', phoneStill.length === 1 && phoneStill[0].anim === 'hourglass' && (await spinName(ph2))?.length === 0, phoneStill)
  await pctx.close()

  /* an old browser pick (SPL-2027: robot) and nothing in the account */
  const mctx = await browser.createBrowserContext()
  const { pg: m, saved: mSaved } = await openPage(mctx, 1440, { legacy: 'robot' })
  await m.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await m.waitForSelector(`.feed-body article.msg[data-msg-id="${A}"] [data-test=await-reply]`, { timeout: 20000 }).catch(() => {})
  await sleep(500)
  const moved = { saved: mSaved.map((x) => JSON.parse(x)), key: await m.evaluate(() => localStorage.getItem('spool-await-anim:t1:HUM-1')) }
  ok('M1 an old browser pick moves to the account once, the old key removed', JSON.stringify(moved.saved) === JSON.stringify([{ await_anims: ['robot'] }]) && moved.key === null, moved)
  const fixed = runsOf(await sampleAnims(m, 4000))
  ok('T4 a single pick (robot) stays fixed over more than a step', fixed.length === 1 && fixed[0].anim === 'robot', fixed)
  await m.reload({ waitUntil: 'networkidle2', timeout: NAV })
  await sleep(1500)
  ok('M1 ... once: a reload sends nothing more', mSaved.length === 1, mSaved)
  await mctx.close()

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
