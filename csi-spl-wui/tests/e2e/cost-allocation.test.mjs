// Settings -> Cost allocation (SPL-5291, spec 143 costs-allocation.md
// section 6) in a real browser, against the mock bundle, at 1440 and 390 px.
//
// A workspace admin who is neither the operator's admin nor a customer admin
// holding a share has no nav entry (CONTROL for the entry). The operator
// admin (spool.mock.operator_admin) sees the Persons and Cloud items, splits
// one 60/40: Save is disabled at 90 %, enabled at 100 %, and the split reads
// "Acme 60 % · Globex 40 %" after a reload. A customer admin of Acme and
// Globex (spool.mock.cost_alloc_admin_of) sees that item only, with what
// they hold, and moves it to 20/80; the operator's view then reads it.
// At 390 px the page has no sideways scroll and the form fits.
//
// Run:
//   pnpm run test:e2e cost-allocation
//   BASE_URL=<generated bundle> pnpm run test:e2e cost-allocation
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { COST_ALLOC_MOCK_ADMIN_KEY, COST_ALLOC_MOCK_KEY } from '../../src/utils/cost-allocations.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim().replace(/\s+/g, ' ')).catch(() => '')
const ITEM = '[data-test=cost-alloc-item][data-item="example-prd / Cloud SQL"]'
const setPct = (p, ws, v) => p.$eval(`${ITEM} [data-test=cost-alloc-pct-${ws}]`, (el, next) => {
  el.value = next
  el.dispatchEvent(new Event('input', { bubbles: true }))
}, String(v))
const saveDisabled = (p) => p.$eval(`${ITEM} [data-test=cost-alloc-save]`, (b) => b.disabled)
const navIds = (p) => p.$$eval('[data-test^=tenant-settings-nav-]', (els) => els.map((e) => e.getAttribute('data-test')))

async function open(p, base, door) {
  await p.goto(base + '/tenant-settings/cost-allocation', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`[data-test=cost-alloc-root][data-state=ready][data-door=${door}]`, { timeout: NAV_TIMEOUT })
}

