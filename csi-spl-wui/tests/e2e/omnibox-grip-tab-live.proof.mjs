// SPL-14 — live proof that the omnibox drag handle is not a keyboard tab stop.
//
// Signed in, from the start of the page, Tab walks through the top bar.
// document.activeElement must never be [data-test=omnibox-resize]. The same
// walk must land on Attach and on Send (those stay in the cycle).
//
//   BASE=https://<wui-host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/omnibox-grip-tab-live.proof.mjs
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
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const need = (k) => {
  if (!process.env[k]) {
    console.error(`FATAL ${k} must be set`)
    process.exit(2)
  }
  return process.env[k]
}
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok: !!ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function goto(p, url) {
  let last
  for (let i = 0; i < 3; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 45000 })
      return
    } catch (e) {
      last = e
      await sleep(1500)
    }
  }
  throw last
}

function describeFocus() {
  const el = document.activeElement
  if (!el || el === document.body || el === document.documentElement) return null
  return {
    test: el.getAttribute('data-test'),
    testid: el.getAttribute('data-testid'),
    tag: el.tagName,
    inTop: !!el.closest('[data-test="top-bar"]'),
  }
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 90000,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })

  await goto(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 20000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signedIn = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('signed in', signedIn, { url: p.url().replace(BASE, '') })
  if (!signedIn) throw new Error('not signed in')

  await p.waitForSelector('[data-test=top-bar]', { timeout: 20000 })
  await p.waitForSelector('[data-test=omnibox-resize]', { timeout: 20000 })
  await p.waitForSelector('[data-testid=attach]', { timeout: 20000 })
  await p.waitForSelector('[data-testid=send]', { timeout: 20000 })
  const present = await p.evaluate(() => ({
    grip: !!document.querySelector('[data-test=omnibox-resize]'),
    attach: !!document.querySelector('[data-testid=attach]'),
    send: !!document.querySelector('[data-testid=send]'),
  }))
  step('grip, Attach and Send are in the top bar', present.grip && present.attach && present.send, present)

  // Start before the first control, then Tab through the top bar.
  await p.evaluate(() => {
    const el = document.activeElement
    if (el && el !== document.body) el.blur()
  })
  const seen = []
  let entered = false
  for (let i = 0; i < 80; i++) {
    await p.keyboard.press('Tab')
    const id = await p.evaluate(describeFocus)
    if (!id) continue
    seen.push(id)
    if (id.inTop) entered = true
    if (entered && !id.inTop) break
  }
  const gripHits = seen.filter((s) => s.test === 'omnibox-resize')
  const sawAttach = seen.some((s) => s.testid === 'attach')
  const sawSend = seen.some((s) => s.testid === 'send')
  const trail = seen.map((s) => s.testid || s.test || s.tag).join(' > ')
  step('Tab never lands on the grip', entered && gripHits.length === 0, { n: seen.length, gripHits: gripHits.length, trail })
  step('the same walk lands on Attach and Send', sawAttach && sawSend, { sawAttach, sawSend, trail })
  await p.screenshot({ path: `${OUT}/after-tab.png` }).catch(() => {})
  res.trail = trail
} catch (e) {
  step('proof threw', false, { err: String(e && e.stack || e).slice(0, 800) })
} finally {
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
if (failed) {
  console.error(`FAIL ${failed} step(s)`)
  process.exit(1)
}
console.log('PASS omnibox grip tab')
