// SPL-1006: an open tab picks up a new deploy safely.
//
// The bundle under test must carry a baked-in commit (window.__BUILD__):
// `nuxt generate` with GITHUB_SHA (CI) or NUXT_PUBLIC_BUILD_COMMIT set. With
// no BASE_URL the test starts `nuxi dev` and sets NUXT_PUBLIC_BUILD_COMMIT
// itself. /build.json is served by request interception, so the "deploy" is
// a changed build.json in front of an unchanged bundle. At 1440, 820 and
// 360 px:
//   - same commit (CONTROL, the 1440 no-change check): no bar, no reload
//   - idle + a newer commit: the tab reloads by itself, route kept
//   - after that reload the bundle is still the old one (the CDN could lag
//     like this): NO second reload (the per-commit guard), the bar instead
//   - a typed draft + a newer commit: no reload, the bar shows, the draft is
//     kept; then the draft is emptied -> the tab reloads by itself
//   - the bar sits inside the viewport, no x-scroll, Reload >= 44 px on touch
//   - the sidebar version pop-up says a newer build is live
//
// Run:
//   node tests/e2e/build-watch.test.mjs
//   BASE_URL=http://127.0.0.1:4173 node tests/e2e/build-watch.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const DEV_COMMIT = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'
if (!process.env.BASE_URL && !process.env.NUXT_PUBLIC_BUILD_COMMIT) process.env.NUXT_PUBLIC_BUILD_COMMIT = DEV_COMMIT
const NEWER = '9999999999999999999999999999999999999999'
const TAP = 44
const results = []
function check(name, pass, ev) {
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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

/* the check fires on focus / visible; 'focus' on window is what a tab gets */
const poke = (p) => p.evaluate(() => window.dispatchEvent(new Event('focus')))
const mark = (p) => p.evaluate(() => { window.__bwMark = 1 })
const reloaded = (p) => p.evaluate(() => window.__bwMark !== 1).catch(() => true)
async function waitReload(p, ms) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    await sleep(250)
    if (await reloaded(p)) {
      await p.waitForSelector('[data-test=top-bar]', { timeout: 20000 })
      return true
    }
  }
  return false
}
const barState = (p) => p.evaluate(() => {
  const bar = document.querySelector('[data-test=build-update-bar]')
  const btn = bar?.querySelector('[data-test=build-update-reload]')
  const box = (el) => { const r = el.getBoundingClientRect(); return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), r: Math.round(r.right), b: Math.round(r.bottom) } }
  const se = document.scrollingElement
  return {
    vw: window.innerWidth,
    vh: window.innerHeight,
    xscroll: se.scrollWidth > window.innerWidth + 1,
    bar: bar ? { ...box(bar), text: bar.textContent.trim() } : null,
    btn: btn ? box(btn) : null,
  }
})
/* the first textarea the reader can actually see: omnibox or phone dock */
const draftBox = (p) => p.evaluateHandle(() => [...document.querySelectorAll('textarea')]
  .find((t) => t.getClientRects().length && getComputedStyle(t).visibility !== 'hidden' && !t.disabled))

async function open(browser, base, width, touch, served, path) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (new URL(req.url()).pathname === '/build.json') {
      if (!served.commit) return req.respond({ status: 404, contentType: 'text/plain', body: 'no build.json' })
      return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ commit: served.commit, built_at: '2026-09-27T13:00:00Z', run: '1' }) })
    }
    req.continue()
  })
  await p.setViewport({ width, height: 800, isMobile: touch, hasTouch: touch })
  await p.goto(`${base}${path || (touch ? '/' : '/lobby')}`, { waitUntil: 'load' })
  await p.waitForSelector('[data-test=top-bar]')
  if (!(await signIn(p))) throw new Error('no session store')
  await sleep(500)
  return { ctx, p }
}

