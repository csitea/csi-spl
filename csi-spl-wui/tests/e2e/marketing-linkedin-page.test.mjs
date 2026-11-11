// Spec 090 phase 4, T041 (SPL-5258; linkedin-company-page.md section 8.4):
// the workspace's LinkedIn company pages in Tenant settings -> General,
// proved in a REAL browser against the mock bundle (tenant-settings-mock.mjs
// mockMarketingLiPage: one page, Mock Company; Connect adds Mock Labs). At
// 1440 and at 390:
//   1. marketing on, the section lists Mock Company, its page link,
//      "Connected" and when the connection ends;
//   2. Publish on it lists the unshared posts, each counted against
//      LinkedIn's 3,000, the button naming the page; a publish goes out and
//      drops its row;
//   3. RED CONTROL: a member without tenant.settings
//      (spool.mock.marketing.publish=forbidden, the hub's 403) is told only
//      an admin or business owner publishes as the page, and sees no list;
//   4. Connect adds Mock Labs (no vanity name: no link);
//   5. Disconnect asks first (how to revoke the app on LinkedIn), then the
//      page leaves the list;
//   6. RED CONTROL: a hub without the Company Page app (503 not_configured)
//      shows ONE line, no Connect button and no retry.
//
// Plant the defect and watch it go red:
//   PROVE_RED=forbidden node tests/e2e/marketing-linkedin-page.test.mjs   (step 3: the flag is not set)
//   PROVE_RED=configured node tests/e2e/marketing-linkedin-page.test.mjs  (step 6: the flag is not set)
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e marketing-linkedin-page
// SHOT_DIR=<dir> writes marketing-linkedin-page-<width>.png.
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''
const SHOT_DIR = process.env.SHOT_DIR || ''

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

const TOGGLE = '[data-test=tenant-marketing-toggle]'
const SECTION = '[data-test=marketing-li-pages]'
const PAGE = '[data-test=marketing-li-page]'
const pg = (id) => `${PAGE}[data-channel="${id}"]`
const PUB = (id) => `[data-test=tenant-marketing-publish][data-channel="${id}"]`
const FLAG = 'spool.mock.marketing.li_page'
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
// a click as a user makes it: the target scrolled clear of the phone's fixed bars first
async function tap(p, sel) {
  await p.$eval(sel, (e) => e.scrollIntoView({ block: 'center' }))
  await p.click(sel)
}
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const pages = (p) => p.$$eval(PAGE, (es) => es.map((e) => ({
  id: e.getAttribute('data-channel'),
  name: e.querySelector('.lp-name')?.textContent.trim(),
  link: e.querySelector('[data-test=marketing-li-page-link]')?.getAttribute('href') || '',
  status: e.querySelector('[data-test=marketing-li-page-status]')?.textContent.trim(),
  expires: e.querySelector('[data-test=marketing-li-page-expires]')?.textContent.trim() || '',
})))
const setItem = (p, k, v) => p.evaluate((key, x) => (x ? localStorage.setItem(key, x) : localStorage.removeItem(key)), k, v)

async function flipOn(p, on) {
  const now = await p.$eval(TOGGLE, (e) => e.checked)
  if (now !== on) await tap(p, TOGGLE)
  await p.waitForFunction((s, want) => document.querySelector(s)?.checked === want && !document.querySelector(s)?.disabled, { timeout: 5000 }, TOGGLE, on).catch(() => null)
  await sleep(300)
}

const rowsOf = (p, channel) => p.$$eval(`${PUB(channel)} [data-test=tenant-marketing-publish-row]`, (es) => es.map((e) => e.getAttribute('data-post')))

async function openPublish(p, channel) {
  await tap(p, `${pg(channel)} [data-test=marketing-li-page-publish-open]`)
  await p.waitForSelector(`${PUB(channel)} [data-test=tenant-marketing-publish-row], [data-test=tenant-marketing-publish-unavailable]`, { visible: true, timeout: 5000 }).catch(() => null)
}

// Publish as the page: the button names the page, the count is LinkedIn's 3,000, a publish drops its row
async function publishSteps(p, w) {
  await openPublish(p, 'mch-lp-1')
  const counts = await p.$$eval(`${PUB('mch-lp-1')} [data-test=marketing-meta-chars]`, (es) => es.map((e) => ({
    limit: e.getAttribute('data-limit'), count: Number(e.getAttribute('data-count')),
  })))
  const sel = `${PUB('mch-lp-1')} [data-post="2026-10-13-mock-second"] [data-test=tenant-marketing-publish-button]`
  const label = await text(p, sel)
  ok(`2 ${w}px: Publish lists 2 posts against 3000, the button says "Publish as Mock Company"`, counts.length === 2 &&
    counts.every((c) => c.limit === '3000' && c.count > 20 && c.count <= 3000) && label === 'Publish as Mock Company', { counts, label })
  await tap(p, sel)
  await p.waitForSelector(`${PUB('mch-lp-1')} [data-test=tenant-marketing-publish-notice], ${PUB('mch-lp-1')} [data-test=tenant-marketing-publish-error]`, { timeout: 5000 }).catch(() => null)
  await sleep(150)
  const done = await text(p, `${PUB('mch-lp-1')} [data-test=tenant-marketing-publish-notice]`)
  const left = await rowsOf(p, 'mch-lp-1')
  ok(`2b ${w}px: the publish as the page goes out and drops its row`, done !== '' && left.join() === '2026-10-12-mock-first', { done, left })
  await tap(p, `${pg('mch-lp-1')} [data-test=marketing-li-page-publish-open]`)
}

