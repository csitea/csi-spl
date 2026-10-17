// SPL-2418 (owner HUM-10, t1 5d787b1a): an admin who is a member of every
// workspace cycles through each one of them on a phone, by touch taps.
// Owner msg 98e10b19: "create a test that an admin user having access to all
// of the workspaces is able to cycle through each one of them on mobile."
//
// At 390x844 with touch emulated, the mock session holds four workspaces:
//   1. in place (the mock's own switch): each tap on the next workspace
//      switches to it and closes the sheet; an outside tap (the scrim)
//      closes the sheet every time.
//   2. leaving the page like the hub does (localStorage
//      spool.mock.tenant-switch-loads, SPL-2399): each tap loads the next
//      workspace's page; then Back. The page under it comes back from the
//      bfcache with the sheet it kept open while leaving. Measured on prd
//      30b3c3e0a (n=1): every row stayed disabled (`switching` stuck true),
//      a tap did nothing, the sheet came back the same after a close. Now the
//      sheet is closed, the box not busy, and a tap switches again.
//
// Run:
//   BASE_URL=<generated mock bundle> node tests/e2e/tenant-cycle-phone.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const TENANTS = [
  { tenant_id: 't1', display_name: 'Workspace one' },
  { tenant_id: 't2', display_name: 'Workspace two' },
  { tenant_id: 't3', display_name: 'Workspace three' },
  { tenant_id: 't4', display_name: 'Workspace four' },
]
const HOOK = 'spool.mock.tenant-switch-loads'
const results = []
function check(name, pass, ev) {
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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* an admin of every workspace, `active` the one on screen */
const signIn = (p, active) => p.evaluate((active, tenants) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({
    hum: 'HUM-1', email: 'admin@example.com', name: 'FirstName LastName', t: active, active_tenant: active, role: 'admin',
    tenants: tenants.map((x) => ({ ...x, role: 'admin' })),
  })
  return true
}, active, TENANTS)

async function ready(p, active) {
  await p.waitForSelector('[data-test=top-bar]')
  if (!(await signIn(p, active))) throw new Error('no session store')
  await p.waitForSelector('[data-testid=top-bar-tenant-box]')
  await sleep(400)
}

const sheetShown = (p) => p.evaluate(() => Boolean(document.querySelector('[data-testid=top-bar-tenant-sheet]')))
const state = (p) => p.evaluate(() => ({
  sheet: Boolean(document.querySelector('[data-testid=top-bar-tenant-sheet]')),
  busy: document.querySelector('[data-testid=top-bar-tenant-box]')?.getAttribute('aria-busy') || null,
  name: document.querySelector('[data-testid=top-bar-tenant-name]')?.textContent?.trim() || '',
  rows: [...document.querySelectorAll('[data-testid=top-bar-tenant-option]')].map((b) => ({ id: b.getAttribute('data-tenant'), off: b.disabled })),
}))

async function openSheet(p) {
  await p.tap('[data-testid=top-bar-tenant-box]')
  await p.waitForSelector('[data-testid=top-bar-tenant-option]', { timeout: 5000 }).catch(() => {})
  await sleep(300)
}

/* an outside tap: the scrim above the sheet */
async function tapOutside(p, tag) {
  await openSheet(p)
  await p.touchscreen.tap(195, 120)
  await sleep(400)
  check(`${tag}: an outside tap closes the sheet`, !(await sheetShown(p)), await state(p))
}

async function inPlace(p, base) {
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(`${base}/`, { waitUntil: 'load' })
  await ready(p, 't1')
  const order = [...TENANTS.slice(1), TENANTS[0]]
  for (const next of order) {
    const tag = `in place -> ${next.tenant_id}`
    await tapOutside(p, tag)
    await openSheet(p)
    const s = await state(p)
    check(`${tag}: the sheet lists all ${TENANTS.length} workspaces, every row enabled`, s.rows.length === TENANTS.length && s.rows.every((r) => !r.off), s.rows)
    await p.tap(`[data-testid=top-bar-tenant-option][data-tenant="${next.tenant_id}"]`)
    await sleep(500)
    const after = await state(p)
    check(`${tag}: the switch lands and closes the sheet`, after.name === next.display_name && !after.sheet && !after.busy, after)
  }
}

async function leaving(p, base) {
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.evaluateOnNewDocument(() => {
    addEventListener('pageshow', (e) => { window.__restored = e.persisted })
  })
  await p.goto(`${base}/`, { waitUntil: 'load' })
  await p.evaluate((k) => localStorage.setItem(k, '1'), HOOK)
  try {
    await ready(p, 't1')
    const order = [...TENANTS.slice(1), TENANTS[0]]
    let at = 't1'
    for (const next of order) {
      const tag = `leaving ${at} -> ${next.tenant_id}`
      await tapOutside(p, tag)
      await openSheet(p)
      const loaded = p.waitForNavigation({ waitUntil: 'load', timeout: 5000 }).then(() => true, () => false)
      await p.tap(`[data-testid=top-bar-tenant-option][data-tenant="${next.tenant_id}"]`)
      const nav = await loaded
      const url = p.url()
      check(`${tag}: the tap loads the workspace's page`, nav && new URL(url).searchParams.get('tenant') === next.tenant_id, { url, nav })
      await ready(p, next.tenant_id)
      at = next.tenant_id
    }
    /* Back: the page before the last switch, restored with its sheet */
    await p.goBack({ waitUntil: 'load' }).catch(() => {})
    await sleep(800)
    const restored = await p.evaluate(() => window.__restored === true)
    check('Back: the page under it came back from the bfcache (the case under test)', restored, { url: p.url() })
    const back = await state(p)
    check('Back: the sheet is closed and the box is not busy', !back.sheet && !back.busy, back)
    await openSheet(p)
    const reopened = await state(p)
    check('Back: the sheet opens with every row enabled', reopened.sheet && reopened.rows.length === TENANTS.length && reopened.rows.every((r) => !r.off), reopened.rows)
    const loaded = p.waitForNavigation({ waitUntil: 'load', timeout: 5000 }).then(() => true, () => false)
    await p.tap('[data-testid=top-bar-tenant-option][data-tenant="t3"]').catch(() => {})
    const nav = await loaded
    check('Back: a tap on another workspace switches again', nav && new URL(p.url()).searchParams.get('tenant') === 't3', { url: p.url(), nav })
  } finally {
    await p.evaluate((k) => localStorage.removeItem(k), HOOK).catch(() => {})
  }
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await inPlace(await browser.newPage(), server.base)
  await leaving(await browser.newPage(), server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntenant-cycle-phone: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
