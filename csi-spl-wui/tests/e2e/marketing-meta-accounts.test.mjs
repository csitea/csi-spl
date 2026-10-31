// Spec 090 T035 (SPL-4494): the workspace's Facebook Pages and Instagram
// accounts in Tenant settings -> General, proved in a REAL browser against
// the mock bundle (tenant-settings-mock.mjs mockMarketingMeta: one Page,
// "Mock Studio", with its Instagram account @mock.studio; Connect adds
// "Mock Shop"). At 1440 and at 390:
//   1. marketing on, the accounts list shows the Page then its Instagram
//      account, each with an initials avatar and "Connected";
//   2. Publish on the Page lists the unshared posts with a picture and the
//      Facebook counter (x / 63 206); a publish goes out and drops its row;
//   3. Publish on Instagram counts against 2 200 and refuses the .webp post
//      (JPEG only, button off); the .jpg post goes out;
//   4. RED CONTROL: Connect a Page whose member holds no posting task
//      (spool.mock.marketing.meta=no_admin) shows the permission banner and
//      no Publish button on it;
//   5. RED CONTROL: Disconnect asks first (the linked Instagram line, how to
//      revoke on Meta), then the Page AND its Instagram account leave the
//      list;
//   6. a hub without the Meta app (503 not_configured) shows ONE line, no
//      Connect button and no retry (no error loop).
// The live client hides Disconnect until the hub route lands (SPL-4496):
// tests/unit/marketing-meta.test.mjs holds that.
//
// Plant the defect and watch it go red:
//   PROVE_RED=admin node tests/e2e/marketing-meta-accounts.test.mjs       (step 4: the flag is not set)
//   PROVE_RED=configured node tests/e2e/marketing-meta-accounts.test.mjs  (step 6: the flag is not set)
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e marketing-meta-accounts
// SHOT_DIR=<dir> writes marketing-meta-accounts-<width>.png.
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
const ACCOUNTS = '[data-test=marketing-meta-accounts]'
const ACCOUNT = '[data-test=marketing-meta-account]'
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
  avatar: e.querySelector('.ma-avatar')?.textContent.trim(),
  name: e.querySelector('.ma-name')?.textContent.trim(),
  status: e.querySelector('[data-test=marketing-meta-status]')?.textContent.trim(),
})))
const setFlag = (p, v) => p.evaluate((x) => (x ? localStorage.setItem('spool.mock.marketing.meta', x) : localStorage.removeItem('spool.mock.marketing.meta')), v)

async function flipOn(p, on) {
  const now = await p.$eval(TOGGLE, (e) => e.checked)
  if (now !== on) await tap(p, TOGGLE)
  await p.waitForFunction((s, want) => document.querySelector(s)?.checked === want && !document.querySelector(s)?.disabled, { timeout: 5000 }, TOGGLE, on).catch(() => null)
  await sleep(300)
}

// one Publish click inside a channel's list; resolves once its buttons are enabled again
async function publishFirst(p, channel, post) {
  await tap(p, `${PUB(channel)} [data-post="${post}"] [data-test=tenant-marketing-publish-button]`)
  await p.waitForSelector(`${PUB(channel)} [data-test=tenant-marketing-publish-notice], ${PUB(channel)} [data-test=tenant-marketing-publish-error]`, { timeout: 5000 }).catch(() => null)
  await sleep(150)
}

async function facebookSteps(p, w) {
  await tap(p, `${acct('mch-fb-1')} [data-test=marketing-meta-publish-open]`)
  await p.waitForSelector(`${PUB('mch-fb-1')} [data-test=tenant-marketing-publish-row]`, { visible: true, timeout: 5000 }).catch(() => null)
  const limits = await p.$$eval(`${PUB('mch-fb-1')} [data-test=marketing-meta-chars]`, (es) => es.map((e) => e.getAttribute('data-limit')))
  const counter = await text(p, `${PUB('mch-fb-1')} [data-test=marketing-meta-chars]`)
  const pics = (await p.$$(`${PUB('mch-fb-1')} [data-test=marketing-meta-preview]`)).length
  ok(`2 ${w}px: Publish on the Page lists 2 posts with the Facebook counter and a picture`, limits.length === 2 && limits.every((x) => x === '63206') &&
    /^\d+ \/ 63\s206 characters$/.test(counter) && pics >= 1, { limits, counter, pics })
  await publishFirst(p, 'mch-fb-1', '2026-10-13-mock-second')
  const done = await text(p, `${PUB('mch-fb-1')} [data-test=tenant-marketing-publish-notice]`)
  const left = await p.$$eval(`${PUB('mch-fb-1')} [data-test=tenant-marketing-publish-row]`, (es) => es.map((e) => e.getAttribute('data-post')))
  ok(`2b ${w}px: the Facebook publish goes out and drops its row`, done === 'Published.' && left.join() === '2026-10-12-mock-first', { done, left })
  await tap(p, `${acct('mch-fb-1')} [data-test=marketing-meta-publish-open]`)
}

