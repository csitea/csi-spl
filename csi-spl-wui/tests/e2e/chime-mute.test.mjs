// SPL-998: the note (chime) button is the ONE sound switch.
//
// Owner, 2026-09-27: "the beeps cannot be suppressed when I click on the note
// icon". The in-page oscillator already read the switch; the browser
// Notification did not, and a Notification plays the operating system's own
// alert sound unless it is `silent`. So with the bell on and the note off
// every alert still beeped.
//
// The page's AudioContext and Notification are replaced by recorders before
// any WUI code runs, so "a sound" is measured, not guessed:
//   - note ON  -> a ping starts an oscillator and raises a NON-silent alert
//   - note OFF -> no oscillator, and the alert is silent
//   - OFF draws the note with the bell-off slash, same stroke width and
//     colour as the bell when it is off
//   - a reload keeps it off; a second tab follows the switch without reload
// At 360 and 820 px (touch) the switch lives in the avatar sheet; at 1440 in
// the sidebar footer.
//
// Run:
//   node tests/e2e/chime-mute.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/chime-mute.test.mjs
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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Record every sound the page could make: oscillators and alerts.
 *  SPL-1221: the fake AudioContext models AudioParam (value + setValueAtTime +
 *  exponential/linearRampToValueAtTime) and ctx.close, so notify.mjs playSound()
 *  motifs (051: the chosen sound is a scheduled envelope, default `chirp`) run
 *  to osc.start() instead of throwing on the first ramp. It still records one
 *  { kind: 'osc' } per oscillator started, so "note ON plays" is unchanged. */
function recorders() {
  window.__sounds = []
  const param = (v = 0) => ({
    value: v,
    setValueAtTime() {},
    exponentialRampToValueAtTime() {},
    linearRampToValueAtTime() {},
  })
  class FakeCtx {
    constructor() { this.currentTime = 0; this.destination = {} }
    createOscillator() {
      return {
        type: 'sine', frequency: param(), connect() {}, onended: null,
        start: () => window.__sounds.push({ kind: 'osc' }), stop() {},
      }
    }
    createGain() { return { gain: param(), connect() {} } }
    close() { return Promise.resolve() }
  }
  window.AudioContext = FakeCtx
  function FakeNotification(title, opts) { window.__sounds.push({ kind: 'alert', silent: Boolean(opts && opts.silent) }) }
  FakeNotification.permission = 'granted'
  FakeNotification.requestPermission = async () => 'granted'
  window.Notification = FakeNotification
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

/** One simulated escalated message; returns the sounds it made. */
const ping = (p) => p.evaluate(() => {
  window.__sounds = []
  const notes = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification')
  notes.ping('New message', 'hello')
  return window.__sounds
})

/** The switch's state as drawn: pressed, glyph, its last path, ink. */
const drawn = (p, scope) => p.evaluate((scope) => {
  const one = (sel) => {
    const b = document.querySelector(`${scope} [data-testid=${sel}]`)
    if (!b) return null
    const svg = b.querySelector('svg')
    const last = [...svg.querySelectorAll('path')].at(-1)
    const cs = getComputedStyle(b)
    const r = b.getBoundingClientRect()
    const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2)
    return {
      pressed: b.getAttribute('aria-pressed'),
      icon: svg.getAttribute('data-icon'),
      strike: last.getAttribute('d'),
      strikeWidth: getComputedStyle(last).strokeWidth,
      color: cs.color,
      opacity: cs.opacity,
      hit: Boolean(hit && b.contains(hit)),
    }
  }
  return { chime: one('notify-chime'), bell: one('notify-alerts') }
}, scope)

async function load(p, base, width, touch, url) {
  await p.setViewport({ width, height: 800, isMobile: touch, hasTouch: touch })
  if (url) await p.goto(`${base}/lobby`, { waitUntil: 'load' })
  else await p.reload({ waitUntil: 'load' })
  await p.waitForSelector('[data-test=top-bar]')
  if (!(await signIn(p))) throw new Error('no session store')
  await sleep(400)
}

