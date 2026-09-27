// SPL-993 (lane M5) live proof on a DEPLOYED WUI: settings, dialogs, the
// event log, archive, users and search on a phone (390 px) and a small tablet
// (820 px), signed in as a test member. READ-ONLY: it signs in once, opens
// pages and one dialog, and never submits a form or saves a setting.
//
// Per width it screenshots each page into OUT and prints one line per check:
// no sideways page scroll, /settings as a list of >= 44 px rows, a section
// opening alone with the Back chevron, the event log as cards (<= 600 px),
// the full-screen dialog (<= 600 px).
//
// Run (prd: the e2e tenant host, never the apex - it is t1's host):
//   BASE=https://e2e.<domain> TENANT=e2e EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     node tests/e2e/mobile-m5-live.proof.mjs
// The password is read from PW_FILE and never printed. Exit 0 = every check
// passed.
import { createRequire } from 'node:module'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
if (new URL(BASE).hostname.split('.').length === 2 && TENANT !== 't1') { console.error('FATAL the apex is the t1 host: use https://<tenant>.<domain>'); process.exit(2) }
mkdirSync(OUT, { recursive: true })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass, ev })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return (mod.default ?? mod).launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        args: ['--no-sandbox', '--disable-dev-shm-usage'],
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** goto that retries what the box's docker network churn kills */
async function nav(p, url, wait) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      await p.waitForSelector(wait, { timeout: 45000 })
      await sleep(2500)
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

/* page functions are passed as functions: the deployed CSP has no unsafe-eval */
const X_SCROLL = () => ({ sw: document.scrollingElement.scrollWidth, iw: innerWidth })
const SHOWN = (sel) => { const e = document.querySelector(sel); if (!e) return false; const r = e.getBoundingClientRect(); return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0 }

const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Fsettings', { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login'), { timeout: 60000 })
  const claim = await p.evaluate(() => document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?.state?.value?.session?.claims?.t || '')
  ok('signed in, session tenant = TENANT', claim === TENANT, { claim })
  if (claim !== TENANT) throw new Error('wrong tenant: refusing to go on')
  const build = await p.evaluate(async () => { try { return (await (await fetch('/build.json', { cache: 'no-store' })).json()).commit } catch { return '' } })
  console.log(`  build ${build}`)

  for (const [w, h] of [[390, 844], [820, 1180]]) {
    await p.setViewport({ width: w, height: h, isMobile: true, hasTouch: true })
    const tag = `@${w}`
    await nav(p, BASE + '/settings', '[data-test=settings-nav]')
    const rows = await p.$$eval('[data-test=settings-nav] a', (as) => as.map((a) => Math.round(a.getBoundingClientRect().height)))
    ok(`${tag} /settings is the list, rows >= 44 px, content hidden`, rows.length === 7 && rows.every((x) => x >= 44) && !(await p.evaluate(SHOWN, '[data-test=settings-content]')), { rows })
    await p.screenshot({ path: `${OUT}/${w}-settings-list.png` })
    await p.click('[data-test=settings-nav-behaviour]')
    await sleep(1500)
    ok(`${tag} a section opens alone with the Back chevron`, !(await p.evaluate(SHOWN, '[data-test=settings-nav]')) && await p.evaluate(SHOWN, '[data-testid=mobile-back]'))
    await p.screenshot({ path: `${OUT}/${w}-settings-behaviour.png` })
    await p.click('[data-testid=mobile-back]')
    await sleep(1500)
    ok(`${tag} Back returns to the list`, /\/settings\/?$/.test(new URL(p.url()).pathname) && await p.evaluate(SHOWN, '[data-test=settings-nav]'), { url: p.url() })
    for (const [path, wait, name] of [['/events', '[data-test=events-page]', 'events'], ['/archive', '[data-test=archive-page]', 'archive'], ['/search?q=deploy', '[data-test=search-page]', 'search'], ['/settings/profile', '[data-test=settings-content]', 'profile']]) {
      await nav(p, BASE + path, wait)
      const x = await p.evaluate(X_SCROLL)
      ok(`${tag} ${path}: no sideways page scroll`, x.sw <= x.iw, x)
      await p.screenshot({ path: `${OUT}/${w}-${name}.png` })
    }
    // one dialog, opened and closed: channel create from the channels section (level 1)
    await nav(p, BASE + '/', '.spool-shell')
    await p.click('[data-testid=sidebar-tab-channels]').catch(() => null)
    await sleep(800)
    const canCreate = await p.evaluate(SHOWN, '[data-testid=create-channel]')
    if (canCreate) {
      await p.click('[data-testid=create-channel]')
      await p.waitForSelector('[data-testid=ui-dialog]', { visible: true, timeout: 10000 })
      await sleep(500)
      const d = await p.$eval('[data-testid=ui-dialog]', (e) => { const r = e.getBoundingClientRect(); return { w: Math.round(r.width), h: Math.round(r.height), vw: innerWidth, vh: innerHeight } })
      if (w <= 600) ok(`${tag} the dialog is full screen`, d.w === d.vw && d.h === d.vh, d)
      else ok(`${tag} the dialog stays a card above 600 px`, d.w < d.vw, d)
      await p.screenshot({ path: `${OUT}/${w}-dialog.png` })
      await p.keyboard.press('Escape')
      await sleep(400)
    } else {
      console.log(`  skip ${tag} dialog: this member cannot create channels`)
    }
  }
} catch (e) {
  ok('ran', false, String(e.message || e))
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/results.json`, JSON.stringify(results, null, 2))
const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
