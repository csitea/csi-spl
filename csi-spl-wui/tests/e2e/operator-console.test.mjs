// Operator console (spec 074 T008) in a real browser, against the mock bundle.
//
// The console is a section of the right-most pane. A workspace admin who is
// not the operator admin sees neither its rail button nor the section (GET
// /v1/operator/workspaces is 403 operator.workspaces). The operator admin
// opens it from the rail, filters by status and by search, suspends a
// workspace, archives one behind a confirm, and creates one.
//
// The mock plays a workspace admin. The operator admin is an opt-in
// (spool.mock.operator_admin), so every other spec stays as it is.
//
// Run:
//   pnpm run test:e2e operator-console
//   BASE_URL=<generated bundle> SHOT_DIR=<dir> pnpm run test:e2e operator-console
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { OPERATOR_MOCK_KEY, OPERATOR_MOCK_STORE_KEY } from '../../src/utils/operator-console.mjs'
import { THEME_KEY } from '../../src/utils/theme.mjs'

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
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const rowIds = (p) => p.$$eval('[data-test=operator-row]', (els) => els.map((e) => e.getAttribute('data-ws')))
const rowStatus = (p, id) => p.$eval(`[data-test=operator-row][data-ws="${id}"]`, (e) => e.getAttribute('data-status')).catch(() => '')
const setField = (p, sel, v) => p.$eval(sel, (el, next) => {
  el.value = next
  el.dispatchEvent(new Event('input', { bubbles: true }))
  el.dispatchEvent(new Event('change', { bubbles: true }))
}, String(v))
const settle = (p) => p.evaluate(() => new Promise((r) => setTimeout(r, 800)))

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, name) })
}

