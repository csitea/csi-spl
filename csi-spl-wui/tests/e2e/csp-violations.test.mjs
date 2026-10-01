// CSP gate (spec 017 FR-SEC-005, T013/T014).
//
// Drives every WUI route in headless Chrome and fails on ANY Content-Security-
// Policy violation (a `securitypolicyviolation` event or a console "Refused to"
// line). Then runs the CONTROL: it injects an inline <script> and an inline
// event handler into a loaded page and requires that neither runs — the
// exploit an XSS would use. With EXPECT_CONTROL=runs the control is inverted,
// which is how the OLD policy ('unsafe-inline') is shown to have let it run.
//
// Run:
//   pnpm test:e2e csp          serve .output/public locally with the headers of
//                              the Hosting render (render-wui-firebase-json.sh)
//   BASE_URL=https://<site>.web.app pnpm test:e2e csp   the deployed site
//
// Env:
//   BASE_URL        audit this origin instead of serving the bundle locally
//   CSP_ENV         env whose cnf the local render uses (default dev)
//   CSP_OVERRIDE    local only: serve this policy instead of the rendered one
//   EXPECT_CONTROL  blocked (default) | runs
//   PUBLIC_DIR      the generated bundle (default .output/public)
//   CHROME_PATH     chrome/chromium binary (default /usr/bin/google-chrome)
//   PATHS           space/comma separated routes to visit
import puppeteer from 'puppeteer-core'
import { spawnSync } from 'node:child_process'
import { createServer } from 'node:http'
import { existsSync, mkdtempSync, readFileSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, extname, join, normalize } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REPO = join(WUI, '..')
const CHROME = process.env.CHROME_PATH ?? '/usr/bin/google-chrome'
const EXPECT_CONTROL = process.env.EXPECT_CONTROL ?? 'blocked'
const PUBLIC_DIR = process.env.PUBLIC_DIR ?? join(WUI, '.output/public')
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 30000)
const split = (v, dflt) => (v ? v.split(/[\s,]+/).filter(Boolean) : dflt)
const PATHS = split(process.env.PATHS, [
  '/login',
  '/',
  '/lobby',
  '/channel/general',
  '/channel/alerts',
  '/t/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  '/settings/keys',
  '/search?q=deploy',
  '/no-such-page',
])
if (!['blocked', 'runs'].includes(EXPECT_CONTROL)) throw new Error(`EXPECT_CONTROL=${EXPECT_CONTROL}`)

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain',
}

/** The `**` headers of a firebase.json rendered for CSP_ENV from this bundle. */
function renderedHeaders() {
  const out = join(mkdtempSync(join(tmpdir(), 'csp-')), 'firebase.json')
  const r = spawnSync('bash', [join(REPO, 'csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh')], {
    env: { ...process.env, ENV: process.env.CSP_ENV ?? 'dev', OUT: out, PUBLIC_DIR },
    encoding: 'utf8',
  })
  if (r.status !== 0) throw new Error(`render failed: ${r.stderr}`)
  const doc = JSON.parse(readFileSync(out, 'utf8'))
  const all = doc.hosting.headers.find((h) => h.source === '**')
  return Object.fromEntries(all.headers.map((h) => [h.key, h.value]))
}

/** Firebase-Hosting-shaped static server: cleanUrls, then the /200.html SPA fallback. */
function serveBundle(headers) {
  const file = (p) => existsSync(p) && statSync(p).isFile()
  const server = createServer((req, res) => {
    const path = normalize(decodeURIComponent(new URL(req.url, 'http://x').pathname)).replace(/^(\.\.[/\\])+/, '')
    const base = join(PUBLIC_DIR, path)
    const hit = [base, `${base}.html`, join(base, 'index.html')].find(file) ?? join(PUBLIC_DIR, '200.html')
    res.writeHead(200, { ...headers, 'Content-Type': MIME[extname(hit)] ?? 'application/octet-stream' })
    res.end(readFileSync(hit))
  })
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)))
}

// Collect violations from inside the page, before any app script runs.
const LISTEN = () => {
  window.__cspViolations = []
  document.addEventListener('securitypolicyviolation', (e) => {
    window.__cspViolations.push(`${e.violatedDirective} blocked ${e.blockedURI || 'inline'} (${e.sourceFile || ''}:${e.lineNumber})`)
  })
}

let server
let baseUrl = process.env.BASE_URL?.replace(/\/+$/, '')
if (!baseUrl) {
  if (!existsSync(join(PUBLIC_DIR, '200.html'))) throw new Error(`no bundle at ${PUBLIC_DIR}: run nuxt generate first`)
  const headers = renderedHeaders()
  if (process.env.CSP_OVERRIDE) headers['Content-Security-Policy'] = process.env.CSP_OVERRIDE
  server = await serveBundle(headers)
  baseUrl = `http://127.0.0.1:${server.address().port}`
}

const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: ['--no-sandbox'] })
const problems = []
let policy = ''
try {
  for (const path of PATHS) {
    const page = await browser.newPage()
    await page.evaluateOnNewDocument(LISTEN)
    const consoleCsp = []
    page.on('console', (m) => {
      if (/Content Security Policy|Refused to/i.test(m.text())) consoleCsp.push(m.text())
    })
    const resp = await page.goto(baseUrl + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    policy ||= resp?.headers()['content-security-policy'] ?? ''
    await new Promise((r) => setTimeout(r, 500))
    const events = await page.evaluate(() => window.__cspViolations ?? [])
    for (const v of [...events, ...consoleCsp]) problems.push(`${path}: ${v.replace(/\s+/g, ' ').slice(0, 300)}`)
    console.log(`${events.length + consoleCsp.length === 0 ? 'ok  ' : 'FAIL'} ${path} (${events.length} event(s), ${consoleCsp.length} console line(s))`)
    await page.close()
  }

  // CONTROL: what an XSS would do once it has a foothold in the DOM.
  const page = await browser.newPage()
  await page.evaluateOnNewDocument(LISTEN)
  await page.goto(`${baseUrl}/login`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const control = await page.evaluate(async () => {
    const s = document.createElement('script')
    s.textContent = 'window.__cspInlineScriptRan = 1'
    document.head.appendChild(s)
    const img = document.createElement('div')
    img.innerHTML = '<img src="data:image/png;base64,!" onerror="window.__cspInlineHandlerRan = 1">'
    document.body.appendChild(img)
    await new Promise((r) => setTimeout(r, 500))
    return {
      script: window.__cspInlineScriptRan === 1,
      handler: window.__cspInlineHandlerRan === 1,
      violations: window.__cspViolations.length,
    }
  })
  await page.close()
  const ran = control.script || control.handler
  console.log(`control: inline script ran=${control.script}, inline handler ran=${control.handler}, violations=${control.violations} (expected: ${EXPECT_CONTROL})`)
  if (EXPECT_CONTROL === 'blocked' && (ran || control.violations < 2)) problems.push('CONTROL: injected inline code was not blocked')
  if (EXPECT_CONTROL === 'runs' && !(control.script && control.handler)) problems.push('CONTROL (runs): injected inline code did not run')
} finally {
  await browser.close()
  server?.close()
}

console.log(`policy: ${policy}`)
if (problems.length) {
  console.error(`FAIL: ${problems.length} CSP problem(s) on ${baseUrl}`)
  for (const p of problems) console.error(`  ${p}`)
  process.exit(1)
}
console.log(`PASS: 0 CSP violations on ${PATHS.length} route(s) of ${baseUrl}; control ${EXPECT_CONTROL}`)
