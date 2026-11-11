// SPL-5336 (owner HUM-10, t1 b3ed7ef5 msg f3a2b854): "The icons of the docs
// must s have ghe docs txt". The phone strip named Messages and Archive under
// their icons and left Docs an icon alone; the docs link now carries its word
// (docs.title) on phone and desktop, in the tabs' label style.
//
//   phone 390x844 (hasTouch), every locale:
//     1 the docs link of the strip shows its word, docs.title of that locale,
//       visible; not clipped in en, an ellipsis where a locale's word is longer
//     2 the same place and style as a named tab: the word under the icon,
//       the tab label's font size, the control as tall as a tab
//   desktop 1440x900, every locale:
//     3 the docs link of the rail shows its word, visible; not clipped in en,
//       an ellipsis where a locale's word is longer
//     4 the label style of the tabs under "Show labels" (main.css): its font
//       size, the word under the icon
//
// Why "not clipped" is en only (dispatch holder, SPL-5336 option 1): measured
// on the mock bundle, n=1 per locale, DejaVu Sans pinned, docs.title clips in
// 16/19 locales on the 390 px strip (61 px slot) and 17/19 on the 43 px
// desktop rail; the strip's own tab labels already clip, with the same
// ellipsis, in 17/19. The docs word follows the tabs; no short key.
//
// The whole-icons rule of the strip (SPL-2062) is mobile-rail-whole-icons.
//
// Run:
//   pnpm run test:e2e rail-docs-label
//   BASE_URL=<generated bundle> pnpm run test:e2e rail-docs-label   # what CI does
//   SHOTS=<dir> ... also writes en screenshots at 390 and 1440 px
import { createRequire } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { readFileSync, readdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const STRIP = '[data-testid=sidebar-rail]'
/* the real strip's docs link, never an endless-strip copy */
const DOCS = `${STRIP} > [data-testid=qto-open]`
const LOCALES_DIR = join(dirname(fileURLToPath(import.meta.url)), '../../i18n/locales')
const WORDS = Object.fromEntries(readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json')).sort()
  .map((f) => [f.replace(/\.json$/, ''), JSON.parse(readFileSync(join(LOCALES_DIR, f), 'utf8')).docs.title]))

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* a fresh context per page: the chosen locale outlives a navigation (en
   after el read Greek), so each locale starts with empty storage */
async function newPage(browser, vp) {
  const p = await (await browser.createBrowserContext()).newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  p.__errors = errors
  await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
  await p.setViewport(vp)
  return p
}

async function open(p, base, code) {
  await p.goto(`${base}${code === 'en' ? '' : '/' + code}/`, { waitUntil: 'networkidle2' })
  await p.waitForSelector(STRIP, { visible: true })
  await p.waitForSelector(DOCS)
  await sleep(400)
}

/* the docs link and the first named tab: their boxes and label boxes */
function measure([docsSel, strip]) {
  const box = (el) => { const r = el.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, h: r.height } }
  const docs = document.querySelector(docsSel)
  const label = docs?.querySelector('.sidebar-tab__label') ?? null
  const svg = docs?.querySelector('svg') ?? null
  const tab = document.querySelector(`${strip} [role=tab]:not([aria-selected=true])`)
  const tabLabel = tab?.querySelector('.sidebar-tab__label') ?? null
  const cs = label ? getComputedStyle(label) : null
  return {
    text: label ? label.textContent.trim() : null,
    shown: !!label && cs.display !== 'none' && cs.visibility !== 'hidden' && label.getBoundingClientRect().height > 0,
    clipped: label ? label.scrollWidth > label.clientWidth : null,
    ellipsis: cs?.textOverflow === 'ellipsis' && cs?.whiteSpace === 'nowrap',
    sw: label?.scrollWidth ?? null,
    cw: label?.clientWidth ?? null,
    font: cs?.fontSize ?? null,
    tabFont: tabLabel ? getComputedStyle(tabLabel).fontSize : null,
    below: !!label && !!svg && label.getBoundingClientRect().top >= svg.getBoundingClientRect().bottom - 1,
    inside: !!label && label.getBoundingClientRect().left >= docs.getBoundingClientRect().left - 0.5 && label.getBoundingClientRect().right <= docs.getBoundingClientRect().right + 0.5,
    docs: docs ? box(docs) : null,
    tab: tab ? box(tab) : null,
  }
}

