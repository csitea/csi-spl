// Zero console errors gate (ported from the donor WUI's console-errors test).
//
// Drives every WUI route and fails on any console error, uncaught page error,
// failed request, HTTP 5xx, or hydration mismatch. Hydration warnings count
// as errors — Vue logs them via console.warn, so warnings whose text matches
// HYDRATION_RE are escalated: they mean server and client rendered different
// DOM.
//
// Run:
//   pnpm test:e2e:console-errors                      (boots nuxi dev, mock tenant)
//   BASE_URL=http://127.0.0.1:3000 pnpm test:e2e:console-errors
//
// Env:
//   BASE_URL     WUI origin to audit (default: start `nuxi dev` in mock mode)
//   CHROME_PATH  chrome/chromium binary (default /usr/bin/google-chrome)
//   PATHS        space/comma separated routes to visit
//   NAV_TIMEOUT  per-navigation timeout in ms (default 30000)
import puppeteer from 'puppeteer-core'
import { startServer } from './lib/server.mjs'

const CHROME = process.env.CHROME_PATH ?? '/usr/bin/google-chrome'
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 30000)

// The deliberate unknown route: Nuxt reports its own 404 (the document status
// in lde, `Page not found: <path>` from the client router on Hosting). Those
// two lines, on this one route, are the error page working, not a defect.
const NOT_FOUND_PATH = '/no-such-page'

const split = (v, dflt) => (v ? v.split(/[\s,]+/).filter(Boolean) : dflt)
const PATHS = split(process.env.PATHS, [
  '/login',
  '/',
  '/lobby',
  '/channel/general',
  '/t/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  '/?thread=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  NOT_FOUND_PATH,
])

// Vue/Nuxt hydration mismatches surface as warnings; treat them as errors.
const HYDRATION_RE = /hydration|hydrat(ing|ed) mismatch|text content does not match/i

// Noise that is not an app defect: browser-level chatter we cannot control.
const IGNORE_RE = [
  /Download the (Vue|React) Devtools/i, // framework advertisement
  /^\[vite\]/i,                         // dev-server HMR chatter
]

const problems = []
const notes = []
const visited = []
let serverStarted = false

function record(scope, kind, text) {
  if (IGNORE_RE.some((re) => re.test(text))) return
  problems.push({ scope, kind, text: text.replace(/\s+/g, ' ').slice(0, 400) })
}

// A harness-started `nuxi dev` has no hub and no auth proxy, so the sign-in
// registry (GET /api/v1/auth/providers) answers 404 there by construction and
// SocialAuthButtons shows "unavailable". That one resource is expected in that
// one setup; against BASE_URL (a real hub or Hosting) it is a failure.
function expectedInHarness(url) {
  return serverStarted && !process.env.NUXT_DEV_AUTH_PROXY && /\/api\/v1\/auth\//.test(url || '')
}

async function auditPage(browser, base, path) {
  const url = `${base}${path}`
  const page = await browser.newPage()
  const scope = path
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  page.on('console', (msg) => {
    const type = msg.type()
    const text = msg.text()
    if (type === 'error') {
      const loc = msg.location()?.url || ''
      if (path === NOT_FOUND_PATH && (text.includes(`Page not found: ${NOT_FOUND_PATH}`) || loc.endsWith(NOT_FOUND_PATH))) return
      if (expectedInHarness(loc)) { notes.push(`${scope}: ${text} (${loc})`); return }
      record(scope, 'console.error', `${text}${loc ? ` @ ${loc}` : ''}`)
    } else if (type === 'warning' && HYDRATION_RE.test(text)) {
      record(scope, 'hydration', text)
    }
  })
  page.on('pageerror', (err) => record(scope, 'pageerror', err.message))
  page.on('requestfailed', (req) => {
    // Aborted navigations are not failures.
    const reason = req.failure()?.errorText ?? ''
    if (reason === 'net::ERR_ABORTED') return
    record(scope, 'requestfailed', `${req.url()} — ${reason}`)
  })
  page.on('response', (res) => {
    if (res.status() >= 500) record(scope, 'http5xx', `${res.status()} ${res.url()}`)
  })
  try {
    const resp = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    const want404 = path === NOT_FOUND_PATH
    if (resp && resp.status() >= 400 && !(want404 && resp.status() === 404)) {
      record(scope, 'http', `${resp.status()} on ${url}`)
    }
    // Let hydration finish; that is where mismatches are logged.
    await page.waitForNetworkIdle({ idleTime: 700, timeout: 12000 }).catch(() => {})
    await new Promise((r) => setTimeout(r, 400))
    if (path === NOT_FOUND_PATH) {
      const shown = await page.$('[data-test="error-page"]')
      if (!shown) record(scope, 'error-page', 'unknown route did not render error.vue')
    }
  } catch (e) {
    record(scope, 'navigation', e.message)
  } finally {
    visited.push(scope)
    await page.close().catch(() => {})
  }
}

;(async () => {
  const server = await startServer()
  serverStarted = server.started
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  })
  console.log(`console-error gate against ${server.base}`)
  console.log(`  paths: ${PATHS.join(', ')}`)
  try {
    for (const path of PATHS) {
      const before = problems.length
      await auditPage(browser, server.base, path)
      const added = problems.length - before
      console.log(added === 0 ? `  OK   ${path}` : `  FAIL ${path} (${added} problem(s))`)
    }
  } finally {
    await browser.close().catch(() => {})
    await server.stop()
  }

  console.log(`\nvisited ${visited.length} page(s)`)
  for (const n of notes) console.log(`  note (expected without a hub): ${n}`)
  if (problems.length) {
    console.log(`\n${problems.length} console problem(s):`)
    for (const p of problems) console.log(`  [${p.kind}] ${p.scope}: ${p.text}`)
    process.exit(1)
  }
  console.log('zero console errors')
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