async function showSwitch(p, touch) {
  if (!touch) return '[data-testid=notify-box-rail]'
  await p.click('[data-test=user-menu-trigger]')
  await p.waitForSelector('[data-test=user-menu-prefs] [data-testid=notify-chime]', { timeout: 10000 })
  await sleep(300)
  return '[data-test=user-menu-prefs]'
}

async function run(browser, base, width, touch) {
  const tag = `${width}px`
  const p = await browser.newPage()
  await p.evaluateOnNewDocument(recorders)
  await load(p, base, width, touch, true)
  await p.evaluate(() => { try { localStorage.setItem('spool.chime', '1'); localStorage.setItem('spool.alerts', '1') } catch {} })
  await load(p, base, width, touch, false)
  let scope = await showSwitch(p, touch)

  const on = await drawn(p, scope)
  check(`${tag}: note ON is pressed, the plain note`, on.chime?.pressed === 'true' && on.chime.icon === 'music', on.chime)
  check(`${tag}: the click reaches the note (nothing on top)`, on.chime?.hit === true, on.chime)
  const loud = await ping(p)
  check(`${tag}: control - note ON: a ping plays the oscillator and a sounding alert`,
    loud.some((s) => s.kind === 'osc') && loud.some((s) => s.kind === 'alert' && !s.silent), loud)

  await p.click(`${scope} [data-testid=notify-chime]`)
  await sleep(200)
  const off = await drawn(p, scope)
  check(`${tag}: one click -> aria-pressed=false, the struck-through note`, off.chime?.pressed === 'false' && off.chime.icon === 'music-off', off.chime)
  const quiet = await ping(p)
  check(`${tag}: note OFF: no oscillator`, !quiet.some((s) => s.kind === 'osc'), quiet)
  check(`${tag}: note OFF: the alert still shows, silent`, quiet.length === 1 && quiet[0].kind === 'alert' && quiet[0].silent === true, quiet)

  // the bell off too, to compare the two strikes as the owner asked
  await p.click(`${scope} [data-testid=notify-alerts]`)
  await sleep(200)
  const both = await drawn(p, scope)
  check(`${tag}: the note strike is the bell strike (path + width)`,
    both.bell?.icon === 'bell-off' && both.chime.strike === both.bell.strike && both.chime.strikeWidth === both.bell.strikeWidth,
    { chime: [both.chime.strike, both.chime.strikeWidth], bell: [both.bell?.strike, both.bell?.strikeWidth] })
  check(`${tag}: ... and the same ink`, both.chime.color === both.bell.color && both.chime.opacity === both.bell.opacity,
    { chime: [both.chime.color, both.chime.opacity], bell: [both.bell.color, both.bell.opacity] })
  await p.click(`${scope} [data-testid=notify-alerts]`)
  await sleep(200)

  await load(p, base, width, touch, false)
  scope = await showSwitch(p, touch)
  const kept = await drawn(p, scope)
  check(`${tag}: reload -> still muted`, kept.chime?.pressed === 'false' && kept.chime.icon === 'music-off', kept.chime)
  const still = await ping(p)
  check(`${tag}: reload -> a ping is still silent`, !still.some((s) => s.kind === 'osc') && still.every((s) => s.silent), still)

  if (!touch) {
    // a second tab that loaded while the note was OFF follows the first tab
    const q = await browser.newPage()
    await q.evaluateOnNewDocument(recorders)
    await load(q, base, width, false, true)
    await p.bringToFront()
    await p.click(`${scope} [data-testid=notify-chime]`)
    await sleep(400)
    const other = await ping(q)
    check(`${tag}: second tab follows ON without a reload`, other.some((s) => s.kind === 'osc'), other)
    await p.click(`${scope} [data-testid=notify-chime]`)
    await sleep(400)
    const other2 = await ping(q)
    check(`${tag}: second tab follows OFF without a reload`, !other2.some((s) => s.kind === 'osc') && other2.every((s) => s.silent), other2)
    await q.close()
  }
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, touch] of [[1440, false], [820, true], [360, true]]) await run(browser, server.base, w, touch)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nchime-mute: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
