// perf round 6 row 03 (SPL-2435): on a rail-only page the sidebar mounts its
// icon rail only. The channel list (`.sidebar-body`, with the footer inside
// it) was mounted and hidden by CSS; now it is not in the DOM at all, and it
// mounts again, whole, when the reader leaves for a channel.
//
// Checks, desktop 1440 px:
//   1. /workspace/docs: the sidebar is the rail, no `.sidebar-body` node and
//      no node under one (control: origin/master 36f58dcae holds a hidden
//      `.sidebar-body`, so this FAILS there).
//   2. The rail's Channels tab leaves Docs: the list mounts with its rows,
//      the version footer and the footer's last-data clock.
//   3. Collapsing the channels pane then hands the clock to the top bar: the
//      footer's ResizeObserver follows the remounted row (useSidebarVersion).
//      Control: with the observer bound at the sidebar's first mount only,
//      no clock is left on screen.
//
// Run:
//   pnpm run test:e2e rail-only-sidebar-unmounted
//   BASE_URL=<generated bundle> pnpm run test:e2e rail-only-sidebar-unmounted
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* the sidebar's state: rail class, the body's nodes, rows, footer, clocks */
const sidebarState = (p) => p.evaluate(() => {
  const seen = (el) => {
    if (!el) return false
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && getComputedStyle(el).display !== 'none'
  }
  const body = document.querySelector('nav.sidebar .sidebar-body')
  return {
    rail: document.querySelector('nav.sidebar')?.classList.contains('sidebar--rail') || false,
    bodyNodes: document.querySelectorAll('nav.sidebar .sidebar-body, nav.sidebar .sidebar-body *').length,
    bodyShown: seen(body),
    rows: [...document.querySelectorAll('#sidebar-panel-channels .nav-item')].filter(seen).length,
    version: seen(document.querySelector('[data-test=app-version]')),
    footClock: seen(document.querySelector('.foot-row__clock')),
    clocks: [...document.querySelectorAll('.last-data-clock')].filter(seen).length,
  }
})

const waitFor = async (p, fn, ms = 10000) => {
  const t0 = Date.now()
  let s = await sidebarState(p)
  while (!fn(s) && Date.now() - t0 < ms) {
    await new Promise((r) => setTimeout(r, 200))
    s = await sidebarState(p)
  }
  return s
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + '/workspace/docs', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('nav.sidebar.sidebar--rail', { timeout: NAV_TIMEOUT }).catch(() => null)
  const docs = await sidebarState(p)
  ok('1. /workspace/docs: the sidebar is the icon rail', docs.rail, docs)
  ok('1. /workspace/docs: no .sidebar-body node is mounted', docs.bodyNodes === 0, docs)

  const tab = await p.$('[data-testid=sidebar-tab-channels]')
  ok('2. the rail has the Channels tab', Boolean(tab))
  if (tab) {
    await tab.click()
    const ch = await waitFor(p, (s) => s.bodyShown && s.rows > 0 && s.footClock)
    ok('2. leaving Docs: the sidebar is no longer the rail', !ch.rail, ch)
    ok('2. leaving Docs: the channel list mounts with its rows', ch.bodyShown && ch.rows > 0, ch)
    ok('2. leaving Docs: the version footer is back', ch.version, ch)
    ok('2. leaving Docs: the footer holds the one clock', ch.footClock && ch.clocks === 1, ch)

    const fold = await p.$('[data-test=pane-collapse-channels]')
    ok('3. the channels pane has its collapse toggle', Boolean(fold))
    if (fold) {
      await fold.click()
      const shut = await waitFor(p, (s) => !s.footClock && s.clocks === 1)
      ok('3. collapsed: the clock moves to the top bar, one on screen', !shut.footClock && shut.clocks === 1, shut)
      await fold.click()
      await waitFor(p, (s) => s.footClock)
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `rail-only-sidebar-unmounted: ${failed} FAILED` : `rail-only-sidebar-unmounted: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
