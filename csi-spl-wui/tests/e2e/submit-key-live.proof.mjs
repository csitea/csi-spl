// SPL-976 live: Settings -> Behaviour -> "Text fields" decides what Enter does
// in the composer, it is kept on the account (a reload and the session claim
// agree), and both modes send exactly on their own key.
//
//   BASE=https://dev.<domain> AUTH_BASE=https://dev.api.<domain> \
//     EMAIL=<member> PW_FILE=<0600 file> [TENANT=t1] OUT=<dir> \
//     node tests/e2e/submit-key-live.proof.mjs
//
// It WRITES two lobby lines, so run it only as the dev test member (t1) or
// the prd e2e tenant. Each mode has its control: the key that must NOT send
// is pressed first and the box must still hold the text with a new line.
// The run puts the account's value back as it found it.
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const BOX = 'form.omnibox--global textarea'
const stamp = new Date().toISOString().replace(/[-:]/g, '').slice(0, 15)

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let original
let p
try {
  p = await (await browser.createBrowserContext()).newPage()
  await p.setViewport({ width: 1280, height: 900 })
  const claim = async () => p.evaluate(async (base) => {
    const r = await fetch(base + '/api/v1/auth/session', { credentials: 'include', cache: 'no-store' })
    return r.status === 200 ? (await r.json()).submit_key : `status ${r.status}`
  }, AUTH_BASE)
  const checkedMode = async () => p.evaluate(() => document.querySelector('[data-test=submit-key-setting] input:checked')?.value || '')
  const pick = async (mode) => {
    await p.goto(`${BASE}/settings/behaviour`, { waitUntil: 'networkidle2' })
    const sel = `[data-test=submit-key-${mode}]`
    await p.waitForSelector(sel, { timeout: 15000 })
    await sleep(600)
    /* a radio that is already checked fires no change: a never-picked account
       shows the default checked, so step through the other mode first and
       every "stored" check below is a real write */
    if (await checkedMode() === mode) {
      const other = `[data-test=submit-key-${mode === 'enter' ? 'ctrl-enter' : 'enter'}]`
      await p.click(other)
      await p.waitForFunction((s) => !document.querySelector(s)?.disabled, { timeout: 10000 }, other)
      await sleep(600)
    }
    await p.click(sel)
    await p.waitForFunction((s) => !document.querySelector(s)?.disabled, { timeout: 10000 }, sel)
    await sleep(600)
  }
  const boxValue = async () => p.$eval(BOX, (el) => el.value)
  const lobby = async () => {
    await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
    await p.waitForSelector(BOX, { timeout: 15000 })
    await sleep(1500)
    await p.click(BOX)
  }
  const landed = async (text) => p.waitForFunction(
    (t) => [...document.querySelectorAll('main, [data-test], article')].some((el) => (el.innerText || '').includes(t)),
    { timeout: 20000 }, text,
  ).then(() => true).catch(() => false)

  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=%2F`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', EMAIL)
  await p.type('[data-test=native-auth-password]', PW)
  await p.click('[data-test=native-auth-submit]')
  await sleep(4000)
  original = await claim()
  step('signed in; the session answers submit_key', original === null || original === 'enter' || original === 'ctrl-enter', { submit_key: original })

  // ── mode ctrl-enter ───────────────────────────────────────────────────
  await pick('ctrl-enter')
  step('ctrl-enter: stored on the account', (await claim()) === 'ctrl-enter')
  await p.reload({ waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=submit-key-setting]')
  await sleep(600)
  step('ctrl-enter: the radio is checked after a reload', (await checkedMode()) === 'ctrl-enter')
  await p.screenshot({ path: `${OUT}/01-settings-ctrl-enter.png` })
  await lobby()
  const ph1 = await p.$eval(BOX, (el) => el.placeholder)
  step('ctrl-enter: the placeholder names Ctrl+Enter', /Ctrl\+Enter/.test(ph1), { placeholder: ph1 })
  const t1 = `SPL-976 proof ctrl-enter ${stamp}`
  await p.keyboard.type(t1)
  await p.keyboard.press('Enter')
  await sleep(700)
  const v1 = await boxValue()
  step('ctrl-enter CONTROL: a bare Enter adds a line and sends nothing', v1 === t1 + '\n', { value: v1 })
  await p.keyboard.type('second line')
  await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
  const sent1 = await landed(t1)
  const v1b = await boxValue()
  step('ctrl-enter: Ctrl+Enter sends (the box empties, the line is in the lobby)', sent1 && v1b === '', { value: v1b, sent: sent1 })
  await p.screenshot({ path: `${OUT}/02-lobby-ctrl-enter-sent.png` })

  // ── mode enter ────────────────────────────────────────────────────────
  await pick('enter')
  step('enter: stored on the account', (await claim()) === 'enter')
  await p.reload({ waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=submit-key-setting]')
  await sleep(600)
  step('enter: the radio is checked after a reload', (await checkedMode()) === 'enter')
  await p.screenshot({ path: `${OUT}/03-settings-enter.png` })
  await lobby()
  const ph2 = await p.$eval(BOX, (el) => el.placeholder)
  step('enter: the placeholder says Enter sends', /Enter sends/.test(ph2) && !/Ctrl\+Enter/.test(ph2), { placeholder: ph2 })
  const t2 = `SPL-976 proof enter ${stamp}`
  await p.keyboard.type(t2)
  await p.keyboard.down('Shift'); await p.keyboard.press('Enter'); await p.keyboard.up('Shift')
  await sleep(700)
  const v2 = await boxValue()
  step('enter CONTROL: Shift+Enter adds a line and sends nothing', v2 === t2 + '\n', { value: v2 })
  await p.keyboard.type('second line')
  await p.keyboard.press('Enter')
  const sent2 = await landed(t2)
  const v2b = await boxValue()
  step('enter: a bare Enter sends (the box empties, the line is in the lobby)', sent2 && v2b === '', { value: v2b, sent: sent2 })
  await p.screenshot({ path: `${OUT}/04-lobby-enter-sent.png` })
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e) })
} finally {
  if (p && (original === null || original === 'enter' || original === 'ctrl-enter')) {
    try {
      const st = await p.evaluate(async (base, v) => (await fetch(base + '/api/v1/auth/preferences', {
        method: 'PUT', credentials: 'include', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ submit_key: v }),
      })).status, AUTH_BASE, original)
      res.restored = { to: original, status: st }
    } catch (e) { res.restored = { error: String(e) } }
  }
  await browser.close()
  res.failed = failed
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed} step(s)` : 'ALL PASS', `-> ${OUT}/result.json`)
  process.exit(failed ? 1 : 0)
}
