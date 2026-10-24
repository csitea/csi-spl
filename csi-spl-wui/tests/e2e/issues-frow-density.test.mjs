// Issues multi-select row 07 (plan issues-multiselect-panel-plan.md 3.6 and
// 7.1; owner t1 0f67a177 "Issues UI professional") in a real browser on the
// mock tenant.
//
// At 1280x800 every control in the sheet's filter row (.issues-frow: Status,
// Priority, Level, Assignee, Label, the deadline field and its calendar
// button) is one height, 36 px (+-1; the plan measured 34 px x5, 24 and 44),
// their drop-down arrows on one line, and the header select-all box starts
// within 1 px of a row box. At 412x915 the phone shows no sheet, no sideways
// scroll, and its controls keep their 44 px tap targets.
//
//   pnpm run test:e2e issues-frow-density
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-frow-density
//   SHOT_DIR=<dir> SHOT_TAG=<before|after> ... also writes the 1280 / 412
//   captures, dark and light, as .png
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { printPageLog, retryOnNetworkChanged, watchPage } from './lib/page-log.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const SHOT_TAG = process.env.SHOT_TAG || 'run'

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

async function shots(p, name) {
  if (!SHOT_DIR) return
  for (const scheme of ['light', 'dark']) {
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }])
    await p.evaluate((s) => { document.documentElement.dataset.theme = s }, scheme)
    await new Promise((r) => setTimeout(r, 150))
    await p.screenshot({ path: join(SHOT_DIR, `r07-${SHOT_TAG}-${name}-${scheme}.png`) })
  }
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }])
}

const server = await startServer()
const browser = await launch()
try {
  const p = watchPage(await browser.newPage(), 'issues-frow-density')

  /* ---- 1280x800: the desktop sheet ---- */
  const desk = { width: 1280, height: 800 }
  await openIssues(p, desk)
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', 'Filter row density')
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-test=issues-row] input.issues-check', { visible: true, timeout: 5000 })

  const d = await p.evaluate(() => {
    const row = document.querySelector('.issues-frow')
    const ctl = []
    for (const el of row.querySelectorAll('select, button, input:not([type=checkbox])')) {
      const r = el.getBoundingClientRect()
      if (!r.width || !r.height || getComputedStyle(el).visibility === 'hidden') continue
      ctl.push({ id: el.getAttribute('data-test') || el.className || el.tagName, h: +r.height.toFixed(1), top: +r.top.toFixed(1), arrowY: getComputedStyle(el).backgroundPositionY })
    }
    const head = document.querySelector('[data-test=issues-select-page]').getBoundingClientRect()
    const box = document.querySelector('[data-test=issues-row] input.issues-check').getBoundingClientRect()
    return { ctl, headLeft: +head.left.toFixed(1), rowLeft: +box.left.toFixed(1) }
  })
  const off = d.ctl.filter((c) => Math.abs(c.h - 36) > 1)
  ok('1 1280: the filter row shows its 7 controls', d.ctl.length >= 7, d.ctl.map((c) => c.id))
  ok('2 1280: every .issues-frow control is 36 px tall (+-1)', d.ctl.length > 0 && off.length === 0, off.length ? off : d.ctl.map((c) => c.h))
  const tops = d.ctl.map((c) => c.top)
  ok('3 1280: the controls share one top edge (+-1 px)', Math.max(...tops) - Math.min(...tops) <= 1, tops)
  const sel = d.ctl.filter((c) => /issues-filter-(status-btn|priority|level|label)/.test(c.id))
  ok('4 1280: the drop-down arrows sit at one height', sel.length === 4 && new Set(sel.map((c) => c.arrowY)).size === 1, sel.map((c) => c.arrowY))
  ok('5 1280: the select-all box starts within 1 px of a row box', Math.abs(d.headLeft - d.rowLeft) <= 1, { head: d.headLeft, row: d.rowLeft })
  await shots(p, '1280x800')

  /* ---- 412x915: the phone, unchanged ---- */
  const phone = { width: 412, height: 915 }
  await openIssues(p, phone)
  await p.waitForSelector('[data-test=issues-mbar]', { visible: true, timeout: 10000 })
  const m = await p.evaluate(() => {
    const small = []
    for (const el of document.querySelectorAll('[data-test=issues-mbar] button, [data-test=issues-mbar] input, [data-test=issues-mbar] select')) {
      const r = el.getBoundingClientRect()
      if (r.width && r.height && (r.width < 43.5 || r.height < 43.5)) small.push(`${el.getAttribute('data-test') || el.tagName} ${Math.round(r.width)}x${Math.round(r.height)}`)
    }
    const frow = document.querySelector('.issues-frow')
    return {
      x: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      small,
      sheet: !!frow && frow.getBoundingClientRect().height > 0,
    }
  })
  ok('6 412: no horizontal page scroll', m.x <= 0, m.x)
  ok('7 412: the phone bar controls stay >= 44 px', m.small.length === 0, m.small)
  ok('8 412: the phone shows no desktop filter row', !m.sheet, m)
  await shots(p, '412x915')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nissues-frow-density: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