// RED CONTROL: a member without tenant.settings (the hub's 403) sees the admin/business-owner line, no list
async function forbiddenSteps(p, w) {
  if (RED !== 'forbidden') await setItem(p, 'spool.mock.marketing.publish', 'forbidden')
  await openPublish(p, 'mch-lp-1')
  await sleep(300)
  const why = await text(p, '[data-test=tenant-marketing-publish-unavailable] .mp-why')
  ok(`3 ${w}px: RED CONTROL a non-admin is told only an admin or business owner publishes as the page`,
    why === 'Only an admin or business owner of the workspace can publish as the company page.' &&
    (await rowsOf(p, 'mch-lp-1')).length === 0, { why })
  await setItem(p, 'spool.mock.marketing.publish', '')
  await tap(p, `${pg('mch-lp-1')} [data-test=marketing-li-page-publish-open]`)
}

async function connectSteps(p, w) {
  await tap(p, '[data-test=marketing-li-page-connect]')
  await p.waitForSelector(pg('mch-lp-2'), { visible: true, timeout: 5000 }).catch(() => null)
  const got = (await pages(p)).map((x) => `${x.id}:${x.name}:${x.link ? 'link' : 'nolink'}`)
  ok(`4 ${w}px: Connect adds Mock Labs (no vanity name, no link)`, got.join() === 'mch-lp-1:Mock Company:link,mch-lp-2:Mock Labs:nolink', got)
}

async function disconnectSteps(p, w) {
  await tap(p, `${pg('mch-lp-1')} [data-test=marketing-li-page-disconnect]`)
  await p.waitForSelector('[data-testid=marketing-li-page-disconnect-dialog-confirm]', { visible: true, timeout: 5000 }).catch(() => null)
  const revoke = await text(p, '[data-test=marketing-li-page-revoke-hint]')
  ok(`5 ${w}px: Disconnect asks first and says how to revoke the app on LinkedIn`,
    revoke.includes('Permitted services') && (await pages(p)).length === 2, { revoke })
  await tap(p, '[data-testid=marketing-li-page-disconnect-dialog-confirm]')
  await p.waitForFunction((s) => !document.querySelector(s), { timeout: 5000 }, pg('mch-lp-1')).catch(() => null)
  await sleep(200)
  const left = (await pages(p)).map((x) => x.id)
  const notice = await text(p, '[data-test=marketing-li-page-notice]')
  ok(`5b ${w}px: the page leaves the list`, left.join() === 'mch-lp-2' && notice === 'Disconnected.' &&
    !(await p.$('[data-testid=marketing-li-page-disconnect-dialog-confirm]')), { left, notice })
}

// RED CONTROL: 503 not_configured: one line, no Connect, no list, no error
async function notConfiguredSteps(p, w) {
  if (RED !== 'configured') await setItem(p, FLAG, 'not_configured')
  await flipOn(p, false)
  await flipOn(p, true)
  await p.waitForSelector(SECTION, { visible: true, timeout: 5000 }).catch(() => null)
  await sleep(1200)
  const line = await text(p, '[data-test=marketing-li-page-not-configured]')
  ok(`6 ${w}px: RED CONTROL without the Company Page app one line says so, no Connect, no list`,
    line === 'LinkedIn company page publishing is not set up on this hub yet.' &&
    !(await p.$('[data-test=marketing-li-page-connect]')) && (await pages(p)).length === 0 && !(await p.$('[data-test=marketing-li-page-failed]')), { line })
  await setItem(p, FLAG, '')
}

async function run(browser, base, w) {
  const phone = w < 600
  const p = await browser.newPage()
  await p.setViewport({ width: w, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  await p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.removeItem('spool.mock.marketing.li_page')
    localStorage.removeItem('spool.mock.marketing.publish')
    localStorage.setItem('spool-theme', 'light')
  })
  await p.goto(base + '/tenant-settings/general', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(TOGGLE, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await flipOn(p, true)
  await p.waitForSelector(PAGE, { visible: true, timeout: 10000 }).catch(() => null)
  const first = await pages(p)
  ok(`1 ${w}px: the section lists Mock Company with its page link, Connected and its end date`, JSON.stringify(first) === JSON.stringify([
    { id: 'mch-lp-1', name: 'Mock Company', link: 'https://www.linkedin.com/company/mock-company', status: 'Connected', expires: 'Connection ends on 2027-11-11' },
  ]), first)
  await publishSteps(p, w)
  await forbiddenSteps(p, w)
  await connectSteps(p, w)
  if (SHOT_DIR) {
    mkdirSync(SHOT_DIR, { recursive: true })
    await p.$eval(SECTION, (e) => e.scrollIntoView({ block: 'start' }))
    await tap(p, `${pg('mch-lp-1')} [data-test=marketing-li-page-publish-open]`)
    await sleep(500)
    await p.screenshot({ path: `${SHOT_DIR}/marketing-linkedin-page-${w}.png`, fullPage: true })
    await tap(p, `${pg('mch-lp-1')} [data-test=marketing-li-page-publish-open]`)
  }
  await disconnectSteps(p, w)
  await notConfiguredSteps(p, w)
  ok(`7 ${w}px: no page errors`, errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const w of [1440, 390]) await run(browser, server.base, w)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
