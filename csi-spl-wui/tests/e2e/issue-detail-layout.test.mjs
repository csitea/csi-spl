// issues-06 (SPL-3072, plan issues-multiselect-panel-plan.md row 06): the open
// issue's property panel is a grid - every label on one left edge, every value
// on one left edge and inside its column (no horizontal overflow), 12 px
// between rows - and the created / updated lines start on the value edge. The
// title sits above the description, the panel below it on a phone and beside
// it on a desktop. A phone keeps 44 px controls and no sideways scroll. Light
// and dark, at 412x915 and 1280x800. The source half is
// tests/unit/issue-detail-layout.test.mjs.
//
//   pnpm run test:e2e issue-detail-layout
//   BASE_URL=<generated bundle> pnpm run test:e2e issue-detail-layout
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, setPageViewport, applyViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const VIEWPORTS = [{ width: 412, height: 915 }, { width: 1280, height: 800 }]
const THEMES = ['light', 'dark']
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

/* a new issue, opened: > 820 px the new top row then its key cell; a phone the
   FAB's full-screen form, which stays open on the created issue */
async function openNewIssue(p, W, title) {
  await p.click('[data-test=issues-new]')
  if (W <= 820) {
    await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-detail-title]', title)
    await p.click('[data-test=issues-create]')
    await p.waitForFunction(() => /^SPL-\d+$/.test(document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''), { timeout: 5000 })
  } else {
    await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-newrow-title]', title)
    await p.keyboard.press('Enter')
    const key = await p.waitForFunction((want) => {
      const row = [...document.querySelectorAll('[data-test=issues-row]')].find((r) => r.querySelector('.issues-title')?.textContent.trim() === want)
      return !document.querySelector('[data-test=issues-newrow]') && row ? row.getAttribute('data-key') : false
    }, { timeout: 5000 }, title).then((h) => h.jsonValue())
    await p.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
  }
  /* wait for the created/updated lines: they come with the stored issue */
  await p.waitForSelector('[data-test=issues-detail] .issues-detail-meta', { visible: true, timeout: 5000 })
}

/* the pane as laid out: each property row's label and value boxes, the meta
   lines, the title/description/panel boxes, overflow and tap sizes */
const measure = (p) => p.evaluate(() => {
  const r = (el) => { const b = el.getBoundingClientRect(); return { l: b.left, r: b.right, t: b.top, b: b.bottom, w: b.width, h: b.height } }
  const rows = [...document.querySelectorAll('[data-test=issues-props] > .issues-prow')].filter((el) => el.offsetParent !== null)
  const props = rows.map((row) => {
    const k = row.querySelector(':scope > .issues-prow__k')
    const v = row.children[1]
    return { k: r(k), v: r(v), row: r(row), vOverflow: v.scrollWidth - v.clientWidth }
  })
  const gaps = props.slice(1).map((x, i) => Math.round((x.row.t - props[i].row.b) * 10) / 10)
  const meta = [...document.querySelectorAll('.issues-detail-meta .issues-meta')].map((el) => r(el).l)
  const title = document.querySelector('[data-test=issues-detail-title]')
  const desc = document.querySelector('[data-test=issues-detail] .issues-detail-desc')
  const panel = document.querySelector('[data-test=issues-props]')
  const taps = [...panel.querySelectorAll('button.issues-pctl, select.issues-pctl')].filter((el) => el.offsetParent !== null).map((el) => [Math.round(r(el).w), Math.round(r(el).h)])
  const cs = getComputedStyle(document.querySelector('.issues-prow__k'))
  return {
    n: props.length,
    kLefts: [...new Set(props.map((x) => Math.round(x.k.l)))],
    vLefts: [...new Set(props.map((x) => Math.round(x.v.l)))],
    kWidths: [...new Set(props.map((x) => Math.round(x.k.w)))],
    vOverflow: Math.max(...props.map((x) => x.vOverflow)),
    vPastRow: Math.max(...props.map((x) => Math.round(x.v.r - x.row.r))),
    gaps,
    meta: meta.map(Math.round),
    titleTop: r(title).t, descTop: r(desc).t, panelTop: r(panel).t, panelLeft: r(panel).l, descRight: r(desc).r,
    titlePx: parseFloat(getComputedStyle(title).fontSize), labelPx: parseFloat(cs.fontSize),
    titleH: Math.round(r(title).h),
    /* where the title's text starts (box + border + padding) vs the description's label */
    titleText: Math.round(r(title).l + parseFloat(getComputedStyle(title).borderLeftWidth) + parseFloat(getComputedStyle(title).paddingLeft)),
    descLabel: Math.round(r(desc.querySelector('.issue-desc__label')).l),
    taps,
    xScroll: document.documentElement.scrollWidth > window.innerWidth,
    labelColor: cs.color, bg: getComputedStyle(document.body).backgroundColor,
  }
})

