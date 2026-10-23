// SPL-2785 (owner HUM-10, t1 c7185b1f: "Clicking on back button should have
// three bouncing small balls like in the meetup web app"): after a Back on a
// phone, components/MobileBackWait.vue shows three small bouncing dots while
// the screen it returns to loads. SPL-3120 (owner, t1 c7185b1f: "Not
// visible on mobile"): the usual phone Backs load nothing, so the dots now
// show at once on EVERY Back for ~0.7 s, and longer while the screen loads.
//
// The plant: the next channel.selectChannel waits SLOW_MS with the feed
// marked loading (aria-busy), as a slow hub would. Each case watches the
// dots with a MutationObserver from the moment of the Back.
//   1-3. a slow Back by each way in (the chevron, browser Back, a swipe
//        right): dots seen, and gone once the feed has loaded
//   4.   the same Back with no plant (the mock answers at once): the dots
//        show for ~0.7 s, then go
//   5.   a Back that needs no load (level 3 -> 2, the feed is there) with
//        the plant armed: the same short show, not held by the unused plant
//   5b.  level 2 -> 1 (the feed to the list): the same short show
//   6.   reduced motion: the dots show and do not move
//   7.   desktop (1440): no dots element at all
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/mobile-back-wait.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
// SHOTS_DIR=<dir> also writes back-wait-<light|dark>.png of the dots.
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SLOW_MS = 1500
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const SHOTS_DIR = process.env.SHOTS_DIR || ''

const results = []
function ok(name, pass, ev) {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
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

const where = (p) => p.evaluate(() => ({
  level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || null,
  path: location.pathname,
  busy: [...document.querySelectorAll('.spool-shell [aria-busy="true"]')].some((e) => e.getBoundingClientRect().width > 0),
}))

async function waitFor(p, want, max = 8000) {
  const end = Date.now() + max
  let s = await where(p)
  while (Date.now() < end && !want(s)) { await sleep(100); s = await where(p) }
  return s
}

const vue = (p, fn, arg) => p.evaluate(fn, arg)

const signIn = (p) => vue(p, () => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  pinia?._s.get('session')?.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
})

const go = (p, path) => vue(p, (to) => {
  void document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$router?.push(to)
}, path)

/* the plant: the next channel open waits `ms` with the feed loading, then reads */
const plantSlow = (p, ms) => vue(p, (wait) => {
  const ch = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('channel')
  const orig = ch.selectChannel
  ch.selectChannel = async (...a) => {
    ch.selectChannel = orig
    ch.loading = true
    await new Promise((r) => setTimeout(r, wait))
    return orig(...a)
  }
}, ms)

/* records every show / hide of the dots, ms after the call */
const watchDots = (p) => vue(p, () => {
  const t0 = performance.now()
  const log = []
  let last = false
  const read = () => {
    const on = Boolean(document.querySelector('[data-testid=back-wait-dots]'))
    if (on !== last) { last = on; log.push([on, Math.round(performance.now() - t0)]) }
  }
  window.__backWait?.obs.disconnect()
  const obs = new MutationObserver(read)
  obs.observe(document.body, { subtree: true, childList: true, attributes: true })
  window.__backWait = { log, obs }
})
const dotsLog = (p) => vue(p, () => window.__backWait?.log || [])

const BACKS = {
  chevron: (p) => vue(p, () => {
    const e = [...document.querySelectorAll('[data-testid=mobile-back]')].find((x) => x.getBoundingClientRect().width > 0)
    e?.click()
    return Boolean(e)
  }),
  'browser Back': (p) => vue(p, () => { history.back(); return true }),
  swipe: (p) => vue(p, () => {
    const target = document.querySelector('.spool-main') || document.querySelector('.spool-shell')
    const y = 400
    const t = (x) => new Touch({ identifier: 1, target, clientX: x, clientY: y })
    target.dispatchEvent(new TouchEvent('touchstart', { touches: [t(20)], changedTouches: [t(20)], bubbles: true }))
    target.dispatchEvent(new TouchEvent('touchend', { touches: [], changedTouches: [t(300)], bubbles: true }))
    return true
  }),
}

async function phone(browser, base, opts = {}) {
  const ctx = await browser.createBrowserContext()
  const page = await ctx.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  if (opts.theme) {
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: opts.theme }])
    await page.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, opts.theme)
  }
  if (opts.reduced) await page.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  await page.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await page.goto(`${base}/`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell')
  await sleep(800)
  await signIn(page)
  const mounted = await page.waitForSelector('[data-testid=back-wait]', { timeout: 8000 }).then(() => true, () => false)
  return { ctx, page, mounted }
}

/* #alerts, then #lobby by a route push: Back returns to #alerts */
async function twoChannels(page) {
  await go(page, '/channel/alerts')
  await waitFor(page, (s) => s.path === '/channel/alerts' && s.level === '2' && !s.busy)
  await go(page, '/channel/lobby')
  return waitFor(page, (s) => s.path === '/channel/lobby' && s.level === '2' && !s.busy)
}

