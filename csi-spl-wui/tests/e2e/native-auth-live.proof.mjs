// SPL-6182 native auth live proof: the whole email + password account flow
// in the deployed WUI against its hub, with no human step (owner HUM-10 msgs
// e4eb9fff, 1bd9911f: "Create snapshots of the evidence"). A fresh relay
// plus-address signs up in the WUI; both mails are read by MAIL_TOKEN_CMD
// (do_spl_mail_verify_token, MAIL_TOKEN_KIND verify / reset):
//
//   0  GET <API>/version: the served build
//   1  /login Register tab: the form, filled; submit -> "check your mail"
//   2  the verify mail arrives (Message-ID)
//   3  /verify-email?token=: the page; the password; submit -> signed in
//      (GET /api/v1/auth/session 200 with the address)
//   4  signed out; /login sign-in with the password -> signed in
//   5  CONTROL: a wrong password -> the error shows, no session
//   6  /login Forgot tab -> submitted (after the hub's 60 s mail floor)
//   7  the reset mail arrives (Message-ID)
//   8  /reset-password?token=: the page; a new password; submit -> signed in
//   9  CONTROL: the old password is refused (POST login 401)
//  10  /login sign-in with the new password -> signed in
//
//   BASE=https://<wui> API=https://<api> EMAIL=<fresh relay plus-address>
//   OUT=<dir for the screenshots + results.json>
//   MAIL_TOKEN_CMD="cd <repo>/csi-spl-orc && ENV=<env> ./run -a do_spl_mail_verify_token"
//   [CRED_FILE=<path>]  the address + the final password, 0600, for an
//     account kept for a person to inspect; else the passwords stay in memory
//   [SEAT_CMD=<shell>]  seats the account (SEAT_EMAIL) as a tenant member
//     after verify: step 4a (CONTROL) shows the WUI tenant refusing the
//     unseated account, 4b runs the command; then 4 and 10 sign in there
//   [FLOOR_S=65] [CHROME_PATH] [PUPPETEER_CORE]
//   node tests/e2e/native-auth-live.proof.mjs
//
// Prints one JSON line per step and a verdict; exit 0 only when every step
// held. No password, token or cookie is printed or saved in OUT.
import { writeFileSync, chmodSync, mkdirSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep, verifyToken } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const EMAIL = need('EMAIL')
const OUT = need('OUT')
need('MAIL_TOKEN_CMD')
const FLOOR_S = Number(process.env.FLOOR_S || 65)
const SEAT_CMD = process.env.SEAT_CMD || ''
mkdirSync(OUT, { recursive: true })

const steps = []
let failed = false
const step = (name, ok, ev = {}) => {
  steps.push({ step: name, ok, ...ev })
  if (!ok) failed = true
  console.log(JSON.stringify({ step: name, ok, ...ev }))
  return ok
}
const shots = []
const shot = async (p, name) => {
  const path = join(OUT, name + '.png')
  await p.screenshot({ path, fullPage: true })
  shots.push(path)
}

/* mail evidence from MAIL_TOKEN_CMD's last line (a JSON object), never the token */
const mail = (kind) => {
  const r = verifyToken({}, EMAIL, kind)
  return { token: r.token, ev: r.token ? { via: r.via, ...(r.mail || {}) } : { via: r.via, error: r.error } }
}

const pw1 = randomBytes(18).toString('base64url')
const pw2 = randomBytes(18).toString('base64url')

let ver = { status: 0 }
for (let i = 0; i < 3 && ver.status !== 200; i++) {
  if (i) await sleep(2000)
  ver = await fetch(API + '/version').then(async (r) => ({ status: r.status, body: r.ok ? await r.json() : null }), (e) => ({ status: 0, error: String(e) }))
}
step('0 version', ver.status === 200, { http: ver.status, version: ver.body, error: ver.error })

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--window-size=1280,900'],
})

const session = (p) => p.evaluate(async (api) => {
  const r = await fetch(api + '/api/v1/auth/session', { credentials: 'include' })
  let b = null
  try { b = await r.json() } catch { /* empty */ }
  return { status: r.status, email: b && b.email }
}, API)
const signedIn = async (p) => {
  for (let i = 0; i < 20; i++) {
    const s = await session(p)
    if (s.status === 200 && s.email === EMAIL) return s
    await sleep(500)
  }
  return session(p)
}
const signOut = async (p) => {
  const c = await p.browserContext().cookies()
  await p.browserContext().deleteCookie(...c)
}
/* /login on the tab; a click before hydration is lost, so it repeats until
   the tab reports itself selected */
