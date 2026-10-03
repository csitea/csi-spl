// Owner t1 topic b3bf3d13 (blocker d0139fd8, "It should show only machines")
// live proof, signed in: the Boxes rail lists machine boxes only — no row for
// the browser pseudo-box box-wui — and a direct link to /boxes/box-wui lands
// on the Boxes list. Read-only: it signs in, opens the Boxes tab, reads the
// rows and takes a screenshot. No message is sent.
//
//   BASE=https://<wui host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//   [TENANT=t1] [EXPECT_COMMIT=<sha prefix>] node tests/e2e/boxes-machines-only-live.proof.mjs
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
    await p.waitForSelector('[data-testid=sidebar-tab-boxes]', { timeout: 30000 })
    await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-boxes]').click())
    await p.waitForSelector('#sidebar-panel-boxes a.nav-item[data-key]', { timeout: 30000 }).catch(() => null)
    await new Promise((r) => setTimeout(r, 2500))
    const rows = await p.evaluate(() => [...document.querySelectorAll('#sidebar-panel-boxes a.nav-item[data-key]')]
      .map((a) => a.getAttribute('data-key')))
    const count = await p.evaluate(() => document.querySelector('[data-testid=boxes-count]')?.textContent.trim() || '')
    step('the Boxes rail lists at least one machine box (control)', rows.length > 0, { rows, count })
    step('no row for the browser box box-wui', !rows.includes('box-wui'), { rows })
    step('the count matches the rows', count.startsWith(String(rows.length)), { count, rows: rows.length })
    await p.screenshot({ path: `${OUT}/boxes-machines-only.png` })
    await p.goto(`${BASE}/boxes/box-wui`, { waitUntil: 'networkidle2' })
    await new Promise((r) => setTimeout(r, 2500))
    const path = new URL(p.url()).pathname
    const card = await p.$('[data-test=box-card]')
    step('/boxes/box-wui lands on the Boxes list, no card', /\/boxes\/?$/.test(path) && !card, { url: p.url() })
  }
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/boxes-machines-only-live.json`, JSON.stringify(res, null, 2))
const failed = res.steps.filter((s) => !s.ok)
console.log(`\nboxes-machines-only-live: ${res.steps.length - failed.length}/${res.steps.length} passed`)
process.exit(failed.length ? 1 : 0)
