// HUM-27 (csi-rel #development, topics f7bb43e8 + d9e3db65, 2026-09-28):
// "the keyboard disappears when I try to switch the typing language" on the
// phone. Switching the on-screen keyboard's language (the input-method picker,
// a taller or shorter layout) bounces the window focus, fires composition
// events and resizes the visual viewport. The window `focus` made the build
// watch ask /build.json; on a newer deploy an EMPTY composer read as idle, so
// the tab reloaded itself under the finger and the keyboard was gone. Deploys
// land many times an hour, so the reader met it on almost every switch.
//
// At 390x844 (touch), the docked composer focused and EMPTY, a newer build
// live, the events a language switch fires:
//   - blur + focusout (no relatedTarget), window blur, compositionstart /
//     update / end, the viewport shrinking and growing (resizes-content),
//     window focus, focus back
//   - the build watch DID ask /build.json (so the check really ran)
//   - NO reload, the same textarea element is still mounted, still focused
//   - typing Cyrillic after the switch lands in the box
// CONTROL: the same newer build with the box NOT focused and empty reloads
// the tab by itself (the build watch's idle reload still works).
//
// Needs a bundle with a baked-in commit (GITHUB_SHA in CI, or
// NUXT_PUBLIC_BUILD_COMMIT); with no BASE_URL the harness starts `nuxi dev`
// and this file sets NUXT_PUBLIC_BUILD_COMMIT itself.
//
// Run:
//   pnpm run test:e2e:keyboard-lang-switch
//   BASE_URL=<generated bundle> pnpm run test:e2e:keyboard-lang-switch
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const DEV_COMMIT = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'
if (!process.env.BASE_URL && !process.env.NUXT_PUBLIC_BUILD_COMMIT) process.env.NUXT_PUBLIC_BUILD_COMMIT = DEV_COMMIT
const NEWER = '9999999999999999999999999999999999999999'
const W = 390
const H = 844
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const BOX = 'form.composer--dock textarea'
const mark = (p) => p.evaluate(() => { window.__kbMark = 1 })
const reloaded = (p) => p.evaluate(() => window.__kbMark !== 1).catch(() => true)
const poke = (p) => p.evaluate(() => window.dispatchEvent(new Event('focus')))

async function open(browser, base, served) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.evaluateOnNewDocument(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }))
  })
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (new URL(req.url()).pathname === '/build.json') {
      served.asked++
      if (!served.commit) return req.respond({ status: 404, contentType: 'text/plain', body: 'no build.json' })
      return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ commit: served.commit, built_at: '2026-09-28T09:00:00Z', run: '1' }) })
    }
    req.continue()
  })
  await p.setViewport({ width: W, height: H, isMobile: true, hasTouch: true })
  /* /lobby: on a phone that is level 2, where the dock composer is */
  await p.goto(`${base}/lobby`, { waitUntil: 'load', timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { visible: true, timeout: 30000 })
  await sleep(800)
  return { ctx, p }
}

/** The events a keyboard language switch sends to the page. */
async function switchLanguage(p) {
  await p.evaluate((sel) => {
    const ta = document.querySelector(sel)
    ta.dispatchEvent(new FocusEvent('blur', { relatedTarget: null }))
    ta.dispatchEvent(new FocusEvent('focusout', { bubbles: true, relatedTarget: null }))
    window.dispatchEvent(new Event('blur'))
    ta.dispatchEvent(new CompositionEvent('compositionstart', { bubbles: true, data: '' }))
    ta.dispatchEvent(new CompositionEvent('compositionupdate', { bubbles: true, data: 'з' }))
    ta.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: '' }))
  }, BOX)
  /* the keyboard re-lays out: the viewport shrinks, then settles (resizes-content) */
  for (const h of [H - 330, H - 360, H - 340]) {
    await p.setViewport({ width: W, height: h, isMobile: true, hasTouch: true })
    await sleep(150)
  }
  await p.evaluate((sel) => {
    const ta = document.querySelector(sel)
    window.dispatchEvent(new Event('focus'))
    ta.dispatchEvent(new FocusEvent('focus'))
    ta.dispatchEvent(new FocusEvent('focusin', { bubbles: true }))
  }, BOX)
}

const boxState = (p) => p.evaluate((sel) => {
  const ta = document.querySelector(sel)
  return {
    same: Boolean(ta) && ta === window.__kbBox,
    mounted: Boolean(window.__kbBox && window.__kbBox.isConnected),
    focused: Boolean(ta) && document.activeElement === ta,
    value: ta ? ta.value : null,
  }
}, BOX).catch(() => ({ same: false, mounted: false, focused: false, value: null }))

async function run(browser, base) {
  const served = { commit: '', asked: 0 }
  let { ctx, p } = await open(browser, base, served)
  const running = await p.evaluate(() => (window.__BUILD__ && window.__BUILD__.commit) || '')
  check(`${W}px: the bundle carries its commit (window.__BUILD__)`, /^[0-9a-f]{40}$/.test(running), running)
  if (!running) { await ctx.close(); return }

  // 1. focused, EMPTY box + a newer build + a language switch: no reload
  await p.tap(BOX)
  await p.evaluate((sel) => { window.__kbBox = document.querySelector(sel) }, BOX)
  const before = await boxState(p)
  check(`${W}px: the empty dock composer has the focus`, before.focused && before.value === '', before)
  served.commit = NEWER
  served.asked = 0
  await mark(p)
  await switchLanguage(p)
  await sleep(4000)
  check(`${W}px: the switch made the build watch ask /build.json`, served.asked > 0, served.asked)
  check(`${W}px: a newer build + the reader in the empty box -> NO reload`, !(await reloaded(p)))
  const after = await boxState(p)
  check(`${W}px: the same textarea is still mounted`, after.same && after.mounted, after)
  check(`${W}px: ... and still focused (the keyboard stays)`, after.focused, after)
  await p.keyboard.sendCharacter('здравей')
  await sleep(300)
  const typed = await boxState(p)
  check(`${W}px: Cyrillic typed after the switch lands in the box`, typed.value === 'здравей', typed.value)
  await ctx.close();

  // 2. CONTROL: the box not focused and empty - the idle reload still happens
  ({ ctx, p } = await open(browser, base, served))
  served.commit = NEWER
  await p.evaluate(() => document.activeElement && document.activeElement.blur && document.activeElement.blur())
  await mark(p)
  await poke(p)
  let didReload = false
  const t0 = Date.now()
  while (Date.now() - t0 < 10000) {
    await sleep(250)
    if (await reloaded(p)) { didReload = true; break }
  }
  check(`${W}px: CONTROL nothing focused + a newer build -> the tab reloads by itself`, didReload)
  await ctx.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await run(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nkeyboard-lang-switch: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
