// HUM-24 (t1 cd9b0f47, a member, Chrome: "when a new message arrives I get no
// notification. I tested the sounds; they are on"). Reproduced on dev
// (WUI 8da7b2ba3, two sessions, n=1 per case): a hidden tab rang, and so did a
// tab on another page; a tab with the message's channel open and in front
// stayed silent, because the open feed signalled only while the reader was
// away - as if every message in it were on screen. A REPLY is not on screen:
// the middle pane shows one card per topic and a reply only moves its count.
// The member's own case: they post a topic in #lobby, stay there, and the
// answer arrives as a reply in that topic.
//
// Mock tenant, AudioContext and Notification replaced by recorders, the tab in
// front and focused (asserted, else the run proves nothing):
//   1 a reply into a topic of the open channel, thread closed -> chime + alert,
//     tagged with the channel, its target the reply (/m/<msg_id>)
//   2 CONTROL: a new topic in the open channel (its own card) -> silent
//   3 CONTROL: a reply with that topic open in the right pane -> silent
//   4 the alert's click target opens the reply, marked (open-focus), in its thread
// And the second cause, measured on dev the same day: the prerendered '/'
// carried the store's server values in its payload (chime off), which replaced
// the browser's stored switch and were then SAVED - one visit to the home page
// switched the member's sound off for good:
//   0 the chime saved ON survives a load of '/' and then of the channel
//
//   node tests/e2e/notify-offscreen-reply.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/notify-offscreen-reply.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const MARK = '2026-09-18T09:00:00.000Z'
const row = (id, task, ts, from, body, isParent) => ({ v: 1, msg_id: id, task_id: task, ts, received_at: ts, from, from_box: 'box-a', to: '@channel', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent: isParent, files: [] })
const EXTRA = [
  row(TASK, TASK, '2026-09-18T08:00:00Z', 'HUM-1', 'my question', 1),
  row('7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a01', TASK, '2026-09-18T08:10:00Z', 'CLE-07', 'an old answer', 0),
]

const results = []
const ok = (name, pass, ev) => {
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

/** Record every sound and alert the page makes (chime-mute.test.mjs's fakes, plus the alert's copy). */
function recorders(extra, mark) {
  try {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
    localStorage.setItem('spool.read-cursors', JSON.stringify(mark))
    /* once: the member switched the sound on; a later load must not undo it */
    if (localStorage.getItem('spool.chime') == null) localStorage.setItem('spool.chime', '1')
    localStorage.setItem('spool.alerts', '1')
  } catch { /* about:blank */ }
  window.__sounds = []
  const param = () => ({ value: 0, setValueAtTime() {}, exponentialRampToValueAtTime() {}, linearRampToValueAtTime() {} })
  class FakeCtx {
    constructor() { this.currentTime = 0; this.destination = {}; this.state = 'running' }
    createOscillator() {
      return { type: 'sine', frequency: param(), connect() {}, onended: null, start: () => window.__sounds.push({ kind: 'osc' }), stop() {} }
    }
    createGain() { return { gain: param(), connect() {} } }
    close() { return Promise.resolve() }
  }
  window.AudioContext = FakeCtx
  function FakeNotification(title, opts) {
    window.__sounds.push({ kind: 'alert', title: String(title), body: String((opts && opts.body) || ''), tag: (opts && opts.tag) || '', data: (opts && opts.data) || null })
  }
  FakeNotification.permission = 'granted'
  FakeNotification.requestPermission = async () => 'granted'
  window.Notification = FakeNotification
}

/** A message from someone else arriving live in #alerts (the channel store's live path). */
const arrive = (p, m) => p.evaluate((m) => {
  window.__sounds = []
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const ts = new Date().toISOString()
  const msg = { ...m, ts, received_at: ts }
  const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
  localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, msg]))
  s.ingestLive(msg)
}, m)

const sounds = async (p) => {
  await new Promise((r) => setTimeout(r, 1200))
  return p.evaluate(() => window.__sounds)
}

