// SPL-1797: /login hydrates without a mismatch when the env comes at runtime.
//
// The deployed /login is prerendered by a build that knows no env; the served
// /config.json (spec 072 A3) gives the client `envName` before hydration. The
// login bar named that env in its first client render ("spool-dev" + a "dev"
// tag), the document said "spool-hub": every load logged "Hydration completed
// but contains mismatches", and p2-smoke on dev failed on it.
//
// The mock bundle asks no /config.json, so this sets the same client-only
// value where the file lands: window.__NUXT__.config.public, before the app
// boots. Then, signed out on /login:
//   - no hydration warning or error in the console
//   - once mounted, the bar names the env: the "dev" tag and "spool-dev"
//
// Run:
//   node tests/e2e/login-env-hydration.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/login-env-hydration.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const HYDRATION_RE = /hydration|hydrat(ing|ed) mismatch|text content does not match/i
const results = []
function check(name, pass, ev) {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* What /config.json does on a deployed page: envName set on the client only. */
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

const server = await startServer()
const browser = await launch()
let failed = false
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  const hydration = []
  p.on('console', (m) => {
    if ((m.type() === 'error' || m.type() === 'warn' || m.type() === 'warning') && HYDRATION_RE.test(m.text())) hydration.push(m.text().slice(0, 200))
  })
  await p.evaluateOnNewDocument(runtimeEnv, 'dev')
  await p.goto(server.base + '/login', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.login-card', { timeout: NAV_TIMEOUT })
  const tag = await p.waitForFunction(
    () => document.querySelector('[data-test=login-bar-env]')?.textContent?.trim() || '',
    { timeout: 15000 },
  ).then((h) => h.jsonValue()).catch(() => '')
  const named = await p.evaluate(() => document.querySelector('[data-test=login-bar-logo]')?.getAttribute('title') || '')
  check('signed out /login: no hydration mismatch with a runtime env', hydration.length === 0, hydration.slice(0, 3))
  check('once mounted the bar names the runtime env ("dev" tag, spool-dev)', tag === 'dev' && named === 'spool-dev', { tag, named })
} catch (e) {
  check('harness', false, String(e && e.message || e))
} finally {
  await browser.close()
  await server.stop()
  failed = results.some((r) => !r.ok)
  console.log(failed ? 'login-env-hydration: FAIL' : 'login-env-hydration: PASS')
  process.exit(failed ? 1 : 0)
}
