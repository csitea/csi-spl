// CLE-77875 (HUM-24, topic 311427c6, third "the notification for new messages
// doesn't work" report): the bell is the reader's switch and defaults ON, so
// it read "alerts on" in a browser never asked for permission, or one that
// blocks it. Settings -> Notifications now names the real state, in a real
// browser, mock tenant signed in, with a fake Notification per case:
//   A  undecided ('default'): state "ask"; the bell draws NO dot (HUM-10,
//      topic f4316e89: "remove that dot") - its hover text names the state;
//      Allow asks the browser -> state "on"
//   T  "send a test notification" raises a real alert through the same path
//      a message takes: tag spool-test, renotify (a same-tag alert must not
//      replace the last one silently)
//   K  blocked ('denied'): state "blocked", no test button, still no dot
//   B  the bell's off state keeps its strike (bell-off's slash); on again is
//      the plain bell
//   I  an iPhone Safari tab (no Notification at all): state "install"
//   F  undecided: the first click anywhere asks the browser, once
//   S  the chime off (005's default): Settings says alerts arrive silently
//   M  a muted channel is listed with Unmute; Unmute clears the sidebar's
//      muted mark at once, without a reload
// CONTROL: granted from the start: state "on", no dot, the bell shows "on".
//
//   node tests/e2e/notify-settings.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/notify-settings.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const DESKTOP = { name: '1440', width: 1440, height: 900 }
const IPHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1'

/* runs before the app: a fake Notification whose permission the case picks */
function fakeNotification(mode, muted) {
  try {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.alerts', '1')
    localStorage.setItem('spool.muted-channels', JSON.stringify(muted))
  } catch { /* opaque origin on the very first document */ }
  window.__alerts = []
  window.__asked = 0
  if (mode === 'none') {
    try { delete window.Notification } catch { /* ignore */ }
    window.Notification = undefined
    return
  }
  function FakeNotification(title, opts) { window.__alerts.push({ title, ...(opts || {}) }) }
  FakeNotification.permission = mode
  FakeNotification.requestPermission = async () => {
    window.__asked++
    FakeNotification.permission = 'granted'
    return 'granted'
  }
  window.Notification = FakeNotification
}

const server = await startServer()
const browser = await launch()
const errors = []

