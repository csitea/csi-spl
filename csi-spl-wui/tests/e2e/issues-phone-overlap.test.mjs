// SPL-3190 (owner HUM-10, t1 22e98a50 msg 623266f7: "There is a small overlap
// of the icons in this view."): the Issues view on a phone, a filter set, in
// fi (the longer strings) and en, at 360 and 412 px, measured by the boxes the
// eye sees, not by the tap targets:
//
//   1 Sort and Filter draw their square clear of the tab rail's bottom border
//     (>= 2 px; it was 0, the square's top edge on the rail's border)
//   2 ... and clear of the epic chips' pills under them (>= 1 px; the chip row
//     tucks 8 px under the bar, SPL-2527, and the squares covered 3 px of it)
//   3 the "sorted by" line ends before the Sort square
//   4 the composer's hint stops >= 4 px before the Search button (it was cut
//     mid-letter at the button's edge: Chrome draws no ellipsis on a
//     textarea's placeholder), and a hint that does not fit fades out
//   5 the targets stay 44 px, the filter dot sits inside the Filter square
//
//   pnpm run test:e2e issues-phone-overlap
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-phone-overlap
//   SHOTS=<dir> ... also writes a screenshot of each case there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { printPageLog, retryOnNetworkChanged, watchPage } from './lib/page-log.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
  if (!pass) printPageLog(name)
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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* every box as drawn: an element that draws itself on an absolute ::before
   (the chips; Sort and Filter since SPL-3190) is that ::before's box */
async function measure(p) {
  return p.evaluate(() => {
    const drawn = (el) => {
      const r = el.getBoundingClientRect()
      const b = getComputedStyle(el, '::before')
      const box = { t: r.top, b: r.bottom, l: r.left, r: r.right }
      if (b.content !== 'none' && b.position === 'absolute' && parseFloat(b.borderTopWidth) > 0) {
        box.t += parseFloat(b.top); box.b -= parseFloat(b.bottom); box.l += parseFloat(b.left); box.r -= parseFloat(b.right)
      }
      return box
    }
    const rail = document.querySelector('[data-testid=sidebar-rail]').getBoundingClientRect()
    const btns = ['issues-sort-open', 'issues-filters-open'].map((id) => document.querySelector(`[data-test=${id}]`))
    const sq = btns.map(drawn)
    const tap = btns.map((e) => { const r = e.getBoundingClientRect(); return Math.min(r.width, r.height) })
    const pills = [...document.querySelectorAll('[data-test=issues-epic-chip]')].map(drawn)
    const sorted = document.querySelector('[data-test=issues-sorted-by]').getBoundingClientRect()
    const dot = document.querySelector('[data-test=issues-filters-open] .issues-mbar__dot')?.getBoundingClientRect()
    const ta = document.querySelector('form.composer--dock textarea')
    const cs = getComputedStyle(ta)
    const tr = ta.getBoundingClientRect()
    const btn = document.querySelector('form.composer--dock [data-test=search-syntax-help]').getBoundingClientRect()
    const rtl = cs.direction === 'rtl'
    /* where the hint's text is cut: the text area's content edge */
    const textEnd = rtl ? tr.left + parseFloat(cs.borderLeftWidth) + parseFloat(cs.paddingLeft) : tr.right - parseFloat(cs.borderRightWidth) - parseFloat(cs.paddingRight)
    const ctx = document.createElement('canvas').getContext('2d')
    ctx.font = `${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`
    const room = tr.width - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight) - parseFloat(cs.borderLeftWidth) - parseFloat(cs.borderRightWidth)
    const r1 = (n) => Math.round(n * 10) / 10
    return {
      railGap: r1(Math.min(...sq.map((s) => s.t - rail.bottom))),
      pillGap: pills.length ? r1(Math.min(...pills.map((c) => c.t)) - Math.max(...sq.map((s) => s.b))) : null,
      pills: pills.length,
      sortedGap: r1(rtl ? sorted.left - sq[0].r : sq[0].l - sorted.right),
      tap: tap.map(r1),
      dotIn: !dot || (dot.top >= sq[1].t && dot.bottom <= sq[1].b && dot.left >= sq[1].l && dot.right <= sq[1].r),
      hintGap: r1(rtl ? textEnd - btn.right : btn.left - textEnd),
      hintFits: ctx.measureText(ta.placeholder).width <= room,
      fade: (cs.maskImage || cs.webkitMaskImage || 'none') !== 'none',
      shown: ta.matches(':placeholder-shown'),
    }
  })
}

const server = await startServer()
const browser = await launch()
try {
  const p = watchPage(await browser.newPage(), 'issues-phone-overlap')
  const errors = []
  const devNoise = (m) => !process.env.BASE_URL && /Failed to fetch dynamically imported module/.test(m)
  p.on('pageerror', (e) => { const m = String(e && e.message); if (!devNoise(m)) errors.push(m) })
  for (const lang of ['fi', 'en']) {
    for (const w of [360, 412]) {
      const vp = { width: w, height: 800 }
      const before = errors.length
      await retryOnNetworkChanged(`/${lang}/issues at ${w} px`, async () => {
        await setPageViewport(p, vp)
        await p.goto(server.base + (lang === 'en' ? '' : `/${lang}`) + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
        await applyViewport(p, vp)
        await p.waitForSelector('[data-test=issues-mbar]', { visible: true, timeout: NAV_TIMEOUT })
      }, { onRetry: () => errors.splice(before) })
      await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
      /* the owner's case: a filter set (the dot on Filter) */
      await p.click('[data-test=issues-filters-open]')
      await p.waitForSelector('[data-test=issues-filter-sheet]', { visible: true, timeout: 5000 })
      await p.select('[data-test=issues-filter-priority]', '1')
      await p.click('[data-test=issues-filter-sheet-close]')
      await p.waitForFunction(() => !document.querySelector('[data-test=issues-filter-sheet]'), { timeout: 5000 })
      await p.waitForSelector('form.composer--dock [data-test=search-syntax-help]', { visible: true, timeout: 10000 })
      await sleep(400)
      const m = await measure(p)
      const c = `${lang} ${w}`
      ok(`1 ${c}: Sort and Filter draw their square >= 2 px below the tab rail`, m.railGap >= 2, { railGap: m.railGap })
      ok(`2 ${c}: ... and >= 1 px above the epic chips' pills`, m.pills > 0 && m.pillGap >= 1, { pillGap: m.pillGap, pills: m.pills })
      ok(`3 ${c}: the "sorted by" line ends before the Sort square`, m.sortedGap >= 0, { sortedGap: m.sortedGap })
      ok(`4 ${c}: the composer hint stops >= 4 px before Search; a hint that does not fit fades out`, m.shown && m.hintGap >= 4 && (m.hintFits || m.fade), { hintGap: m.hintGap, hintFits: m.hintFits, fade: m.fade })
      ok(`5 ${c}: the targets stay >= 44 px; the filter dot is inside the Filter square`, m.tap.every((t) => t >= 43.5) && m.dotIn, { tap: m.tap, dotIn: m.dotIn })
      if (SHOTS) await p.screenshot({ path: join(SHOTS, `issues-phone-overlap-${lang}-${w}.png`) })
    }
  }
  ok('6 no page errors', errors.length === 0, errors.slice(0, 3))
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
