// Issues multi-select row 01 (plan issues-multiselect-panel-plan.md 7.1; owner
// HUM-10, t1 405e08ba msg 83a58259: "the select boxes should not be radio
// boxes, but they should be like checkboxes") in a real browser on the mock
// tenant.
//
// At 412x915 a card's box is a square (the 4 px --radius-xs corners, a 2 px
// border; the plan's 3 px is no token, and raw px radii are banned), not the
// 16 px circle the status glyph also draws; its 44x44 tap target stays and
// never covers the card's text; the phone header stack (sort/filter bar plus
// the epic chips) is at most 80 px tall, every control in it still >= 44 px.
// At 1280 px the table's row box is the native square and no phone bar shows.
//
//   pnpm run test:e2e issues-checkbox-header
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-checkbox-header
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { printPageLog, retryOnNetworkChanged, watchPage } from './lib/page-log.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
  if (!pass) printPageLog(name)
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

async function openIssues(p, vp) {
  await retryOnNetworkChanged(`/issues at ${vp.width} px`, async () => {
    await setPageViewport(p, vp)
    await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  })
  /* `nuxi dev` floats its devtools button over the bottom of a phone screen */
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
}

const server = await startServer()
const browser = await launch()
try {
  const p = watchPage(await browser.newPage(), 'issues-checkbox-header')

  /* ---- 412x915: the phone card list ---- */
  const phone = { width: 412, height: 915 }
  await openIssues(p, phone)
  /* the mock tenant's issues live in the page: make one the phone way */
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-detail-title]', 'Square checkbox card')
  await p.click('[data-test=issues-create]')
  await p.waitForFunction(() => /^SPL-\d+$/.test(document.querySelector('[data-test=issues-detail-key]')?.textContent.trim() || ''), { timeout: 5000 })
  await p.click('[data-test=issues-detail-back]')
  await p.waitForSelector('[data-test=issues-card]', { visible: true, timeout: 10000 })
  await p.waitForSelector('[data-test=issues-epic-chips]', { visible: true, timeout: 10000 })

  const m = await p.evaluate(() => {
    const input = document.querySelector('.issues-check--card input')
    const box = getComputedStyle(input, '::before')
    const ir = input.getBoundingClientRect()
    const card = input.closest('.issues-card-li').querySelector('[data-test=issues-card]')
    const cr = card.getBoundingClientRect()
    const hit = document.elementFromPoint(cr.left + 50, cr.top + 22)
    const bar = document.querySelector('[data-test=issues-mbar]').getBoundingClientRect()
    const chips = document.querySelector('[data-test=issues-epic-chips]').getBoundingClientRect()
    const small = []
    for (const el of document.querySelectorAll('[data-test=issues-mbar] button, [data-test=issues-mbar] input, [data-test=issues-epic-chips] button')) {
      const r = el.getBoundingClientRect()
      if (r.width && r.height && (r.width < 43.5 || r.height < 43.5)) small.push(`${el.getAttribute('data-test') || el.tagName} ${Math.round(r.width)}x${Math.round(r.height)}`)
    }
    return {
      radius: box.borderTopLeftRadius,
      border: box.borderTopWidth,
      tap: [Math.round(ir.width), Math.round(ir.height)],
      textHitIsBox: hit === input || !!hit?.closest('.issues-check--card'),
      stack: Math.round(chips.bottom - bar.top),
      bar: Math.round(bar.height),
      chips: Math.round(chips.height),
      small,
    }
  })
  ok('1 412: the card box is a square (4 px --radius-xs corners), not a 16 px circle', m.radius === '4px', m)
  ok('2 412: the card box has a 2 px border', m.border === '2px', m)
  ok('3 412: the card box keeps its 44x44 tap target', m.tap[0] >= 44 && m.tap[1] >= 44, m.tap)
  ok('4 412: a tap on the card text 50 px in is not the box', !m.textHitIsBox, m)
  ok('5 412: the header stack (bar + epic chips) is <= 80 px', m.stack > 0 && m.stack <= 80, { stack: m.stack, bar: m.bar, chips: m.chips })
  ok('6 412: every control in the header stack stays >= 44 px', m.small.length === 0, m.small)
  const x = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  ok('7 412: no horizontal page scroll', x <= 0, x)

  /* ---- 1280x800: the desktop table, unchanged ---- */
  const desk = { width: 1280, height: 800 }
  await openIssues(p, desk)
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', 'Desktop row box')
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-test=issues-row] input.issues-check', { visible: true, timeout: 5000 })
  const d = await p.evaluate(() => {
    const input = document.querySelector('[data-test=issues-row] input.issues-check')
    const r = input.getBoundingClientRect()
    return { size: [Math.round(r.width), Math.round(r.height)], appearance: getComputedStyle(input).appearance, bar: !!document.querySelector('[data-test=issues-mbar]') }
  })
  ok('8 1280: the row box is the native 16 px checkbox, no phone bar', d.size[0] === 16 && d.size[1] === 16 && d.appearance !== 'none' && !d.bar, d)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nissues-checkbox-header: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
