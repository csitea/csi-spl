// Spec 078 AC6 (FR-006, US3, owner 73f13491): with no stored width, the right
// pane opens at 40 % of the space right of the left pane, wide enough that the
// topic title is not cut. Runs against the lde mock (no hub).
//
//   1  1440x900, no spool.pane-widths: each #lobby root topic opens at about
//      470 px (1440 - 260 - 6 = 1174, x 0.4), not the old fixed 380
//   2  each title is whole: nothing cut below its line, and a title cut
//      sideways has the full title as its hover. Spec 109 FR-011 (F7: "4
//      lines, cut mid-word") replaces 078 T004b's four-line wrap in this pane:
//      "the topic title on one line (ellipsis)"; the /t page keeps the wrap
//   3  1920x1080: the default follows the window, about 662 px, title whole
//   4  a dragged (stored) width still wins over the default
//   5  spec 109 T011 (FR-011): at 1440 the header is one row <= 48 px, the
//      title one line, and every control in it has an accessible name
//      (aria-label or text, read from the DOM, so any locale passes)
//
// Run:
//   pnpm test:e2e topic-pane-title-fits
//   BASE_URL=<generated bundle> pnpm test:e2e topic-pane-title-fits   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { PANE_WIDTHS_KEY } from '../../src/utils/pane-widths.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
/* The #lobby root topics of the mock (src/utils/mock-data.mjs). */
const ROOTS = [
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'abababab-abab-4bab-8bab-abababababab',
]

if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

/** Open a channel topic through its store, as a row click does. */
async function openTopic(p, id) {
  await p.evaluate((id) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    pinia._s.get('topic').openTopic(id)
  }, id)
  await until(p, (id) => {
    const h = document.querySelector('aside.topic [data-test=topic-heading]')
    return Boolean(h && h.textContent.trim().length > 0 && document.querySelector('aside.topic'))
  }, id)
  await sleep(400)
}

/** The pane's width and its title's fit. */
const measure = (p) => p.evaluate(() => {
  const aside = document.querySelector('aside.topic')
  const h = aside && aside.querySelector('[data-test=topic-heading]')
  return {
    paneW: aside ? Math.round(aside.getBoundingClientRect().width) : 0,
    title: h ? h.textContent.trim() : '',
    scrollW: h ? h.scrollWidth : -1,
    clientW: h ? h.clientWidth : -1,
    scrollH: h ? h.scrollHeight : -1,
    clientH: h ? h.clientHeight : -1,
    hover: h ? h.title : '',
  }
})

/** The title is whole: nothing cut below, and cut sideways only with the
 *  full title on hover (FR-011's ellipsis). */
const fits = (m) => m.clientW > 0 && m.scrollH <= m.clientH &&
  (m.scrollW <= m.clientW || (m.title.length > 0 && m.hover.includes(m.title)))

/** T011: the header row, the title's line count, every control's name. */
const header = (p) => p.evaluate(() => {
  const head = document.querySelector('aside.topic header')
  const h = head && head.querySelector('[data-test=topic-heading]')
  const shown = (el) => el.getClientRects().length > 0
  const name = (el) => (el.getAttribute('aria-label') || el.textContent || '').trim()
  const controls = head ? [...head.querySelectorAll('button, [role=radiogroup]')].filter(shown) : []
  const radios = head ? [...head.querySelectorAll('input[type=radio]')] : []
  const lineH = h ? parseFloat(getComputedStyle(h).lineHeight) : 0
  return {
    headerH: head ? Math.round(head.getBoundingClientRect().height) : 0,
    kids: head ? [...head.children].filter(shown).map((el) => `${el.className || el.tagName}:${Math.round(el.getBoundingClientRect().height)}`) : [],
    lines: h && lineH ? Math.round(h.querySelector('.topic-heading__text').getBoundingClientRect().height / lineH) : 0,
    controls: controls.length,
    unnamed: controls.filter((el) => !name(el)).map((el) => el.outerHTML.slice(0, 80)),
    radios: radios.length,
    unnamedRadios: radios.filter((r) => !(r.closest('label')?.textContent || '').trim()).length,
  }
})

/** Fresh shell at this viewport, with the given stored widths (null = none). */
async function load(p, base, w, h, stored) {
  await p.setViewport({ width: w, height: h })
  await p.goto(`${base}/channel/lobby`, { waitUntil: 'networkidle2' })
  await p.evaluate(({ key, stored }) => {
    if (stored) localStorage.setItem(key, JSON.stringify(stored))
    else localStorage.removeItem(key)
  }, { key: PANE_WIDTHS_KEY, stored })
  await p.reload({ waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(1000)
}

const near = (a, b, tol = 3) => Math.abs(a - b) <= tol

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)

  /* ---- 1 + 2. 1440, nothing stored ------------------------------------- */
  await load(p, srv.base, 1440, 900, null)
  for (const id of ROOTS) {
    await openTopic(p, id)
    const m = await measure(p)
    ok(`1 1440: ${id.slice(0, 8)} opens at the proportional default (~470, not 380)`, near(m.paneW, 470), m)
    ok(`2 1440: ${id.slice(0, 8)} title is whole (one line, full title on hover)`, fits(m), m)
    await shot(p, `1-1440-${id.slice(0, 8)}`)
  }

  /* ---- 3. 1920 follows the window --------------------------------------- */
  await load(p, srv.base, 1920, 1080, null)
  await openTopic(p, ROOTS[0])
  const wide = await measure(p)
  ok('3 1920: the default is ~662', near(wide.paneW, 662), wide)
  ok('3 1920: the title is whole (one line, full title on hover)', fits(wide), wide)
  await shot(p, '3-1920')

  /* ---- 4. a stored (dragged) width wins --------------------------------- */
  await load(p, srv.base, 1440, 900, { sidebar: 260, topic: 400 })
  await openTopic(p, ROOTS[0])
  const kept = await measure(p)
  ok('4 1440: a stored topic width of 400 wins over the default', near(kept.paneW, 400), kept)
  await shot(p, '4-stored')

  /* ---- 5. T011: one-row header, labelled controls ------------------------ */
  await load(p, srv.base, 1440, 900, null)
  for (const id of ROOTS) {
    await openTopic(p, id)
    const hd = await header(p)
    ok(`5 1440: ${id.slice(0, 8)} header is one row <= 48 px, the title one line (T011)`, hd.headerH > 0 && hd.headerH <= 48 && hd.lines === 1, hd)
    ok(`5 1440: ${id.slice(0, 8)} every header control has an accessible name (T011)`, hd.controls >= 2 && hd.unnamed.length === 0 && hd.radios > 0 && hd.unnamedRadios === 0, hd)
  }
  await shot(p, '5-header')

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-pane-title-fits: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
