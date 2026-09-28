// SPL-1132 live proof (owner, prd t1 topic beb4024f: "the columns of the
// issues grid should be resizable"): on a deployed WUI + hub, 1440 px, the
// Issues sheet's column widths are the PERSON's. The control is the automatic
// layout (no stored widths); a drag on the Status header's grip widens the
// column, does not sort, and the hub keeps issues_columns; a reload and a
// second, fresh browser profile (another device) both open with that width,
// in the List and in By status; a double-click fits the column to its
// content. The person's widths and view are put back as found.
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> EMAIL=<member>
//     (prd: BASE=https://<tenant>.<domain>; writes only when the session's
//     tenant AND the page host are TENANT)
//     PW_FILE=<0600 file> OUT=<dir> [TENANT=t1] [CHROME_PATH=...]
//     [PUPPETEER_CORE=<path>] node tests/e2e/issues-col-width-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
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
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const nav = (p, url) => p.goto(url, { waitUntil: 'networkidle2', timeout: 60000 })
const until = async (fn, ms) => { const t0 = Date.now(); for (;;) { const v = await fn().catch(() => null); if (v || Date.now() - t0 > ms) return v; await sleep(300) } }

async function signIn(browser, ctx) {
  const p = await (ctx || browser).newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  /* the tenant-host guard of issues-live.proof.mjs (6c080b57): nothing is
     written unless the claim AND the page host's tenant are TENANT */
  const where = await until(() => p.evaluate(() => {
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
  }), 15000)
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  step('the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...where, url: p.url() })
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  return p
}



/* the person's settings as the hub keeps them (the session claims) */
const hubClaims = (p) => p.evaluate(async (api) => {
  const r = await fetch(`${api}/api/v1/auth/session`, { credentials: 'include' })
  if (!r.ok) return { status_code: r.status }
  const j = await r.json()
  return { cols: j.issues_columns ?? null, view: j.issues_view ?? null }
}, API)
const putPref = (p, body) => p.evaluate(async (api, b) => {
  const r = await fetch(`${api}/api/v1/auth/preferences`, { method: 'PUT', credentials: 'include', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b) })
  return r.status
}, API, body)
const COL = 'status'
const TH = `.issues-names th[data-col="${COL}"]`
const GRIP = `[data-test=issues-col-grip-${COL}]`
const thWidth = (p) => p.$eval(TH, (el) => Math.round(el.getBoundingClientRect().width)).catch(() => -1)
const openSheet = async (p) => {
  await nav(p, BASE + '/issues')
  await p.waitForSelector(TH, { visible: true, timeout: 30000 })
  await sleep(600)
}
const near = (a, b, tol = 3) => Math.abs(Number(a) - Number(b)) <= tol

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
let page = null
let original
try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => null)
  res.hub = await (await fetch(API + '/version')).json().catch(() => null)
  const p = await signIn(browser)
  page = p
  res.prefs_wire = []
  p.on('response', (r) => {
    if (r.url().includes('/preferences') && r.request().method() === 'PUT') res.prefs_wire.push({ status: r.status(), body: (r.request().postData() || '').slice(0, 200) })
  })
  original = await hubClaims(p)
  res.original = original
  if (original.status_code) throw new Error('session read ' + original.status_code)

  /* control: no stored widths = the automatic layout, nothing marked resized */
  step('control: PUT issues_columns null answers 200', (await putPref(p, { issues_columns: null, issues_view: 'list' })) === 200)
  await openSheet(p)
  const auto = await thWidth(p)
  const marked0 = await p.$$eval('[data-resized="true"]', (els) => els.length)
  step('control: without a stored width the sheet keeps its automatic layout (no column marked resized)', auto > 0 && marked0 === 0, { auto, marked0 })

  /* a drag on the grip: wider, no sort, and the hub keeps it */
  const url0 = new URL(p.url())
  const box = await (await p.$(GRIP)).boundingBox()
  const x = box.x + box.width / 2
  const y = box.y + box.height / 2
  await p.mouse.move(x, y)
  await p.mouse.down()
  for (let i = 1; i <= 8; i++) { await p.mouse.move(x + i * 10, y); await sleep(16) }
  await p.mouse.up()
  const dragged = await thWidth(p)
  const url1 = new URL(p.url())
  step('a drag of 80 px on the Status grip widens the column by ~80 px', near(dragged, auto + 80, 6), { auto, dragged })
  step('the drag did not sort (?sort= and ?dir= unchanged)', url0.searchParams.get('sort') === url1.searchParams.get('sort') && url0.searchParams.get('dir') === url1.searchParams.get('dir'),
    { before: url0.search, after: url1.search })
  const kept = await until(async () => { const c = await hubClaims(p); return c.cols && c.cols[COL] ? c.cols : null }, 8000)
  const store = await p.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    return { state: s.state, cols: JSON.parse(JSON.stringify(s.claims?.issues_columns ?? null)) }
  })
  step('the hub keeps issues_columns for the person (one PUT after the gesture)', Boolean(kept) && near(kept[COL], dragged, 3), { kept, store, wire: res.prefs_wire.slice() })
  await p.screenshot({ path: `${OUT}/col-dragged.png` })

  /* a reload, then another device (a fresh profile) */
  await openSheet(p)
  const reloaded = await thWidth(p)
  step('a reload opens with the stored width', near(reloaded, dragged, 3), { reloaded, dragged })
  const ctx2 = await browser.createBrowserContext()
  const p2 = await signIn(browser, ctx2)
  await openSheet(p2)
  /* the first paint may be the automatic width until the session probe
     answers (the claim then applies); recorded, the step waits up to 5 s */
  const first = await thWidth(p2)
  const other = await until(async () => { const w = await thWidth(p2); return near(w, dragged, 3) ? w : null }, 5000) || await thWidth(p2)
  const seen = await p2.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    return { state: s.state, claim: JSON.parse(JSON.stringify(s.claims?.issues_columns ?? null)), style: document.querySelector('[data-test=issues-table]')?.getAttribute('style') || '' }
  })
  step('a second browser profile (another device) opens with the same width - per person, not per browser', near(other, dragged, 3), { first, other, dragged, seen })
  await p2.screenshot({ path: `${OUT}/col-other-device.png` })
  await ctx2.close()

  /* the same width in By status (every group shares the one table) */
  await putPref(p, { issues_view: 'status' })
  await openSheet(p)
  const grouped = await thWidth(p)
  step('By status shows the same width', near(grouped, dragged, 3), { grouped })
  await putPref(p, { issues_view: 'list' })
  await openSheet(p)

  /* a sort click still sorts */
  await p.click(`.issues-names th[data-col="${COL}"] button`)
  const sorted = await until(async () => (new URL(p.url()).searchParams.get('sort') === COL ? true : null), 5000)
  step('a click on the Status header still sorts (?sort=status)', Boolean(sorted), { url: new URL(p.url()).search })

  /* a double-click fits the column to its content, and is stored */
  await p.click(GRIP, { count: 2 })
  await sleep(300)
  const fit = await thWidth(p)
  const fitKept = await until(async () => { const c = await hubClaims(p); return c.cols && c.cols[COL] && near(c.cols[COL], fit, 3) ? c.cols : null }, 8000)
  step('a double-click fits the column to its content (a new width, stored at the hub)', fit > 0 && !near(fit, dragged, 3) && Boolean(fitKept), { fit, dragged, fitKept })
  await p.screenshot({ path: `${OUT}/col-fit.png` })

  const noise = res.console.filter((c) => !/favicon|ResizeObserver loop|Failed to load resource/.test(c))
  step('no page errors', noise.length === 0, { noise: noise.slice(0, 5) })
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  /* put the person's widths and view back as found (null = never set) */
  if (page && original && !original.status_code) {
    res.restored = await putPref(page, { issues_columns: original.cols, issues_view: original.view }).catch((e) => String(e))
  }
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
console.log(`${res.steps.length - failed}/${res.steps.length} PASS; build ${res.build && res.build.commit}; hub ${res.hub && res.hub.commit}; restored ${res.restored}`)
process.exit(failed ? 1 : 0)