const srv = await startServer()
const browser = await launch()
try {
  /* phone: every locale */
  const phoneBad = []
  const phoneErrors = []
  for (const [code, word] of Object.entries(WORDS)) {
    const p = await newPage(browser, { width: 390, height: 844, isMobile: true, hasTouch: true })
    await open(p, srv.base, code)
    const m = await p.evaluate(measure, [DOCS, STRIP])
    const good = m.text === word && m.shown && (!m.clipped || m.ellipsis) && m.below && m.inside
      && m.font === m.tabFont && Math.abs(m.docs.h - m.tab.h) <= 1
    if (!good) phoneBad.push({ code, word, ...m })
    if (code === 'en') {
      ok('390 1 en: the docs link shows "Docs" under its icon, not clipped', m.text === word && m.shown && !m.clipped && m.below, m)
      ok('390 2 en: the tab label font size, the control as tall as a tab', m.font === m.tabFont && Math.abs(m.docs.h - m.tab.h) <= 1, m)
      if (SHOTS) {
        await p.$eval(DOCS, (e) => e.scrollIntoView({ inline: 'center' }))
        await sleep(600)
        await p.screenshot({ path: join(SHOTS, 'rail-docs-label-390.png') })
      }
    }
    phoneErrors.push(...p.__errors)
    await p.browserContext().close()
  }
  ok(`390 1+2 every locale (${Object.keys(WORDS).length}): its word, shown, an ellipsis if longer, in the tab style`, phoneBad.length === 0, phoneBad)
  ok('390 no page error', phoneErrors.length === 0, phoneErrors)

  /* desktop: every locale */
  const deskBad = []
  const deskErrors = []
  for (const [code, word] of Object.entries(WORDS)) {
    const d = await newPage(browser, { width: 1440, height: 900 })
    await open(d, srv.base, code)
    const m = await d.evaluate(measure, [DOCS, STRIP])
    /* the tabs' "Show labels" style, read off a tab with the class on */
    const labelsFont = await d.evaluate((strip) => {
      const html = document.documentElement
      const had = html.classList.contains('rail-labels')
      html.classList.add('rail-labels')
      const l = document.querySelector(`${strip} [role=tab] .sidebar-tab__label`)
      const f = l ? getComputedStyle(l).fontSize : null
      if (!had) html.classList.remove('rail-labels')
      return f
    }, STRIP)
    const good = m.text === word && m.shown && (!m.clipped || m.ellipsis) && m.below && m.inside && m.font === labelsFont
    if (!good) deskBad.push({ code, word, labelsFont, ...m })
    if (code === 'en') {
      ok('1440 3 en: the docs link shows "Docs" under its icon, not clipped', m.text === word && m.shown && !m.clipped && m.below && m.inside, m)
      ok('1440 4 en: the font size of the tabs under "Show labels"', m.font === labelsFont, { font: m.font, labelsFont })
      if (SHOTS) await d.screenshot({ path: join(SHOTS, 'rail-docs-label-1440.png'), clip: { x: 0, y: 0, width: 400, height: 900 } })
    }
    deskErrors.push(...d.__errors)
    await d.browserContext().close()
  }
  ok(`1440 3+4 every locale (${Object.keys(WORDS).length}): its word, shown, an ellipsis if longer, in the labels style`, deskBad.length === 0, deskBad)
  ok('1440 no page error', deskErrors.length === 0, deskErrors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((x) => !x.ok)
console.log(`\nrail-docs-label: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
