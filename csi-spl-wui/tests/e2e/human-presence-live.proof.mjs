// a signed-in human must be listed, and lit, in the people pane.
//
// The owner signed in on the deployed dev WUI and the presence/roster pane
// listed no human at all. This proof measures the three layers that carry a
// human into that pane, against a LIVE deployment:
//
//   1. GET /v1/view/roster      — view-v1 §4.1 `humans`: the tenant's members
//   2. the WS presence snapshot — wui-live-ws §3.2 `HUM-n@box-wui` online
//   3. the rendered sidebar     — one row per peer, `.dot.on` when online
//
// Every selector it keys on exists in builds BEFORE the fix too
// (`.sidebar .nav-item[data-key]`, `.dot`), so the run goes red on a broken
// deploy instead of skipping the assertion.
//
//   BASE=https://dev.<fqdn> EMAIL=<member> PW_FILE=<0600 file> \
//     TENANT=t1 OUT=/var/tmp/CLE-3448-proof [LOCALE=he] \
//     [CHROME_PATH=/usr/bin/google-chrome] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/human-presence-live.proof.mjs
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

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
const EMAIL = need('EMAIL')
const PW = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
/*
 * LOCALE drives the run through one language's routes (spec 021,
 * prefix_except_default: the default locale has NO prefix, every other one
 * is `/<code>/...`). Empty = the default. The catalogue is read from disk so
 * the assertion compares the DEPLOYED bundle against what this tree ships,
 * rather than against a string written twice.
 */
const LOCALE = (process.env.LOCALE || '').trim()
const PREFIX = LOCALE ? `/${LOCALE}` : ''
const HERE = dirname(fileURLToPath(import.meta.url))
const catalogue = JSON.parse(readFileSync(join(HERE, `../../i18n/locales/${LOCALE || 'en'}.json`), 'utf8'))
const WANT_YOU = String(catalogue.sidebar.you || '')
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, tenant: TENANT, locale: LOCALE || '(default)', at: new Date().toISOString(), steps: [], ws: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let failed = 0
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 900 })

  /* Every hub->browser frame, read off the wire: the page holds the socket
     open, so `networkidle2` would never settle here. */
  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')
  cdp.on('Network.webSocketFrameReceived', (e) => {
    try { res.ws.push(JSON.parse(e.response.payloadData)) } catch { /* not JSON */ }
  })

  await p.goto(`${BASE}${PREFIX}/login?tenant=${encodeURIComponent(TENANT)}&redirect=${encodeURIComponent(`${PREFIX}/lobby`)}`, { waitUntil: 'domcontentloaded' })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 30000 })
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url().replace(/\?.*/, '') })
  if (!trig) throw new Error('not signed in (rate limit? read the /api/v1/auth/login response)')

  /* The shell hydrates the roster and the socket on session 'in'; give both a
     beat, then let one roster refresh land on top of the presence snapshot. */
  await p.waitForSelector('.sidebar .nav-item', { timeout: 20000 })
  await sleep(6000)

  const welcome = res.ws.find((f) => f && f.type === 'welcome')
  const meId = welcome && String(welcome.as || '')
  step('welcome names the signed-in member', /^HUM-\d+$/.test(meId || ''), { as: meId })

  const presence = res.ws.filter((f) => f && f.type === 'presence')
  const humansOnline = presence.filter((f) => /^HUM-\d+@box-wui$/.test(String(f.peer)) && f.status === 'online').map((f) => f.peer)
  step('hub pushes presence online for the signed-in human', humansOnline.includes(`${meId}@box-wui`),
    { humansOnline, n_presence: presence.length })

  const store = await p.evaluate(() => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const pinia = app?.config?.globalProperties?.$pinia
    const r = pinia?._s?.get('roster')
    if (!r) return null
    const val = (x) => JSON.parse(JSON.stringify(x?.value !== undefined ? x.value : x))
    return { roster: val(r.roster), online: val(r.online), me: val(r.me), peers: val(r.peers) }
  })
  res.store = store
  step('the roster store is reachable', !!store, {})

  const rows = await p.evaluate(() => [...document.querySelectorAll('.sidebar [data-key]')]
    .map((el) => ({ key: el.getAttribute('data-key'), lit: !!el.querySelector('.dot.on'), hasDot: !!el.querySelector('.dot') }))
    .filter((r) => String(r.key).includes('@')))
  res.rows = rows
  await p.screenshot({ path: `${OUT}/01-signed-in-sidebar.png` })

  const humanRows = rows.filter((r) => /^HUM-\d+@box-wui$/.test(String(r.key)))
  step('the people pane lists at least one human', humanRows.length > 0, { humanRows, n_rows: rows.length })

  const mine = rows.find((r) => r.key === `${meId}@box-wui`)
  step('the people pane lists the signed-in human', !!mine, { looked_for: `${meId}@box-wui`, keys: rows.map((r) => r.key) })
  step('the signed-in human is shown ONLINE', !!(mine && mine.lit), { row: mine || null })

  /*
   * The row has to SAY it is the reader's. A missing catalogue key does not
   * throw in vue-i18n - it renders the key path - so the failure this
   * catches is a live "sidebar.you" sitting in the sidebar, which no unit
   * test can see and which every build gate reads green.
   */
  const youText = await p.evaluate(() => {
    const el = document.querySelector('[data-testid=people-self] .self-row__you')
      || document.querySelector('[data-testid=people-self]')
    return el ? el.textContent.trim() : ''
  })
  step('the self row carries the localised "you" marker', Boolean(youText) && youText === WANT_YOU,
    { locale: LOCALE || '(default)', text: youText, want: WANT_YOU })

  /* Every member of the tenant belongs in the pane, online or not
     (view-v1 §4.1 `humans`), not only the ones holding a socket right now. */
  const members = store && store.roster ? (store.roster['box-wui'] || []) : []
  step('the roster store carries the tenant members', members.length > 0, { members })
} catch (e) {
  step('proof threw', false, { err: String((e && e.stack) || e) })
} finally {
  await browser.close().catch(() => {})
  failed = res.steps.filter((s) => !s.ok).length
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed} step(s)` : `PASS ${res.steps.length}/${res.steps.length}`)
  process.exit(failed ? 1 : 0)
}
