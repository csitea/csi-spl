// SPL-6286 invite accepted with email + password, no Google: a live proof in
// the deployed WUI (owner HUM-10, t1 1269968d msg 01649437: "invite a fresh
// test address to the test workspace e2e, accept it with email and password,
// post the steps here"). do_spl_invite_native_e2e (csi-spl-orc) creates the
// invite first and runs this; it reads the hub's rows back after it (step 9).
//
//   0  GET <API>/version: the served build
//   1  the hub stored the invite and its relay took the mail (INVITE_JSON)
//   2  the invite mail arrived; its link names the tenant and the invitee
//      (INVITE_LINK_CMD prints the link facts; the link is never printed)
//   3  the invite link's page opens: the sign-in page of the tenant
//   4  Register tab on that page: name + password; submit -> "check your mail"
//   5  the verify mail arrives (MAIL_TOKEN_CMD, kind verify)
//   6  /verify-email?token= on the same host: the password; submit -> signed
//      in, the session bound to TENANT as a named human (bound.json)
//   7  signed out; the invite link again, sign-in tab, email + password ->
//      signed in to TENANT, the same human
//   8  CONTROL: a wrong password on the same page is refused, no session
//
//   API=https://<api> EMAIL=<the invited relay plus-address> TENANT=<slug>
//   OUT=<dir for the screenshots + results.json + bound.json>
//   INVITE_JSON=<the invite answer> INVITE_LINK_CMD=<shell> MAIL_TOKEN_CMD=<shell>
//   [CHROME_PATH] [PUPPETEER_CORE]
//   node tests/e2e/invite-native-live.proof.mjs
//
// Prints one JSON line per step and a verdict; exit 0 only when every step
// held. No password, token, cookie, link or address is printed or saved.
import { writeFileSync, readFileSync, mkdirSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep, verifyToken } from './lib/proof.mjs'

const API = need('API').replace(/\/+$/, '')
const EMAIL = need('EMAIL')
const TENANT = need('TENANT')
const OUT = need('OUT')
const INVITE_JSON = need('INVITE_JSON')
const LINK_CMD = need('INVITE_LINK_CMD')
need('MAIL_TOKEN_CMD')
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
const lastJson = (s) => {
  for (const l of String(s || '').trim().split('\n').reverse()) {
    try { return JSON.parse(l) } catch { /* not JSON */ }
  }
  return null
}
const where = (p) => new URL(p.url()).pathname
const pw = randomBytes(18).toString('base64url')

let ver = { status: 0 }
for (let i = 0; i < 3 && ver.status !== 200; i++) {
  if (i) await sleep(2000)
  ver = await fetch(API + '/version').then(async (r) => ({ status: r.status, body: r.ok ? await r.json() : null }), (e) => ({ status: 0, error: String(e) }))
}
step('0 version', ver.status === 200, { http: ver.status, version: ver.body, error: ver.error })

/* 1 the invite the wrapper created */
let inv = {}
try { inv = JSON.parse(readFileSync(INVITE_JSON, 'utf8')) } catch { /* empty */ }
step('1 invite stored + mailed', inv.status === 201 && inv.tenant_id === TENANT && inv.mail_outcome === 'sent',
  { http: inv.status, role: inv.role, mail_outcome: inv.mail_outcome, mail_message_id: inv.mail_message_id, expires_at: inv.expires_at })

/* 2 the invite mail */
const lr = spawnSync('sh', ['-c', LINK_CMD], { env: { ...process.env, INVITE_MESSAGE_ID: inv.mail_message_id || '' }, encoding: 'utf8', timeout: 600000 })
const lk = lastJson(lr.stdout) || {}
const { link = '', ...lkEv } = lk
step('2 invite mail', lr.status === 0 && Boolean(link) && lk.link_tenant === TENANT && lk.link_login_hint_is_invitee === true,
  { exit: lr.status, ...lkEv })
const BASE = link ? new URL(link).origin : ''

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
  return { status: r.status, email: b && b.email, t: b && b.t, hum: b && b.hum, p: b && b.p }
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
/* the invite link's page on a tab; a click before hydration is lost, so it
   repeats until the tab reports itself selected */
