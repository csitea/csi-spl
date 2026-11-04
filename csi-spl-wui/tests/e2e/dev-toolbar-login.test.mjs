// Spec 148 row B7 (SPL-4750): the sign-in page offers the one-click "Dev
// login" on local dev mode, and nowhere else. Acceptance run c-820 (SPL-4533)
// found the API answering but no button on /login: DevToolbar.vue was mounted
// nowhere and no served script carried the endpoint.
//
// Local dev mode is what the compose web container's /config.json says
// (envName "lde") on a loopback page. The mock bundle asks no /config.json,
// so this sets the same client-only value where the file lands
// (window.__NUXT__.config.public), as login-env-hydration does; the e2e
// server is on 127.0.0.1, a loopback host. POST /api/v1/auth/dev-login is
// answered here. Then, signed out on /login:
//   1. envName "lde": the toolbar and its Dev login button show; a click
//      POSTs the endpoint and loads the ?redirect page
//   2. envName "prd", and 3. the bundle as built (no envName): no toolbar,
//      and no script the page loaded names the endpoint, "/dev-login"
//      (CONTROL: case 1's scripts do), so a dev / prd page never downloads it
//
// Run:
//   node tests/e2e/dev-toolbar-login.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/dev-toolbar-login.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const ENDPOINT = '/api/v1/auth/dev-login'
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: { width: 1280, height: 900 }, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* What /config.json does on a served page: envName set on the client only. */
function runtimeEnv(env) {
  let held
  Object.defineProperty(window, '__NUXT__', {
    configurable: true,
    get: () => held,
    set: (v) => {
      held = new Proxy(v || {}, {
        set(t, k, val) {
          if (k === 'config' && val && val.public) val.public.envName = env
          t[k] = val
          return true
        },
      })
    },
  })
}

/** A page on /login?redirect=/lobby with envName `env` (null = as built). */
async function open(browser, base, env) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const seen = { posts: [], scripts: [], errors: [] }
  p.on('pageerror', (e) => seen.errors.push(String(e && e.message)))
  p.on('response', async (res) => {
    if (res.request().resourceType() !== 'script') return
    seen.scripts.push(await res.text().catch(() => ''))
  })
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (new URL(req.url()).pathname.endsWith(ENDPOINT)) {
      seen.posts.push({ method: req.method() })
      return req.respond({ status: 204, body: '' })
    }
    return req.continue()
  })
  if (env !== null) await p.evaluateOnNewDocument(runtimeEnv, env)
  await p.goto(base + '/login?redirect=%2Flobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.login-card', { timeout: NAV_TIMEOUT })
  return { p, ctx, seen, namesEndpoint: () => seen.scripts.some((s) => s.includes('/dev-login')) }
}

const server = await startServer()
const browser = await launch()
try {
  // 1. local dev mode: shown, and it signs in
  const lde = await open(browser, server.base, 'lde')
  const btn = await lde.p.waitForSelector('[data-testid=dev-toolbar-login]', { visible: true, timeout: 20000 }).catch(() => null)
  ok('1 envName "lde" on 127.0.0.1: the Dev login button is shown', Boolean(btn))
  const label = btn ? await btn.evaluate((e) => e.textContent.trim()) : ''
  ok('1b it is labelled, in words', /dev/i.test(label), label)
  ok('1c the Mailpit inbox link is there too', Boolean(await lde.p.$('[data-testid=dev-toolbar-mailpit]')))
  ok('1d CONTROL: a script this page loaded names the endpoint', lde.namesEndpoint())
  if (btn) {
    await Promise.all([
      lde.p.waitForNavigation({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => null),
      btn.click(),
    ])
  }
  ok('1e the click POSTs the dev-login endpoint once', lde.seen.posts.length === 1 && lde.seen.posts[0].method === 'POST', lde.seen.posts)
  ok('1f then the app loads on the ?redirect page', new URL(lde.p.url()).pathname === '/lobby', lde.p.url())
  ok('1g no page errors', lde.seen.errors.length === 0, lde.seen.errors)
  await lde.ctx.close()

  // 2, 3. a deployed env, and the bundle as built: absent, never downloaded
  for (const [n, why, env] of [['2', 'envName "prd"', 'prd'], ['3', 'the bundle as built (no envName)', null]]) {
    const o = await open(browser, server.base, env)
    await new Promise((r) => setTimeout(r, 2500))
    ok(`${n} ${why}: no dev toolbar`, !(await o.p.$('[data-testid=dev-toolbar]')))
    ok(`${n}b ${why}: no script the page loaded names the endpoint`, !o.namesEndpoint(), o.seen.scripts.length)
    ok(`${n}c ${why}: no dev-login request`, o.seen.posts.length === 0, o.seen.posts)
    await o.ctx.close()
  }
} catch (e) {
  ok('harness', false, String(e && e.message || e))
} finally {
  await browser.close()
  await server.stop()
}
if (failed) { console.error(`dev-toolbar-login: FAIL (${failed})`); process.exit(1) }
console.log('dev-toolbar-login: PASS')
