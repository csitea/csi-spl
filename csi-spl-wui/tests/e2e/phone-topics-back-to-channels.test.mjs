// SPL-6379 (owner HUM-10, t1 acfc125c, msgs 6d7f4f27, 64154494, d911deb2):
// "Whenever I'm on the topics listing in a channel, if I click on the back
// button or on the back button on the top row, I should get to the channel
// level and not outside of the whole discussions UI." ... "Once I am in the
// discussions area, the only way to get out of there when clicking the back
// button is by being on the channels' top channels view."
//
// Spec 087 section 3.4: on a channel's topics list (level 2 on a phone), Back
// lands on the channel list (Discussions' top, level 1 with the Channels
// list on screen), however the topics list was reached:
//   entries  tap      `/`, then a tap on #lobby in the channel list
//            deep     a fresh tab on `/channel/lobby` (a deep link, a reload)
//            topic    a fresh tab on a topic (`?topic=`), then the chevron
//                     Back to the channel's topics
//            link     `/`, `/issues`, then a link from that page to #lobby
//                     (router.push, as an issue's discussion link)
//            rail     `/`, `/notes`, the strip's Channels, then #lobby
//            section  `/`, #lobby, a topic, the strip's Issues (SPL-6356),
//                     browser Back to the topic, then the chevron to the topics
//   methods  browser  browser Back (page.goBack)
//            chevron  the top row's "<" (MobileBack in the feed head)
//   widths   360x780, 390x844
// A cell passes when one Back lands on level 1 with the Channels list on
// screen, in the app (not about:blank, not another section's page), and a
// second browser Back then moves off that entry (no dead entry under it: the
// channel list is the one place Back leaves Discussions from).
//
// Measured on origin/master 09f137d40, mock bundle, n = 1 per cell: 360 and
// 390 failed deep/browser, topic/browser (about:blank: a deep link built no
// entries under it) and link/browser (the /issues page the link was on);
// every chevron cell and tap, rail, section passed. With SPL-6379
// (utils/mobile-stack.mjs mobileDiscussionStack) all 24 phone cells pass.
//
// 1440 px (desktop, no stack, no chevron): the channel list is on screen
// beside every feed and browser Back is the browser's own history. Its cells
// print INFO and do not count (deep/browser leaves the app, link/browser
// returns to /issues, on master and with the fix); DESKTOP=strict counts them.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/phone-topics-back-to-channels.test.mjs
// Narrow: ENTRIES=deep,link METHODS=browser WIDTHS=360
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const SIZES = { 360: 780, 390: 844, 1440: 900 }
const ALL_ENTRIES = ['tap', 'deep', 'topic', 'link', 'rail', 'section']
const ALL_METHODS = ['browser', 'chevron']
const pick = (env, all) => (env ? env.split(',').filter((x) => all.includes(x)) : all)
const ENTRIES = pick(process.env.ENTRIES, ALL_ENTRIES)
const METHODS = pick(process.env.METHODS, ALL_METHODS)
const WIDTHS = (process.env.WIDTHS || '360,390,1440').split(',').map(Number).filter((w) => SIZES[w])
const DESKTOP_STRICT = process.env.DESKTOP === 'strict'
const MEMBER = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

/* before any app code: a signed-in mock member */
function boot(member) {
  try {
    localStorage.setItem('spool.mock.session', JSON.stringify(member))
    localStorage.setItem('spool.was-signed-in', '1')
  } catch { /* private mode */ }
}

const state = (p) => p.evaluate(() => {
  const seen = (s) => [...document.querySelectorAll(s)].some((e) => {
    const r = e.getBoundingClientRect()
    return getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility !== 'hidden' && r.width > 0 && r.height > 0
  })
  return {
    level: Number(document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || 0),
    path: location.protocol === 'about:' ? 'about:blank' : location.pathname + location.search,
    channels: seen('[data-testid=sidebar-panel-channels]'),
  }
}).catch(() => ({ level: 0, path: 'about:blank', channels: false }))

async function until(p, want, ms = 6000) {
  const t0 = Date.now()
  let s = await state(p)
  while (!want(s) && Date.now() - t0 < ms) { await sleep(100); s = await state(p) }
  await sleep(400)
  return state(p)
}

const click = (p, sel) => p.evaluate((q) => {
  const e = [...document.querySelectorAll(q)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e || e.disabled) return false
  e.click()
  return true
}, sel)