const linkTab = async (p, tab, open = true) => {
  if (open) await p.goto(link, { waitUntil: 'networkidle2', timeout: 60000 })
  const sel = `[data-test=native-auth-tab-${tab}]`
  for (let i = 0; i < 20; i++) {
    try {
      await p.waitForSelector('[data-test=native-auth-email]', { timeout: 45000 })
      await p.click(sel)
      await sleep(300)
      if (await p.$eval(sel, (e) => e.getAttribute('aria-selected') === 'true')) return
    } catch (e) {
      /* the page navigated under the click (hydration, a client redirect):
         wait for it to settle and try again */
      if (!/context was destroyed|detached|not clickable|No element/i.test(String(e && e.message))) throw e
      await sleep(1000)
    }
  }
  throw new Error(`the ${tab} tab did not open`)
}
/* the email field: the invite's login_hint pre-fills it; typed when empty */
const email = async (p) => {
  const v = await p.$eval('[data-test=native-auth-email]', (e) => e.value)
  if (v !== EMAIL) {
    await p.$eval('[data-test=native-auth-email]', (e) => { e.value = '' })
    await p.type('[data-test=native-auth-email]', EMAIL)
  }
  return v === EMAIL
}
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
  if (!link) throw new Error('no invite link')
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 900 })

  /* 3 + 4 the invite link's page, Register */
  await linkTab(p, 'login')
  await shot(p, '01-invite-link-page')
  step('3 invite link page', where(p).endsWith('/login'), { host: new URL(BASE).host, page: where(p) })
  await linkTab(p, 'register')
  const pre = await email(p)
  await p.type('[data-test=native-auth-name]', 'Invite Native E2E')
  await p.type('[data-test=native-auth-password]', pw)
  await shot(p, '02-register-form')
  const { r: reg, tries: regTries } = await submit(p, '[data-test=native-auth-submit]', '/api/v1/auth/register')
  await p.waitForSelector('[data-test=native-auth-notice]', { timeout: 20000 }).catch(() => null)
  await shot(p, '03-register-check-mail')
  if (!step('4 sign-up on the invite page (Register)', reg && reg.status() === 202, { tries: regTries, http: reg && reg.status(), email_prefilled_from_invite: pre })) throw new Error('sign-up')

  /* 5 + 6 verify: the click lands signed in, in the invited tenant */
  const v = verifyToken({}, EMAIL, 'verify')
  if (!step('5 verify mail', Boolean(v.token), v.token ? { via: v.via, ...(v.mail || {}) } : { via: v.via, error: v.error })) throw new Error('verify mail')
  await signOut(p)
  await p.goto(BASE + '/verify-email?token=' + v.token, { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=verify-email-password]', { timeout: 30000 })
  await shot(p, '04-verify-link-page')
  await p.type('[data-test=verify-email-password]', pw)
  const { r: vr, tries: vrTries } = await submit(p, '[data-test=verify-email-submit]', '/api/v1/auth/email/verify')
  const s6 = await signedIn(p)
  await sleep(2000)
  await shot(p, '05-signed-in-after-verify')
  writeFileSync(join(OUT, 'bound.json'), JSON.stringify({ session_hum: s6.hum || '', session_tenant: s6.t || '' }))
  step('6 verify: signed in, in the invited tenant', vr && vr.status() === 200 && s6.status === 200 && s6.t === TENANT && /^HUM-/.test(s6.hum || ''),
    { tries: vrTries, http: vr && vr.status(), session: s6.status, provider: s6.p, tenant: s6.t, hum: s6.hum, page: where(p) })

  /* 7 sign in from the invite link with email + password, in a fresh
     browser (no cookie, no storage of the verify session) */
  const ctx2 = await browser.createBrowserContext()
  const p2 = await ctx2.newPage()
  await p2.setViewport({ width: 1280, height: 900 })
  await linkTab(p2, 'login')
  await email(p2)
  await p2.type('[data-test=native-auth-password]', pw)
  const { r: li, tries: liTries } = await submit(p2, '[data-test=native-auth-submit]', '/api/v1/auth/login')
  const s7 = await signedIn(p2)
  await sleep(2500)
  await shot(p2, '06-signed-in-from-invite-link')
  step('7 sign-in with email + password: in the tenant, same human', li && li.status() === 200 && s7.status === 200 && s7.t === TENANT && s7.hum === s6.hum,
    { tries: liTries, http: li && li.status(), session: s7.status, provider: s7.p, tenant: s7.t, hum: s7.hum, page: where(p2) })

  /* 8 CONTROL a wrong password, in another fresh browser */
  const ctx3 = await browser.createBrowserContext()
  const p3 = await ctx3.newPage()
  await p3.setViewport({ width: 1280, height: 900 })
  await linkTab(p3, 'login')
  await email(p3)
  await p3.type('[data-test=native-auth-password]', pw + 'x')
  const { r: bad, tries: badTries } = await submit(p3, '[data-test=native-auth-submit]', '/api/v1/auth/login')
  const err = await p3.waitForSelector('[data-test=native-auth-error]', { timeout: 15000 }).catch(() => null)
  await shot(p3, '07-wrong-password-refused')
  const s8 = await session(p3)
  step('8 CONTROL wrong password refused', bad && bad.status() === 401 && Boolean(err) && s8.status === 401, { tries: badTries, http: bad && bad.status(), session: s8.status })
} catch (e) {
  step('aborted', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
}

const n = steps.filter((s) => /^\d/.test(s.step) && s.ok).length
const want = 9
writeFileSync(join(OUT, 'results.json'), JSON.stringify({ base: BASE, api: API, tenant: TENANT, steps, screenshots: shots }, null, 1))
const ok = !failed && n === want
console.log(`${ok ? 'PASS' : 'FAIL'} invite native live proof: ${n}/${want} steps held, screenshots ${OUT}`)
process.exit(ok ? 0 : 1)
