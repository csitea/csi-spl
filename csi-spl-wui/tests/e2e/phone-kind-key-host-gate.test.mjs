// perf round 6 row 11 (SPL-2439): Shift + K is off on a phone (KindKeyHost
// returns on usePhone()), so layouts/default.vue mounts <LazyKindKeyHost />
// only where stack.isMobile is false. A phone neither fetches the host's
// chunk nor runs its setup; a desktop keeps Shift + K (shift-k-middle.test.mjs
// proves the shortcut itself).
//
// The host's chunk is found by content: the one script response whose body
// holds the host's test id, so the check holds for a generated bundle (hashed
// names) and for `nuxi dev` (one module per file) alike.
//   - phone /, /channel/alerts, /issues: 0 kind-key-host elements, 0 chunks
//   - desktop /channel/alerts: 1 element, the chunk fetched
//   - phone /channel/alerts widened past 820 px: the host mounts, no reload
// Red on a build without the row: every phone case finds the host and its chunk.
//
//   BASE_URL=<generated bundle> node tests/e2e/phone-kind-key-host-gate.test.mjs
//   (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }
const DESK = { width: 1440, height: 900 }
const HOST = 'kind-key-host'
const PHONE_ROUTES = (process.env.ROUTES || '/,/channel/alerts,/issues').split(',').filter(Boolean)
const results = []
const ok = (name, pass, ev) => {
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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* opens path at viewport; census() counts the host elements and every script whose body names the host */
async function open(browser, path, viewport) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  const chunks = []
  const reads = []
  p.on('response', (res) => {
    if (res.request().resourceType() !== 'script') return
    reads.push(res.text().then((body) => { if (body.includes(HOST)) chunks.push(new URL(res.url()).pathname) }).catch(() => {}))
  })
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
    } catch { /* private mode */ }
  })
  await p.setViewport(viewport)
  await p.goto(`${srv.base}${path}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { visible: true })
  await sleep(1500)
  const census = async () => {
    await Promise.all(reads)
    return {
      hosts: await p.evaluate((id) => document.querySelectorAll(`[data-testid="${id}"]`).length, HOST),
      chunks: [...new Set(chunks)],
    }
  }
  return { p, census }
}

const srv = await startServer()
const browser = await launch()
try {
  /* 1. a phone cold load mounts no host and fetches no host chunk */
  for (const path of PHONE_ROUTES) {
    const { p, census } = await open(browser, path, PHONE)
    const c = await census()
    ok(`390px ${path}: 0 ${HOST} elements, 0 host chunks`, c.hosts === 0 && c.chunks.length === 0, c)
    await p.close()
  }

  /* 2. a desktop mounts it, so Shift + K keeps working */
  let { p, census } = await open(browser, '/channel/alerts', DESK)
  let c = await census()
  ok(`1440px /channel/alerts: 1 ${HOST} element, its chunk fetched`, c.hosts === 1 && c.chunks.length >= 1, c)
  await p.close()

  /* 3. a phone window widened past the stack breakpoint gets the host */
  ;({ p, census } = await open(browser, '/channel/alerts', PHONE))
  const before = await census()
  await p.setViewport({ ...PHONE, width: DESK.width, height: DESK.height })
  const t0 = Date.now()
  while ((await census()).hosts === 0 && Date.now() - t0 < 8000) await sleep(200)
  c = await census()
  ok('390px -> 1440px /channel/alerts: the host mounts after the widen', before.hosts === 0 && c.hosts === 1 && c.chunks.length >= 1, { before, after: c })
  await p.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nphone-kind-key-host-gate: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
