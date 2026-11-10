// Spec 090 X row (SPL-5194): the workspace's X accounts in Tenant settings ->
// General, proved in a REAL browser against the mock bundle
// (tenant-settings-mock.mjs mockMarketingX: one account, @mock_studio;
// Connect adds @mock_shop). At 1440 and at 390:
//   1. marketing on, the X section lists @mock_studio, "Connected";
//   2. Publish on it lists the unshared posts, each counted as X counts it
//      against 280; a publish goes out and drops its row;
//   3. RED CONTROL: a post the hub refuses as too long for X
//      (spool.mock.marketing.x=too_long, the hub's 422) shows X's line and
//      keeps its row;
//   4. Connect adds @mock_shop to the list;
//   5. Disconnect asks first (how to revoke the app on X), then the account
//      leaves the list;
//   6. RED CONTROL: a hub without the X app (503 not_configured) shows ONE
//      line, no Connect button and no retry (no error loop).
//
// Plant the defect and watch it go red:
//   PROVE_RED=too_long node tests/e2e/marketing-x-accounts.test.mjs    (step 3: the flag is not set)
//   PROVE_RED=configured node tests/e2e/marketing-x-accounts.test.mjs  (step 6: the flag is not set)
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e marketing-x-accounts
// SHOT_DIR=<dir> writes marketing-x-accounts-<width>.png.
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
const SECTION = '[data-test=marketing-x-accounts]'
const ACCOUNT = '[data-test=marketing-x-account]'
const acct = (id) => `${ACCOUNT}[data-channel="${id}"]`
const PUB = (id) => `[data-test=tenant-marketing-publish][data-channel="${id}"]`
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
// a click as a user makes it: the target scrolled clear of the phone's fixed bars first
async function tap(p, sel) {
  await p.$eval(sel, (e) => e.scrollIntoView({ block: 'center' }))
  await p.click(sel)
}
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const accounts = (p) => p.$$eval(ACCOUNT, (es) => es.map((e) => ({
  id: e.getAttribute('data-channel'),
  avatar: Boolean(e.querySelector('.mx-avatar')?.textContent.trim()),
  name: e.querySelector('.mx-name')?.textContent.trim(),
  status: e.querySelector('[data-test=marketing-x-status]')?.textContent.trim(),
})))
const setFlag = (p, v) => p.evaluate((x) => (x ? localStorage.setItem('spool.mock.marketing.x', x) : localStorage.removeItem('spool.mock.marketing.x')), v)

async function flipOn(p, on) {
  const now = await p.$eval(TOGGLE, (e) => e.checked)
  if (now !== on) await tap(p, TOGGLE)
  await p.waitForFunction((s, want) => document.querySelector(s)?.checked === want && !document.querySelector(s)?.disabled, { timeout: 5000 }, TOGGLE, on).catch(() => null)
  await sleep(300)
}

// one Publish click inside the account's list; resolves once a notice or an error shows
async function publishOne(p, channel, post) {
  await tap(p, `${PUB(channel)} [data-post="${post}"] [data-test=tenant-marketing-publish-button]`)
  await p.waitForSelector(`${PUB(channel)} [data-test=tenant-marketing-publish-notice], ${PUB(channel)} [data-test=tenant-marketing-publish-error]`, { timeout: 5000 }).catch(() => null)
  await sleep(150)
}

const rowsOf = (p, channel) => p.$$eval(`${PUB(channel)} [data-test=tenant-marketing-publish-row]`, (es) => es.map((e) => e.getAttribute('data-post')))

async function publishSteps(p, w) {
  await tap(p, `${acct('mch-x-1')} [data-test=marketing-x-publish-open]`)
  await p.waitForSelector(`${PUB('mch-x-1')} [data-test=tenant-marketing-publish-row]`, { visible: true, timeout: 5000 }).catch(() => null)
  const counts = await p.$$eval(`${PUB('mch-x-1')} [data-test=marketing-meta-chars]`, (es) => es.map((e) => ({
    limit: e.getAttribute('data-limit'), count: Number(e.getAttribute('data-count')), line: e.textContent.replace(/\s+/g, ' ').trim(),
  })))
  ok(`2 ${w}px: Publish on X lists 2 posts, each counted against 280`, counts.length === 2 &&
    counts.every((c) => c.limit === '280' && c.count > 23 && c.count <= 280 && c.line === `${c.count} / 280 characters, as X counts them`), counts)
  await publishOne(p, 'mch-x-1', '2026-10-13-mock-second')
  const done = await text(p, `${PUB('mch-x-1')} [data-test=tenant-marketing-publish-notice]`)
  const left = await rowsOf(p, 'mch-x-1')
  ok(`2b ${w}px: the X publish goes out and drops its row`, done === 'Published.' && left.join() === '2026-10-12-mock-first', { done, left })
}

