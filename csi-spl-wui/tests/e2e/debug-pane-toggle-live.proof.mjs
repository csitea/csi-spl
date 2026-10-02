// CLE-34963 live: the "Debug pane" checkbox in Settings → Appearance shows
// the diagnostics panel at the bottom of the app and unticking hides it —
// both without a reload, and both surviving a reload (the hub stored it).
//
//   BASE=https://dev.<domain> AUTH_BASE=https://dev.api.<domain> \
//     EMAIL=<member> PW_FILE=<0600 file> [TENANT=t1] OUT=<dir> \
//     node tests/e2e/debug-pane-toggle-live.proof.mjs
//
// CONTROL first: the same signed-in member with the box unticked has no
// [data-test="debug-panel"] anywhere, so a panel that is always on (or a
// selector that matches nothing) cannot read green. The run ends unticked.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const EMAIL = need('EMAIL')
const AUTH_BASE = (process.env.AUTH_BASE || BASE).replace(/\/+$/, '')
const TENANT = process.env.TENANT || 't1'
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
const BOX = '[data-test=settings-debug-pane]'
const PANEL = '[data-test=debug-panel]'

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
try {
  const p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport({ width: 1280, height: 900 })
  const claim = async () => p.evaluate(async (base) => {
    const r = await fetch(base + '/api/v1/auth/session', { credentials: 'include', cache: 'no-store' })
    return r.status === 200 ? (await r.json()).diagnostics_enabled : `status ${r.status}`
  }, AUTH_BASE)
  const panelIn = async () => (await p.$(PANEL)) !== null
  const checked = async () => p.$eval(BOX, (el) => el.checked)
  const openSettings = async () => {
    await p.goto(`${BASE}/settings/appearance`, { waitUntil: 'networkidle2' })
    await p.waitForSelector(BOX, { timeout: 15000 })
    await sleep(800)
  }
  // Click, then wait for the save to settle (the box is disabled while saving).
  const click = async () => {
    await p.click(BOX)
    await p.waitForFunction((s) => !document.querySelector(s)?.disabled, { timeout: 10000 }, BOX)
    await sleep(600)
  }

  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2F`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  await sleep(4000)
  const c0 = await claim()
  step('signed in', typeof c0 === 'boolean', { diagnostics_enabled: c0 })

  await openSettings()
  if (await checked()) await click() // start from unticked
  // ── CONTROL: unticked = no panel, on settings and on the app root ──────
  await p.reload({ waitUntil: 'networkidle2' })
  await p.waitForSelector(BOX)
  await sleep(800)
  step('control: box unticked', (await checked()) === false)
  step('control: claim false', (await claim()) === false)
  step('control: no panel on /settings/appearance', !(await panelIn()))
  await p.goto(BASE + '/', { waitUntil: 'networkidle2' })
  await sleep(1500)
  step('control: no panel on /', !(await panelIn()))
  await p.screenshot({ path: `${OUT}/01-unticked-root.png` })

  // ── tick: the panel appears with NO reload ─────────────────────────────
  await openSettings()
  await click()
  step('tick: box checked', (await checked()) === true)
  step('tick: panel at once, no reload', await panelIn())
  const geo = await p.$eval(PANEL, (el) => {
    const r = el.getBoundingClientRect()
    return { top: Math.round(r.top), bottom: Math.round(r.bottom), vh: window.innerHeight }
  })
  step('tick: panel sits at the bottom of the viewport', geo.bottom >= geo.vh - 2 && geo.top > geo.vh / 2, geo)
  res.panel_text = (await p.$eval(PANEL, (el) => el.innerText)).replace(/\s+/g, ' ').trim().slice(0, 160)
  await p.screenshot({ path: `${OUT}/02-ticked-settings.png` })
  step('tick: hub stored it', (await claim()) === true)
  await p.goto(BASE + '/', { waitUntil: 'networkidle2' })
  await sleep(1500)
  step('tick: panel on / after a full load', await panelIn())
  await p.screenshot({ path: `${OUT}/03-ticked-root.png` })

  // ── untick: the panel disappears with NO reload ────────────────────────
  await openSettings()
  await click()
  step('untick: box unchecked', (await checked()) === false)
  step('untick: panel gone at once, no reload', !(await panelIn()))
  step('untick: hub stored it', (await claim()) === false)
  await p.goto(BASE + '/', { waitUntil: 'networkidle2' })
  await sleep(1500)
  step('untick: no panel on / after a full load', !(await panelIn()))
  await p.screenshot({ path: `${OUT}/04-unticked-root.png` })
} catch (e) {
  step('ran to completion', false, { error: String(e && e.message || e) })
} finally {
  await browser.close()
  res.failed = failed
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAILED ${failed}` : 'OK all assertions')
  process.exit(failed ? 1 : 0)
}
