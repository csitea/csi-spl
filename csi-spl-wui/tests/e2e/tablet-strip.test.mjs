// SPL-2145 (epic SPL-2130, UI review suggestion 3): a tablet (600..820 px)
// keeps a narrow strip of the channel list beside the page it reads, where
// a phone (under 600 px) still shows ONE panel full screen (SPL-989).
//   700 px, level 2 (a channel): the strip is beside the page, a tap on one
//          of its channels opens that channel, its expand button opens the
//          full list (level 1); level 3 (a topic) keeps the strip too.
//   390 px: no strip, the phone's one-pane stack is unchanged.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/tablet-strip.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
/** Poll read() until want(state) holds (or `max` ms pass); returns the last state. */
async function until(read, want, max = 10000) {
  const end = Date.now() + max
  let s = await read()
  while (Date.now() < end && !want(s)) {
    await sleep(150)
    s = await read()
  }
  return s
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

/** The panels on screen, the strip's box and the main pane's width. */
const state = (p) => p.evaluate(() => {
  const sh = document.querySelector('.spool-shell')
  const box = (s) => {
    const e = document.querySelector(s)
    if (!e || getComputedStyle(e).display === 'none') return null
    const r = e.getBoundingClientRect()
    return r.width > 0 && r.height > 0 ? { x: Math.round(r.x), w: Math.round(r.width), h: Math.round(r.height) } : null
  }
  return {
    level: sh ? sh.getAttribute('data-mobile-level') : null,
    side: Boolean(box('.spool-shell > .sidebar')),
    main: box('.spool-shell > .spool-main'),
    topic: box('.spool-shell > .topic'),
    strip: box('[data-testid=tablet-strip]'),
    rows: [...document.querySelectorAll('[data-testid=tablet-strip-channel]')].map((e) => e.getAttribute('data-key')),
    path: location.pathname + location.search,
    xscroll: document.scrollingElement.scrollWidth > innerWidth,
  }
})

/** A topic, opened the way a card click opens it (MessageFeed -> topic store). */
const openTopic = (p) => p.evaluate((id) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  pinia?._s.get('topic')?.openTopic(id)
}, TASK)

const srv = await startServer()
const browser = await launch()
try {
  /* tablet: 700 px */
  let page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width: 700, height: 1000, isMobile: true, hasTouch: true })
  await page.goto(`${srv.base}/channel/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell')
  let s = await until(() => state(page), (x) => x.level === '2' && x.strip && x.rows.length > 1)
  ok('700px level 2: the strip shows beside the page', s.level === '2' && Boolean(s.strip) && Boolean(s.main) && !s.side && !s.xscroll, s)
  ok('700px the strip is narrow (<= 72 px) and the page takes the rest',
    Boolean(s.strip) && s.strip.w <= 72 && Boolean(s.main) && s.main.w >= 700 - 72 - 2 && s.main.x >= s.strip.w - 1, s)
  ok('700px the strip lists the channels', s.rows.length > 1 && s.rows.includes('lobby'), s.rows)
  const small = await page.evaluate(() => [...document.querySelectorAll('[data-testid=tablet-strip] a, [data-testid=tablet-strip] button')]
    .map((e) => e.getBoundingClientRect()).filter((r) => r.width < 44 || r.height < 44).length)
  ok('700px every strip control is a >= 44 px target', Boolean(s.strip) && small === 0, small)

  const other = s.rows.find((k) => k !== 'lobby') || 'none'
  await page.evaluate((k) => document.querySelector(`[data-testid=tablet-strip-channel][data-key="${k}"]`)?.click(), other)
  s = await until(() => state(page), (x) => x.path.startsWith(`/channel/${other}`) && x.level === '2' && x.strip)
  ok('700px a strip tap opens that channel, strip still there', s.path.startsWith(`/channel/${other}`) && s.level === '2' && Boolean(s.strip), s)
  const current = await page.evaluate((k) => document.querySelector(`[data-testid=tablet-strip-channel][data-key="${k}"]`)?.getAttribute('aria-current'), other)
  ok('700px the open channel is marked current in the strip', current === 'page', current)

  // Re-issued while level 3 is not up: right after the channel switch the
  // store may not be registered yet, or that navigation may still reset it.
  s = await until(async () => {
    const x = await state(page)
    if (x.level !== '3') await openTopic(page)
    return x
  }, (x) => x.level === '3' && x.topic)
  ok('700px level 3: the topic shows beside the strip', s.level === '3' && Boolean(s.topic) && Boolean(s.strip) && !s.main && !s.xscroll, s)

  await page.evaluate(() => document.querySelector('[data-testid=tablet-strip-expand]')?.click())
  s = await until(() => state(page), (x) => x.level === '1' && x.side)
  ok('700px the expand button opens the full list (level 1, no strip)', s.level === '1' && s.side && !s.strip && !s.main, s)
  await page.close()

  /* phone: 390 px, unchanged */
  page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await page.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await page.goto(`${srv.base}/channel/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell')
  await until(() => state(page), (x) => x.level === '2' && x.main)
  await sleep(1500)
  s = await state(page)
  ok('390px level 2: one panel, full width, no strip', s.level === '2' && !s.strip && !s.side && Boolean(s.main) && s.main.w >= 388 && !s.xscroll, s)
  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntablet-strip: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
