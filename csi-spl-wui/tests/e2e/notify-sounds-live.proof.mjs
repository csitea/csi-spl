// HUM-24 round 2 (311427c6, msg d4c4c791) live proof, signed in, read-only
// (nothing is posted; the note and the sound are per-browser switches in
// localStorage, reset at the end).
//
// 1. Every sound in the picker, played by the DEPLOYED bundle through the
//    store's ping, is 0.4-1.0 s of at least two notes, none a bare sine
//    (the page's AudioContext is a recorder; the motif is read from the
//    oscillators it makes).
// 2. The catch-up read after a reconnect pings once for a channel whose hub
//    count grew (a growing #lobby row fed to applyChannels with catchUp), and
//    the same rows without catchUp (a first load) ping nothing - the control.
//
// Run (prd: the e2e tenant host only - the apex is t1's host):
//   BASE=https://<tenant host> TENANT=t1 EMAIL=... PW_FILE=... OUT=<dir> \
//     node tests/e2e/notify-sounds-live.proof.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}

async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

function recorders() {
  window.__sounds = []
  const param = () => ({ value: 0, setValueAtTime() {}, exponentialRampToValueAtTime() {} })
  class FakeCtx {
    constructor() { this.currentTime = 0; this.destination = {}; this.state = 'running' }
    createOscillator() {
      const o = { type: 'sine', frequency: param(), connect() {}, start: (t) => { o.at = t }, stop: (t) => { o.end = t; window.__sounds.push({ kind: 'osc', type: o.type, at: o.at, end: t }) } }
      return o
    }
    createGain() { return { gain: param(), connect() {} } }
    close() { return Promise.resolve() }
  }
  window.AudioContext = FakeCtx
  function FakeNotification(title, opts) { window.__sounds.push({ kind: 'alert', title, body: opts && opts.body, silent: Boolean(opts && opts.silent) }) }
  FakeNotification.permission = 'granted'
  FakeNotification.requestPermission = async () => 'granted'
  window.Notification = FakeNotification
}

const browser = await (await loadPuppeteer()).launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  defaultViewport: null,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.evaluateOnNewDocument(recorders)
  await p.setViewport({ width: 1440, height: 900 })
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  res.build = await p.evaluate(() => fetch('/build.json', { cache: 'no-cache' }).then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build))

  await p.evaluate(() => { localStorage.setItem('spool.chime', '1'); localStorage.setItem('spool.alerts', '1') })
  await nav(p, BASE + '/lobby')
  await p.waitForSelector('[data-testid=notify-box-rail]', { timeout: 30000 })
  await sleep(1500)

  // ---- 1. every sound ----
  for (const name of ['plain', 'pop', 'chirp', 'marimba', 'boing']) {
    const notes = await p.evaluate((name) => {
      window.__sounds = []
      const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification')
      s.sound = name
      s.ping('New message', 'hello', `proof-${name}-${Date.now()}`)
      return new Promise((r) => setTimeout(() => r(window.__sounds.filter((x) => x.kind === 'osc')), 300))
    }, name)
    const t0 = Math.min(...notes.map((n) => n.at))
    const len = Math.max(...notes.map((n) => n.end)) - t0
    step(`${name}: ${notes.length} notes over ${len.toFixed(2)} s, waves ${[...new Set(notes.map((n) => n.type))].join('/')}`,
      notes.length >= 2 && len >= 0.4 && len <= 1.0 && notes.every((n) => n.type !== 'sine'), { len, notes })
    await sleep(2100)
  }

  // ---- 2. reconnect catch-up ----
  const catchUp = (flag) => p.evaluate((flag) => {
    window.__sounds = []
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification')
    const was = s.unread['ch:proof-catchup'] || 0
    s.applyChannels([{ channel_id: 'proof-catchup', unread: was + 2 }], '', { catchUp: flag })
    const out = window.__sounds.filter((x) => x.kind === 'alert')
    s.unread = { ...s.unread, 'ch:proof-catchup': 0 }
    return out
  }, flag)
  const control = await catchUp(false)
  step('control: a first-load read (no catchUp) pings nothing', control.length === 0, { control })
  await sleep(2100)
  const missed = await catchUp(true)
  step('catch-up read after a reconnect: one alert for the channel that grew, "+2"', missed.length === 1 && /proof-catchup/.test(missed[0].title) && missed[0].body === '+2', { missed })

  await p.evaluate(() => { localStorage.removeItem('spool.chime'); localStorage.removeItem('spool.alerts') })
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
console.log(`\nnotify-sounds-live: ${res.steps.length - failed}/${res.steps.length} passed`)
process.exit(failed ? 1 : 0)
