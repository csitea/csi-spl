// Tenant drop box (SPL-71) — live proof, signed in, against a deployed WUI.
//
// The switcher is a drop box: the name and the arrow sit in one bordered box,
// and a press on the arrow opens it (focuses the select). Its rows are the
// session's `tenants` in the order the hub sent them (tenants.sort_order,
// rdb 0051), never re-sorted. EXPECT_ORDER (comma-separated display labels)
// pins that order when given.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [EXPECT_ORDER=csitea,e2e] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/tenant-drop-box-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { tenantSwitchOptions } from '../../src/utils/tenant-switcher.mjs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const EXPECT = (process.env.EXPECT_ORDER || '').split(',').map((s) => s.trim()).filter(Boolean)
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}

const READ_BOX = () => {
  const sel = document.querySelector('[data-testid=tenant-switcher-select]')
  const arrow = document.querySelector('[data-testid=tenant-switcher-arrow]')
  const field = document.querySelector('[data-testid=tenant-switcher-box]')
  if (!(sel instanceof HTMLSelectElement) || !(arrow instanceof Element) || !(field instanceof HTMLElement)) return { missing: true }
  const fr = field.getBoundingClientRect()
  const inside = (r) => r.left >= fr.left - 0.5 && r.right <= fr.right + 0.5 && r.top >= fr.top - 0.5 && r.bottom <= fr.bottom + 0.5
  const sr = sel.getBoundingClientRect()
  const ar = arrow.getBoundingClientRect()
  const fcs = getComputedStyle(field)
  return {
    missing: false,
    options: [...sel.options].map((o) => ({ id: o.value, label: (o.textContent || '').trim() })),
    selected: sel.value,
    borders: ['Top', 'Right', 'Bottom', 'Left'].map((e) => parseFloat(fcs['border' + e + 'Width']) || 0),
    borderStyle: fcs.borderTopStyle,
    borderColor: fcs.borderTopColor,
    inBox: inside(sr) && inside(ar),
    boxHeight: fr.height,
    arrowCenter: { x: ar.left + ar.width / 2, y: ar.top + ar.height / 2 },
  }
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 60000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=en-GB'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  let session = null
  p.on('response', async (r) => {
    if (!/\/api\/v1\/auth\/session(\?|$)/.test(r.url()) || r.request().method() !== 'GET' || r.status() !== 200) return
    try { session = await r.json() } catch { /* not json */ }
  })

  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signedIn = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', signedIn, { url: p.url().replace(BASE, '') })
  if (!signedIn) throw new Error('not signed in')

  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-testid=tenant-switcher-box]', { timeout: 20000 })
  await sleep(400)
  const box = await p.evaluate(READ_BOX)
  const hubOrder = Array.isArray(session && session.tenants) ? session.tenants.map((t) => t.tenant_id) : []
  const want = tenantSwitchOptions(session || {}).options.filter((o) => o.id).map((o) => o.id)
  const got = box.missing ? [] : box.options.filter((o) => o.id).map((o) => o.id)
  step('rows are the session tenants in the hub order', hubOrder.length > 0 && JSON.stringify(got) === JSON.stringify(want)
    && JSON.stringify(got) === JSON.stringify(hubOrder), { hubOrder, rows: box.options })
  if (EXPECT.length) {
    const labels = box.missing ? [] : box.options.filter((o) => o.id).map((o) => o.label)
    step('rows are ' + EXPECT.join(', '), JSON.stringify(labels) === JSON.stringify(EXPECT), { labels })
  }
  step('a drop box: one bordered box holds the name and the arrow',
    !box.missing && box.borders.every((w) => w >= 1) && box.borderStyle === 'solid' && box.inBox === true,
    { borders: box.borders, style: box.borderStyle, color: box.borderColor, height: box.boxHeight })
  const el = await p.$('[data-testid=tenant-switcher]')
  const shot = `${OUT}/drop-box.png`
  if (el) await el.screenshot({ path: shot })
  await p.evaluate(() => { if (document.activeElement instanceof HTMLElement) document.activeElement.blur() })
  if (!box.missing) await p.mouse.click(box.arrowCenter.x, box.arrowCenter.y)
  const focused = await p.evaluate(() => document.activeElement?.getAttribute('data-testid') || '')
  await p.keyboard.press('Escape')
  step('a press on the arrow opens the drop box', focused === 'tenant-switcher-select', { focused, shot })
  const url = p.url()
  await sleep(300)
  step('opening it did not switch or navigate', p.url() === url, { url: url.replace(BASE, '') })
} catch (e) {
  step('proof ran', false, { error: String(e && e.stack || e).slice(0, 500) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAIL ${failed} step(s)` : `PASS all ${res.steps.length} steps`, '->', OUT + '/results.json')
process.exit(failed ? 1 : 0)
