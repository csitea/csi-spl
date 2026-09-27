// OSS stage 0 (spec 044 T001, FR-OS-008): the standalone stack of the root
// docker-compose.yml works end to end in a real browser. A stranger's first
// minutes, nothing seeded but the tenant:
//   1. sign up on the login page (native email + password)
//   2. sign in: the first member of the empty tenant becomes its owner
//   3. post a line in the lobby; it lands in the feed
//   4. reload: the line is still there, so it came back from the hub + Postgres,
//      not from the page's memory
// CONTROL: a fresh browser context that never signed in has no session
// (GET /api/v1/auth/session is not 200), so step 2 is what opened the door.
//
//   BASE=http://localhost:8080 OUT=<dir> [CHROME_PATH=...] \
//     node tests/e2e/standalone-live.proof.mjs
//
// Writes a random throwaway account and one lobby line: run it only against a
// throwaway stack. Screenshots and result.json go to OUT. Exit 0 = all PASS.
import { createRequire } from 'node:module'
import { writeFileSync, mkdirSync } from 'node:fs'
import { randomBytes } from 'node:crypto'
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
mkdirSync(OUT, { recursive: true })

const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const BOX = 'form.omnibox--global textarea'
const id = randomBytes(4).toString('hex')
const EMAIL = `stranger-${id}@example.org`
const PW = randomBytes(18).toString('base64url') // held in memory only
const LINE = `hello from a standalone stack ${id}`

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
const sessionStatus = (page) => page.evaluate(async (base) => {
  const r = await fetch(base + '/api/v1/auth/session', { credentials: 'include', cache: 'no-store' })
  return r.status
}, BASE)
const inFeed = (page, text, timeout = 20000) => page.waitForFunction(
  (t) => [...document.querySelectorAll('main, [data-test], article')].some((el) => (el.innerText || '').includes(t)),
  { timeout }, text,
).then(() => true).catch(() => false)

try {
  const p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport({ width: 1280, height: 900 })
  const pageErrors = []
  p.on('pageerror', (e) => pageErrors.push(String(e.message || e).slice(0, 200)))

  // CONTROL first: no session before anyone signs in
  await p.goto(`${BASE}/login`, { waitUntil: 'networkidle2' })
  const before = await sessionStatus(p)
  step('CONTROL: a browser that never signed in has no session', before !== 200, { status: before })

  // 1. sign up
  await p.waitForSelector('[data-native-auth=on]', { timeout: 20000 })
  await p.click('[data-test=native-auth-tab-register]')
  await p.waitForSelector('[data-test=native-auth-name]')
  await p.type('[data-test=native-auth-name]', `Stranger ${id}`)
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.screenshot({ path: `${OUT}/01-sign-up.png` })
  await p.click('[data-test=native-auth-submit]')
  const signedUp = await p.waitForSelector('[data-test=native-auth-notice], [data-test=native-auth-error]', { timeout: 15000 })
    .then((el) => el.evaluate((n) => ({ test: n.dataset.test, text: n.innerText })))
    .catch(() => ({ test: 'none', text: '' }))
  step('sign up: the hub accepts the new account', signedUp.test === 'native-auth-notice', signedUp)

  // 1b. confirm the email: the local stack shows the link on the form
  //     (SPOOL_AUTH_DEBUG_LINKS); a mail relay would carry the same link
  const verifyHref = await p.waitForSelector('[data-test=native-auth-debug] a', { timeout: 10000 })
    .then((a) => a.evaluate((n) => n.getAttribute('href'))).catch(() => '')
  step('sign up: the confirmation link is offered', /verify-email/.test(verifyHref || ''), { href: (verifyHref || '').replace(/token=[^&]+/, 'token=<redacted>') })
  await p.goto(new URL(verifyHref || '/verify-email', BASE).href, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=verify-email-password]', { timeout: 15000 })
  await p.type('[data-test=verify-email-password]', PW)
  await p.click('[data-test=verify-email-submit]')
  const verified = await p.waitForSelector('[data-test=verify-email-ok], [data-test=verify-email-error]', { timeout: 15000 })
    .then((el) => el.evaluate((n) => n.dataset.test)).catch(() => 'none')
  step('confirm email: the hub marks the account verified', verified === 'verify-email-ok', { got: verified })

  // 2. sign in
  await p.goto(`${BASE}/login`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-native-auth=on]', { timeout: 20000 })
  await p.click('[data-test=native-auth-tab-login]')
  await sleep(300)
  // the fields keep what was typed on the other tab: type into empty ones
  for (const [sel, v] of [['[data-test=native-auth-email]', EMAIL], ['[data-test=native-auth-password]', PW]]) {
    await p.click(sel, { clickCount: 3 })
    await p.keyboard.press('Backspace')
    await p.type(sel, v)
  }
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login'), { timeout: 20000 }).catch(() => {})
  await sleep(1500)
  const after = await sessionStatus(p)
  step('sign in: the session is live', after === 200, { status: after, path: await p.evaluate(() => location.pathname) })

  // 3. post in the lobby
  await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
  await p.waitForSelector(BOX, { timeout: 20000 })
  await sleep(1500)
  await p.click(BOX)
  await p.keyboard.type(LINE)
  await p.keyboard.press('Enter')
  let sent = await inFeed(p, LINE, 6000)
  if (!sent || (await p.$eval(BOX, (el) => el.value)) !== '') {
    // the account's submit key may be Ctrl+Enter (SPL-976): a bare Enter then
    // only added a new line
    await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
    sent = await inFeed(p, LINE)
  }
  const boxLeft = await p.$eval(BOX, (el) => el.value)
  step('post: the line lands in the lobby and the composer empties', sent && boxLeft.trim() === '', { sent, box: boxLeft })
  await sleep(1000)
  await p.screenshot({ path: `${OUT}/02-lobby-posted.png` })

  // 4. reload: it came from the hub
  await p.reload({ waitUntil: 'networkidle2' })
  const kept = await inFeed(p, LINE)
  step('reload: the line is read back from the hub', kept)
  await sleep(800)
  await p.screenshot({ path: `${OUT}/03-lobby-after-reload.png` })

  step('no uncaught page error', pageErrors.length === 0, { errors: pageErrors })
} catch (e) {
  step('proof ran to the end', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  res.failed = failed
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAIL ${failed} step(s)` : 'PASS all steps')
process.exit(failed ? 1 : 0)
