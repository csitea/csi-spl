// Spec 087 T003 (FR-001), SPL-5319: a phone Back onto a stale /login entry of
// the SAME document (signed in at /login, Continue, then Back) is a popstate.
// composables/useMobileStack.ts guardStaleLogin must leave it before
// vue-router renders it: the guard's popstate listener runs BEFORE the
// router's, its stopImmediatePropagation keeps the router from starting a
// navigation to /login, and the sign-in card never paints.
//
// At window, popstate listeners run in the order they were added, capture or
// not (no capture phase at the target). Measured on aecbc47cb (c-582, n=3)
// and again here before the fix: the router's listener ran first, the guard
// second, so the router began a navigation to /login on every Back.
//
// A run passes when, on that Back:
//   - the first popstate listener that runs is the one that stops the event
//     (the guard),
//   - the router's beforeEach never sees a navigation to /login,
//   - a MutationObserver that runs from the first byte of every document
//     never saw `.login-landing-card`, and the tab does not stay on /login.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/phone-stale-login-popstate.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
// RUNS=<n> repeats the walk (default 3), each in a fresh browser context.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RUNS = Number(process.env.RUNS ?? 3)
const MEMBER = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
const LOGIN = /(^|\/)login\/?$/
const CONTINUE = '.login-landing-card a[href$="/"]'
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

/* Before any app code, on every document: a signed-in mock member, a watch
   that records the sign-in card if it is ever painted, and a log of each
   popstate listener as it runs (its add order, and whether it stopped the
   event). The logs live in sessionStorage: the guard's step back past /login
   may land on another document. */
function boot(member) {
  try {
    localStorage.setItem('spool.mock.session', JSON.stringify(member))
    localStorage.setItem('spool.was-signed-in', '1')
  } catch { /* private mode */ }
  const mark = () => {
    const card = document.querySelector('.login-landing-card')
    if (!card || getComputedStyle(card).visibility === 'hidden') return
    try { if (sessionStorage.getItem('e2e.watch')) sessionStorage.setItem('e2e.loginPainted', location.pathname) } catch { /* */ }
  }
  new MutationObserver(mark).observe(document, { childList: true, subtree: true })
  mark()
  let added = 0
  let running = -1
  const log = (key, f) => {
    try {
      if (!sessionStorage.getItem('e2e.watch')) return
      const v = JSON.parse(sessionStorage.getItem(key) || '[]')
      f(v)
      sessionStorage.setItem(key, JSON.stringify(v))
    } catch { /* */ }
  }
  window.__e2eLog = log
  const add = window.addEventListener
  window.addEventListener = function (type, fn, opts) {
    if (type !== 'popstate' || typeof fn !== 'function') return add.call(this, type, fn, opts)
    const id = added++
    const wrapped = function (e) {
      running = id
      log('e2e.pops', (v) => v.push({ id, stopped: false }))
      try { return fn.call(this, e) } finally { running = -1 }
    }
    return add.call(this, type, wrapped, opts)
  }
  const stop = Event.prototype.stopImmediatePropagation
  Event.prototype.stopImmediatePropagation = function () {
    if (this.type === 'popstate' && running >= 0) {
      log('e2e.pops', (v) => { const last = v[v.length - 1]; if (last && last.id === running) last.stopped = true })
    }
    return stop.call(this)
  }
}

/* In the page: watch the router and the card from here on. */
function arm() {
  const router = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router
  sessionStorage.setItem('e2e.watch', '1')
  router.beforeEach((to) => { if (/(^|\/)login\/?$/.test(to.path)) window.__e2eLog('e2e.toLogin', (v) => v.push(to.path)) })
}

const read = (p) => p.evaluate(() => ({
  pops: JSON.parse(sessionStorage.getItem('e2e.pops') || '[]'),
  toLogin: JSON.parse(sessionStorage.getItem('e2e.toLogin') || '[]'),
  painted: sessionStorage.getItem('e2e.loginPainted'),
  path: location.pathname,
}))

function verdict(r) {
  const fails = []
  const first = r.pops[0]
  if (!first) fails.push('no popstate listener ran: the Back proved nothing')
  else if (!first.stopped) fails.push(`the first popstate listener (#${first.id}) did not stop the event: the router ran before the guard`)
  if (r.toLogin.length) fails.push(`vue-router began a navigation to ${r.toLogin.join(',')}`)
  if (r.painted) fails.push(`the sign-in card painted at ${r.painted}`)
  if (LOGIN.test(r.path)) fails.push(`the tab stayed on ${r.path}`)
  return fails
}

async function walk(browser, base) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  try {
    await p.setViewport({ width: 360, height: 780, isMobile: true, hasTouch: true })
    await p.evaluateOnNewDocument(boot, MEMBER)
    /* an entry under /login, so the guard's step back has somewhere to go */
    await p.goto(base + '/', { waitUntil: 'domcontentloaded' })
    await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
    await p.goto(base + '/login', { waitUntil: 'domcontentloaded' })
    /* signed in: the card offers Continue (a NuxtLink: router.push, same document) */
    await p.waitForSelector(CONTINUE, { timeout: NAV_TIMEOUT })
    await p.evaluate((q) => document.querySelector(q).click(), CONTINUE)
    await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
    await sleep(500)
    await p.evaluate(arm)
    await p.goBack({ timeout: 8000 }).catch(() => null)
    await sleep(2000)
    const r = await read(p)
    return { fails: verdict(r), r }
  } finally {
    await ctx.close().catch(() => {})
  }
}

const srv = await startServer()
const browser = await launch()
let failed = 0
try {
  for (let i = 1; i <= RUNS; i++) {
    let res
    try { res = await walk(browser, srv.base) } catch (e) { res = { fails: [`error: ${e.message}`], r: {} } }
    const { fails, r } = res
    console.log(`  ${fails.length ? 'FAIL' : 'OK  '} run ${i}: pops=${JSON.stringify(r.pops)} toLogin=${JSON.stringify(r.toLogin)} painted=${r.painted} path=${r.path}${fails.length ? '  ' + fails.join('; ') : ''}`)
    if (fails.length) failed++
  }
} finally {
  await browser.close()
  await srv.stop()
}
console.log(`phone-stale-login-popstate: ${RUNS - failed}/${RUNS} passed`)
if (!RUNS || failed) process.exit(1)
