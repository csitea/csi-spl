// SPL-993 (M5): the desktop no-change check. Screenshots of every page this
// lane touches at 1440x900, written to SHOTS_DIR; run it on the tree before
// and after the change and compare the files byte for byte (cmp). A desktop
// layout that moved a pixel shows as a differing file.
//
// Run:
//   SHOTS_DIR=/tmp/before node tests/e2e/mobile-m5-desktop-shots.mjs
import { createRequire } from 'node:module'
import { mkdir } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const DIR = process.env.SHOTS_DIR || ''
if (!DIR) { console.error('SHOTS_DIR must be set'); process.exit(2) }
const W = Number(process.env.SHOT_W || 1440)
const H = Number(process.env.SHOT_H || 900)
const PAGES = [
  ['settings-profile', '/settings/profile', '[data-test=settings]'],
  ['settings-behaviour', '/settings/behaviour', '[data-test=rail-order-setting]'],
  ['archive', '/archive', '[data-test=archive-page]'],
  ['events', '/events', '[data-test=events-page]'],
  ['login', '/login', '.login-card'],
  ['reset', '/reset-password?token=' + 'a'.repeat(64), '.login-card'],
  ['dialog', '/channel/lobby', '[data-testid=create-channel]', '[data-testid=create-channel]'],
]

// One signed-in owner, the auth routes only (the display-name test's hub).
const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
function answer(req) {
  const u = new URL(req.url())
  if (!u.pathname.startsWith('/api/v1/auth/')) return null
  const path = u.pathname.slice('/api/v1/auth/'.length)
  if (path === 'session' && req.method() === 'GET' && !process.env.SIGNED_OUT) {
    return json(200, {
      v: 1, p: 'password', sub: 'person@example.com', email: 'person@example.com', name: 'FirstName LastName',
      hum: 'HUM-4', t: 't1', iat: 1, exp: 4102444800, preferred_locale: null, diagnostics_enabled: false,
      active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'owner' }],
    })
  }
  if (path === 'session') return json(401, { error: 'unauthenticated' })
  if (path === 'providers') return json(200, { providers: [], native: true })
  if (path === 'events') return json(200, { events: [
    { id: 2, error_id: 'e-2', at: '2026-09-27T08:00:00Z', received_at: '2026-09-27T08:00:01Z', source: 'wui', status: 500, message: 'a long message that has to wrap on a phone and must never widen the page', route: '/channel/lobby?with=a-long-query-string' },
    { id: 1, error_id: 'e-1', at: '2026-09-27T07:00:00Z', received_at: '2026-09-27T07:00:01Z', source: 'hub', status: 404, message: 'not found', route: '/t/abc' },
  ], next_before: 0 })
  return json(404, { error: 'not_found' })
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return (mod.default ?? mod).launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: { width: W, height: H },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

await mkdir(DIR, { recursive: true })
const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    const a = answer(req)
    if (a) req.respond(a).catch(() => {})
    else req.continue().catch(() => {})
  })
  await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  for (const [name, path, wait, click] of PAGES) {
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: 60000 })
    await p.waitForSelector(wait, { timeout: 30000 }).catch(() => null)
    if (click) {
      await p.click(click).catch(() => null)
      await p.waitForSelector('[data-testid=ui-dialog]', { timeout: 5000 }).catch(() => null)
    }
    await new Promise((r) => setTimeout(r, 800))
    await p.screenshot({ path: `${DIR}/${name}.png` })
    console.log(`  shot ${name}`)
  }
} finally {
  await browser.close()
  await server.stop()
}