const load = async (p, base, path) => {
  await p.goto(base + path, { waitUntil: 'domcontentloaded' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
}

const onLobby = (s, phone) => s.path === '/channel/lobby' && (!phone || s.level === 2)

async function tapLobby(p, phone) {
  await p.evaluate(() => {
    const row = [...document.querySelectorAll('#sidebar-panel-channels .nav-item')].find((e) => (e.getAttribute('href') || '').endsWith('/channel/lobby'))
    row?.click()
  })
  return until(p, (s) => onLobby(s, phone))
}

/** Open the entry; resolve to the state on the channel's topics list. */
async function enter(p, base, entry, phone) {
  if (entry === 'tap') {
    await load(p, base, '/')
    await until(p, (s) => s.channels)
    await click(p, '[data-testid=sidebar-tab-channels]')
    await sleep(300)
    return tapLobby(p, phone)
  }
  if (entry === 'deep') {
    await load(p, base, '/channel/lobby')
    return until(p, (s) => onLobby(s, phone))
  }
  if (entry === 'topic') {
    await load(p, base, `/channel/lobby?topic=${TASK}`)
    await until(p, (s) => s.level === 3, 8000)
    await click(p, '[data-testid=mobile-back]')
    return until(p, (s) => onLobby(s, phone))
  }
  if (entry === 'link') {
    await load(p, base, '/')
    await sleep(600)
    await load(p, base, '/issues')
    await sleep(800)
    await p.evaluate(() => document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$router?.push('/channel/lobby'))
    return until(p, (s) => onLobby(s, phone))
  }
  if (entry === 'section') return sectionEntry(p, base, phone)
  /* rail */
  await load(p, base, '/')
  await sleep(600)
  await load(p, base, '/notes')
  await sleep(800)
  await click(p, '[data-testid=sidebar-tab-channels]')
  await until(p, (s) => s.channels)
  return tapLobby(p, phone)
}

/* SPL-6356: another section opened from a topic, Back to the topic, Back to its topics */
async function sectionEntry(p, base, phone) {
  await load(p, base, '/')
  await until(p, (s) => s.channels)
  await tapLobby(p, phone)
  await sleep(600)
  await p.evaluate((id) => document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('topic')?.openTopic(id), TASK)
  await until(p, (s) => s.path.includes('topic='), 8000)
  await sleep(400)
  await click(p, '[data-testid=sidebar-tab-issues]')
  await until(p, (s) => s.path.startsWith('/issues'), 8000)
  await sleep(600)
  /* the Issues top draws no chevron: browser Back, as the owner's reference */
  await back(p, 'browser')
  await until(p, (s) => s.path.includes('topic='), 8000)
  await sleep(600)
  await back(p, 'chevron')
  return until(p, (s) => onLobby(s, phone))
}

async function back(p, method) {
  if (method === 'chevron') return click(p, '[data-testid=mobile-back]')
  await p.goBack({ timeout: 8000 }).catch(() => null)
  return true
}

async function cell(browser, base, width, entry, method) {
  const phone = width <= 820
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  try {
    await p.setViewport({ width, height: SIZES[width], isMobile: phone, hasTouch: phone })
    await p.evaluateOnNewDocument(boot, MEMBER)
    const s0 = await enter(p, base, entry, phone)
    if (!onLobby(s0, phone)) return { pass: false, why: `entry did not reach #lobby's topics: ${JSON.stringify(s0)}` }
    await sleep(500)
    const pressed = await back(p, method)
    if (!pressed) return { pass: false, why: 'no chevron to press' }
    const s1 = await until(p, (s) => !onLobby(s, phone), 6000)
    if (!phone) return { pass: s1.channels && s1.path !== 'about:blank', why: JSON.stringify(s1) }
    if (!(s1.level === 1 && s1.channels && s1.path !== 'about:blank')) return { pass: false, why: JSON.stringify(s1) }
    await sleep(400)
    await back(p, 'browser')
    const s2 = await until(p, (s) => s.path !== s1.path || s.level !== 1, 6000)
    const moved = s2.path !== s1.path || s2.level !== 1
    return { pass: moved, why: `${JSON.stringify(s1)}, then ${moved ? 'leaves to' : 'DEAD ENTRY, stays on'} ${s2.path}` }
  } finally {
    await ctx.close().catch(() => {})
  }
}

const server = await startServer()
const browser = await launch()
const lines = []
let failed = 0
try {
  console.log(`phone-topics-back-to-channels on ${server.base}`)
  for (const w of WIDTHS) {
    for (const entry of ENTRIES) {
      for (const method of METHODS) {
        /* desktop: no chevron, and a topic is closed by its own pane, not a Back */
        if (w > 820 && (method === 'chevron' || entry === 'topic' || entry === 'section')) continue
        const r = await cell(browser, server.base, w, entry, method)
        const info = w > 820 && !DESKTOP_STRICT
        if (!r.pass && !info) failed++
        const line = `  ${r.pass ? 'OK  ' : info ? 'INFO' : 'FAIL'} ${w} ${entry}/${method} -> ${r.why}`
        lines.push(line)
        console.log(line)
      }
    }
  }
} finally {
  await browser.close().catch(() => {})
  await server.stop()
}
const counted = lines.filter((l) => !l.includes(' INFO ')).length
console.log(`phone-topics-back-to-channels: ${counted - failed}/${counted} passed`)
process.exit(failed ? 1 : 0)
