// E14 (perf edition 20261004, the W4 remainder): the top-bar tenant drop box
// forces no layout at mount, on the desktop either, and is not in a phone's
// DOM at all.
//   - Every computed-font read of the tenant select (measureControlText's
//     getComputedStyle) runs inside a ResizeObserver callback, i.e. after the
//     frame's own layout and before its paint. A read at mount (onMounted,
//     nextTick) found style + layout dirty and forced them: one forced style
//     recalc + layout per load on / and on /issues at d1440 (trace census n=5).
//   - The measured width is applied (the select carries an inline width).
//   - At <= 820 px the top bar does not mount the box (TopBarTenant is the
//     phone's switcher): 0 `.tenant-drop` elements instead of 18 hidden ones.
//     Widening the same page mounts and measures it, still inside the observer.
//
// Run:
//   pnpm run test:e2e tenant-measure-no-forced-layout
//   BASE_URL=<generated bundle> pnpm run test:e2e tenant-measure-no-forced-layout
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { setPageViewport, applyViewport, CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const DESKTOP = { name: '1440x900', width: 1440, height: 900 }
/* width only: flipping isMobile / hasTouch would make puppeteer reload the page */
const PHONE = { name: '390x844', width: 390, height: 844 }
const SELECT = '[data-testid=tenant-switcher-select]'

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* before any app script: note, for every getComputedStyle of the tenant
   select, whether a ResizeObserver callback is on the stack */
function instrument(selector) {
  const log = { reads: 0, outside: 0 }
  window.__e14 = log
  let depth = 0
  const RO = window.ResizeObserver
  window.ResizeObserver = class extends RO {
    constructor(cb) {
      super(function (entries, ro) {
        depth++
        try { return cb.call(this, entries, ro) } finally { depth-- }
      })
    }
  }
  const gcs = window.getComputedStyle
  window.getComputedStyle = function (el, pseudo) {
    if (el instanceof Element && el.matches(selector)) {
      log.reads++
      if (depth === 0) log.outside++
    }
    return gcs.call(window, el, pseudo)
  }
}

async function load(browser, vp, path) {
  const p = await browser.newPage()
  await p.evaluateOnNewDocument(instrument, SELECT)
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  return p
}

const settle = (p) => p.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r()))))

async function measured(p) {
  await p.waitForSelector(SELECT, { timeout: NAV_TIMEOUT })
  await p.waitForFunction((sel) => {
    const el = document.querySelector(sel)
    return el instanceof HTMLElement && parseFloat(el.style.width) > 0
  }, { timeout: NAV_TIMEOUT }, SELECT).catch(() => null)
  await settle(p)
  return p.evaluate((sel) => {
    const el = document.querySelector(sel)
    return { ...window.__e14, width: el instanceof HTMLElement ? el.style.width : null }
  }, SELECT)
}

const server = await startServer()
const browser = await launch()
try {
  for (const path of ['/', '/issues']) {
    const p = await load(browser, DESKTOP, path)
    const got = await measured(p)
    ok(`${DESKTOP.name} ${path}: the select is measured and its width applied`, got.reads > 0 && parseFloat(got.width) > 0, got)
    ok(`${DESKTOP.name} ${path}: every computed-font read runs in a ResizeObserver callback (no forced layout)`, got.reads > 0 && got.outside === 0, got)
    await p.close()
  }

  const p = await load(browser, PHONE, '/')
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  await settle(p)
  const phone = await p.evaluate(() => ({
    drop: document.querySelectorAll('[data-test=top-bar] .tenant-drop').length,
    els: document.querySelectorAll('[data-test=top-bar] .tenant-drop, [data-test=top-bar] .tenant-drop *').length,
    reads: window.__e14.reads,
  }))
  ok(`${PHONE.name} /: the top bar does not mount the desktop drop box`, phone.drop === 0 && phone.els === 0, phone)
  ok(`${PHONE.name} /: nothing is measured`, phone.reads === 0, phone)
  await applyViewport(p, DESKTOP)
  const wide = await measured(p)
  ok(`${PHONE.name} -> ${DESKTOP.name}: the box mounts, is measured, inside the observer`, wide.reads > 0 && wide.outside === 0 && parseFloat(wide.width) > 0, wide)
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
