// Bug A live proof (t1 5002067f, CLE-77848): "notifications for new messages
// are enabled, but no signal comes". Signs one member in with the chime and
// browser alerts ON (notifications granted to the origin), parks on a page
// that is NOT the target channel, then runs SEND_CMD - another identity (an
// agent desk) posting an ORDINARY message into CHANNEL: no mention, not a DM,
// not #alerts, the case that was silent. Requires, for that one post:
//   - an oscillator started (the chime),
//   - a browser alert whose body carries NEEDLE, tagged with the channel key,
//   - the tab title leading with the unread count "(n) ...".
// AudioContext and Notification are wrapped, not replaced: every call still
// reaches the real browser API, the wrapper only records it.
// CONTROL: before SEND_CMD runs, no alert carries NEEDLE (a page that alerts
// on anything would pass the positive half vacuously).
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     CHANNEL=<slug> NEEDLE=<text in the post> SEND_CMD='<command that posts it>' \
//     [TENANT=t1] [WAIT=60] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/notify-new-message-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { join } from 'node:path'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const CHANNEL = need('CHANNEL').replace(/^#/, '').toLowerCase()
const NEEDLE = need('NEEDLE')
const SEND_CMD = need('SEND_CMD')
const TENANT = process.env.TENANT || 't1'
const WAIT = Number(process.env.WAIT || 60)
// Read once, held in memory, never printed or screenshotted.
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* record every sound and alert, then hand the call to the real API */
function recorders() {
  try {
    localStorage.setItem('spool.chime', '1')
    localStorage.setItem('spool.alerts', '1')
  } catch { /* the step below reads it back */ }
  window.__signals = []
  const RealCtx = window.AudioContext
  if (RealCtx) {
    window.AudioContext = class extends RealCtx {
      createOscillator() {
        const o = super.createOscillator()
        const start = o.start.bind(o)
        o.start = (...a) => { window.__signals.push({ kind: 'osc', state: this.state }); return start(...a) }
        return o
      }
    }
  }
  const RealN = window.Notification
  if (RealN) {
    const Wrapped = function (title, opts) {
      window.__signals.push({ kind: 'alert', title: String(title), body: String((opts && opts.body) || ''), tag: (opts && opts.tag) || '', silent: Boolean(opts && opts.silent) })
      return new RealN(title, opts)
    }
    Object.defineProperty(Wrapped, 'permission', { get: () => RealN.permission })
    Wrapped.requestPermission = (...a) => RealN.requestPermission(...a)
    window.Notification = Wrapped
  }
}

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--autoplay-policy=no-user-gesture-required'],
})
try {
  const ctx = await browser.createBrowserContext()
  await ctx.overridePermissions(BASE, ['notifications'])
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.setDefaultNavigationTimeout(90000)
  await p.evaluateOnNewDocument(recorders)

  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2F`, { waitUntil: 'domcontentloaded' })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  await sleep(5000)

  /* a page that is not the channel's feed: the message lands elsewhere */
  await p.goto(`${BASE}/settings/notifications`, { waitUntil: 'domcontentloaded' })
  await p.waitForSelector('[data-test=settings-notifications]', { timeout: 60000 })
  await sleep(6000)
  const pre = await p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const n = pinia._s.get('notification')
    const total = Object.values(n.unread).reduce((a, v) => a + (Number(v) || 0), 0)
    return { permission: n.permission, chime: n.chime, alertsOn: n.alertsOn, title: document.title, total, build: document.querySelector('meta[name=version]')?.content || '' }
  })
  step('signed in, the chime and browser alerts ON, notifications granted', pre.permission === 'granted' && pre.chime === true && pre.alertsOn === true, pre)
  const before = await p.evaluate((needle) => window.__signals.filter((s) => s.kind === 'alert' && s.body.includes(needle)).length, NEEDLE)
  step('CONTROL: no alert carries the needle before the post', before === 0, { before })
  await p.evaluate(() => { window.__signals = [] })

  const sentAt = Date.now()
  let sendOut = ''
  try {
    sendOut = execSync(SEND_CMD, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 120000 })
  } catch (e) {
    sendOut = String(e.stdout || '') + String(e.stderr || '')
  }
  const sendLine = sendOut.split('\n').filter((l) => l.trim().startsWith('{')).pop() || sendOut.split('\n').slice(-3).join(' ')
  step('the other identity posted an ordinary message into the channel', /"ok"\s*:\s*true|"msg_id"|delivered|stored/i.test(sendLine), { send: sendLine.slice(0, 300) })

  const got = await p.waitForFunction((needle) => {
    const a = window.__signals.find((s) => s.kind === 'alert' && s.body.includes(needle))
    return a ? { alert: a, osc: window.__signals.filter((s) => s.kind === 'osc').length, title: document.title } : null
  }, { timeout: WAIT * 1000, polling: 250 }, NEEDLE).then((h) => h.jsonValue()).catch(() => null)
  const ms = Date.now() - sentAt
  await sleep(800)
  const after = await p.evaluate(() => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const n = pinia._s.get('notification')
    const total = Object.values(n.unread).reduce((a, v) => a + (Number(v) || 0), 0)
    return { title: document.title, total, signals: window.__signals }
  })
  step('a browser alert for the post, tagged with its channel', Boolean(got && got.alert.tag === `ch:${CHANNEL}` && got.alert.silent === false), { ms, alert: got && got.alert })
  step('the chime played (an oscillator started)', after.signals.some((s) => s.kind === 'osc'), { osc: after.signals.filter((s) => s.kind === 'osc').length })
  /* the title caps at (99+), so the count it shows is checked on the store */
  step('the tab title leads with the unread count, and the count went up', /^\(\d+\+?\) /.test(after.title) && after.total > pre.total, { title: after.title, before: pre.total, after: after.total })
  await p.screenshot({ path: join(OUT, 'notify-new-message-live.png') })
} catch (e) {
  step('the run completed', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  res.failed = failed
  writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
  console.log(failed ? `notify-new-message-live: ${failed} FAIL` : 'notify-new-message-live: all PASS')
  process.exit(failed ? 1 : 0)
}
