// perf round 6 row 07 (SPL-2436): on a phone that boots at level 2 or 3 the
// channel sidebar is CSS-hidden (main.css, .spool-shell:not([data-mobile-
// level="1"]) > .sidebar), so layouts/default.vue mounts it in an idle slot
// (utils/perf-idle.mjs) instead of in the first render.
//
// The control holds every requestIdleCallback of the page (an init script
// queues them and runs none), so "the first render" stays observable however
// fast the box is:
//   - phone /channel/alerts, /lobby, /workspace/docs: no nav.sidebar in the document while idle is
//     held; releasing the queue mounts it, still hidden, at level 2
//   - phone /channel/alerts, Back to level 1 with idle still held: the
//     sidebar is there and visible at once (no wait for idle)
//   - phone / (level 1), phone /issues (a section page: its strip shows),
//     desktop /channel/alerts: mounted in the first render, idle held
//   - phone /channel/alerts, idle NOT held: mounted within IDLE_WAIT_MS
// Red on a build without the row: the first case finds the sidebar mounted.
//
//   BASE_URL=<generated bundle> node tests/e2e/phone-sidebar-idle-mount.test.mjs
//   (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* perf-idle's requestIdleCallback timeout is 4 s after load */
const IDLE_WAIT_MS = 8000
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const DESK = { width: 1440, height: 900 }
/* phone boots where the sidebar is CSS-hidden (no section strip) */
const HIDDEN_AT_BOOT = (process.env.ROUTES || '/channel/alerts,/lobby,/workspace/docs').split(',').filter(Boolean)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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

/* every requestIdleCallback waits in window.__heldIdle until __releaseIdle() */
function holdIdle() {
  const held = []
  window.__heldIdle = held
  window.requestIdleCallback = (fn) => { held.push(fn); return held.length }
  window.cancelIdleCallback = () => {}
  window.__releaseIdle = () => {
    let n = 0
    while (held.length) { const fn = held.shift(); n++; try { fn({ didTimeout: false, timeRemaining: () => 50 }) } catch { /* the page's own */ } }
    return n
  }
}

const census = (p) => p.evaluate(() => {
  const side = document.querySelector('.spool-shell > nav.sidebar')
  return {
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
    sideInDom: Boolean(side),
    sideNodes: side ? side.querySelectorAll('*').length + 1 : 0,
    sideVisible: side ? getComputedStyle(side).display !== 'none' : false,
    dom: document.getElementsByTagName('*').length,
    path: location.pathname,
  }
})

async function open(browser, path, { viewport = PHONE, hold = true } = {}) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport(viewport)
  if (hold) await p.evaluateOnNewDocument(holdIdle)
  await p.goto(`${srv.base}${path}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { visible: true })
  await sleep(1000)
  return p
}

const srv = await startServer()
const browser = await launch()
try {
  /* 1. a level-2 boot leaves the hidden sidebar out until idle */
  for (const path of HIDDEN_AT_BOOT) {
    const p = await open(browser, path)
    const before = await census(p)
    ok(`390px ${path}, idle held: no nav.sidebar in the first render (level 2)`, before.level === '2' && !before.sideInDom, before)
    const released = await p.evaluate(() => window.__releaseIdle())
    await sleep(800)
    const after = await census(p)
    ok(`390px ${path}, idle released: the sidebar mounts, still hidden`, after.level === '2' && after.sideInDom && !after.sideVisible && after.sideNodes > 50, { released, ...after })
    console.log(`  dom ${path}: ${before.dom} nodes before idle, ${after.dom} after (+${after.dom - before.dom}; sidebar ${after.sideNodes})`)
    await p.close()
  }

  /* 2. Back to level 1 never waits for idle */
  let p = await open(browser, '/channel/alerts')
  await p.click('[data-testid=mobile-back]')
  await sleep(800)
  let c = await census(p)
  ok('390px /channel/alerts -> Back, idle held: level 1 shows the sidebar at once', c.level === '1' && c.sideInDom && c.sideVisible && c.sideNodes > 50, c)
  await p.close()

  /* 3. where the sidebar shows, the first render mounts it */
  p = await open(browser, '/')
  c = await census(p)
  ok('390px / (level 1), idle held: the sidebar is mounted and visible', c.level === '1' && c.sideInDom && c.sideVisible, c)
  await p.close()
  p = await open(browser, '/issues')
  c = await census(p)
  ok('390px /issues (section strip), idle held: the strip is mounted and visible', c.level === '2' && c.sideInDom && c.sideVisible, c)
  await p.close()
  p = await open(browser, '/channel/alerts', { viewport: DESK })
  c = await census(p)
  ok('1440px /channel/alerts, idle held: the sidebar is mounted and visible', c.sideInDom && c.sideVisible, c)
  await p.close()

  /* 4. the real idle slot (no hold) mounts it soon after load */
  p = await open(browser, '/channel/alerts', { hold: false })
  const t0 = Date.now()
  while (!(await census(p)).sideInDom && Date.now() - t0 < IDLE_WAIT_MS) await sleep(200)
  c = await census(p)
  ok(`390px /channel/alerts, real idle: the sidebar mounts within ${IDLE_WAIT_MS} ms`, c.sideInDom && c.level === '2', c)
  await p.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nphone-sidebar-idle-mount: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
