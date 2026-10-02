// spec 021 T032 live proof of the signed-in language preference on a DEV WUI:
//   1. register a throwaway native account (debug tokens: dev only), verify it
//      through the hub API — the registration locale is the WUI's X-Locale;
//   2. sign in WITH NO TENANT through the hub API from the WUI page (the WUI
//      form always sends the build's default tenant, which a non-member is
//      refused, and a tenant sign-in can seat a test account as a zero-member
//      tenant's bootstrap owner; tenant-less creates only the human);
//   3. /<ui>/settings/language: pick `WANT` in LanguageSetting, Save →
//      GET /api/v1/auth/session answers preferred_locale=WANT, AND the page
//      switches into WANT on the spot — URL prefix and <html lang> both
//      (owner 2026-09-23; until then Save stored the preference and left the
//      page in the old language, which is the bug that was reported);
//   4. sign out, sign in again at the default-locale /login → the WUI opens in
//      WANT once (plugins/preferred-locale.client.ts);
//   5. PUT preferences {"preferred_locale":"xx"} → 400 unsupported_locale.
// Screenshots + results.json to OUT.
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> OUT=<dir> \
//     [UI=en] [WANT=fi] [DEFAULT_LOCALE=en] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/language-setting-live.proof.mjs
//
// The password is random per run and never printed. Exit 0 = every step PASS.
import { randomBytes } from 'node:crypto'
import { writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
if (process.env.TENANT) { console.error('FATAL this proof signs in with NO tenant on purpose; unset TENANT'); process.exit(2) }
const UI = process.env.UI || 'en'
const WANT = process.env.WANT || 'fi'
const DEF = process.env.DEFAULT_LOCALE || 'en'
const pfx = (c) => (c === DEF ? '' : '/' + c)
const email = `wui-i18n-proof+${Date.now()}@example.com`
const pw = randomBytes(18).toString('base64url')
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, api: API, ui: UI, want: WANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const settle = (ms = 800) => new Promise((r) => setTimeout(r, ms))
const post = (path, body) => fetch(API + '/api/v1/auth' + path, {
  method: 'POST', headers: { 'content-type': 'application/json', origin: BASE, 'x-locale': UI }, body: JSON.stringify(body),
})

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  try { res.build = await (await fetch(BASE + '/build.json')).json() } catch { res.build = null }
  try { res.hub = await (await fetch(API + '/version')).json() } catch { res.hub = null }

  // 1. register + verify through the API (dev debug token)
  const reg = await post('/register', { email, password: pw })
  const regBody = await reg.json().catch(() => ({}))
  step('register answers a debug token (dev)', reg.ok && !!regBody.debug_token, { status: reg.status })
  const ver = await post('/email/verify', { token: String(regBody.debug_token || ''), password: pw })
  step('verify', ver.ok, { status: ver.status })

  // 2. sign in, no tenant (see the header)
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  const signIn = async (at) => {
    await p.goto(BASE + at + '/login', { waitUntil: 'networkidle2' })
    const r = await p.evaluate(async (api, e, w, x) => {
      const res = await fetch(api + '/api/v1/auth/login', { method: 'POST', credentials: 'include',
        headers: { 'content-type': 'application/json', 'x-locale': x }, body: JSON.stringify({ email: e, password: w, redirect: '/' }) })
      return res.status
    }, API, email, pw, at.slice(1) || DEF)
    await p.goto(BASE + at + '/lobby', { waitUntil: 'networkidle2' })
    return r
  }
  const st = await signIn(pfx(UI))
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('signed in (no tenant)', st === 200 && !!trig, { login: st, url: p.url().replace(BASE, '') })

  // 3. Settings → Language: pick WANT, Save
  await p.goto(BASE + pfx(UI) + '/settings/language', { waitUntil: 'networkidle2' })
  const input = await p.waitForSelector('[data-test=settings-preferred-locale]', { visible: true, timeout: 20000 })
  await input.click()
  await p.keyboard.type(WANT === 'fi' ? 'suo' : WANT, { delay: 40 })
  await p.waitForSelector(`[data-test=settings-preferred-locale-item-${WANT}]`, { visible: true, timeout: 5000 })
  await p.click(`[data-test=settings-preferred-locale-item-${WANT}]`)
  await Promise.all([
    // The switch IS the confirmation, so wait for it rather than for a status
    // line — the page remounts in WANT and the status ref goes with it.
    p.waitForFunction((c) => document.documentElement.lang.startsWith(c), { timeout: 20000 }, WANT),
    p.click('[data-test=settings-preferred-locale-save]'),
  ])
  await settle()
  const lang = await p.evaluate(() => document.documentElement.lang)
  const savedPath = new URL(p.url()).pathname
  const sess = await p.evaluate(async (api) => (await fetch(api + '/api/v1/auth/session', { credentials: 'include' })).json(), API)
  step(`save ${WANT}: session preferred_locale AND the page switches to ${WANT}`,
    sess.preferred_locale === WANT && lang.startsWith(WANT) && savedPath === pfx(WANT) + '/settings/language',
    { preferred_locale: sess.preferred_locale, html_lang: lang, path: savedPath })
  await p.screenshot({ path: `${OUT}/settings-language-saved.png` })

  // 5. an unsupported code is refused (page context: cookie + CORS as the WUI)
  const bad = await p.evaluate(async (api) => {
    const r = await fetch(api + '/api/v1/auth/preferences', { method: 'PUT', credentials: 'include',
      headers: { 'content-type': 'application/json' }, body: JSON.stringify({ preferred_locale: 'xx' }) })
    return { status: r.status, body: await r.json().catch(() => ({})) }
  }, API)
  step('PUT an unsupported code → 400', bad.status === 400 && bad.body.error === 'unsupported_locale', bad)

  // 4. sign out, sign in at the default-locale /login → opens in WANT
  await p.click('[data-test=user-menu-trigger]')
  await p.click('[data-test=user-menu-signout]')
  await p.waitForFunction(() => /\/login/.test(location.pathname), { timeout: 15000 })
  await p.evaluate(() => { try { sessionStorage.clear() } catch { /* */ } })
  await signIn(pfx(DEF))
  await p.waitForFunction((w) => document.documentElement.lang.startsWith(w), { timeout: 30000 }, WANT).catch(() => null)
  await settle(1500)
  const lang2 = await p.evaluate(() => document.documentElement.lang)
  step(`next sign-in opens in ${WANT}`, lang2.startsWith(WANT) && new URL(p.url()).pathname.startsWith('/' + WANT),
    { html_lang: lang2, path: new URL(p.url()).pathname })
  await p.screenshot({ path: `${OUT}/after-signin-${WANT}.png` })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`\n${res.steps.length - bad}/${res.steps.length} steps PASS`)
process.exit(bad ? 1 : 0)
