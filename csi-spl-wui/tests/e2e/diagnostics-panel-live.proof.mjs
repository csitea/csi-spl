// 005 T035 live: the diagnostics panel appears for a human the operator
// granted, and for nobody else. One signed-in browser, one hub, the grant the
// only thing that differs between the two runs.
//
//   BASE=http://localhost:3141 OUT=/var/tmp/<id>/diag \
//     [EXPECT=on|off] [PROVIDER=google] [CHROME_PATH=...] \
//     node tests/e2e/diagnostics-panel-live.proof.mjs
//
// Sign-in is the hub's own provider round trip by default (lde, fake IdP). On
// a deployed env pass EMAIL + PW_FILE and it signs in through the WUI's native
// form instead, and reads the session on AUTH_BASE — Firebase Hosting forwards
// no request cookie but __session, so a credentialed call to the WUI host is
// always 401 there:
//
//   BASE=https://dev.<domain> AUTH_BASE=https://dev.api.<domain> \
//     EMAIL=<member> PW_FILE=<0600 file> [TENANT=t1] EXPECT=off OUT=<dir> \
//     node tests/e2e/diagnostics-panel-live.proof.mjs
//
// The hub behind BASE decides the grant (SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS);
// EXPECT says which answer this run is asserting, so a run that proves
// nothing cannot read green.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
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
const EXPECT = process.env.EXPECT === 'on' ? 'on' : 'off'
const PROVIDER = process.env.PROVIDER || 'google'
const AUTH_BASE = (process.env.AUTH_BASE || BASE).replace(/\/+$/, '')
const TENANT = process.env.TENANT || 't1'
const EMAIL = process.env.EMAIL || ''
// Read once, held in memory, never printed or screenshotted.
const PW = process.env.PW_FILE ? readFileSync(process.env.PW_FILE, 'utf8').trim() : ''
mkdirSync(OUT, { recursive: true })

const puppeteer = await loadPuppeteer()
const res = { base: BASE, expect: EXPECT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let failed = 0
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 900 })

  // ── signed out: no panel, whatever the grant says ─────────────────────
  await p.goto(BASE + '/', { waitUntil: 'networkidle2' })
  await sleep(1200)
  const anon = await p.$('[data-test=debug-panel]')
  step('signed out: no panel', anon === null)
  if (anon !== null) failed++
  await p.screenshot({ path: `${OUT}/01-signed-out.png` })

  // ── sign in ───────────────────────────────────────────────────────────
  if (EMAIL && PW) {
    // A deployed env: the WUI's own native form, so the session is made the
    // way a person makes one.
    await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2F`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=native-auth-email]')
    await p.type('[data-test=native-auth-email]', EMAIL)
    await p.type('[data-test=native-auth-password]', PW)
    await p.click('[data-test=native-auth-submit]')
    await sleep(4000)
  } else {
    // lde: the hub's provider round trip, with the fake IdP consenting.
    await p.goto(`${BASE}/api/v1/auth/${PROVIDER}/start?redirect=%2F`, { waitUntil: 'networkidle2' })
    await sleep(2500)
  }
  const claims = await p.evaluate(async (base) => {
    const r = await fetch(base + '/api/v1/auth/session', { credentials: 'include', cache: 'no-store' })
    return { status: r.status, body: r.status === 200 ? await r.json() : null }
  }, AUTH_BASE)
  res.session = claims
  step('signed in', claims.status === 200, { email: claims.body && claims.body.email })
  if (claims.status !== 200) failed++
  const claim = claims.body ? claims.body.diagnostics_enabled : undefined
  step(`the session claim is ${EXPECT === 'on'}`, claim === (EXPECT === 'on'), { diagnostics_enabled: claim })
  if (claim !== (EXPECT === 'on')) failed++

  // ── the panel in the DOM, not merely hidden ───────────────────────────
  await p.goto(BASE + '/', { waitUntil: 'networkidle2' })
  await sleep(1500)
  const panel = await p.$('[data-test=debug-panel]')
  // The BODY markup, not p.content(): a dev server injects every component's
  // scoped CSS into <head>, so `.debug-panel` is in the document's text
  // whether or not the component rendered. The rendered markup is the claim
  // being made here, and the stylesheet is not part of it.
  const body = await p.evaluate(() => document.body.innerHTML)
  res.panel_in_dom = panel !== null
  res.panel_in_source = /debug-panel/.test(body)
  const want = EXPECT === 'on'
  step(`panel in the DOM: ${want}`, res.panel_in_dom === want, { in_dom: res.panel_in_dom })
  if (res.panel_in_dom !== want) failed++
  // A v-if contributes NO markup: when it is off the class is not in the
  // rendered body either, so nothing is merely visually hidden.
  step(`panel in the rendered body: ${want}`, res.panel_in_source === want, { in_body: res.panel_in_source })
  if (res.panel_in_source !== want) failed++
  if (panel) {
    res.panel_text = (await p.evaluate((el) => el.innerText, panel)).replace(/\s+/g, ' ').trim().slice(0, 200)
    console.log('     panel:', res.panel_text)
  }
  await p.screenshot({ path: `${OUT}/02-signed-in.png`, fullPage: true })
} catch (e) {
  failed++
  step('ran to completion', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  res.failed = failed
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAILED ${failed}` : 'OK all assertions')
  process.exit(failed ? 1 : 0)
}
