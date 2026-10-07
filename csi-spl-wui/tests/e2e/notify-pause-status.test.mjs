// Spec 096 T005 (Q1, the pause box): a member who sets "Unavailable" with
// "pause my notifications" ticked gets no chime and no browser alert; "Busy"
// never silences, and Unavailable without the pause still rings.
//
// Mock tenant, signed in as HUM-1, AudioContext and Notification replaced by
// recorders (notify-offscreen-reply.test.mjs's), the tab in front and focused
// (asserted, else the run proves nothing). Each case lands a reply into a
// topic of the open channel whose thread is closed - a message that rings
// (notify-offscreen-reply case 1):
//   1 Unavailable + pause, seeded as the lde mock keeps it -> silent
//   2 Busy -> chime + alert
//   3 CONTROL: Unavailable, no pause -> chime + alert
//   4 Unavailable + pause again, set the way the picker applies it -> silent
//
//   node tests/e2e/notify-pause-status.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/notify-pause-status.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = '7b7b7b7b-7b7b-4b7b-8b7b-7b7b7b7b7b7b'
const MARK = '2026-09-18T09:00:00.000Z'
const row = (id, task, ts, from, body, isParent) => ({ v: 1, msg_id: id, task_id: task, ts, received_at: ts, from, from_box: 'box-a', to: '@channel', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent: isParent, files: [] })
const EXTRA = [
  row(TASK, TASK, '2026-09-18T08:00:00Z', 'HUM-1', 'my question', 1),
  row('7b7b7b7b-7b7b-4b7b-8b7b-7b7b7b7b7b01', TASK, '2026-09-18T08:10:00Z', 'CLE-07', 'an old answer', 0),
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

/** The mock session, the reader's own paused Unavailable, and the sound recorders. */
function recorders(extra, mark, until) {
  try {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
    localStorage.setItem('spool.read-cursors', JSON.stringify(mark))
    localStorage.setItem('spool.mock.human-status', JSON.stringify({ 'HUM-1': { state: 'unavailable', note: 'Off', until, pause_notify: true } }))
    localStorage.setItem('spool.chime', '1')
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
    window.__sounds.push({ kind: 'alert', title: String(title), body: String((opts && opts.body) || '') })
  }
  FakeNotification.permission = 'granted'
  FakeNotification.requestPermission = async () => 'granted'
  window.Notification = FakeNotification
}

/** A reply from someone else arriving live in #alerts (the channel store's live path). */
const arrive = (p, m) => p.evaluate((m) => {
  window.__sounds = []
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const ts = new Date().toISOString()
  const msg = { ...m, ts, received_at: ts }
  const extra = JSON.parse(localStorage.getItem('spool.mock.extra-messages') || '[]')
  localStorage.setItem('spool.mock.extra-messages', JSON.stringify([...extra, msg]))
  s.ingestLive(msg)
}, m)

/* past the 2 s ping throttle (notify.mjs pingThrottle), so each case can ring */
const sounds = async (p) => {
  await new Promise((r) => setTimeout(r, 2200))
  return p.evaluate(() => window.__sounds)
}

/** The reader's own status as the status store holds it. */
const own = (p) => p.evaluate(() => {
  const st = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('human-status')
  return st ? JSON.parse(JSON.stringify(st.statusByPeer['HUM-1'] || null)) : 'no store'
})

/** Set the reader's own status as the picker does: the mock hub's write
 *  (utils/human-status putMyStatus), then stores/human-status applyStatus. */
const setOwn = (p, body) => p.evaluate(async (body) => {
  const map = JSON.parse(localStorage.getItem('spool.mock.human-status') || '{}')
  map['HUM-1'] = { state: body.state, note: body.note || '', until: body.until || '', pause_notify: body.pause_notify === true }
  localStorage.setItem('spool.mock.human-status', JSON.stringify(map))
  const st = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('human-status')
  await st.applyStatus({ type: 'status', peer: 'HUM-1', ...body })
}, body)

let n = 2
const reply = (body) => row(`7b7b7b7b-7b7b-4b7b-8b7b-7b7b7b7b7b${String(n++).padStart(2, '0')}`, TASK, '', 'CLE-07', body, 0)
const rang = (s, body) => ({ osc: s.some((x) => x.kind === 'osc'), alert: s.some((x) => x.kind === 'alert' && x.body.includes(body)) })

const server = await startServer()
const browser = await launch()
let code = 0
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  const until = new Date(Date.now() + 2 * 3600e3).toISOString()
  await p.evaluateOnNewDocument(recorders, EXTRA, { 'ch:alerts': { ts: MARK, id: '' } }, until)
  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  await p.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector(`.feed-body article.msg[data-msg-id="${TASK}"]`, { timeout: NAV })
  await p.bringToFront()
  const f = await p.evaluate(() => ({ hidden: document.hidden, focus: document.hasFocus() }))
  ok('precondition: the tab is in front and focused', !f.hidden && f.focus, f)
  await p.waitForFunction(() => {
    const st = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('human-status')
    return Boolean(st && st.statusByPeer['HUM-1'] && st.statusByPeer['HUM-1'].state)
  }, { timeout: NAV, polling: 100 }).catch(() => {})
  const seeded = await own(p)
  ok('precondition: the store holds the reader\'s Unavailable with the pause', seeded && seeded.state === 'unavailable' && seeded.pauseNotify === true, seeded)

  let s
  await arrive(p, reply('while paused'))
  s = await sounds(p)
  ok('1 Unavailable + pause: no chime, no alert', s.length === 0, s)

  await setOwn(p, { state: 'busy', note: 'Meeting' })
  await arrive(p, reply('while busy'))
  s = await sounds(p)
  const busy = rang(s, 'while busy')
  ok('2 Busy: still a chime and an alert', busy.osc && busy.alert, { busy, own: await own(p) })

  await setOwn(p, { state: 'unavailable', note: 'Off', until })
  await arrive(p, reply('unavailable unpaused'))
  s = await sounds(p)
  const plain = rang(s, 'unavailable unpaused')
  ok('3 CONTROL: Unavailable without the pause: chime and alert', plain.osc && plain.alert, { plain, own: await own(p) })

  await setOwn(p, { state: 'unavailable', note: 'Off', until, pause_notify: true })
  await arrive(p, reply('paused again'))
  s = await sounds(p)
  ok('4 Unavailable + pause, set as the picker applies it: silent', s.length === 0, { s, own: await own(p) })

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
console.log(`\nnotify-pause-status: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