/* WCAG relative luminance contrast of two rgb() colours (label on the page) */
function contrast(a, b) {
  const lum = (s) => {
    const [r, g, bl] = (s.match(/[\d.]+/g) || []).slice(0, 3).map(Number).map((c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4 })
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl
  }
  const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m)
  return Math.round(((x + 0.05) / (y + 0.05)) * 100) / 100
}

const shot = process.env.SHOT_DIR || mkdtempSync(join(tmpdir(), 'spl-e2e-'))
const server = await startServer()
const browser = await launch()
try {
  for (const theme of THEMES) {
    for (const vp of VIEWPORTS) {
      const W = vp.width
      const tag = `${W}x${vp.height} ${theme}`
      console.log(`-- ${tag}`)
      const p = await browser.newPage()
      await setPageViewport(p, vp)
      await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
      const errors = []
      p.on('pageerror', (e) => errors.push(String(e && e.message)))
      await p.evaluateOnNewDocument((t) => {
        try {
          localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' }))
          localStorage.setItem('spool-theme', t)
        } catch { /* private mode */ }
      }, theme)
      await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, vp)
      await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
      await openNewIssue(p, W, `layout ${W} ${theme}`)
      await new Promise((res) => setTimeout(res, 300))
      const m = await measure(p)
      await p.screenshot({ path: `${shot}/issues-06-detail-${W}x${vp.height}-${theme}.png` })

      ok(`1 ${tag}: every property label on one left edge, one width`, m.n >= 5 && m.kLefts.length === 1 && m.kWidths.length === 1, { n: m.n, kLefts: m.kLefts, kWidths: m.kWidths })
      ok(`2 ${tag}: every value on one left edge, no horizontal overflow`, m.vLefts.length === 1 && m.vOverflow <= 1 && m.vPastRow <= 1, { vLefts: m.vLefts, vOverflow: m.vOverflow, vPastRow: m.vPastRow })
      ok(`3 ${tag}: 12 px between the property rows`, m.gaps.length > 0 && m.gaps.every((g) => Math.abs(g - 12) <= 0.5), m.gaps)
      ok(`4 ${tag}: created / updated lines start on the value edge`, m.meta.length > 0 && m.meta.every((l) => Math.abs(l - m.vLefts[0]) <= 1), { meta: m.meta, v: m.vLefts[0] })
      const order = W <= 820 ? m.titleTop < m.descTop && m.descTop < m.panelTop : m.titleTop < m.descTop && m.panelLeft >= m.descRight
      ok(`5 ${tag}: title, then description, then the panel (${W <= 820 ? 'below' : 'beside'}); the title outranks the labels`, order && m.titlePx >= 20 && m.titlePx > m.labelPx, { titleTop: m.titleTop, descTop: m.descTop, panelTop: m.panelTop, titlePx: m.titlePx, labelPx: m.labelPx })
      ok(`6 ${tag}: no sideways scroll`, !m.xScroll)
      ok(`10 ${tag}: the title's text starts on the description label's edge`, Math.abs(m.titleText - m.descLabel) <= 1, { titleText: m.titleText, descLabel: m.descLabel })
      if (W <= 820) ok(`7 ${tag}: title and property controls are >= 44 px tall`, m.titleH >= 44 && m.taps.every(([, h]) => h >= 44), { titleH: m.titleH, taps: m.taps })
      const c = contrast(m.labelColor, m.bg)
      ok(`8 ${tag}: labels readable on the page (contrast >= 3)`, c >= 3, { c, label: m.labelColor, bg: m.bg })
      const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
      ok(`9 ${tag}: no page errors`, mine.length === 0, mine)
      await p.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed (shots: ${shot})`)
process.exit(failed.length ? 1 : 0)
