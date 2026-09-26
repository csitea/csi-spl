// SPL-979 live: the left-rail icons are reordered by dragging them in the
// rail itself (mouse and touch), the order is kept on the account (a reload
// and a fresh sign-in draw it), Settings -> Behaviour -> "Left panel order"
// shows the same order and changes it with up / down, and a plain click on
// an icon still navigates instead of reordering.
//
//   BASE=https://dev.<domain> AUTH_BASE=https://dev.api.<domain> \
//     EMAIL=<member> PW_FILE=<0600 file> [TENANT=t1] OUT=<dir> \
//     node tests/e2e/rail-order-live.proof.mjs
//
// It changes only the signed-in test member's own rail_order and puts it back
// as it found it. Run it as the dev test member (t1) or in prd tenant e2e.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const AUTH_BASE = (process.env.AUTH_BASE || BASE).replace(/\/+$/, '')
const TENANT = process.env.TENANT || 't1'
// Read once, held in memory, never printed or screenshotted.
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const DEFAULT = ['dm', 'channels', 'issues', 'topics', 'flow', 'events']
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let original
let p
const claimOf = async (page) => page.evaluate(async (base) => {
  const r = await fetch(base + '/api/v1/auth/session', { credentials: 'include', cache: 'no-store' })
  return r.status === 200 ? (await r.json()).rail_order : `status ${r.status}`
}, AUTH_BASE)
const putOrder = async (page, v) => page.evaluate(async (base, v) => (await fetch(base + '/api/v1/auth/preferences', {
  method: 'PUT', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ rail_order: v }),
})).status, AUTH_BASE, v)
const railOf = async (page) => page.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
const centre = async (page, sel) => page.$eval(sel, (el) => { const r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, h: r.height } })
const signIn = async (page) => {
  await page.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2Flobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('[data-test=native-auth-email]')
  await page.type('[data-test=native-auth-email]', EMAIL)
  await page.type('[data-test=native-auth-password]', PW)
  await page.click('[data-test=native-auth-submit]')
  await sleep(4000)
}
const waitClaim = async (page, want) => {
  for (let i = 0; i < 20; i++) { if (same(await claimOf(page), want)) return true; await sleep(300) }
  return false
}
try {
  p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport({ width: 1280, height: 900 })
  await signIn(p)
  original = await claimOf(p)
  step('signed in; the session answers rail_order', original === null || Array.isArray(original), { rail_order: original })
  // start from the default so every step below is a real change
  step('start: default order stored (PUT null)', (await putOrder(p, null)) === 200)
  await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: 15000 })
  await sleep(1000)
  step('CONTROL: the rail draws the default order', same(await railOf(p), DEFAULT), { rail: await railOf(p) })

  // ── a plain click navigates and does not reorder ─────────────────────
  await p.click('[data-testid=sidebar-tab-issues]')
  await p.waitForFunction(() => /\/issues$/.test(location.pathname), { timeout: 15000 }).catch(() => {})
  await sleep(800)
  step('click: Issues navigates to /issues', /\/issues$/.test(new URL(p.url()).pathname), { url: p.url() })
  step('click: the order did not change', same(await railOf(p), DEFAULT) && (await claimOf(p)) === null)

  // ── mouse drag: Event log to the top ─────────────────────────────────
  const from = await centre(p, '[data-testid=sidebar-tab-events]')
  const to = await centre(p, '[data-testid=sidebar-tab-dm]')
  const urlBefore = p.url()
  await p.mouse.move(from.x, from.y)
  await p.mouse.down()
  for (let i = 1; i <= 12; i++) await p.mouse.move(from.x, from.y + ((to.y - to.h / 2 - 2) - from.y) * i / 12)
  await sleep(150)
  const mid = await railOf(p)
  await p.mouse.up()
  const wantMouse = ['events', 'dm', 'channels', 'issues', 'topics', 'flow']
  await sleep(400)
  step('mouse drag: the icons follow the pointer while dragging', same(mid, wantMouse), { mid })
  step('mouse drag: the rail keeps the new order at once', same(await railOf(p), wantMouse), { rail: await railOf(p) })
  step('mouse drag: the drop is stored on the account', await waitClaim(p, wantMouse), { claim: await claimOf(p) })
  step('mouse drag: the drop did not click (no navigation)', p.url() === urlBefore, { url: p.url() })
  await p.screenshot({ path: `${OUT}/01-rail-after-mouse-drag.png` })
  await p.reload({ waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]')
  await sleep(1000)
  step('reload: the same order', same(await railOf(p), wantMouse), { rail: await railOf(p) })

  // ── Settings shows the same order; up / down change it ───────────────
  await p.goto(`${BASE}/settings/behaviour`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=rail-order-list]', { timeout: 15000 })
  await sleep(800)
  const listOf = async () => p.$$eval('[data-test=rail-order-list] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
  step('settings: the list shows the rail order', same(await listOf(), wantMouse), { list: await listOf() })
  step('settings: the first row cannot move up, the last cannot move down',
    await p.$eval('[data-test=rail-order-up-events]', (b) => b.disabled) && await p.$eval('[data-test=rail-order-down-flow]', (b) => b.disabled))
  await p.focus('[data-test=rail-order-down-events]')
  await p.keyboard.press('Enter')
  await sleep(900)
  const wantDown = ['dm', 'events', 'channels', 'issues', 'topics', 'flow']
  step('settings: the keyboard moves Event log down one', same(await listOf(), wantDown), { list: await listOf() })
  step('settings: that is stored', await waitClaim(p, wantDown))
  step('settings: the rail on this page redrew at once', same(await railOf(p), wantDown), { rail: await railOf(p) })
  await p.screenshot({ path: `${OUT}/02-settings-list.png` })

  // ── a fresh browser (another device) signs in to the same order ──────
  const q = await (await browser.createBrowserContext()).newPage()
  await q.setViewport({ width: 390, height: 844, hasTouch: true, isMobile: true })
  await signIn(q)
  await q.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
  await q.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: 15000 })
  await sleep(1000)
  step('another device: the same order after sign-in', same(await railOf(q), wantDown), { rail: await railOf(q) })

  // ── touch drag on that phone: Topics to the top ──────────────────────
  const tf = await centre(q, '[data-testid=sidebar-tab-topics]')
  const tt = await centre(q, '[data-testid=sidebar-tab-dm]')
  await q.touchscreen.touchStart(tf.x, tf.y)
  for (let i = 1; i <= 12; i++) await q.touchscreen.touchMove(tf.x, tf.y + ((tt.y - tt.h / 2 - 2) - tf.y) * i / 12)
  await sleep(150)
  await q.touchscreen.touchEnd()
  await sleep(500)
  const wantTouch = ['topics', 'dm', 'events', 'channels', 'issues', 'flow']
  step('touch drag: the rail reorders on a phone', same(await railOf(q), wantTouch), { rail: await railOf(q) })
  step('touch drag: stored on the account', await waitClaim(q, wantTouch))
  await q.screenshot({ path: `${OUT}/03-phone-after-touch-drag.png` })

  // ── Default order in Settings clears it ──────────────────────────────
  await p.goto(`${BASE}/settings/behaviour`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=rail-order-reset]')
  await sleep(800)
  step('settings: the first browser shows the touch order after a load', same(await listOf(), wantTouch), { list: await listOf() })
  await p.click('[data-test=rail-order-reset]')
  await sleep(900)
  step('Default order: the list and the claim go back to the default', same(await listOf(), DEFAULT) && (await claimOf(p)) === null)
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e) })
} finally {
  if (p && (original === null || Array.isArray(original))) {
    try { res.restored = { to: original, status: await putOrder(p, original) } } catch (e) { res.restored = { error: String(e) } }
  }
  await browser.close()
  res.failed = failed
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed} step(s)` : 'ALL PASS', `-> ${OUT}/result.json`)
  process.exit(failed ? 1 : 0)
}