async function slowBack(browser, base, how) {
  const { ctx, page, mounted } = await phone(browser, base)
  try {
    ok(`${how}: the dots region is on the page (390 px)`, mounted)
    const s0 = await twoChannels(page)
    ok(`${how}: setup, #lobby on level 2 after #alerts`, s0.path === '/channel/lobby' && s0.level === '2', s0)
    await plantSlow(page, SLOW_MS)
    await watchDots(page)
    const t0 = Date.now()
    const pressed = await BACKS[how](page)
    await sleep(SLOW_MS / 2)
    const mid = await page.$('[data-testid=back-wait-dots]')
    const back = await waitFor(page, (s) => s.path === '/channel/alerts' && !s.busy, SLOW_MS + 6000)
    await sleep(400)
    const log = await dotsLog(page)
    const gone = !(await page.$('[data-testid=back-wait-dots]'))
    const firstOn = log.find(([on]) => on)
    ok(`${how}: Back returns to #alerts and the feed loads`, pressed && back.path === '/channel/alerts' && !back.busy, back)
    ok(`${how}: the dots show while the feed loads`, Boolean(mid) && Boolean(firstOn), log)
    ok(`${how}: at once (first shown at ${firstOn ? firstOn[1] : '-'} ms)`, Boolean(firstOn) && firstOn[1] < 140, log)
    ok(`${how}: gone once the feed has loaded (${Date.now() - t0} ms)`, gone && log.length >= 2 && !log[log.length - 1][0], log)
  } finally {
    await ctx.close().catch(() => {})
  }
}

/* one show then one hide, held at least MIN_MS and less than `max` */
const MIN_MS = 600
const shortShow = (log, max) => log.length === 2 && log[0][0] && !log[1][0] && log[1][1] - log[0][1] >= MIN_MS && log[1][1] - log[0][1] < max

async function instantBacks(browser, base) {
  const { ctx, page, mounted } = await phone(browser, base)
  try {
    ok('instant: the dots region is on the page (390 px)', mounted)
    await twoChannels(page)
    await watchDots(page)
    await BACKS.chevron(page)
    const s = await waitFor(page, (x) => x.path === '/channel/alerts' && !x.busy)
    await sleep(1200)
    let log = await dotsLog(page)
    ok('instant: a Back the mock answers at once shows the dots ~0.7 s, then they go', s.path === '/channel/alerts' && shortShow(log, 1500), { s, log })

    await vue(page, (id) => document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('topic')?.openTopic(id), TASK)
    const l3 = await waitFor(page, (x) => x.level === '3')
    ok('instant: setup, a topic on level 3', l3.level === '3', l3)
    await plantSlow(page, SLOW_MS)
    await watchDots(page)
    await BACKS.chevron(page)
    const l2 = await waitFor(page, (x) => x.level === '2')
    await sleep(SLOW_MS)
    log = await dotsLog(page)
    ok('instant: 3 -> 2 needs no load, the dots show ~0.7 s, not held by the slow hub armed', l2.level === '2' && shortShow(log, SLOW_MS), { l2, log })
    /* drop the unused plant */
    await vue(page, () => { const ch = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('channel'); delete ch.selectChannel })

    await watchDots(page)
    await BACKS.chevron(page)
    const l1 = await waitFor(page, (x) => x.level === '1')
    await sleep(1200)
    log = await dotsLog(page)
    ok('instant: 2 -> 1 (the feed to the list) shows the dots ~0.7 s, then they go', l1.level === '1' && shortShow(log, 1500), { l1, log })
  } finally {
    await ctx.close().catch(() => {})
  }
}

/* reduced motion: static dots; and the screenshots, light and dark */
async function looks(browser, base, opts) {
  const { ctx, page } = await phone(browser, base, opts)
  try {
    await twoChannels(page)
    await plantSlow(page, SLOW_MS * 2)
    await BACKS.chevron(page)
    const dots = await page.waitForSelector('[data-testid=back-wait-dots]', { timeout: SLOW_MS }).catch(() => null)
    const read = await vue(page, () => {
      const dot = document.querySelector('[data-testid=back-wait-dots] circle')
      const region = document.querySelector('[data-testid=back-wait]')
      return {
        anim: dot ? getComputedStyle(dot).animationName : null,
        live: region?.getAttribute('aria-live'),
        busy: region?.getAttribute('aria-busy'),
        hidden: document.querySelector('[data-testid=back-wait-dots] svg')?.getAttribute('aria-hidden'),
      }
    })
    const tag = opts.reduced ? 'reduced motion' : opts.theme
    ok(`${tag}: the dots show`, Boolean(dots), read)
    if (opts.reduced) ok(`${tag}: the dots do not move`, read.anim === 'none', read)
    else ok(`${tag}: the dots bounce`, Boolean(read.anim) && read.anim !== 'none', read)
    ok(`${tag}: region aria-live=polite aria-busy=true, drawing aria-hidden`, read.live === 'polite' && read.busy === 'true' && read.hidden === 'true', read)
    if (SHOTS_DIR && dots && !opts.reduced) await sleep(400)
    if (SHOTS_DIR && dots && !opts.reduced) await page.screenshot({ path: join(SHOTS_DIR, `back-wait-${opts.theme}.png`) })
  } finally {
    await ctx.close().catch(() => {})
  }
}

async function desktop(browser, base) {
  const ctx = await browser.createBrowserContext()
  try {
    const page = await ctx.newPage()
    await page.setViewport({ width: 1440, height: 900 })
    await page.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
    await sleep(1500)
    const n = await page.evaluate(() => document.querySelectorAll('[data-testid=back-wait], [data-testid=mobile-back]').length)
    ok('1440px: no dots region and no chevron (desktop unchanged)', n === 0, n)
  } finally {
    await ctx.close().catch(() => {})
  }
}

const server = await startServer()
const browser = await launch()
try {
  console.log(`mobile-back-wait on ${server.base}`)
  for (const how of Object.keys(BACKS)) await slowBack(browser, server.base, how)
  await instantBacks(browser, server.base)
  await looks(browser, server.base, { theme: 'light' })
  await looks(browser, server.base, { theme: 'dark' })
  await looks(browser, server.base, { reduced: true })
  await desktop(browser, server.base)
} finally {
  await browser.close().catch(() => {})
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`mobile-back-wait: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