const loginForm = async (p, tab) => {
  await p.goto(BASE + '/login', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 })
  const sel = `[data-test=native-auth-tab-${tab}]`
  for (let i = 0; i < 20; i++) {
    await p.click(sel)
    await sleep(300)
    if (await p.$eval(sel, (e) => e.getAttribute('aria-selected') === 'true')) return
  }
  throw new Error(`the ${tab} tab did not open`)
}
const signInUi = async (p, pw, name) => {
  await loginForm(p, 'login')
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const s = await signedIn(p)
  await sleep(1500)
  await shot(p, name)
  return s
}

/* click a form's submit and wait for its POST; when the hub did not answer
   (the page says "try again"), press it again, up to 3 times, as a person
   would; the evidence counts the tries */
const submit = async (p, sel, path) => {
  for (let i = 1; i <= 3; i++) {
    const w = p.waitForResponse((r) => r.request().method() === 'POST' && r.url().endsWith(path), { timeout: 30000 }).catch(() => null)
    await p.click(sel)
    const r = await w
    if (r) return { r, tries: i }
    await sleep(3000)
  }
  return { r: null, tries: 3 }
}

try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 900 })

  /* 1 sign-up in the WUI */
  await loginForm(p, 'register')
  await p.type('[data-test=native-auth-name]', 'Native E2E')
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', pw1)
  await shot(p, '01-signup-form')
  const { r: reg, tries: reg_tries } = await submit(p, '[data-test=native-auth-submit]', '/api/v1/auth/register')
  await p.waitForSelector('[data-test=native-auth-notice]', { timeout: 20000 }).catch(() => null)
  await shot(p, '02-signup-check-mail')
  const tMail = Date.now()
  if (!step('1 sign-up (WUI register form)', reg && reg.status() === 202, { tries: reg_tries, http: reg && reg.status() })) throw new Error('sign-up')

  /* 2 + 3 verify */
  const v = mail('verify')
  if (!step('2 verify mail', Boolean(v.token), v.ev)) throw new Error('verify mail')
  await signOut(p)
  await p.goto(BASE + '/verify-email?token=' + v.token, { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=verify-email-password]', { timeout: 30000 })
  await shot(p, '03-verify-link-page')
  await p.type('[data-test=verify-email-password]', pw1)
  const { r: vr, tries: vr_tries } = await submit(p, '[data-test=verify-email-submit]', '/api/v1/auth/email/verify')
  const s3 = await signedIn(p)
  await sleep(1500)
  await shot(p, '04-signed-in-after-verify')
  step('3 verify (signed in)', vr && vr.status() === 200 && s3.status === 200, { tries: vr_tries, http: vr && vr.status(), session: s3.status, page: new URL(p.url()).pathname })

  /* 4a + 4b (SEAT_CMD): the account is a member of no tenant, so the WUI
     host's tenant refuses it; then it is seated as a member and signs in */
  if (SEAT_CMD) {
    await signOut(p)
    await loginForm(p, 'login')
    await p.type('[data-test=native-auth-email]', EMAIL)
    await p.type('[data-test=native-auth-password]', pw1)
    const { r: un, tries: un_tries } = await submit(p, '[data-test=native-auth-submit]', '/api/v1/auth/login')
    const unErr = await p.waitForSelector('[data-test=native-auth-error]', { timeout: 15000 }).catch(() => null)
    await shot(p, '05a-unseated-no-access')
    const s4a = await session(p)
    step('4a CONTROL unseated account: the WUI tenant refuses it', Boolean(un) && un.status() !== 200 && Boolean(unErr) && s4a.status === 401,
      { tries: un_tries, http: un && un.status(), session: s4a.status })
    const seat = spawnSync('sh', ['-c', SEAT_CMD], { env: { ...process.env, SEAT_EMAIL: EMAIL }, encoding: 'utf8', timeout: 600000 })
    const okLine = String(seat.stdout || '').split('\n').filter((l) => /^OK|\[OK\]/.test(l)).slice(-1)[0] || ''
    step('4b seat as member (SEAT_CMD)', seat.status === 0, { exit: seat.status, ok_line: okLine.slice(0, 200) })
  }

  /* 4 sign-in */
  await signOut(p)
  const s4 = await signInUi(p, pw1, '05-signed-in')
  step('4 sign-in', s4.status === 200, { session: s4.status, page: new URL(p.url()).pathname })

  /* 5 CONTROL wrong password */
  await signOut(p)
  await loginForm(p, 'login')
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', pw1 + 'x')
  const { r: bad, tries: bad_tries } = await submit(p, '[data-test=native-auth-submit]', '/api/v1/auth/login')
  const err = await p.waitForSelector('[data-test=native-auth-error]', { timeout: 15000 }).catch(() => null)
  await shot(p, '06-wrong-password-refused')
  const s5 = await session(p)
  step('5 CONTROL wrong password refused', bad && bad.status() === 401 && Boolean(err) && s5.status === 401, { tries: bad_tries, http: bad && bad.status(), session: s5.status })

  /* 6 forgot */
  const wait = tMail + FLOOR_S * 1000 - Date.now()
  if (wait > 0) await sleep(wait)
  await loginForm(p, 'forgot')
  await p.type('[data-test=native-auth-email]', EMAIL)
  const { r: fr, tries: fr_tries } = await submit(p, '[data-test=native-auth-submit]', '/api/v1/auth/password/forgot')
  await p.waitForSelector('[data-test=native-auth-notice]', { timeout: 20000 }).catch(() => null)
  await shot(p, '07-forgot-sent')
  if (!step('6 forgot (WUI)', fr && fr.status() === 204, { tries: fr_tries, http: fr && fr.status() })) throw new Error('forgot')

  /* 7 + 8 reset */
  const rs = mail('reset')
  if (!step('7 reset mail', Boolean(rs.token), rs.ev)) throw new Error('reset mail')
  await p.goto(BASE + '/reset-password?token=' + rs.token, { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=reset-password-new]', { timeout: 30000 })
  await shot(p, '08-reset-link-page')
  await p.type('[data-test=reset-password-new]', pw2)
  await p.type('[data-test=reset-password-repeat]', pw2)
  const { r: rr, tries: rr_tries } = await submit(p, '[data-test=reset-password-submit]', '/api/v1/auth/password/reset')
  const s8 = await signedIn(p)
  await sleep(1500)
  await shot(p, '09-signed-in-after-reset')
  step('8 reset (signed in)', rr && rr.status() === 200 && s8.status === 200, { tries: rr_tries, http: rr && rr.status(), session: s8.status, page: new URL(p.url()).pathname })

  /* 9 CONTROL old password */
  const old = await fetch(API + '/api/v1/auth/login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ email: EMAIL, password: pw1 }) })
  step('9 CONTROL old password refused', old.status === 401, { http: old.status })

  /* 10 sign-in with the new password */
  await signOut(p)
  const s10 = await signInUi(p, pw2, '10-signed-in-new-password')
  step('10 sign-in new password', s10.status === 200, { session: s10.status, page: new URL(p.url()).pathname })
} catch (e) {
  step('aborted', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
}

if (process.env.CRED_FILE && steps.some((s) => s.step.startsWith('1 ') && s.ok)) {
  const pw = steps.some((s) => s.step.startsWith('8 ') && s.ok) ? pw2 : pw1
  writeFileSync(process.env.CRED_FILE, `email=${EMAIL}\npassword=${pw}\nurl=${BASE}/login\n`, { mode: 0o600 })
  chmodSync(process.env.CRED_FILE, 0o600)
}
const n = steps.filter((s) => /^\d/.test(s.step) && s.ok).length
const want = SEAT_CMD ? 13 : 11
writeFileSync(join(OUT, 'results.json'), JSON.stringify({ base: BASE, api: API, steps, screenshots: shots }, null, 1))
const ok = !failed && n === want
console.log(`${ok ? 'PASS' : 'FAIL'} native auth live proof: ${n}/${want} steps held, screenshots ${OUT}`)
process.exit(ok ? 0 : 1)
