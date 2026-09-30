// The "Display name" field, proved in a REAL browser (owner
// 2026-09-25: "there should be an option for the users to show their display
// name" / "in their user settings").
//
// Against the mock bundle, with the hub's two auth routes answered by this
// test (GET /api/v1/auth/session and PUT /api/v1/auth/preferences, the
// contract of auth-v1 §3): Settings → Profile shows the current name; an
// empty name is refused in the page and never sent; a new name is PUT as
// display_name alone, with no header the hub's auth CORS does not allow
// (auth_cors.go: Content-Type, X-Locale); the user menu shows it without a reload; after a reload the
// hub's answer still carries it.
//
// CONTROL: the user menu shows the OLD name before the save, so a menu that
// always reads the typed text (or a selector that matches nothing) cannot
// read green. Plant the defect and watch it go red (the save is skipped):
//   PROVE_RED=no-save pnpm run test:e2e:display-name
//
// Run:
//   pnpm run test:e2e:display-name
//   BASE_URL=<generated bundle> pnpm run test:e2e:display-name     # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''
const FIELD = '[data-test=settings-display-name]'
const SAVE = '[data-test=settings-display-name-save]'
const STATUS = '[data-test=settings-display-name-status]'

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
        defaultViewport: { width: 1280, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

// The hub, as far as this page needs it: one signed-in human whose name the
// PUT changes. It mirrors the hub's rule only loosely - the page must refuse
// the bad name before it is ever sent, and step 3 counts the PUTs.
const hub = { name: 'Old Name', puts: [] }
const json = (status, body) => ({ status, contentType: 'application/json', body: JSON.stringify(body) })
function answer(req) {
  const u = new URL(req.url())
  if (!u.pathname.startsWith('/api/v1/auth/')) return null
  const path = u.pathname.slice('/api/v1/auth/'.length)
  if (path === 'session' && req.method() === 'GET') {
    return json(200, {
      v: 1, p: 'password', sub: 'person@example.com', email: 'person@example.com', name: hub.name,
      hum: 'HUM-4', t: 't1', iat: 1, exp: 4102444800, preferred_locale: null, diagnostics_enabled: false,
      active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'owner' }],
    })
  }
  if (path === 'preferences' && req.method() === 'PUT') {
    let body = {}
    try { body = JSON.parse(req.postData() || '{}') } catch { /* counted below */ }
    hub.puts.push({ body, headers: req.headers() })
    const name = typeof body.display_name === 'string' ? body.display_name.trim() : ''
    if (!name) return json(400, { error: 'invalid_display_name' })
    hub.name = name
    return json(200, { display_name: name })
  }
  if (path === 'providers') return json(200, { providers: [], native: true })
  return json(404, { error: 'not_found' })
}

async function menuName(p) {
  await p.click('[data-test=user-menu-trigger]')
  const el = await p.waitForSelector('[data-test=user-menu-primary]', { visible: true, timeout: 5000 }).catch(() => null)
  const text = el ? (await el.evaluate((e) => e.textContent || '')).trim() : null
  await p.keyboard.press('Escape')
  await sleep(150)
  return text
}

async function setField(p, text) {
  await p.$eval(FIELD, (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  if (text) await p.type(FIELD, text)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  // specs/054: the mock is signed-OUT by default and its GET /session no longer
  // rides the network (auth-client.mjs), so the `session` stub above only serves
  // a real BASE_URL. In the mock bundle we opt into a signed-in owner through
  // localStorage; the display name rides a control key (spool.mock.name) so the
  // reload's probe reads the persisted name (kept in step with hub.name below).
  await p.evaluateOnNewDocument(() => {
    try {
      const nm = localStorage.getItem('spool.mock.name')
      localStorage.setItem('spool.mock.session', JSON.stringify({
        v: 1, p: 'password', sub: 'person@example.com', email: 'person@example.com',
        name: nm === null ? 'Old Name' : nm, hum: 'HUM-4', t: 't1',
        active_tenant: 't1', tenants: [{ tenant_id: 't1', role: 'owner' }],
      }))
    } catch { /* opaque origin on the very first document */ }
  })
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    const a = answer(req)
    if (a) req.respond(a).catch(() => {})
    else req.continue().catch(() => {})
  })
  await p.goto(server.base + '/settings/profile', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(FIELD, { visible: true, timeout: NAV_TIMEOUT })

  // 1. the current name, in the field and (CONTROL) in the menu
  const v0 = await p.$eval(FIELD, (e) => e.value)
  ok('1 the field shows the current name', v0 === 'Old Name', { v0 })
  const m0 = await menuName(p)
  ok('2 CONTROL: the user menu shows the old name before any save', m0 === 'Old Name', { m0 })

  // 2. an empty name is refused in the page and never sent
  await setField(p, '   ')
  await p.click(SAVE)
  await sleep(300)
  const s1 = await p.$eval(STATUS, (e) => e.textContent.trim()).catch(() => '')
  ok('3 an empty name is refused in the page, nothing is sent', hub.puts.length === 0 && s1 !== '', { puts: hub.puts.length, s1 })

  // 3. a new name is saved and shows in the menu without a reload
  await setField(p, 'New Name')
  if (RED !== 'no-save') await p.click(SAVE)
  await p.waitForFunction((sel) => document.querySelector(sel)?.textContent?.trim(), { timeout: 5000 }, STATUS).catch(() => null)
  const put = hub.puts[0]
  ok('4 exactly one PUT, carrying display_name only', hub.puts.length === 1 && JSON.stringify(put?.body) === '{"display_name":"New Name"}',
    { puts: hub.puts.map((x) => x.body) })
  const custom = put ? Object.keys(put.headers).filter((h) => /^x-/i.test(h) && h.toLowerCase() !== 'x-locale') : []
  ok('5 no header the auth CORS does not allow', Boolean(put) && custom.length === 0 && /json/.test(put.headers['content-type'] || ''), { custom })
  const m1 = await menuName(p)
  ok('6 the user menu shows the new name without a reload', m1 === 'New Name', { m1 })

  // 4. a reload asks the hub again — the opt-in mock session reads the saved
  //    name from the control key (the network /session stub is bypassed in mock)
  await p.evaluate((nm) => localStorage.setItem('spool.mock.name', nm), hub.name).catch(() => {})
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(FIELD, { visible: true, timeout: NAV_TIMEOUT })
  const v2 = await p.$eval(FIELD, (e) => e.value)
  const m2 = await menuName(p)
  ok('7 after a reload the field and the menu keep the new name', v2 === 'New Name' && m2 === 'New Name', { v2, m2 })
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