// RED CONTROL: the hub's 422 for a post too long for X shows X's line, the row stays
async function tooLongSteps(p, w) {
  if (RED !== 'too_long') await setFlag(p, 'too_long')
  await publishOne(p, 'mch-x-1', '2026-10-12-mock-first')
  const err = await text(p, `${PUB('mch-x-1')} [data-test=tenant-marketing-publish-error]`)
  const left = await rowsOf(p, 'mch-x-1')
  ok(`3 ${w}px: RED CONTROL a post too long for X shows X's line and keeps its row`,
    err === "This post does not fit X's 280 characters, even shortened." && left.join() === '2026-10-12-mock-first', { err, left })
  await setFlag(p, '')
  await tap(p, `${acct('mch-x-1')} [data-test=marketing-x-publish-open]`)
}

async function connectSteps(p, w) {
  await tap(p, '[data-test=marketing-x-connect]')
  await p.waitForSelector(acct('mch-x-2'), { visible: true, timeout: 5000 }).catch(() => null)
  const ids = (await accounts(p)).map((a) => `${a.id}:${a.name}`)
  ok(`4 ${w}px: Connect adds @mock_shop`, ids.join() === 'mch-x-1:@mock_studio,mch-x-2:@mock_shop', ids)
}

async function disconnectSteps(p, w) {
  await tap(p, `${acct('mch-x-1')} [data-test=marketing-x-disconnect]`)
  await p.waitForSelector('[data-testid=marketing-x-disconnect-dialog-confirm]', { visible: true, timeout: 5000 }).catch(() => null)
  const revoke = await text(p, '[data-test=marketing-x-revoke-hint]')
  ok(`5 ${w}px: Disconnect asks first and says how to revoke the app on X`,
    revoke.includes('Connected apps') && (await accounts(p)).length === 2, { revoke })
  await tap(p, '[data-testid=marketing-x-disconnect-dialog-confirm]')
  await p.waitForFunction((s) => !document.querySelector(s), { timeout: 5000 }, acct('mch-x-1')).catch(() => null)
  await sleep(200)
  const left = (await accounts(p)).map((a) => a.id)
  const notice = await text(p, '[data-test=marketing-x-notice]')
  ok(`5b ${w}px: the account leaves the list`, left.join() === 'mch-x-2' && notice === 'Disconnected.' &&
    !(await p.$('[data-testid=marketing-x-disconnect-dialog-confirm]')), { left, notice })
}

// RED CONTROL: 503 not_configured: one line, no Connect, no retry
async function notConfiguredSteps(p, w) {
  if (RED !== 'configured') await setFlag(p, 'not_configured')
  await flipOn(p, false)
  await flipOn(p, true)
  await p.waitForSelector(SECTION, { visible: true, timeout: 5000 }).catch(() => null)
  await sleep(1200)
  const line = await text(p, '[data-test=marketing-x-not-configured]')
  ok(`6 ${w}px: RED CONTROL without the X app one line says so, no Connect, no list`, line === 'X is not set up on this hub yet.' &&
    !(await p.$('[data-test=marketing-x-connect]')) && (await accounts(p)).length === 0 && !(await p.$('[data-test=marketing-x-failed]')), { line })
  await setFlag(p, '')
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
    localStorage.removeItem('spool.mock.marketing.x')
    localStorage.setItem('spool-theme', 'light')
  })
  await p.goto(base + '/tenant-settings/general', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(TOGGLE, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await flipOn(p, true)
  await p.waitForSelector(ACCOUNT, { visible: true, timeout: 10000 }).catch(() => null)
  const first = await accounts(p)
  ok(`1 ${w}px: the X section lists @mock_studio, an initials avatar, Connected`, JSON.stringify(first) === JSON.stringify([
    { id: 'mch-x-1', avatar: true, name: '@mock_studio', status: 'Connected' },
  ]), first)
  await publishSteps(p, w)
  await tooLongSteps(p, w)
  await connectSteps(p, w)
  if (SHOT_DIR) {
    mkdirSync(SHOT_DIR, { recursive: true })
    await p.$eval(SECTION, (e) => e.scrollIntoView({ block: 'start' }))
    await tap(p, `${acct('mch-x-1')} [data-test=marketing-x-publish-open]`)
    await sleep(500)
    await p.screenshot({ path: `${SHOT_DIR}/marketing-x-accounts-${w}.png`, fullPage: true })
    await tap(p, `${acct('mch-x-1')} [data-test=marketing-x-publish-open]`)
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