const focused = (p) => p.evaluate(() => ({ hidden: document.hidden, focus: document.hasFocus() }))

const server = await startServer()
const browser = await launch()
let code = 0
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument(recorders, EXTRA, { 'ch:alerts': { ts: MARK, id: '' } })
  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  const chimeNow = () => p.evaluate(() => ({
    path: location.pathname,
    chime: document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification').chime,
    saved: localStorage.getItem('spool.chime'),
  }))
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  const home = await chimeNow()
  ok('0 the chime saved ON is still on after loading / (the prerendered page)', home.chime === true && home.saved === '1', home)
  await p.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  const card = `.feed-body article.msg[data-msg-id="${TASK}"]`
  await p.waitForSelector(card, { timeout: NAV })
  await p.bringToFront()
  const f = await focused(p)
  ok('precondition: the tab is in front and focused (else nothing below is measured)', !f.hidden && f.focus, f)
  const pre = await p.evaluate(() => {
    const n = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification')
    return { chime: n.chime, alertsOn: n.alertsOn }
  })
  ok('0 ... and still on in the channel, so the alerts below can ring', pre.chime === true && pre.alertsOn === true, pre)

  /* 1: the member's case - an answer lands in their topic, thread closed */
  const REPLY = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a02'
  await arrive(p, row(REPLY, TASK, '', 'CLE-07', 'the new answer', 0))
  let s = await sounds(p)
  const alert = s.find((x) => x.kind === 'alert' && x.body.includes('the new answer'))
  ok('1 a reply into a topic whose thread is closed raises an alert, tagged with the channel', Boolean(alert && alert.tag === 'ch:alerts'), { alert })
  ok('1 ... and plays the chime', s.some((x) => x.kind === 'osc'), { osc: s.filter((x) => x.kind === 'osc').length })
  ok('1 ... and its click target is that reply', Boolean(alert && alert.data && alert.data.url && alert.data.url.endsWith(`/m/${REPLY}`)), { data: alert && alert.data })

  /* 2: a new topic is its own card in the middle, on screen */
  const NEW = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a03'
  await arrive(p, row(NEW, NEW, '', 'CLE-07', 'a new topic in view', 1))
  s = await sounds(p)
  ok('2 CONTROL: a new topic in the open channel, tab in front: silent', s.length === 0, s)

  /* 3: the topic open in the right pane, its replies are on screen */
  await p.click(`${card} [data-test=topic-replies]`)
  await p.waitForSelector(`[data-test=topic-root] article.msg[data-msg-id="${TASK}"]`, { timeout: NAV })
  await p.bringToFront()
  await arrive(p, row('7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a04', TASK, '', 'CLE-07', 'an answer in view', 0))
  s = await sounds(p)
  const pane = await p.evaluate(() => {
    const st = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s
    return { thread: st.get('topic')?.open ? st.get('topic').parentTaskId : null, pane: st.get('live-pane')?.taskId || null }
  })
  ok('3 CONTROL: a reply with its thread open in the right pane: silent', s.length === 0, { s, pane })
  await p.click('[data-test=live-topic-close]').catch(() => {})

  /* 4: tapping the alert opens that reply, marked, in its thread */
  await p.evaluate((data) => {
    document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification').openTarget(data)
  }, alert ? alert.data : { url: `/m/${REPLY}` })
  const marked = await p.waitForFunction((sel) => [...document.querySelectorAll(sel)].some((el) => el.getBoundingClientRect().height > 0),
    { timeout: 15000, polling: 50 }, `.msg[data-msg-id="${REPLY}"].open-focus`).then(() => true).catch(() => false)
  ok('4 the alert\'s target opens the reply, marked open-focus', marked, { url: p.url() })
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/notify-offscreen-reply.png` })
  ok('no page error', errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
  await ctx.close()
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nnotify-offscreen-reply: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
