// HUM-10 fb8d109f: the phone app reloads itself into a new build when it is
// reopened, and keeps the session and the place.
//
// At 390 px (touch): an old build is open on a topic, signed in, with the
// composer focused and EMPTY (the keyboard was up when the phone was put
// away). The app goes hidden for longer than RESUME_AFTER_MS, a new build is
// deployed (/build.json and the page document now name NEWER), and the app
// is re-activated (focus + visibilitychange, as a phone delivers them):
//   - the tab reloads by itself into the new build (window.__BUILD__ = NEWER)
//   - still signed in (the session store reads 'in'), no sign-in page
//   - the same route and open topic (pathname + ?topic=)
//   - the shell is painted (top bar), not a blank page
// CONTROL: the same page and deploy, but the focus comes back with no hidden
// period (a keyboard's language picker, HUM-27): NO reload, the bar instead.
//
// The "deploy" is request interception: /build.json and every page document
// are rewritten to the newer commit, so the reloaded tab really runs it.
//
// Run:
//   node tests/e2e/pwa-resume-reload.test.mjs
//   BASE_URL=http://127.0.0.1:4173 node tests/e2e/pwa-resume-reload.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const DEV_COMMIT = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'
if (!process.env.BASE_URL && !process.env.NUXT_PUBLIC_BUILD_COMMIT) process.env.NUXT_PUBLIC_BUILD_COMMIT = DEV_COMMIT
const NEWER = '9999999999999999999999999999999999999999'
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const PLACE = `/t/${TASK}`
/* utils/build-watch.mjs RESUME_AFTER_MS is 10 s; hide a little longer */
const HIDDEN_MS = 11_000
const WIDTH = 390
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

/* the mock bundle's signed-in session (utils/act-as-mock.mjs): survives a reload */
const MOCK_SESSION = JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })

const sessionState = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  return pinia?._s.get('session')?.state || ''
}).catch(() => '')
const mark = (p) => p.evaluate(() => { window.__resumeMark = 1 })
const reloaded = (p) => p.evaluate(() => window.__resumeMark !== 1).catch(() => true)
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
async function waitIn(p, ms) {
  const t0 = Date.now()
  let s = ''
  while (Date.now() - t0 < ms) {
    s = await sessionState(p)
    if (s === 'in') return s
    await sleep(250)
  }
  return s
}

/* a phone putting the app away / reopening it: the page reads its own
   visibility, so it is overridden and the events are dispatched for it */
const setHidden = (p, hidden) => p.evaluate((h) => {
  if (!window.__visPatched) {
    window.__visPatched = true
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => (window.__vis || 'visible') })
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => window.__vis === 'hidden' })
  }
  window.__vis = h ? 'hidden' : 'visible'
  if (!h) window.dispatchEvent(new Event('focus'))
  document.dispatchEvent(new Event('visibilitychange'))
}, hidden)

/* the visible composer textarea (topic reply box or the phone dock), focused and empty */
const focusEmptyComposer = (p) => p.evaluate(() => {
  const ta = [...document.querySelectorAll('textarea')]
    .find((t) => t.getClientRects().length && getComputedStyle(t).visibility !== 'hidden' && !t.disabled && !t.readOnly)
  if (!ta) return false
  ta.value = ''
  ta.focus()
  return document.activeElement === ta
})

async function open(browser, base, served) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  /* the worker would fetch the reloaded document itself, past this page's
     interception, and the "deploy" below could not rewrite it */
  await p.setBypassServiceWorker(true)
  await p.setRequestInterception(true)
  p.on('request', async (req) => {
    const url = new URL(req.url())
    if (url.pathname === '/build.json') {
      if (!served.commit) return req.respond({ status: 404, contentType: 'text/plain', body: 'no build.json' })
      return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ commit: served.commit, built_at: '2026-10-05T17:00:00Z', run: '1' }) })
    }
    if (served.html && req.isNavigationRequest() && req.resourceType() === 'document' && url.origin === new URL(base).origin) {
      try {
        const r = await fetch(req.url())
        const body = (await r.text()).split(served.running).join(served.html)
        return req.respond({ status: r.status, contentType: r.headers.get('content-type') || 'text/html', body })
      } catch {
        return req.continue()
      }
    }
    req.continue()
  })
  await p.setViewport({ width: WIDTH, height: 844, isMobile: true, hasTouch: true })
  await p.goto(`${base}/login`, { waitUntil: 'load' })
  await p.evaluate((s) => localStorage.setItem('spool.mock.session', s), MOCK_SESSION)
  await p.goto(`${base}${PLACE}`, { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=top-bar]', { timeout: 30000 })
  return { ctx, p }
}

async function run(browser, base) {
  const tag = `${WIDTH}px`
  const served = { commit: '', html: '', running: '' }

  // 1. the resume: hidden > RESUME_AFTER_MS, deployed meanwhile, reopened
  let { ctx, p } = await open(browser, base, served)
  const running = await p.evaluate(() => (window.__BUILD__ && window.__BUILD__.commit) || '')
  check(`${tag}: the old bundle carries its commit (window.__BUILD__)`, /^[0-9a-f]{40}$/.test(running), running)
  if (!running) { await ctx.close(); return }
  served.running = running
  served.commit = running
  check(`${tag}: signed in before the deploy`, (await waitIn(p, 10000)) === 'in')
  const place0 = await p.evaluate(() => location.pathname + location.search)
  check(`${tag}: the topic is open in the route`, place0.includes(TASK), place0)
  const focused = await focusEmptyComposer(p)
  check(`${tag}: an empty composer holds the focus (the keyboard was up)`, focused)
  await mark(p)
  await setHidden(p, true)
  await sleep(HIDDEN_MS)
  served.commit = NEWER
  served.html = NEWER
  await setHidden(p, false)
  const did = await waitReload(p, 15000)
  check(`${tag}: re-activated after a deploy -> the app reloads by itself`, did)
  const now = await p.evaluate(() => (window.__BUILD__ && window.__BUILD__.commit) || '').catch(() => '')
  check(`${tag}: ... into the new build.json version`, now === NEWER, now)
  check(`${tag}: ... still signed in (no sign-in page)`, (await waitIn(p, 10000)) === 'in')
  const place1 = await p.evaluate(() => location.pathname + location.search)
  check(`${tag}: ... on the same route and open topic`, place1 === place0, { place0, place1 })
  check(`${tag}: ... not on /login`, !/\/login/.test(place1), place1)
  const painted = await p.evaluate(() => Boolean(document.querySelector('[data-test=top-bar]')) && document.body.innerText.trim().length > 20)
  check(`${tag}: ... the shell is painted, never blank`, painted)
  await ctx.close()

  // 2. CONTROL: the same deploy, focus back with no hidden period (HUM-27)
  served.commit = ''
  served.html = '';
  ({ ctx, p } = await open(browser, base, served))
  served.commit = running
  check(`${tag}: CONTROL focus held by an empty composer`, await focusEmptyComposer(p))
  served.commit = NEWER
  await mark(p)
  await p.evaluate(() => window.dispatchEvent(new Event('focus')))
  await sleep(5000)
  check(`${tag}: CONTROL focus back with no hidden period -> NO reload`, !(await reloaded(p)))
  const bar = await p.evaluate(() => Boolean(document.querySelector('[data-test=build-update-bar]')))
  check(`${tag}: CONTROL ... the "new version" bar instead`, bar)
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
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length || !results.length) code = 1
process.exit(code)
