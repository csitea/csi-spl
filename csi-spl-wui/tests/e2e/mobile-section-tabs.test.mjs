// SPL-4551 (owner HUM-10, t1 6cfd0257, msg 3207d42c: "The font and size of
// the tabs could 20% smaller on mobile"): the Monitoring and Reporting sub-tab
// bars (spec 153 3.1) at the phone breakpoint (max-width: 820px).
//   - at 390x844 a tab's font size, padding and height are 0.8x the values
//     before the change (OLD below, measured on the generated mock bundle of
//     origin/master 44ca5f516), the active tab included, both bars;
//   - at 1440x900 every one of them is unchanged;
//   - at 390 px a tap 43 px above a tab's bottom edge still lands on the tab
//     (the WUI's --tap minimum, 44 px), for the idle and the active tab;
//   - the focused tab keeps a visible focus ring.
// RED CONTROL: on origin/master 44ca5f516 the 390 px checks fail (the tabs
// keep their desktop size) and the file exits 1.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e mobile-section-tabs
//   SHOT_DIR=<dir> keeps a screenshot of each bar at each size.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const MEASURE = process.env.MEASURE === '1'
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

const MOCK_SESSION = JSON.stringify({ hum: 'HUM-1', name: 'FirstName LastName', email: 'person@example.com', t: 'mock' })
const BARS = [
  { name: 'monitoring', path: '/monitoring/agents', active: '[data-test=monitoring-tab-agents]', idle: '.monitoring-tab:not(.monitoring-tab--active)' },
  { name: 'reporting', path: '/reporting/releases', active: '[data-test=reporting-tab-releases]', idle: '.reporting-tab:not(.reporting-tab--active)' },
]
// The values before SPL-4551 (MEASURE=1 on origin/master 44ca5f516), the
// same at both widths: font px, height px, padding top/right/bottom/left px.
const OLD = {
  monitoring: { idle: { font: 18, h: 46, pad: [8, 11, 9, 11] }, active: { font: 18, h: 50, pad: [12, 11, 9, 11] } },
  reporting: { idle: { font: 18, h: 45, pad: [8, 12, 8, 12] }, active: { font: 18, h: 45, pad: [8, 12, 8, 12] } },
}

const measure = (p, sel) => p.$eval(sel, (e) => {
  const s = getComputedStyle(e)
  const r = e.getBoundingClientRect()
  const one = (v) => Math.round(parseFloat(v) * 10) / 10
  return {
    font: one(s.fontSize),
    h: one(r.height),
    pad: [s.paddingTop, s.paddingRight, s.paddingBottom, s.paddingLeft].map(one),
  }
})

const near = (got, want) => Math.abs(got - want) <= 1

async function open(browser, base, vp, path) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((session) => {
    try { localStorage.setItem('spool.mock.session', session) } catch { /* first document */ }
  }, MOCK_SESSION)
  await p.setViewport({ width: vp.w, height: vp.h, isMobile: vp.mobile, hasTouch: vp.mobile, deviceScaleFactor: 1 })
  await p.goto(base + path, { waitUntil: 'networkidle2' })
  await sleep(1200)
  return { ctx, p }
}

async function checkSizes(p, tag, vp, bar) {
  const factor = vp.mobile ? 0.8 : 1
  for (const kind of ['idle', 'active']) {
    const got = await measure(p, kind === 'active' ? bar.active : bar.idle)
    if (MEASURE) { console.log(`  MEASURE ${tag} ${kind} ${JSON.stringify(got)}`); continue }
    const old = OLD[bar.name][kind]
    const want = { font: old.font * factor, h: old.h * factor, pad: old.pad.map((v) => v * factor) }
    ok(`${tag} ${kind}: font size is ${factor}x (${want.font} px)`, near(got.font, want.font), got.font)
    ok(`${tag} ${kind}: height is ${factor}x (${want.h} px)`, near(got.h, want.h), got.h)
    ok(`${tag} ${kind}: padding is ${factor}x`, got.pad.every((v, i) => near(v, want.pad[i])), { got: got.pad, want: want.pad })
  }
}

// The tap area: the element under (centre x, bottom - 43) is the tab itself.
async function checkTap(p, tag, bar) {
  for (const kind of ['idle', 'active']) {
    const hit = await p.$eval(kind === 'active' ? bar.active : bar.idle, (e) => {
      const r = e.getBoundingClientRect()
      const under = document.elementFromPoint(r.left + r.width / 2, r.bottom - 43)
      return { h: Math.round(r.height * 10) / 10, onTab: under === e || e.contains(under) }
    })
    ok(`${tag} ${kind}: a tap 43 px above the tab's bottom lands on the tab`, hit.onTab, hit)
  }
}

async function checkBar(browser, base, vp, bar) {
  const tag = `${vp.w}px ${bar.name}`
  const { ctx, p } = await open(browser, base, vp, bar.path)
  try {
    const seen = await p.waitForSelector(bar.active, { visible: true, timeout: 20000 }).then(() => true, () => false)
    ok(`${tag}: the bar and its active tab render`, seen)
    if (!seen) return
    await checkSizes(p, tag, vp, bar)
    if (vp.mobile && !MEASURE) await checkTap(p, tag, bar)
    if (SHOT_DIR) {
      mkdirSync(SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(SHOT_DIR, `${bar.name}-${vp.w}.png`) })
    }
    await p.keyboard.press('Tab')
    const ring = await p.$eval(bar.active, (e) => {
      e.focus({ focusVisible: true })
      const s = getComputedStyle(e)
      return { focused: e.matches(':focus-visible'), style: s.outlineStyle, w: parseFloat(s.outlineWidth) }
    })
    ok(`${tag}: the focused tab keeps a visible focus ring`, ring.focused && ring.style !== 'none' && ring.w > 0, ring)
  } finally {
    await ctx.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  for (const vp of [{ w: 390, h: 844, mobile: true }, { w: 1440, h: 900, mobile: false }]) {
    console.log(`-- ${vp.w}x${vp.h}`)
    for (const bar of BARS) await checkBar(browser, server.base, vp, bar)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
