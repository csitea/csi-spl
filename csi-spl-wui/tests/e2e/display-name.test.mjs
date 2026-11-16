// The "Name and phone" fields (first name, last name, phone; SPL-5707, spec
// 154 section 12.5, which replaced the single "Display name" field), proved
// in a REAL browser (owner 2026-09-25: "there should be an option for the
// users to show their display name" / "in their user settings"; t1 028ac340
// poll 36ec7895: first + last name and a phone shown to the other members).
//
// Against the mock bundle, with the hub's two auth routes answered by this
// test (GET /api/v1/auth/session and PUT /api/v1/auth/preferences, the
// contract of auth-v1 §3; GET /api/v1/auth/profile too on a real BASE_URL):
// Settings → Profile shows the current name split into first and last (the
// mock has no profile read); an empty first name and a national-form phone
// are refused in the page and never sent; the three are PUT together as
// first_name, last_name and phone (normalised), with no header the hub's
// auth CORS does not allow (auth_cors.go: Content-Type, X-Locale); the user
// menu shows the joined name without a reload; after a reload the hub's
// answer still carries it. SHOT_DIR saves the screenshot.
//
// CONTROL: the user menu shows the OLD name before the save, so a menu that
// always reads the typed text (or a selector that matches nothing) cannot
// read green. Plant the defect and watch it go red (the save is skipped):
//   PROVE_RED=no-save pnpm run test:e2e display-name
//
// Run:
//   pnpm run test:e2e display-name
//   BASE_URL=<generated bundle> pnpm run test:e2e display-name     # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''
const FIELD = '[data-test=settings-first-name]'
const LAST = '[data-test=settings-last-name]'
const PHONE = '[data-test=settings-phone]'
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
const hub = { name: 'Old Name', first: 'Old', last: 'Name', phone: null, puts: [] }
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
    const first = typeof body.first_name === 'string' ? body.first_name.trim() : ''
    if (!first) return json(400, { error: 'invalid_name' })
    if (body.phone != null && !/^\+[1-9][0-9]{6,14}$/.test(body.phone)) return json(400, { error: 'invalid_phone' })
    hub.first = first
    hub.last = body.last_name || null
    hub.phone = body.phone ?? null
    hub.name = (first + ' ' + (hub.last || '')).trim()
    return json(200, { first_name: first, last_name: hub.last, display_name: hub.name, phone: hub.phone })
  }
  if (path === 'profile' && req.method() === 'GET') {
    return json(200, { first_name: hub.first, last_name: hub.last, phone: hub.phone })
  }
  if (path === 'providers') return json(200, { providers: [], native: true })
  return json(404, { error: 'not_found' })
}

/* CLE-77853: Settings is a modal over the view, and the user menu sits behind
   its backdrop - close it (Escape), read the menu, then reopen Settings from
   the menu's own entry (the gear) on the same Profile section. */
async function menuName(p) {
  const modal = Boolean(await p.$('[data-test=settings]'))
  if (modal) {
    await p.keyboard.press('Escape')
    await p.waitForFunction(() => !document.querySelector('[data-test=settings]'), { timeout: 5000 }).catch(() => null)
  }
  await p.click('[data-test=user-menu-trigger]')
  const el = await p.waitForSelector('[data-test=user-menu-primary]', { visible: true, timeout: 5000 }).catch(() => null)
  const text = el ? (await el.evaluate((e) => e.textContent || '')).trim() : null
  if (modal) {
    await p.click('[data-test=user-menu-settings]')
    await p.waitForSelector(FIELD, { visible: true, timeout: 10000 }).catch(() => null)
  } else {
    await p.keyboard.press('Escape')
  }
  await sleep(150)
  return text
}

async function setField(p, text, sel = FIELD) {
  await p.$eval(sel, (e) => { e.value = ''; e.dispatchEvent(new Event('input', { bubbles: true })) })
  if (text) await p.type(sel, text)
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

  // 1. the current name, split into the two fields, and (CONTROL) in the menu
  const v0 = await p.$eval(FIELD, (e) => e.value)
  const l0 = await p.$eval(LAST, (e) => e.value)
  ok('1 the fields show the current name, split at the first space', v0 === 'Old' && l0 === 'Name', { v0, l0 })
  const m0 = await menuName(p)
  ok('2 CONTROL: the user menu shows the old name before any save', m0 === 'Old Name', { m0 })

  // 2. an empty first name, and a phone without + and the country code, are
  //    refused in the page and never sent
  await setField(p, '   ')
  await p.click(SAVE)
  await sleep(300)
  const s1 = await p.$eval(STATUS, (e) => e.textContent.trim()).catch(() => '')
  ok('3 an empty first name is refused in the page, nothing is sent', hub.puts.length === 0 && s1 !== '', { puts: hub.puts.length, s1 })
  await setField(p, 'New')
  await setField(p, '040 123 4567', PHONE)
  await p.click(SAVE)
  await sleep(300)
  const s2 = await p.$eval(STATUS, (e) => e.textContent.trim()).catch(() => '')
  ok('4 a national-form phone is refused in the page, nothing is sent', hub.puts.length === 0 && s2 !== '' && s2 !== s1, { puts: hub.puts.length, s2 })

  // 3. the three are saved together and the name shows in the menu without a reload
  await setField(p, 'Person Name', LAST)
  await setField(p, '+358 40 123 4567', PHONE)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/settings-name-phone.png` })
  if (RED !== 'no-save') await p.click(SAVE)
  await p.waitForFunction((sel) => document.querySelector(sel)?.textContent?.trim(), { timeout: 5000 }, STATUS).catch(() => null)
  const put = hub.puts[0]
  ok('5 exactly one PUT, carrying first_name, last_name and the normalised phone', hub.puts.length === 1 &&
    JSON.stringify(put?.body) === '{"first_name":"New","last_name":"Person Name","phone":"+358401234567"}',
  { puts: hub.puts.map((x) => x.body) })
  const custom = put ? Object.keys(put.headers).filter((h) => /^x-/i.test(h) && h.toLowerCase() !== 'x-locale') : []
  ok('6 no header the auth CORS does not allow', Boolean(put) && custom.length === 0 && /json/.test(put.headers['content-type'] || ''), { custom })
  const m1 = await menuName(p)
  ok('7 the user menu shows the joined name without a reload', m1 === 'New Person Name', { m1 })

  // 4. a reload asks the hub again — the opt-in mock session reads the saved
  //    name from the control key (the network /session stub is bypassed in mock)
  await p.evaluate((nm) => localStorage.setItem('spool.mock.name', nm), hub.name).catch(() => {})
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(FIELD, { visible: true, timeout: NAV_TIMEOUT })
  const v2 = await p.$eval(FIELD, (e) => e.value)
  const l2 = await p.$eval(LAST, (e) => e.value)
  const m2 = await menuName(p)
  ok('8 after a reload the fields and the menu keep the new name', v2 === 'New' && l2 === 'Person Name' && m2 === 'New Person Name', { v2, l2, m2 })
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
