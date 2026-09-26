// SPL-977 (CLE-35015) — live proof, signed in: the omnibox's GO button and
// the top bar's height, on a deployed WUI. Read-only: nothing is sent.
//
// Owner, 2026-09-26: "change the Send button on the right of the omnibox to a
// 'play' icon button or some kind of item which shouts 'GO', and add the Go,
// Send tooltip on top of the button"; "also make the top bar 6 pixels wider,
// the Go button should be 6 pixels smaller than the Send button now".
//
// Always measured (n = 1 per run): the top bar's height, the send control's
// width / height / text / aria-label. With EXPECT_GO=1 it also asserts:
//   1. the top bar is TOP_BAR_H px (default 58)
//   2. the control is an icon (svg[data-icon=go]) with no text, aria-label
//      "Go / Send", GO_SIZE px square (default 42)
//   3. hover shows the "Go / Send" tooltip next to the control, inside the
//      window, on the top layer (the bar is the window's top edge: no room
//      above it, so it is drawn under the button, over the page)
//   4. aria-disabled while the omnibox is empty, enabled once it has text
//   5. "/search <word>" shows the same GO glyph and a click runs the search
//
//   BASE=https://<tenant>.<domain> API=https://api.<domain> EMAIL=<member>
//     PW_FILE=<0600 file> OUT=<dir> TENANT=<tenant> [EXPECT_GO=1]
//     node tests/e2e/go-button-live.proof.mjs
//
// The password is read from PW_FILE and never printed.
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
const run = Date.now().toString(36)
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

/** goto / reload that retries what the box's docker network churn killed. */
async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      if (url) await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      else await p.reload({ waitUntil: 'domcontentloaded', timeout: 60000 })
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

async function until(fn, ms = 15000) {
  const end = Date.now() + ms
  let v
  while (Date.now() < end) {
    v = await fn()
    if (v) return v
    await sleep(300)
  }
  return v
}

async function signIn(browser) {
  const p = await browser.newPage()
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
  /* Nothing is written unless BOTH the session's tenant (claim t) and the
     tenant the page writes to are TENANT. With tenant hosts on (SPL-959) the
     WUI writes to the page host's tenant (useSpoolApi hostTenant: the apex is
     t1) whatever the claim says: on 2026-09-26 this proof wrote SPL-967..970
     into prd t1 from the apex, one run with the claim reading e2e. On prd run
     it at https://<tenant>.<domain>. */
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

const EXPECT_GO = process.env.EXPECT_GO === '1'
const BAR_H = Number(process.env.TOP_BAR_H || 58)
const GO = Number(process.env.GO_SIZE || 42)
const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
const FIELD = '[data-test=top-bar-omnibox] textarea'
const measure = (p) => p.evaluate(() => {
  const bar = document.querySelector('[data-test=top-bar]').getBoundingClientRect()
  const b = document.querySelector('[data-test=top-bar-omnibox] [data-testid=send], [data-test=top-bar-omnibox] [data-test=omnibox-search]')
  if (!b) return { barH: Math.round(bar.height) }
  const r = b.getBoundingClientRect()
  return { barH: Math.round(bar.height * 10) / 10, w: Math.round(r.width * 10) / 10, h: Math.round(r.height * 10) / 10,
    text: [...b.childNodes].filter((c) => !(c.classList && c.classList.contains('composer-go__tip'))).map((c) => c.textContent).join('').trim(), aria: b.getAttribute('aria-label'), disabled: b.getAttribute('aria-disabled') || String(b.disabled),
    icon: b.querySelector('svg') ? b.querySelector('svg').getAttribute('data-icon') : '', test: b.getAttribute('data-testid') || b.getAttribute('data-test') }
})
async function typeInto(p, text) {
  await p.click(FIELD)
  await p.keyboard.down('Control'); await p.keyboard.press('KeyA'); await p.keyboard.up('Control')
  await p.keyboard.press('Backspace')
  if (text) await p.type(FIELD, text)
  await sleep(300)
}

try {
  const p = await signIn(browser)
  await nav(p, BASE + '/lobby')
  await p.waitForSelector('[data-test=top-bar-omnibox] [data-testid=send]', { visible: true, timeout: 30000 })
  await sleep(1500)
  const empty = await measure(p)
  step('0 measured (empty omnibox)', true, empty)
  await shot(p, '01-top-bar')
  if (EXPECT_GO) {
    step(`1 the top bar is ${BAR_H} px high`, Math.abs(empty.barH - BAR_H) < 0.6, { barH: empty.barH })
    step(`2 the control is the GO icon, no text, aria-label "Go / Send", ${GO} px square`,
      empty.icon === 'go' && empty.text === '' && empty.aria === 'Go / Send' && Math.abs(empty.w - GO) < 0.6 && Math.abs(empty.h - GO) < 0.6, empty)
    await p.hover('[data-test=top-bar-omnibox] [data-testid=send]')
    const tip = await until(() => p.evaluate(() => {
      const b = document.querySelector('[data-test=top-bar-omnibox] [data-testid=send]')
      const tt = document.querySelector('[data-test=go-tip]')
      if (!b || !tt || getComputedStyle(tt).visibility !== 'visible' || Number(getComputedStyle(tt).opacity) < 0.9) return null
      const br = b.getBoundingClientRect(); const tr = tt.getBoundingClientRect()
      return { text: tt.textContent.trim(), adjacent: tr.top >= br.bottom - 1 || tr.bottom <= br.top + 1, gap: Math.round(tr.top - br.bottom), btnTop: Math.round(br.top), inView: tr.top >= 0 && tr.left >= 0 && tr.right <= innerWidth && tr.bottom <= innerHeight, z: getComputedStyle(tt).zIndex }
    }), 5000)
    await shot(p, '02-go-tooltip')
    step('3 hover shows the "Go / Send" tooltip next to the control, inside the window, on the top layer', !!tip && tip.text === 'Go / Send' && tip.adjacent && tip.inView && Number(tip.z) >= 100, tip || {})
    await typeInto(p, `go proof ${run}`)
    const typed = await measure(p)
    step('4 disabled while the omnibox is empty, enabled with text', empty.disabled === 'true' && typed.disabled === 'false', { empty: empty.disabled, typed: typed.disabled })
    await typeInto(p, '/search proof')
    await p.waitForSelector('[data-test=top-bar-omnibox] [data-test=omnibox-search]', { visible: true, timeout: 5000 })
    const srch = await measure(p)
    const url0 = p.url()
    await p.click('[data-test=top-bar-omnibox] [data-test=omnibox-search]')
    const ran = await until(() => p.evaluate(() => /\/search/.test(location.pathname) || Boolean(document.querySelector('[data-test=search-results], [data-testid=search-results]'))), 10000)
    await shot(p, '03-search-ran')
    step('5 /search shows the same GO glyph, and a click runs the search', srch.icon === 'go' && srch.text === '' && srch.aria === 'Go / Send' && !!ran, { srch, ran: !!ran, from: url0, to: p.url() })
    await typeInto(p, '')
  }
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAILED ${failed}` : 'ALL PASS', `-> ${OUT}/result.json`)
  process.exit(failed ? 1 : 0)
}