async function open(mode, opts = {}) {
  const p = await browser.newPage()
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  if (opts.ua) await p.setUserAgent(opts.ua)
  await p.evaluateOnNewDocument(fakeNotification, mode, opts.muted || [])
  await setPageViewport(p, DESKTOP)
  await p.goto(server.base + (opts.path || '/settings/notifications'), { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
  await applyViewport(p, DESKTOP)
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  if (!opts.path) await p.waitForSelector('[data-test=settings-notify-state]', { visible: true, timeout: NAV_TIMEOUT })
  await sleep(600)
  return p
}

const state = (p) => p.evaluate(() => document.querySelector('[data-test=settings-notify-state]')?.getAttribute('data-state') || null)
/* a dot is anything the bell button draws besides its glyph: a child element
   or a ::before/::after with content, on every copy of the bell */
const dot = (p) => p.evaluate(() => [...document.querySelectorAll('[data-testid=notify-alerts]')].some((b) => {
  if ([...b.children].some((c) => !c.matches('svg.ui-icon'))) return true
  return ['::before', '::after'].some((pe) => !['none', 'normal'].includes(getComputedStyle(b, pe).content))
}))
const bell = (p) => p.evaluate(() => {
  const b = document.querySelector('[data-testid=notify-alerts]')
  const svg = b?.querySelector('svg.ui-icon')
  return { icon: svg?.getAttribute('data-icon') || null, strike: Boolean(svg?.querySelector('path[d="M2 2 22 22"]')), title: b?.getAttribute('title') || '' }
})
const has = async (p, sel) => (await p.$(sel)) !== null

try {
  /* CONTROL */
  let p = await open('granted')
  ok('C0 CONTROL granted: state on', (await state(p)) === 'on', { state: await state(p) })
  ok('C1 CONTROL granted: no warn dot on the bell', !(await dot(p)))
  ok('C2 CONTROL granted: the test button is offered', await has(p, '[data-test=settings-notify-test]'))
  /* S (HUM-24 msg 031f937d "no sound is heard"): the chime is opt-in, and
     with it off every alert is silent too - Settings says so */
  ok('S1 chime off: Settings says alerts arrive silently', await has(p, '[data-test=settings-notify-silent]'))
  await p.click('[data-test=settings-notify-chime]')
  await sleep(300)
  ok('S2 chime on: the silent warning is gone', !(await has(p, '[data-test=settings-notify-silent]')))
  /* B (HUM-10): the dot is gone, the strike stays */
  const on0 = await bell(p)
  ok('B0 CONTROL on: the plain bell, no strike', on0.icon === 'bell' && !on0.strike, on0)
  const flip = async (want) => {
    await p.evaluate(() => document.querySelector('[data-testid=notify-alerts]').click())
    await p.waitForFunction((w) => document.querySelector('[data-testid=notify-alerts] svg.ui-icon')?.getAttribute('data-icon') === w, { timeout: 5000 }, want).catch(() => {})
  }
  await flip('bell-off')
  const off = await bell(p)
  ok('B1 off: bell-off with its strike', off.icon === 'bell-off' && off.strike, off)
  ok('B2 off: no dot', !(await dot(p)))
  await flip('bell')
  const on1 = await bell(p)
  ok('B3 on again: the plain bell', on1.icon === 'bell' && !on1.strike, on1)
  await p.close()

  /* A + T */
  p = await open('default')
  ok('A1 undecided: state ask', (await state(p)) === 'ask', { state: await state(p) })
  ok('A2 undecided: the bell draws no dot (HUM-10)', !(await dot(p)))
  const askBell = await bell(p)
  ok('A2b undecided: the bell is on and its hover text names the state', askBell.icon === 'bell' && askBell.title.includes(':'), askBell)
  ok('A3 undecided: Allow is offered', await has(p, '[data-test=settings-notify-allow]'))
  await p.click('[data-test=settings-notify-allow]')
  await p.waitForFunction(() => document.querySelector('[data-test=settings-notify-state]')?.getAttribute('data-state') === 'on', { timeout: 5000 }).catch(() => {})
  ok('A4 Allow asked the browser and the state is on', (await state(p)) === 'on' && (await p.evaluate(() => window.__asked)) >= 1)
  ok('A5 still no dot', !(await dot(p)))
  await p.click('[data-test=settings-notify-test]')
  await p.waitForSelector('[data-test=settings-notify-test-result]', { timeout: 5000 }).catch(() => {})
  const alerts = await p.evaluate(() => window.__alerts)
  const result = await p.evaluate(() => document.querySelector('[data-test=settings-notify-test-result]')?.getAttribute('data-result'))
  ok('T1 the test raised one alert', alerts.length === 1, alerts)
  ok('T2 tagged spool-test with renotify', alerts[0]?.tag === 'spool-test' && alerts[0]?.renotify === true, alerts[0])
  ok('T3 the result reads shown', result === 'shown', { result })
  await p.close()

  /* K */
  p = await open('denied')
  ok('K1 blocked: state blocked', (await state(p)) === 'blocked', { state: await state(p) })
  ok('K2 blocked: no test button, no Allow', !(await has(p, '[data-test=settings-notify-test]')) && !(await has(p, '[data-test=settings-notify-allow]')))
  ok('K3 blocked: the bell draws no dot (HUM-10)', !(await dot(p)))
  await p.close()

  /* I */
  p = await open('none', { ua: IPHONE_UA })
  ok('I1 iPhone Safari tab: state install', (await state(p)) === 'install', { state: await state(p) })
  await p.close()

  /* F */
  p = await open('default', { path: '/channel/general' })
  const before = await p.evaluate(() => window.__asked)
  await p.mouse.click(700, 450)
  await sleep(400)
  await p.mouse.click(700, 460)
  await sleep(400)
  ok('F0 CONTROL: nothing asked before a click', before === 0, { before })
  ok('F1 the first click asked once', (await p.evaluate(() => window.__asked)) === 1, { asked: await p.evaluate(() => window.__asked) })
  await p.close()

  /* M */
  p = await open('granted', { muted: ['alerts'] })
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await sleep(400)
  const markedBefore = await p.evaluate(() => document.querySelectorAll('[data-testid=row-muted]').length)
  ok('M0 CONTROL: the sidebar marks the muted channel', markedBefore >= 1, { markedBefore })
  ok('M1 Settings lists #alerts as muted', await has(p, '[data-test=settings-notify-unmute-alerts]'))
  await p.click('[data-test=settings-notify-unmute-alerts]')
  await sleep(500)
  ok('M2 Unmute empties the list', !(await has(p, '[data-test=settings-notify-muted]')))
  ok('M3 the sidebar mark is gone without a reload', (await p.evaluate(() => document.querySelectorAll('[data-testid=row-muted]').length)) === 0)
  ok('M4 stored unmuted', (await p.evaluate(() => localStorage.getItem('spool.muted-channels'))) === '[]')
  await p.close()

  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('no page errors', real.length === 0, real.slice(0, 3))
} finally {
  await browser.close()
  await server.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
