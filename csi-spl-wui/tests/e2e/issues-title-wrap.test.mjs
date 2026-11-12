// SPL-5350 (owner HUM-10, t1 0ca07420): "the title of an issue should wrap
// to the second line and be maximum 2 lines long". In a REAL browser,
// against the mock bundle, a desktop list row with a long title:
//   1  the title wraps: it is taller than one line
//   2  it stops at two lines: its box is at most two line heights and the
//      text it holds is longer than what it shows (clamped, not cut short)
//   3  the full title stays reachable: the title attribute holds all of it
//   4  a short title stays one line
// Red control: TITLE_WRAP_CONTROL=1 drops the page's clamp rule in the
// browser, so 2 reads the unclamped height and fails.
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e issues-title-wrap
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CONTROL = process.env.TITLE_WRAP_CONTROL === '1'

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
        defaultViewport: { width: 1280, height: 800 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function create(p, title) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  return p.waitForFunction((want) => {
    const row = [...document.querySelectorAll('[data-test=issues-row]')].find((r) => r.querySelector('.issues-title')?.textContent.trim() === want)
    return !document.querySelector('[data-test=issues-newrow]') && row ? row.getAttribute('data-key') : false
  }, { timeout: 5000 }, title).then((h) => h.jsonValue())
}

/** the title box of a row: its height in lines, and how much it hides */
const measure = (p, key) => p.$eval(`[data-test=issues-row][data-key="${key}"] .issues-title`, (el) => {
  const cs = getComputedStyle(el)
  const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2
  const h = el.getBoundingClientRect().height
  const w = Math.round(el.getBoundingClientRect().width), cell = Math.round(el.closest('td').getBoundingClientRect().width)
  return { lines: Math.round((h / lh) * 100) / 100, h, lh, w, cell, hidden: el.scrollHeight > el.clientHeight + 1, title: el.getAttribute('title') }
})

const LONG = 'A long issue title that keeps going ' + Array.from({ length: 12 }, (_, i) => `word${i} and more words`).join(' ') + ' end'
const SHORT = 'short title'

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument(() => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' })) } catch { /* about:blank */ }
  })
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  const longKey = await create(p, LONG)
  const shortKey = await create(p, SHORT)
  if (CONTROL) {
    /* drop the clamp: the row title as it was before SPL-5350, but wrapping */
    await p.addStyleTag({ content: '.issues-c-title .issues-title { display: block !important; -webkit-line-clamp: unset !important; line-clamp: none !important; overflow: visible !important; white-space: normal !important; }' })
  }
  const long = await measure(p, longKey)
  const short = await measure(p, shortKey)
  ok('1 a long title wraps to a second line', long.lines > 1.5, long)
  ok('2 a long title shows at most 2 lines, and hides the rest', long.lines <= 2.05 && long.hidden, long)
  ok('3 the full title stays reachable on hover (title attribute)', long.title === LONG, long.title?.length)
  ok('4 a short title stays one line', short.lines <= 1.05, short)
  ok('5 no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nissues-title-wrap: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
