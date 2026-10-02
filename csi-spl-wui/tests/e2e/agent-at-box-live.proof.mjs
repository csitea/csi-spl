// specs/058 (CLE-77932) live proof, signed in: every agent id that two or more
// boxes of the tenant announce is listed in the DM rail once per box, each row
// showing <ID>@<box> (and the same on hover). Read-only: it signs in, opens the
// DM tab, reads the rows and takes a screenshot. No message is sent.
//
//   BASE=https://<wui host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//   [TENANT=t1] [EXPECT_COMMIT=<sha prefix>] node tests/e2e/agent-at-box-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}
const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const EXPECT = process.env.EXPECT_COMMIT || ''
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  const build = await (await fetch(BASE + '/build.json', { cache: 'no-store' })).json()
  res.build = build
  step('build.json serves the expected commit', !EXPECT || String(build.commit || '').startsWith(EXPECT), { commit: build.commit, version: build.version })
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=${encodeURIComponent('/')}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('signed in', Boolean(trig), { url: p.url() })
  if (trig) {
    await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: 30000 })
    await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-dm]').click())
    await p.waitForSelector('#sidebar-panel-dm a.nav-item[data-key]', { timeout: 30000 }).catch(() => null)
    await new Promise((r) => setTimeout(r, 2500))
    const rows = await p.evaluate(() => [...document.querySelectorAll('#sidebar-panel-dm a.nav-item[data-key]')]
      .map((a) => ({ key: a.getAttribute('data-key'), text: a.querySelector('.label')?.textContent.trim() || '', tip: a.querySelector('.human-name')?.getAttribute('title') || '' })))
    const agents = rows.filter((r) => /^[A-Z]{2,4}-\d+@/.test(r.key) && !/^(HUM|GST)-/.test(r.key))
    const byId = {}
    for (const r of agents) (byId[r.key.split('@')[0]] ||= []).push(r)
    const shared = Object.fromEntries(Object.entries(byId).filter(([, v]) => v.length > 1))
    step('an id announced by two or more boxes is one row per box', Object.keys(shared).length > 0,
      { shared: Object.fromEntries(Object.entries(shared).map(([k, v]) => [k, v.map((r) => r.key)])) })
    step('every agent row shows <ID>@<box>, also on hover', agents.length > 0 && agents.every((r) => r.text === r.key && r.tip === r.key),
      { mismatched: agents.filter((r) => r.text !== r.key || r.tip !== r.key) })
    await p.screenshot({ path: `${OUT}/agent-at-box-dm-list.png` })
  }
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/agent-at-box-live.json`, JSON.stringify(res, null, 2))
const failed = res.steps.filter((s) => !s.ok)
console.log(`\nagent-at-box-live: ${res.steps.length - failed.length}/${res.steps.length} passed`)
process.exit(failed.length ? 1 : 0)