async function instagramSteps(p, w) {
  await tap(p, `${acct('mch-ig-1')} [data-test=marketing-meta-publish-open]`)
  await p.waitForSelector(`${PUB('mch-ig-1')} [data-test=tenant-marketing-publish-row]`, { visible: true, timeout: 5000 }).catch(() => null)
  const limits = await p.$$eval(`${PUB('mch-ig-1')} [data-test=marketing-meta-chars]`, (es) => es.map((e) => e.getAttribute('data-limit')))
  const webp = `${PUB('mch-ig-1')} [data-post="2026-10-13-mock-second"]`
  const jpegLine = await text(p, `${webp} [data-test=marketing-meta-needs-jpeg]`)
  const off = await p.$eval(`${webp} [data-test=tenant-marketing-publish-button]`, (e) => e.disabled).catch(() => false)
  ok(`3 ${w}px: Instagram counts against 2 200 and refuses the .webp post`, limits.length === 2 && limits.every((x) => x === '2200') &&
    jpegLine === 'Instagram takes only a JPEG picture, and this post has none.' && off, { limits, jpegLine, off })
  await publishFirst(p, 'mch-ig-1', '2026-10-12-mock-first')
  const done = await text(p, `${PUB('mch-ig-1')} [data-test=tenant-marketing-publish-notice]`)
  ok(`3b ${w}px: the .jpg post goes out on Instagram`, done === 'Published.', { done })
  await tap(p, `${acct('mch-ig-1')} [data-test=marketing-meta-publish-open]`)
}

// RED CONTROL: a Page whose member holds no posting task shows the banner
async function connectNoAdminSteps(p, w) {
  if (RED !== 'admin') await setFlag(p, 'no_admin')
  await tap(p, '[data-test=marketing-meta-connect]')
  await p.waitForSelector(acct('mch-fb-2'), { visible: true, timeout: 5000 }).catch(() => null)
  const banner = await text(p, `${acct('mch-fb-2')} [data-test=marketing-meta-no-admin]`)
  const publish = Boolean(await p.$(`${acct('mch-fb-2')} [data-test=marketing-meta-publish-open]`))
  ok(`4 ${w}px: RED CONTROL a Page without a posting task shows the permission banner, no Publish`,
    banner.startsWith('You cannot post on this Page') && !publish && !(await p.$(`${acct('mch-fb-1')} [data-test=marketing-meta-no-admin]`)), { banner, publish })
  await setFlag(p, '')
}

// RED CONTROL: Disconnect asks, then purges the Page and its Instagram account
async function disconnectSteps(p, w) {
  await tap(p, `${acct('mch-fb-1')} [data-test=marketing-meta-disconnect]`)
  await p.waitForSelector('[data-testid=marketing-meta-disconnect-dialog-confirm]', { visible: true, timeout: 5000 }).catch(() => null)
  const linked = await text(p, '[data-test=marketing-meta-disconnect-linked]')
  const revoke = await text(p, '[data-test=marketing-meta-revoke-hint]')
  ok(`5 ${w}px: Disconnect asks first, names the linked Instagram account and how to revoke on Meta`,
    linked === 'Its linked Instagram account is disconnected too.' && revoke.includes('Business integrations') && (await accounts(p)).length === 3, { linked, revoke })
  await tap(p, '[data-testid=marketing-meta-disconnect-dialog-confirm]')
  await p.waitForFunction((s) => !document.querySelector(s), { timeout: 5000 }, acct('mch-fb-1')).catch(() => null)
  await sleep(200)
  const left = (await accounts(p)).map((a) => a.id)
  const notice = await text(p, '[data-test=marketing-meta-notice]')
  ok(`5b ${w}px: RED CONTROL the Page and its Instagram account leave the list`, left.join() === 'mch-fb-2' && notice === 'Disconnected.' &&
    !(await p.$('[data-testid=marketing-meta-disconnect-dialog-confirm]')), { left, notice })
}

// 503 not_configured: one line, no Connect, no retry
async function notConfiguredSteps(p, w) {
  if (RED !== 'configured') await setFlag(p, 'not_configured')
  await flipOn(p, false)
  await flipOn(p, true)
  await p.waitForSelector(ACCOUNTS, { visible: true, timeout: 5000 }).catch(() => null)
  await sleep(1200)
  const line = await text(p, '[data-test=marketing-meta-not-configured]')
  ok(`6 ${w}px: without the Meta app one line says so, no Connect, no list`, line === 'Facebook and Instagram are not set up on this hub yet.' &&
    !(await p.$('[data-test=marketing-meta-connect]')) && (await accounts(p)).length === 0 && !(await p.$('[data-test=marketing-meta-failed]')), { line })
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
    localStorage.removeItem('spool.mock.marketing.meta')
    localStorage.setItem('spool-theme', 'light')
  })
  await p.goto(base + '/tenant-settings/general', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(TOGGLE, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await flipOn(p, true)
  await p.waitForSelector(ACCOUNT, { visible: true, timeout: 10000 }).catch(() => null)
  const first = await accounts(p)
  ok(`1 ${w}px: the Page then its Instagram account, initials avatars, Connected`, JSON.stringify(first) === JSON.stringify([
    { id: 'mch-fb-1', avatar: 'MS', name: 'Mock Studio', status: 'Connected' },
    { id: 'mch-ig-1', avatar: 'MS', name: '@mock.studio', status: 'Connected' },
  ]), first)
  await facebookSteps(p, w)
  await instagramSteps(p, w)
  await connectNoAdminSteps(p, w)
  if (SHOT_DIR) {
    mkdirSync(SHOT_DIR, { recursive: true })
    await p.$eval(ACCOUNTS, (e) => e.scrollIntoView({ block: 'start' }))
    await tap(p, `${acct('mch-fb-1')} [data-test=marketing-meta-publish-open]`)
    await sleep(500)
    await p.screenshot({ path: `${SHOT_DIR}/marketing-meta-accounts-${w}.png`, fullPage: true })
    await tap(p, `${acct('mch-fb-1')} [data-test=marketing-meta-publish-open]`)
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
