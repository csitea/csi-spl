// SPL-976 follow-up live: the default (never picked) is Enter sends, and an
// explicit choice is kept (owner, 2026-09-27, topic a4bc52dc).
//
//   BASE=https://dev.<domain> AUTH_BASE=https://dev.api.<domain> \
//     EMAIL=<member> PW_FILE=<0600 file> [TENANT=t1] OUT=<dir> \
//     [WIDTHS=390,820,1440] node tests/e2e/submit-key-default-live.proof.mjs
//
// The account must be NEVER PICKED (submit_key null) when it starts; the run
// refuses otherwise, since that is the case under proof. Per width:
//   A. never picked: Shift+Enter adds a line (control), a bare Enter sends
//      and the line lands; Settings shows Enter sends checked; the session
//      still answers null, so the default was never written to the row.
//   B. explicit ctrl-enter (stored with the preferences PUT, as the radio
//      does): a bare Enter adds a line (control), Ctrl+Enter sends; Settings
//      shows ctrl-enter checked.
// The account is put back to null (never picked) at the end.
// It WRITES lobby lines, so run it only as the dev test member (t1) or the
// prd e2e tenant.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const AUTH_BASE = (process.env.AUTH_BASE || BASE).replace(/\/+$/, '')
const TENANT = process.env.TENANT || 't1'
const WIDTHS = (process.env.WIDTHS || '390,820,1440').split(',').map(Number)
// Read once, held in memory, never printed or screenshotted.
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })

