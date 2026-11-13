// SPL-5429 (owner HUM-10, t1 6407fdbe msgs 958f78cd, f6230e89, 7b053f63):
// "There should be a label "Settings" below the icon of the active one",
// "this label should be translated into all of the languages", "And the same
// for the internal help, so it should be just called help." Help and the gear
// carry their word under the icon as the docs link does (SPL-5336,
// rail-docs-label): help.title and sidebar.settings, a short key, since
// tenant_settings.title ("Workspace settings") is too long for the strip.
//
//   phone 390x844 (hasTouch), every locale, Help and the gear:
//     1 the control of the strip shows its word, that locale's, visible; not
//       clipped in en, an ellipsis where a locale's word is longer
//     2 the same place and style as a named tab: the word under the icon,
//       the tab label's font size, the control as tall as a tab
//   desktop 1440x900, every locale, Help and the gear:
//     3 the control of the rail shows its word, visible; an ellipsis where
//       the word is longer than the 43 px rail ("Settings" in en, labels off)
//     4 the label style of the tabs under "Show labels" (main.css)
//   desktop 1440x900, en, "Show labels" off and on:
//     5 Help, the docs link and the gear stay squares of one size
//     6 with "Show labels" on (71 px), "Help" and "Settings" are not clipped
//
// Run:
//   pnpm run test:e2e rail-help-settings-label
//   BASE_URL=<generated bundle> pnpm run test:e2e rail-help-settings-label   # what CI does
//   SHOTS=<dir> ... also writes en and ru screenshots at 390 px
import { createRequire } from 'node:module'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { readFileSync, readdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const STRIP = '[data-testid=sidebar-rail]'
/* the real strip's controls, never an endless-strip copy */
const CONTROLS = [
  { name: 'Help', sel: `${STRIP} > [data-testid=help-open]`, word: (j) => j.help.title },
  { name: 'Settings', sel: `${STRIP} > [data-testid=tenant-settings-open]`, word: (j) => j.sidebar.settings },
]
const DOCS = `${STRIP} > [data-testid=qto-open]`
const LOCALES_DIR = join(dirname(fileURLToPath(import.meta.url)), '../../i18n/locales')
const LOCALES = Object.fromEntries(readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json')).sort()
  .map((f) => [f.replace(/\.json$/, ''), JSON.parse(readFileSync(join(LOCALES_DIR, f), 'utf8'))]))

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

/* a fresh context per page: the chosen locale outlives a navigation */
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
  for (const c of CONTROLS) await p.waitForSelector(c.sel)
  await sleep(400)
}

/* a control and the first unselected named tab: boxes and label boxes */
function measure([sel, strip]) {
  const box = (el) => { const r = el.getBoundingClientRect(); return { w: r.width, h: r.height } }
  const el = document.querySelector(sel)
  const label = el?.querySelector('.sidebar-tab__label') ?? null
  const svg = el?.querySelector('svg') ?? null
  const tab = document.querySelector(`${strip} [role=tab]:not([aria-selected=true])`)
  const tabLabel = tab?.querySelector('.sidebar-tab__label') ?? null
  const cs = label ? getComputedStyle(label) : null
  return {
    text: label ? label.textContent.trim() : null,
    shown: !!label && cs.display !== 'none' && cs.visibility !== 'hidden' && label.getBoundingClientRect().height > 0,
    clipped: label ? label.scrollWidth > label.clientWidth : null,
    ellipsis: cs?.textOverflow === 'ellipsis' && cs?.whiteSpace === 'nowrap',
    font: cs?.fontSize ?? null,
    tabFont: tabLabel ? getComputedStyle(tabLabel).fontSize : null,
    below: !!label && !!svg && label.getBoundingClientRect().top >= svg.getBoundingClientRect().bottom - 1,
    inside: !!label && label.getBoundingClientRect().left >= el.getBoundingClientRect().left - 0.5 && label.getBoundingClientRect().right <= el.getBoundingClientRect().right + 0.5,
    el: el ? box(el) : null,
    tab: tab ? box(tab) : null,
  }
}