async function run(browser, base, width, touch) {
  const tag = `${width}px`
  const served = { commit: '' }

  // 1. same commit: nothing happens (the desktop no-change check at 1440)
  let { ctx, p } = await open(browser, base, width, touch, served)
  const running = await p.evaluate(() => (window.__BUILD__ && window.__BUILD__.commit) || '')
  check(`${tag}: the bundle carries its commit (window.__BUILD__)`, /^[0-9a-f]{40}$/.test(running), running)
  if (!running) { await ctx.close(); return }
  served.commit = running
  await mark(p)
  await poke(p)
  await sleep(1500)
  let s = await barState(p)
  check(`${tag}: CONTROL same commit - no reload`, !(await reloaded(p)))
  check(`${tag}: CONTROL same commit - no bar`, s.bar === null, s.bar)
  await ctx.close();

  // 2. idle + newer: silent reload, route kept; then the guard stops a loop
  ({ ctx, p } = await open(browser, base, width, touch, served))
  served.commit = NEWER
  const path0 = await p.evaluate(() => location.pathname)
  await mark(p)
  await poke(p)
  const didReload = await waitReload(p, 8000)
  check(`${tag}: idle + a newer build -> the tab reloads by itself`, didReload)
  const path1 = await p.evaluate(() => location.pathname)
  check(`${tag}: the route is kept`, path1 === path0, { path0, path1 })
  if (!(await signIn(p))) throw new Error('no session store after reload')
  await sleep(500)
  await mark(p)
  await poke(p)
  await sleep(6000)
  s = await barState(p)
  check(`${tag}: still the old bundle after the reload -> no second reload (guard)`, !(await reloaded(p)))
  check(`${tag}: ... the bar says a new version is available instead`, Boolean(s.bar && /new version/i.test(s.bar.text)), s.bar)
  await ctx.close();

  // 3. a typed draft + newer: the bar, the draft kept; emptied -> reload
  //    (/lobby: on a phone that is level 2, where the dock composer is)
  ({ ctx, p } = await open(browser, base, width, touch, served, '/lobby'))
  served.commit = running
  const ta = await draftBox(p)
  if (!ta || !(await ta.evaluate((t) => Boolean(t)))) { check(`${tag}: a visible composer to type into`, false); await ctx.close(); return }
  await ta.click()
  await ta.type('half a thought')
  served.commit = NEWER
  await mark(p)
  await poke(p)
  await sleep(5000)
  s = await barState(p)
  const kept = await ta.evaluate((t) => t.value)
  check(`${tag}: a draft + a newer build -> NO reload`, !(await reloaded(p)))
  check(`${tag}: the draft is kept`, kept === 'half a thought', kept)
  check(`${tag}: the bar shows`, Boolean(s.bar), s.bar)
  if (s.bar) {
    check(`${tag}: the bar sits inside the viewport`, s.bar.x >= 0 && s.bar.r <= s.vw && s.bar.y >= 0 && s.bar.b <= s.vh, { bar: s.bar, vw: s.vw })
    check(`${tag}: no x-scroll`, !s.xscroll)
    // en fits one line down to 360 px (left:50% + translate wrapped it into 3 at 390)
    check(`${tag}: the bar is one line (<= 72 px with a 44 px touch button)`, s.bar.h <= 72, s.bar)
    if (touch) check(`${tag}: Reload >= ${TAP} px`, s.btn && s.btn.h >= TAP, s.btn)
  }
  if (!touch) {
    // the sidebar pop-up says a newer build is live (desktop: the sidebar shows)
    const newer = await p.evaluate(() => document.querySelector('[data-test=app-version-newer]')?.textContent.trim() || '')
    check(`${tag}: the version pop-up says a newer build is live`, newer.includes(NEWER.slice(0, 7)), newer)
    const shown = await p.evaluate(() => document.querySelector('.vs-pop__sha')?.textContent.trim() || '')
    check(`${tag}: the version pop-up shows the RUNNING commit`, shown === running, shown)
  }
  await ta.evaluate((t) => t.focus())
  await p.keyboard.down('Control'); await p.keyboard.press('a'); await p.keyboard.up('Control')
  await p.keyboard.press('Backspace')
  /* HUM-27: a FOCUSED empty box still holds the reader (the keyboard is up),
     so the reload waits for the focus to leave it, on every width */
  await p.evaluate(() => document.activeElement && document.activeElement.blur())
  const after = await waitReload(p, 10000)
  check(`${tag}: the draft emptied -> the tab reloads by itself`, after)
  await ctx.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, touch] of [[1440, false], [820, true], [360, true]]) await run(browser, server.base, w, touch)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nbuild-watch: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