const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const BOX = 'form.omnibox--global textarea'
const stamp = new Date().toISOString().replace(/[-:]/g, '').slice(0, 15)

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let p
let signedIn = false
try {
  p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport({ width: 1280, height: 900 })
  const claim = async () => p.evaluate(async (base) => {
    const r = await fetch(base + '/api/v1/auth/session', { credentials: 'include', cache: 'no-store' })
    return r.status === 200 ? (await r.json()).submit_key : `status ${r.status}`
  }, AUTH_BASE)
  const store = async (v) => p.evaluate(async (base, v) => (await fetch(base + '/api/v1/auth/preferences', {
    method: 'PUT', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ submit_key: v }),
  })).status, AUTH_BASE, v)
  const settings = async () => {
    await p.goto(`${BASE}/settings/behaviour`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=submit-key-setting] input', { timeout: 15000 })
    await sleep(600)
    return p.evaluate(() => document.querySelector('[data-test=submit-key-setting] input:checked')?.value || '')
  }
  const lobby = async () => {
    await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
    await p.waitForSelector(BOX, { visible: true, timeout: 15000 })
    await sleep(1500)
    await p.focus(BOX)
  }
  const boxValue = async () => p.$eval(BOX, (el) => el.value)
  const landed = async (text) => p.waitForFunction(
    (t) => [...document.querySelectorAll('main, [data-test], article')].some((el) => (el.innerText || '').includes(t)),
    { timeout: 20000 }, text,
  ).then(() => true).catch(() => false)
  const press = async (mod) => {
    if (mod) await p.keyboard.down(mod)
    await p.keyboard.press('Enter')
    if (mod) await p.keyboard.up(mod)
  }

  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2F`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  /* Nothing is written unless BOTH the session's tenant (claim t) and the
     tenant the page writes to are TENANT: with tenant hosts on (SPL-959) the
     WUI writes to the page host's tenant (the prd apex is t1) whatever the
     claim says. On prd run it at https://<tenant>.<domain>. Same guard as
     issues-live.proof.mjs. */
  let where = null
  for (let i = 0; i < 30 && !where; i++) {
    where = await p.evaluate(() => {
      const app = document.querySelector('#__nuxt')?.__vue_app__
      const g = app && app.config.globalProperties
      const s = g && g.$pinia && g.$pinia.state.value.session
      const pub = (g && g.$config && g.$config.public) || null
      if (!pub || !s || !s.claims) return null
      const hosts = String(pub.tenantHosts || '0') === '1'
      let page = ''
      if (hosts) {
        const site = new URL(String(pub.siteUrl || location.origin)).hostname.toLowerCase()
        const h = location.hostname.toLowerCase()
        page = h === site ? String(pub.tenant || '') : h.endsWith('.' + site) ? h.slice(0, -site.length - 1) : '?'
      }
      return { claim: String(s.claims.t || ''), hosts, page }
    })
    if (!where) await sleep(500)
  }
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  step('the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...where, url: p.url() })
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  const original = await claim()
  signedIn = original === null || original === 'enter' || original === 'ctrl-enter'
  step('signed in, and the account has never picked (submit_key null)', original === null, { submit_key: original })
  if (original !== null) throw new Error('the account is not never-picked: this proof needs submit_key null')

  for (const w of WIDTHS) {
    const touch = w < 1024
    await p.setViewport({ width: w, height: touch ? 844 : 900, isMobile: touch, hasTouch: touch })

    // ── A. never picked ────────────────────────────────────────────────
    const mode = await settings()
    step(`${w}px never picked: Settings shows Enter sends checked`, mode === 'enter', { mode })
    await p.screenshot({ path: `${OUT}/${w}-1-settings-default.png` })
    await lobby()
    const t1 = `SPL-976 default Enter sends ${w}px ${stamp}`
    await p.keyboard.type(t1)
    await press('Shift')
    await sleep(700)
    const v1 = await boxValue()
    step(`${w}px never picked CONTROL: Shift+Enter adds a line, sends nothing`, v1 === t1 + '\n', { value: v1 })
    await p.keyboard.type('second line')
    await press(null)
    const sent1 = await landed(t1)
    const v1b = await boxValue()
    step(`${w}px never picked: a bare Enter sends (box empties, line lands)`, sent1 && v1b === '', { value: v1b, sent: sent1 })
    await p.screenshot({ path: `${OUT}/${w}-2-lobby-default-sent.png` })
    const after = await claim()
    step(`${w}px never picked: the account still reads null (the default is not written)`, after === null, { submit_key: after })

    // ── B. explicit ctrl-enter ─────────────────────────────────────────
    const st = await store('ctrl-enter')
    step(`${w}px explicit: ctrl-enter stored`, st === 200 && (await claim()) === 'ctrl-enter', { status: st })
    const mode2 = await settings()
    step(`${w}px explicit: Settings shows ctrl-enter checked`, mode2 === 'ctrl-enter', { mode: mode2 })
    await lobby()
    const t2 = `SPL-976 explicit Ctrl+Enter kept ${w}px ${stamp}`
    await p.keyboard.type(t2)
    await press(null)
    await sleep(700)
    const v2 = await boxValue()
    step(`${w}px explicit CONTROL: a bare Enter adds a line, sends nothing`, v2 === t2 + '\n', { value: v2 })
    await p.keyboard.type('second line')
    await press('Control')
    const sent2 = await landed(t2)
    const v2b = await boxValue()
    step(`${w}px explicit: Ctrl+Enter sends (box empties, line lands)`, sent2 && v2b === '', { value: v2b, sent: sent2 })
    await p.screenshot({ path: `${OUT}/${w}-3-lobby-explicit-sent.png` })
    const back = await store(null)
    step(`${w}px back to never picked`, back === 200 && (await claim()) === null, { status: back })
  }
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e) })
} finally {
  if (p && signedIn) {
    try { res.restored = { to: null, status: await p.evaluate(async (base) => (await fetch(base + '/api/v1/auth/preferences', {
      method: 'PUT', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ submit_key: null }),
    })).status, AUTH_BASE) } } catch (e) { res.restored = { error: String(e) } }
  }
  await browser.close()
  res.failed = failed
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed} step(s)` : 'ALL PASS', `-> ${OUT}/result.json`)
  process.exit(failed ? 1 : 0)
}
