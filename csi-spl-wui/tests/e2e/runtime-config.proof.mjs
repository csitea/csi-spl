// Spec 072 A3 acceptance: ONE `nuxt generate` with no NUXT_PUBLIC_* set,
// served with two different config.json files, calls two different api hosts.
//
// Not discovered by the e2e runner (a *.proof.mjs): it needs a NON-mock
// bundle, while CI's e2e bundle is the mock one. Build it first:
//   env -u NUXT_PUBLIC_API_BASE ... pnpm run generate   (no NUXT_PUBLIC_* at all)
// Run:
//   node tests/e2e/runtime-config.proof.mjs
//   BUNDLE=<dir> node tests/e2e/runtime-config.proof.mjs
//
// Two local servers serve the same directory; each answers /config.json with
// its own api host (host A, host B: reserved .test names, never resolved).
// The browser's requests to those hosts are intercepted and answered here:
// the session probe signs in, everything else gets an empty 200. Each origin
// must call its own host and never the other, and a third origin with NO
// config.json must call its own origin (the compose shape). Exit 0 = all held.
import { createServer } from 'node:http'
import { createRequire } from 'node:module'
import { existsSync, readFileSync, statSync } from 'node:fs'
import { extname, join, normalize, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const BUNDLE = process.env.BUNDLE || join(WUI, '.output/public')
const HOST_A = 'https://api.a-estate.test'
const HOST_B = 'https://api.b-estate.test'
const results = []
function check(name, ok, ev) {
  results.push(ok)
  console.log(`  ${ok ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

if (!existsSync(join(BUNDLE, 'index.html'))) {
  console.error(`runtime-config proof: no generated bundle at ${BUNDLE} (run pnpm run generate first)`)
  process.exit(1)
}
{
  // the bundle itself must carry no api host: the A3 premise
  const html = readFileSync(join(BUNDLE, 'index.html'), 'utf8')
  const baked = /"apiBase":"([^"]*)"/.exec(html)?.[1] ?? /apiBase:"([^"]*)"/.exec(html)?.[1] ?? '(not found)'
  check('the bundle bakes no api base (built with no NUXT_PUBLIC_API_BASE)', baked === '', { baked })
}

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' }

/** A static server for BUNDLE; `config` = the /config.json body, or null for a 404. */
function serve(config) {
  const server = createServer((req, res) => {
    const path = decodeURIComponent(new URL(req.url, 'http://x').pathname)
    if (path === '/config.json') {
      if (config === null) { res.writeHead(404); res.end(); return }
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify(config))
      return
    }
    for (const cand of [path, `${path}.html`, join(path, 'index.html'), '/200.html', '/index.html']) {
      const file = normalize(join(BUNDLE, cand))
      if (!file.startsWith(BUNDLE)) break
      if (existsSync(file) && statSync(file).isFile()) {
        res.writeHead(200, { 'content-type': TYPES[extname(file)] || 'application/octet-stream' })
        res.end(readFileSync(file))
        return
      }
    }
    res.writeHead(404)
    res.end()
  })
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ server, origin: `http://127.0.0.1:${server.address().port}` })))
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

/** Open `${origin}/` and return the hosts of the requests that went to a hub. */
async function hubCalls(browser, origin, hubHosts) {
  const page = await browser.newPage()
  const seen = []
  await page.setRequestInterception(true)
  page.on('request', (req) => {
    const u = new URL(req.url())
    const hub = hubHosts.includes(u.origin) || (u.origin === origin && /^\/(api|v1)\//.test(u.pathname))
    if (!hub) { req.continue(); return }
    seen.push(`${u.origin}${u.pathname}`)
    const headers = { 'access-control-allow-origin': origin, 'access-control-allow-credentials': 'true', 'access-control-allow-headers': '*' }
    if (req.method() === 'OPTIONS') { req.respond({ status: 204, headers }); return }
    const session = u.pathname.endsWith('/api/v1/auth/session')
    req.respond({
      status: 200,
      headers,
      contentType: 'application/json',
      body: JSON.stringify(session ? { sub: 'h1', email: 'h1@example.org', tenant: 'main', role: 'owner' } : {}),
    })
  })
  await page.goto(`${origin}/`, { waitUntil: 'domcontentloaded' })
  await new Promise((r) => setTimeout(r, Number(process.env.SETTLE_MS || 4000)))
  const pub = await page.evaluate(() => {
    const c = window.useNuxtApp?.()?.$config?.public ?? window.__NUXT__?.config?.public ?? {}
    return { apiBase: c.apiBase, authBase: c.authBase, tenant: c.tenant }
  })
  await page.close()
  return { seen, pub }
}

const a = await serve({ apiBase: HOST_A, authBase: HOST_A, tenant: 'alpha' })
const b = await serve({ apiBase: HOST_B, authBase: HOST_B, tenant: 'beta' })
const none = await serve(null)
const browser = await launch()
try {
  const ra = await hubCalls(browser, a.origin, [HOST_A, HOST_B])
  const rb = await hubCalls(browser, b.origin, [HOST_A, HOST_B])
  const rn = await hubCalls(browser, none.origin, [HOST_A, HOST_B])
  const on = (r, host) => r.seen.filter((s) => s.startsWith(host))
  check('config A: the page config names host A', r(ra.pub.apiBase) === HOST_A, ra.pub)
  check('config A: the page calls host A', on(ra, HOST_A).length > 0, on(ra, HOST_A))
  check('config A: and never host B', on(ra, HOST_B).length === 0, on(ra, HOST_B))
  check('config B: the page config names host B', r(rb.pub.apiBase) === HOST_B, rb.pub)
  check('config B: the page calls host B', on(rb, HOST_B).length > 0, on(rb, HOST_B))
  check('config B: and never host A', on(rb, HOST_A).length === 0, on(rb, HOST_A))
  check('no config.json: the api base is the page origin (compose)', r(rn.pub.apiBase) === none.origin, rn.pub)
  check('no config.json: the page calls its own origin only', on(rn, none.origin).length > 0 && on(rn, HOST_A).length + on(rn, HOST_B).length === 0, rn.seen)
} finally {
  await browser.close()
  for (const s of [a, b, none]) s.server.close()
}

function r(v) { return String(v ?? '') }

const bad = results.filter((ok) => !ok).length
console.log(bad ? `\n${bad} failed` : '\nruntime-config proof: all passed')
process.exit(bad ? 1 : 0)