async function noSideScroll(p) {
  return p.evaluate(() => ({ sw: document.scrollingElement.scrollWidth, w: window.innerWidth }))
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((keys) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    for (const k of keys) localStorage.removeItem(k)
  }, [TOKENS_MOCK_OPERATOR_KEY, COST_ALLOC_MOCK_ADMIN_KEY, COST_ALLOC_MOCK_KEY])

  // 1 nobody to allocate for: no entry (the mock's admin is no operator admin and holds no share)
  await p.goto(server.base + '/tenant-settings/members', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-settings-nav-members]', { visible: true, timeout: NAV_TIMEOUT })
  await new Promise((r) => setTimeout(r, 500))
  const before = await navIds(p)
  ok('1 neither door: no Cost allocation in the nav', !before.includes('tenant-settings-nav-cost-allocation'), before)

  // 2 the operator admin
  await p.evaluate((k) => localStorage.setItem(k, '1'), TOKENS_MOCK_OPERATOR_KEY)
  await p.goto(server.base + '/tenant-settings/members', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const navOk = await p.waitForSelector('[data-test=tenant-settings-nav-cost-allocation]', { visible: true, timeout: NAV_TIMEOUT }).then(() => true, () => false)
  ok('2 CONTROL: the operator admin has the entry', navOk, await navIds(p))
  await open(p, server.base, 'operator')
  const items = await p.$$eval('[data-test=cost-alloc-item]', (els) => els.map((e) => e.getAttribute('data-item')))
  const persons = await p.$$eval('[data-test=cost-alloc-persons] [data-test=cost-alloc-item]', (els) => els.length)
  ok('3 the Persons and Cloud items, two of them Persons', items.length === 5 && persons === 2, items)
  ok('4 not split yet', (await text(p, `${ITEM} [data-test=cost-alloc-split]`)) === 'Not allocated')

  // 5 a 60/40 split: Save waits for 100 %
  await p.click(`${ITEM} [data-test=cost-alloc-edit]`)
  await p.waitForSelector(`${ITEM} [data-test=cost-alloc-form]`, { visible: true, timeout: NAV_TIMEOUT })
  await setPct(p, 'acme', '60')
  await setPct(p, 'globex', '30')
  ok('5 at 90 % Save is disabled and the sum says so', await saveDisabled(p) && (await text(p, `${ITEM} [data-test=cost-alloc-sum]`)).includes('90'), await text(p, `${ITEM} [data-test=cost-alloc-sum]`))
  await setPct(p, 'globex', '40')
  ok('6 at 100 % Save is enabled', !(await saveDisabled(p)))
  await p.click(`${ITEM} [data-test=cost-alloc-save]`)
  await p.waitForFunction((sel) => !document.querySelector(sel), { timeout: NAV_TIMEOUT }, `${ITEM} [data-test=cost-alloc-form]`)
  await open(p, server.base, 'operator')
  const split = await text(p, `${ITEM} [data-test=cost-alloc-split]`)
  ok('7 after a reload the split reads Acme 60 % · Globex 40 %', split === 'Acme 60 % · Globex 40 %', split)

  // 8 390 px: no sideways scroll, the form fits
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await open(p, server.base, 'operator')
  await p.click(`${ITEM} [data-test=cost-alloc-edit]`)
  await p.waitForSelector(`${ITEM} [data-test=cost-alloc-form]`, { visible: true, timeout: NAV_TIMEOUT })
  const phone = await noSideScroll(p)
  const formRight = await p.$eval(`${ITEM} [data-test=cost-alloc-save]`, (b) => b.getBoundingClientRect().right)
  ok('8 at 390 px no sideways scroll, Save inside the screen', phone.w === 390 && phone.sw <= phone.w && formRight <= phone.w, { ...phone, formRight })
  await p.setViewport({ width: 1440, height: 900 })
  const desk = await noSideScroll(p)
  ok('9 at 1440 px no sideways scroll', desk.w === 1440 && desk.sw <= desk.w, desk)

  // 10 a customer admin of Acme and Globex
  await p.evaluate((op, adm) => {
    localStorage.removeItem(op)
    localStorage.setItem(adm, JSON.stringify(['acme', 'globex']))
  }, TOKENS_MOCK_OPERATOR_KEY, COST_ALLOC_MOCK_ADMIN_KEY)
  await open(p, server.base, 'tenant')
  const mine = await p.$$eval('[data-test=cost-alloc-item]', (els) => els.map((e) => e.getAttribute('data-item')))
  ok('10 a customer admin sees only the item their workspaces hold', mine.length === 1 && mine[0] === 'example-prd / Cloud SQL', mine)
  await p.click(`${ITEM} [data-test=cost-alloc-edit]`)
  await p.waitForSelector(`${ITEM} [data-test=cost-alloc-held]`, { visible: true, timeout: NAV_TIMEOUT })
  const rowsShown = await p.$$eval(`${ITEM} [data-test^=cost-alloc-pct-]`, (els) => els.map((e) => e.getAttribute('data-test')))
  ok('11 the form lists their two workspaces, and what they hold', rowsShown.length === 2 && (await text(p, `${ITEM} [data-test=cost-alloc-held]`)).includes('100'), rowsShown)
  await setPct(p, 'acme', '20')
  await setPct(p, 'globex', '70')
  ok('12 at 90 % of their 100 % Save is disabled', await saveDisabled(p))
  await setPct(p, 'globex', '80')
  await p.click(`${ITEM} [data-test=cost-alloc-save]`)
  await p.waitForFunction((sel) => !document.querySelector(sel), { timeout: NAV_TIMEOUT }, `${ITEM} [data-test=cost-alloc-form]`)
  await p.evaluate((op) => localStorage.setItem(op, '1'), TOKENS_MOCK_OPERATOR_KEY)
  await open(p, server.base, 'operator')
  const moved = await text(p, `${ITEM} [data-test=cost-alloc-split]`)
  ok('13 the operator then reads Globex 80 % · Acme 20 %', moved === 'Globex 80 % · Acme 20 %', moved)

  ok('no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const bad = results.filter((r) => !r.ok)
if (bad.length) {
  console.error(`\n${bad.length} failure(s)`)
  process.exit(1)
}
console.log(`\nAll ${results.length} cost-allocation checks passed.`)
