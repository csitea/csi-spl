// specs/077 T020 (owner HUM-10, 2026-10-05): the sign-in page explains the
// demo before the sign-in buttons, and only while GET /v1/demo answers 200.
// Flag on: the intro, the live visitor limit the hub sent, and one "Try the
// demo" sign-in per provider the demo admits, each starting with
// tenant=<demo id>. Flag off (404): no intro, the page as before. A 10th
// visitor's auth_error=demo_full is said in words. Desktop and phone (360,
// 390) never scroll sideways. Proved in a REAL browser against the mock
// bundle; /providers and /v1/demo are answered here.
//
//   node tests/e2e/login-demo-intro.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/login-demo-intro.test.mjs
//   SHOT_DIR=/var/tmp/x ... also writes a screenshot per case
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
let failed = 0
const ok = (name, cond, extra) => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${JSON.stringify(extra ?? '')}`) }
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
        defaultViewport: { width: 1280, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const DESKTOP = { width: 1280, height: 900 }
const PHONES = [{ width: 360, height: 780, isMobile: true, hasTouch: true }, { width: 390, height: 844, isMobile: true, hasTouch: true }]

const server = await startServer()
const browser = await launch()
try {
  let demo = { status: 200, body: { workspace: 'demo', max_live: 9, max_stay: '3h' } }
  let demoAsked = 0
  const errors = []
  const page = async (vp) => {
    const p = await browser.newPage()
    p.on('pageerror', (e) => errors.push(String(e && e.message)))
    await setPageViewport(p, vp)
    await p.setRequestInterception(true)
    p.on('request', (req) => {
      const path = new URL(req.url()).pathname
      if (path.endsWith('/api/v1/auth/providers')) {
        return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ providers: ['google', 'facebook', 'microsoft'], native: true }) })
      }
      if (path.endsWith('/v1/demo')) {
        demoAsked++
        return req.respond({ status: demo.status, contentType: 'application/json', body: JSON.stringify(demo.body) })
      }
      return req.continue()
    })
    return p
  }
  const open = async (p, vp, q = '?redirect=%2Flobby') => {
    await p.goto(server.base + '/login' + q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-test=social-auth-google]', { visible: true, timeout: NAV_TIMEOUT })
  }
  const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')
  const noXScroll = (p) => p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)
  const shot = async (p, name) => { if (SHOT_DIR) await p.screenshot({ path: join(SHOT_DIR, `${name}.png`), fullPage: true }) }

  // 1. flag on, desktop: the intro, the live limit, Try the demo per demo provider
  const d = await page(DESKTOP)
  await open(d, DESKTOP)
  await d.waitForSelector('[data-test=demo-intro]', { visible: true, timeout: 15000 }).catch(() => null)
  ok('1 flag on: the demo intro is shown', Boolean(await d.$('[data-test=demo-intro]')))
  ok('1b it states the live limit the hub sent', /\b9\b/.test(await text(d, '[data-test=demo-intro-limit]')), await text(d, '[data-test=demo-intro-limit]'))
  ok('1c it says nothing about a stay length (T009 is not live)', !/\b3\s*h|hour/i.test(await text(d, '[data-test=demo-intro]')))
  await d.waitForSelector('[data-test=demo-try-google]', { visible: true, timeout: 15000 }).catch(() => null)
  const tries = await d.$$eval('[data-test^=demo-try-]', (els) => els.map((e) => ({ t: e.getAttribute('data-test'), href: e.getAttribute('href') })))
  ok('1d one Try the demo per admitted sign-in, in registry order', JSON.stringify(tries.map((x) => x.t)) === '["demo-try-google","demo-try-facebook"]', tries)
  ok('1e each starts the sign-in with tenant=<demo id> and the redirect', tries.length === 2 && tries.every((x) => /\/api\/v1\/auth\/(google|facebook)\/start\?/.test(x.href) && /[?&]tenant=demo(&|$)/.test(x.href) && /[?&]redirect=%2Flobby(&|$)/.test(x.href)), tries)
  const order = await d.evaluate(() => {
    const i = document.querySelector('[data-test=demo-intro]'); const s = document.querySelector('[data-test=social-auth]')
    return Boolean(i && s && (i.compareDocumentPosition(s) & Node.DOCUMENT_POSITION_FOLLOWING))
  })
  ok('1f the intro comes before the sign-in', order)
  ok('1g desktop: no sideways scroll', await noXScroll(d))
  await shot(d, 'demo-on-desktop')
  await d.close()

  // 2. flag on, phones
  for (const vp of PHONES) {
    const m = await page(vp)
    await open(m, vp)
    await m.waitForSelector('[data-test=demo-try-facebook]', { visible: true, timeout: 15000 }).catch(() => null)
    const w = await m.$eval('[data-test=demo-intro]', (e) => e.getBoundingClientRect().right <= window.innerWidth + 1).catch(() => false)
    ok(`2 ${vp.width}px: the intro fits and the page does not scroll sideways`, w && await noXScroll(m))
    await shot(m, `demo-on-${vp.width}`)
    await m.close()
  }

  // 3. CONTROL: flag off (404) = the page as before, on desktop and a phone
  demo = { status: 404, body: { error: 'not_found', detail: 'the demo is off' } }
  for (const vp of [DESKTOP, PHONES[1]]) {
    const before = demoAsked
    const o = await page(vp)
    await open(o, vp)
    await new Promise((r) => setTimeout(r, 800))
    ok(`3 ${vp.width}px CONTROL: flag off asks /v1/demo and shows no intro`, demoAsked > before && !(await o.$('[data-test=demo-intro]')) && !(await o.$('[data-test^=demo-try-]')))
    await shot(o, `demo-off-${vp.width}`)
    await o.close()
  }

  // 4. the 10th visitor: auth_error=demo_full in words, not "Sign-in failed"
  demo = { status: 200, body: { workspace: 'demo', max_live: 9, max_stay: '3h' } }
  const f = await page(DESKTOP)
  await open(f, DESKTOP, '?auth_error=demo_full')
  await f.waitForSelector('.login-error', { visible: true, timeout: 15000 }).catch(() => null)
  ok('4 demo_full: the demo is full, try later', /demo is full/i.test(await text(f, '.login-error')), await text(f, '.login-error'))
  await f.close()

  ok('5 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}
if (failed) { console.error(`FAIL: ${failed} check(s) failed`); process.exit(1) }
console.log('all login-demo-intro checks passed')
