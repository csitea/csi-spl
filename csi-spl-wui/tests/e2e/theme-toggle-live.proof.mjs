// GRK-3374 live proof of the icon-only theme toggle on a served WUI
// (deployed dev, or a local nuxi / generated bundle):
// dark shows a sun, light shows a half-moon, click flips, reload keeps it,
// 390px the icon stays visible next to the brand, no x-scroll.
//
//   BASE=https://dev.<domain> OUT=/var/tmp/GRK-3374-proof \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/theme-toggle-live.proof.mjs
import { createRequire } from 'node:module'
import { writeFileSync, mkdirSync } from 'node:fs'
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
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function snapshot() {
  const btn = document.querySelector('[data-test=theme-toggle]')
  const brand = document.querySelector('.top-bar__brand')
  const icon = btn?.querySelector('[data-icon]')
  const br = brand?.getBoundingClientRect()
  const tr = btn?.getBoundingClientRect()
  let stored = null
  try { stored = localStorage.getItem('spool-theme') } catch { /* private */ }
  return {
    theme: document.documentElement.getAttribute('data-theme'),
    label: btn?.getAttribute('aria-label') || '',
    title: btn?.getAttribute('title') || '',
    pressed: btn?.getAttribute('aria-pressed') || '',
    icon: icon?.getAttribute('data-icon') || '',
    stored,
    visible: !!(btn && tr && tr.width > 0 && tr.height >= 32),
    hit: tr ? { w: Math.round(tr.width), h: Math.round(tr.height), x: Math.round(tr.x), y: Math.round(tr.y) } : null,
    brand: br ? { w: Math.round(br.width), h: Math.round(br.height), x: Math.round(br.x), y: Math.round(br.y) } : null,
    rightOfBrand: !!(br && tr && tr.x >= br.x + br.width - 2 && Math.abs((tr.y + tr.height / 2) - (br.y + br.height / 2)) < 24),
    xscroll: document.documentElement.scrollWidth - document.documentElement.clientWidth,
  }
}

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let failed = 0
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()

  async function gotoLobby() {
    await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=theme-toggle]', { timeout: 20000 })
    await sleep(200)
  }

  // desktop: default dark → sun, click → light/moon, reload keeps light, click back
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  await p.evaluate(() => { try { localStorage.removeItem('spool-theme') } catch { /* */ } })
  await gotoLobby()
  let s = await p.evaluate(snapshot)
  const darkOk = s.theme === 'dark' && s.icon === 'sun' && s.pressed === 'true' && s.visible && s.rightOfBrand && s.xscroll <= 0 && /light/i.test(s.label)
  step('desktop dark: sun icon right of brand, Switch to light theme', darkOk, s)
  await p.screenshot({ path: `${OUT}/desktop-dark.png` })

  await p.click('[data-test=theme-toggle]')
  await sleep(150)
  s = await p.evaluate(snapshot)
  const lightOk = s.theme === 'light' && s.icon === 'moon' && s.pressed === 'false' && s.stored === 'light' && /dark/i.test(s.label)
  step('desktop click: light theme, half-moon, persisted', lightOk, s)
  await p.screenshot({ path: `${OUT}/desktop-light.png` })

  await p.reload({ waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=theme-toggle]', { timeout: 20000 })
  await sleep(200)
  s = await p.evaluate(snapshot)
  step('desktop reload keeps light + moon', s.theme === 'light' && s.icon === 'moon' && s.stored === 'light', s)

  await p.click('[data-test=theme-toggle]')
  await sleep(150)
  s = await p.evaluate(snapshot)
  step('desktop click back to dark + sun', s.theme === 'dark' && s.icon === 'sun' && s.stored === 'dark', s)

  // mobile 390: icon stays visible next to the brand
  await p.setViewport({ width: 390, height: 844 })
  await gotoLobby()
  s = await p.evaluate(snapshot)
  const mobOk = s.visible && s.rightOfBrand && s.hit && s.hit.w >= 32 && s.hit.h >= 32 && s.xscroll <= 0 && (s.icon === 'sun' || s.icon === 'moon')
  step('mobile 390: toggle visible next to brand, no x-scroll', mobOk, s)
  await p.screenshot({ path: `${OUT}/mobile-390.png` })

  await p.click('[data-test=theme-toggle]')
  await sleep(150)
  const after = await p.evaluate(snapshot)
  step('mobile 390 click flips theme and icon', after.theme !== s.theme && after.icon !== s.icon && after.visible && after.rightOfBrand && after.xscroll <= 0, { before: s, after })
  await p.screenshot({ path: `${OUT}/mobile-390-flipped.png` })
} catch (e) {
  step('proof threw', false, { err: String(e && e.stack || e) })
} finally {
  await browser.close()
  failed = res.steps.filter((s) => !s.ok).length
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed}` : 'PASS all', '->', `${OUT}/results.json`)
  process.exit(failed ? 1 : 0)
}
