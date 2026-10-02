// CLE-35066 live proof against a deployed WUI (owner, prd t1 topic 110d842c:
// "In issues on mobile, clicking on the omnibox, typing and clicking the GO
// button does not create a comment"). At a phone width (default 390):
//  A. ISSUE open (level 3): the dock says "Commenting on ISSUE"; a line typed
//     in the dock + GO appears as a comment in the issue's discussion and the
//     dock empties (ONE comment is posted on ISSUE in TENANT; the only write)
//  B. the issues list: the dock says it is search-only, GO with plain text
//     opens /search?q=<text>
// The comment's text is printed (res.note) so the DB row can be read after.
// Screenshots and results.json to OUT.
//
//   BASE=https://<tenant>.<domain> TENANT=<tenant> [ISSUE=<key in TENANT>, default
//     the first card on the phone list]
//     EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> [WIDTH=390] [HEIGHT=844]
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/issue-dock-comment-live.proof.mjs
//
// Writes only when the session's tenant AND the page host's tenant are
// TENANT. The password is read from PW_FILE and never printed.
// Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
let ISSUE = process.env.ISSUE || ''
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const PHONE = { width: Number(process.env.WIDTH || 390), height: Number(process.env.HEIGHT || 844), isMobile: true, hasTouch: true }
const DOCK = 'form.composer.omnibox--global'
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
async function until(fn, ms) {
  const end = Date.now() + ms
  for (;;) {
    const v = await fn().catch(() => null)
    if (v || Date.now() > end) return v
    await sleep(400)
  }
}

const look = (p) => p.evaluate((dockSel) => {
  const dock = document.querySelector(dockSel)
  const hint = dock && dock.querySelector('[data-test=dock-target]')
  const vis = (el) => Boolean(el && el.getClientRects().length > 0)
  return {
    docked: Boolean(dock && dock.classList.contains('composer--dock')),
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
    mode: vis(hint) ? hint.getAttribute('data-mode') : '',
    hint: vis(hint) ? hint.textContent.trim() : '',
    field: dock ? (dock.querySelector('textarea')?.value || '') : null,
    path: location.pathname,
    q: new URLSearchParams(location.search).get('q') || '',
  }
}, DOCK)

async function typeAndGo(p, text) {
  await p.focus(`${DOCK} textarea`)
  await p.type(`${DOCK} textarea`, text)
  await p.click(`${DOCK} [data-testid=send], ${DOCK} [data-test=omnibox-search]`)
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok)
  if (!ok) throw new Error('not signed in')
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
  step('the session AND the page host are in TENANT', inTenant, { want: TENANT, ...where })
  if (!inTenant) throw new Error(`not in ${TENANT}: refusing to write`)

  // A. the issue open on a phone: GO comments on it
  await p.setViewport(PHONE)
  if (!ISSUE) {
    await p.goto(BASE + '/issues', { waitUntil: 'networkidle2', timeout: 60000 })
    ISSUE = await until(() => p.$eval('[data-test=issues-card]', (e) => e.getAttribute('data-key')), 20000) || ''
    if (!ISSUE) throw new Error('no issue on the list: set ISSUE')
  }
  res.issue = ISSUE
  await p.goto(BASE + `/issues?issue=${encodeURIComponent(ISSUE)}`, { waitUntil: 'networkidle2', timeout: 60000 })
  await until(async () => (await look(p)).mode === 'comment', 20000)
  const a = await look(p)
  await p.screenshot({ path: `${OUT}/issue-open-${PHONE.width}.png` })
  step(`A1 ${PHONE.width}px issue open: the dock says "Commenting on ${ISSUE}"`, a.docked && a.mode === 'comment' && a.hint.includes(ISSUE), a)
  const note = `CLE-35066 live proof: a comment from the phone dock GO (${new Date().toISOString()})`
  res.note = note
  await typeAndGo(p, note)
  const shown = await until(() => p.evaluate((t) => [...document.querySelectorAll('[data-test=issues-comment]')].some((c) => c.innerText.includes(t)), note), 20000)
  const a2 = await look(p)
  await p.screenshot({ path: `${OUT}/issue-commented-${PHONE.width}.png` })
  step(`A2 ${PHONE.width}px GO posts the line as a comment on ${ISSUE}`, Boolean(shown), a2)
  step(`A3 ${PHONE.width}px the dock empties and the page stays on the issue`, a2.field === '' && a2.path.endsWith('/issues'), a2)

  // B. the list: search-only, GO searches
  await p.goto(BASE + '/issues', { waitUntil: 'networkidle2', timeout: 60000 })
  await until(async () => (await look(p)).mode === 'search', 20000)
  const b = await look(p)
  await p.screenshot({ path: `${OUT}/issues-list-${PHONE.width}.png` })
  step(`B1 ${PHONE.width}px list: the dock says it is search-only`, b.docked && b.mode === 'search', b)
  const q = 'cle35066proof'
  await typeAndGo(p, q)
  await until(() => p.evaluate(() => location.pathname.endsWith('/search')), 15000)
  const b2 = await look(p)
  step(`B2 ${PHONE.width}px list: GO with plain text opens /search?q=<text>`, b2.path.endsWith('/search') && b2.q === q, b2)
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
const failed = res.steps.filter((s) => !s.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${res.steps.length}` : `${res.steps.length}/${res.steps.length} PASS`)
process.exit(failed.length ? 1 : 0)