const srv = await startServer()
const browser = await launch()
try {
  /* phone: every locale */
  const phoneBad = []
  const phoneErrors = []
  for (const [code, json] of Object.entries(LOCALES)) {
    const p = await newPage(browser, { width: 390, height: 844, isMobile: true, hasTouch: true })
    await open(p, srv.base, code)
    for (const c of CONTROLS) {
      const word = c.word(json)
      const m = await p.evaluate(measure, [c.sel, STRIP])
      const good = m.text === word && m.shown && (!m.clipped || m.ellipsis) && m.below && m.inside
        && m.font === m.tabFont && Math.abs(m.el.h - m.tab.h) <= 1
      if (!good) phoneBad.push({ code, control: c.name, word, ...m })
      if (code === 'en' || code === 'ru') {
        ok(`390 1 ${code}: ${c.name} shows "${word}" under its icon${code === 'en' ? ', not clipped' : ''}`, m.text === word && m.shown && (code !== 'en' || !m.clipped) && m.below, m)
        ok(`390 2 ${code}: ${c.name} has the tab label font size and is as tall as a tab`, m.font === m.tabFont && Math.abs(m.el.h - m.tab.h) <= 1, m)
      }
    }
    if (SHOTS && (code === 'en' || code === 'ru')) {
      await p.$eval(CONTROLS[0].sel, (e) => e.scrollIntoView({ inline: 'center' }))
      await sleep(600)
      await p.screenshot({ path: join(SHOTS, `rail-help-settings-label-390-${code}.png`) })
    }
    phoneErrors.push(...p.__errors)
    await p.browserContext().close()
  }
  ok(`390 1+2 every locale (${Object.keys(LOCALES).length}): Help and the gear show their word, an ellipsis if longer, in the tab style`, phoneBad.length === 0, phoneBad)
  ok('390 no page error', phoneErrors.length === 0, phoneErrors)

  /* desktop: every locale */
  const deskBad = []
  const deskErrors = []
  for (const [code, json] of Object.entries(LOCALES)) {
    const d = await newPage(browser, { width: 1440, height: 900 })
    await open(d, srv.base, code)
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
    for (const c of CONTROLS) {
      const word = c.word(json)
      const m = await d.evaluate(measure, [c.sel, STRIP])
      const good = m.text === word && m.shown && (!m.clipped || m.ellipsis) && m.below && m.inside && m.font === labelsFont
      if (!good) deskBad.push({ code, control: c.name, word, labelsFont, ...m })
      if (code === 'en' || code === 'ru') {
        ok(`1440 3 ${code}: ${c.name} shows "${word}" under its icon`, m.text === word && m.shown && (!m.clipped || m.ellipsis) && m.below && m.inside, m)
        ok(`1440 4 ${code}: ${c.name} has the font size of the tabs under "Show labels"`, m.font === labelsFont, { font: m.font, labelsFont })
      }
    }
    deskErrors.push(...d.__errors)
    await d.browserContext().close()
  }
  /* 5: Help, docs and the gear are squares of one size, labels off and on */
  {
    const d = await newPage(browser, { width: 1440, height: 900 })
    await open(d, srv.base, 'en')
    for (const labels of [false, true]) {
      const m = await d.evaluate(async ([sels, on]) => {
        document.documentElement.classList.toggle('rail-labels', on)
        await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
        return sels.map((sel) => { const r = document.querySelector(sel)?.getBoundingClientRect(); return r ? { w: r.width, h: r.height } : null })
      }, [[...CONTROLS.map((c) => c.sel), DOCS], labels])
      const ref = m[0]
      const square = m.every((b) => !!b && Math.abs(b.w - b.h) <= 1 && Math.abs(b.w - ref.w) <= 1 && Math.abs(b.h - ref.h) <= 1)
      ok(`1440 5 en, Show labels ${labels ? 'on' : 'off'}: Help, the gear and docs are squares of one size`, square, m)
      if (labels) {
        const clipped = await d.evaluate((sels) => sels.map((sel) => { const l = document.querySelector(`${sel} .sidebar-tab__label`); return l ? l.scrollWidth > l.clientWidth : null }), CONTROLS.map((c) => c.sel))
        ok('1440 6 en, Show labels on: "Help" and "Settings" are not clipped', clipped.every((x) => x === false), clipped)
      }
    }
    deskErrors.push(...d.__errors)
    await d.browserContext().close()
  }
  ok(`1440 3+4 every locale (${Object.keys(LOCALES).length}): Help and the gear show their word, an ellipsis if longer, in the labels style`, deskBad.length === 0, deskBad)
  ok('1440 no page error', deskErrors.length === 0, deskErrors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((x) => !x.ok)
console.log(`\nrail-help-settings-label: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