async function signIn(p, base, { operator, theme }) {
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((opKey, storeKey, themeKey, op, th) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.removeItem(storeKey)
    if (op) localStorage.setItem(opKey, '1')
    else localStorage.removeItem(opKey)
    localStorage.setItem(themeKey, th)
  }, OPERATOR_MOCK_KEY, OPERATOR_MOCK_STORE_KEY, THEME_KEY, operator, theme)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-testid=tenant-settings-open]', { visible: true, timeout: NAV_TIMEOUT })
  await settle(p)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))

  /* 1. a workspace admin who is not the operator admin */
  await signIn(p, server.base, { operator: false, theme: 'light' })
  ok('1 a workspace admin sees no operator rail button', !(await p.$('[data-testid=operator-console-open]')))
  ok('1b and no operator section', !(await p.$('[data-section=operator]')))
  await shot(p, 'operator-hidden-light.png')
  await p.evaluate((k) => localStorage.setItem(k, 'dark'), THEME_KEY)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-testid=tenant-settings-open]', { visible: true, timeout: NAV_TIMEOUT })
  await settle(p)
  ok('1c dark: still no operator rail button', !(await p.$('[data-testid=operator-console-open]')))
  await shot(p, 'operator-hidden-dark.png')

  /* 2. the operator admin */
  await signIn(p, server.base, { operator: true, theme: 'light' })
  await p.waitForSelector('[data-testid=operator-console-open]', { visible: true, timeout: NAV_TIMEOUT })
  ok('2 the operator admin sees the rail button', true)
  await p.click('[data-testid=operator-console-open]')
  await p.waitForSelector('[data-section=operator] [data-test=operator-row]', { visible: true, timeout: NAV_TIMEOUT })
  const sections = await p.$$eval('[data-test=topic-section]', (els) => els.map((e) => e.getAttribute('data-section')))
  ok('2b the console is the ONE right-pane section', sections.join() === 'operator', sections)
  const listed = await rowIds(p)
  ok('3 the list shows every workspace, the operator one first', listed.join() === 't1,acme,beta,gamma', listed)
  await shot(p, 'operator-console-light.png')

  await p.select('[data-test=operator-status]', 'suspended')
  await p.waitForFunction(() => document.querySelectorAll('[data-test=operator-row]').length === 1, { timeout: NAV_TIMEOUT })
  ok('4 status filter: suspended shows beta only', (await rowIds(p)).join() === 'beta')
  await p.select('[data-test=operator-status]', '')
  await setField(p, '[data-test=operator-search]', 'acm')
  await p.waitForFunction(() => document.querySelectorAll('[data-test=operator-row]').length === 1, { timeout: NAV_TIMEOUT })
  ok('5 search finds acme', (await rowIds(p)).join() === 'acme')
  await setField(p, '[data-test=operator-search]', '')
  await p.waitForFunction(() => document.querySelectorAll('[data-test=operator-row]').length === 4, { timeout: NAV_TIMEOUT })

  ok('6 the operator workspace offers no suspend or archive',
    !(await p.$('[data-test=operator-row][data-ws="t1"] [data-test=operator-suspend]'))
    && !(await p.$('[data-test=operator-row][data-ws="t1"] [data-test=operator-archive]')))
  await p.click('[data-test=operator-row][data-ws="acme"] [data-test=operator-suspend]')
  await p.waitForSelector('[data-test=operator-row][data-ws="acme"][data-status=suspended]', { timeout: NAV_TIMEOUT })
  ok('7 suspend marks acme suspended', (await rowStatus(p, 'acme')) === 'suspended')
  await p.click('[data-test=operator-row][data-ws="acme"] [data-test=operator-resume]')
  await p.waitForSelector('[data-test=operator-row][data-ws="acme"][data-status=active]', { timeout: NAV_TIMEOUT })
  ok('8 resume brings acme back', (await rowStatus(p, 'acme')) === 'active')

  await p.click('[data-test=operator-row][data-ws="acme"] [data-test=operator-archive]')
  await p.waitForSelector('[data-test=operator-archive-confirm]', { visible: true, timeout: NAV_TIMEOUT })
  ok('9 archive asks first and changes nothing yet', (await rowStatus(p, 'acme')) === 'active')
  await p.click('[data-test=operator-archive-no]')
  ok('9b cancel keeps acme active', !(await p.$('[data-test=operator-archive-confirm]')) && (await rowStatus(p, 'acme')) === 'active')
  await p.click('[data-test=operator-row][data-ws="acme"] [data-test=operator-archive]')
  await p.click('[data-test=operator-archive-yes]')
  await p.waitForSelector('[data-test=operator-row][data-ws="acme"][data-status=archived]', { timeout: NAV_TIMEOUT })
  ok('10 confirmed archive marks acme archived', true)

  await p.click('[data-test=operator-create-open]')
  await p.waitForSelector('[data-test=operator-create-id]', { visible: true, timeout: NAV_TIMEOUT })
  await setField(p, '[data-test=operator-create-id]', 'Bad Id')
  await p.click('[data-test=operator-create-submit]')
  await p.waitForSelector('[data-test=operator-error]', { visible: true, timeout: NAV_TIMEOUT })
  ok('11 a bad id is refused before the call', !(await rowIds(p)).includes('bad id'))
  await setField(p, '[data-test=operator-create-id]', 'delta')
  await setField(p, '[data-test=operator-create-name]', 'Delta')
  await setField(p, '[data-test=operator-create-email]', 'first@example.com')
  await p.click('[data-test=operator-create-submit]')
  await p.waitForSelector('[data-test=operator-row][data-ws="delta"]', { timeout: NAV_TIMEOUT })
  ok('12 create adds delta, active', (await rowStatus(p, 'delta')) === 'active')
  ok('12b the root key is shown once', Boolean(await p.$('[data-test=operator-root-key]')))

  await p.evaluate((k) => localStorage.setItem(k, 'dark'), THEME_KEY)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-testid=operator-console-open]', { visible: true, timeout: NAV_TIMEOUT })
  await p.click('[data-testid=operator-console-open]')
  await p.waitForSelector('[data-section=operator] [data-test=operator-row]', { visible: true, timeout: NAV_TIMEOUT })
  const kept = await rowIds(p)
  ok('13 dark, after a reload: the console lists delta and acme stays archived', kept.includes('delta') && (await rowStatus(p, 'acme')) === 'archived', kept)
  await shot(p, 'operator-console-dark.png')

  await p.click('[data-test=operator-close]')
  await p.waitForFunction(() => !document.querySelector('[data-section=operator]'), { timeout: NAV_TIMEOUT })
  ok('14 close removes the section', true)

  await p.setViewport({ width: 390, height: 800 })
  await p.click('[data-testid=operator-console-open]').catch(() => {})
  const phone = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  ok('15 phone: no page x-scroll', phone <= 1, phone)

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
console.log(`\nAll ${results.length} operator-console checks passed.`)
