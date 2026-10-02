// SPL-980 — live proof, signed in: 2px of the tenant switcher's
// white box before and after the tenant name, closed box and open list.
// Read-only: nothing is switched or written.
//
// Owner, 2026-09-26: "there should be 2px in front and after the text of the
// tenants switcher dropbox in the white background of the texts".
//
// Light theme, the select focused (as in the owner's screenshot). Measured
// (n = 1 per run): the select's inline padding, the gap from the select's
// edges to the name, the name-to-arrow gap, each option's inline padding, and
// a 3x screenshot of the switcher. With EXPECT_PAD=1 it asserts 2px each side
// and the arrow still 3px after the name. The native open list is not drawn
// by headless Chrome, so the option rows are proven by their computed padding.
//
//   BASE=https://<tenant>.<domain> API=https://api.<domain> EMAIL=<member>
//     PW_FILE=<0600 file> OUT=<dir> TENANT=<tenant> [EXPECT_PAD=1]
//     node tests/e2e/tenant-pad-live.proof.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

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

const EXPECT_PAD = process.env.EXPECT_PAD === '1'
const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
try {
  const p = await signIn(browser)
  await p.setViewport({ width: 1440, height: 900, deviceScaleFactor: 3 })
  await p.evaluate(() => { try { localStorage.setItem('spool-theme', 'light') } catch { /* private */ } })
  await nav(p, BASE + '/issues')
  await p.waitForSelector('[data-testid=tenant-switcher-select]', { visible: true, timeout: 30000 })
  await p.evaluate(() => document.documentElement.setAttribute('data-theme', 'light'))
  await sleep(1500)
  await p.focus('[data-testid=tenant-switcher-select]')
  await sleep(300)
  const m = await p.evaluate(() => {
    const sel = document.querySelector('[data-testid=tenant-switcher-select]')
    const arrow = document.querySelector('[data-testid=tenant-switcher-arrow]')
    const cs = getComputedStyle(sel)
    const probe = document.createElement('span')
    probe.style.cssText = 'position:absolute;visibility:hidden;white-space:pre;padding:0;margin:0;border:0'
    probe.style.font = cs.font
    document.body.appendChild(probe)
    const widthOf = (text) => { probe.textContent = text; return probe.getBoundingClientRect().width }
    /* the select is as wide as its WIDEST name; the selected one may be shorter */
    const names = [...sel.options].map((o) => o.text)
    const textW = Math.max(0, ...names.map(widthOf))
    const selected = sel.options[sel.selectedIndex] ? sel.options[sel.selectedIndex].text : ''
    probe.remove()
    const r = sel.getBoundingClientRect()
    const a = arrow.getBoundingClientRect()
    const padL = parseFloat(cs.paddingLeft); const padR = parseFloat(cs.paddingRight)
    const nameEnd = r.left + padL + textW
    const opts = [...sel.options].map((o) => { const oc = getComputedStyle(o); return [parseFloat(oc.paddingLeft), parseFloat(oc.paddingRight)] })
    return { theme: document.documentElement.getAttribute('data-theme'), name: selected, names, bg: cs.backgroundColor,
      fieldBg: getComputedStyle(sel.parentElement).backgroundColor,
      selectW: Math.round(r.width * 100) / 100, textW: Math.round(textW * 100) / 100, padL, padR,
      beforeName: padL, afterName: Math.round((r.right - nameEnd) * 100) / 100, nameToArrow: Math.round((a.left - nameEnd) * 100) / 100,
      options: opts.length, optionPads: [...new Set(opts.map((x) => x.join('/')))] }
  })
  step('0 measured (light theme, select focused)', true, m)
  const box = await p.$eval('[data-testid=tenant-switcher]', (el) => { const r = el.getBoundingClientRect(); return { x: r.left, y: r.top, width: r.width, height: r.height } })
  await p.screenshot({ path: `${OUT}/tenant-switcher.png`, clip: { x: Math.max(0, box.x - 8), y: Math.max(0, box.y - 6), width: box.width + 16, height: box.height + 12 } })
  if (EXPECT_PAD) {
    step('1 the closed box has 2px of its box before and after the (widest) name', m.padL === 2 && m.padR === 2 && Math.abs(m.afterName - 2) < 0.6, { padL: m.padL, padR: m.padR, beforeName: m.beforeName, afterName: m.afterName, widest: m.textW })
    /* Chrome draws the open list itself and takes the rows' inline padding
       from the SELECT (the options' own 2px UA padding was there before and
       the rows were flush), so the rows follow step 1's padding */
    step('2 the open list rows: the select carries 2px each side, and every option 2px', m.padL === 2 && m.padR === 2 && m.options > 0 && m.optionPads.length === 1 && m.optionPads[0] === '2/2', { options: m.options, pads: m.optionPads, selectPad: [m.padL, m.padR] })
    step('3 the arrow still sits 3px after the name', Math.abs(m.nameToArrow - 3) < 0.6, { nameToArrow: m.nameToArrow })
  }
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAILED ${failed}` : 'ALL PASS', `-> ${OUT}/result.json`)
  process.exit(failed ? 1 : 0)
}
