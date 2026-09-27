// Live proof of the palette theme picker on a deployed WUI.
// Signs in, opens the palette, selects each of the five themes, and checks
// html[data-theme] plus the computed body background against that theme's
// --color-bg (THEMES[].swatch[0]). One screenshot per theme.
//
//   BASE=https://<wui-host> EMAIL=m3-e2e-human@example.com \
//     PW_FILE=<0600 file> OUT=<dir> [TENANT=t1] [CHROME_PATH=...] \
//     node tests/e2e/theme-picker-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { THEMES } from '../../src/utils/theme.mjs'

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

function hexRgb(hex) {
  const n = String(hex).replace('#', '')
  const r = parseInt(n.slice(0, 2), 16)
  const g = parseInt(n.slice(2, 4), 16)
  const b = parseInt(n.slice(4, 6), 16)
  return `rgb(${r}, ${g}, ${b})`
}

function normColor(c) {
  const m = String(c).match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/)
  return m ? `rgb(${m[1]}, ${m[2]}, ${m[3]})` : String(c)
}

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = process.env.EMAIL || readFileSync(need('EMAIL_FILE'), 'utf8').trim()
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const EXPECT = THEMES.map((t) => ({ id: t.id, bg: hexRgb(t.swatch[0]) }))
const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, themes: [], steps: [] }
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

function readTheme() {
  const brand = document.querySelector('.top-bar__brand')
  const tenant = document.querySelector('[data-testid=tenant-switcher]')
  const btn = document.querySelector('[data-test=theme-picker]')
  const list = document.querySelector('[data-test=theme-picker-list]')
  let stored = null
  try { stored = localStorage.getItem('spool-theme') } catch { stored = 'ERR' }
  const bg = getComputedStyle(document.body).backgroundColor
  const listBox = list ? list.getBoundingClientRect() : null
  return {
    theme: document.documentElement.getAttribute('data-theme'),
    stored,
    bg,
    brand: brand ? brand.textContent.trim() : '',
    tenantBeforePicker: !!(tenant && btn && tenant.getBoundingClientRect().right <= btn.getBoundingClientRect().left + 1),
    expanded: btn ? btn.getAttribute('aria-expanded') : null,
    label: btn ? btn.getAttribute('aria-label') : null,
    popup: btn ? btn.getAttribute('aria-haspopup') : null,
    listVisible: !!(listBox && listBox.width > 0 && listBox.height > 0),
    xscroll: document.documentElement.scrollWidth - document.documentElement.clientWidth,
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

  await p.waitForSelector('[data-test=theme-picker]', { timeout: 20000 })
  const opened = await p.evaluate(readTheme)
  step('no brand text, the tenant drop box before the palette button, and the button is closed', opened.brand === '' && opened.tenantBeforePicker && opened.expanded === 'false' && opened.popup === 'listbox' && opened.xscroll <= 0, opened)

  for (const theme of EXPECT) {
    await p.click('[data-test=theme-picker]')
    await p.waitForSelector(`[data-test="theme-option-${theme.id}"]`, { visible: true, timeout: 10000 })
    const menu = await p.evaluate(readTheme)
    step(`${theme.id} list is open`, menu.expanded === 'true' && menu.listVisible, { expanded: menu.expanded, listVisible: menu.listVisible })
    await p.click(`[data-test="theme-option-${theme.id}"]`)
    await p.waitForFunction(
      (id) => document.documentElement.getAttribute('data-theme') === id,
      { timeout: 5000 },
      theme.id,
    )
    await sleep(150)
    const got = await p.evaluate(readTheme)
    const bgOk = normColor(got.bg) === theme.bg
    const ok = got.theme === theme.id && got.stored === theme.id && bgOk && got.expanded === 'false' && got.xscroll <= 0
    const shot = `${OUT}/${theme.id}.png`
    await p.screenshot({ path: shot })
    step(`${theme.id} applied`, ok, {
      theme: got.theme,
      stored: got.stored,
      bg: normColor(got.bg),
      want: theme.bg,
      expanded: got.expanded,
      xscroll: got.xscroll,
      shot,
    })
    res.themes.push({ id: theme.id, shot, bg: normColor(got.bg) })
  }

  const last = EXPECT[EXPECT.length - 1]
  await p.reload({ waitUntil: 'domcontentloaded', timeout: 45000 })
  await p.waitForSelector('[data-test=theme-picker]', { timeout: 20000 })
  await sleep(200)
  const kept = await p.evaluate(readTheme)
  step('reload keeps the last theme', kept.theme === last.id && kept.stored === last.id && normColor(kept.bg) === last.bg, {
    theme: kept.theme, stored: kept.stored, bg: normColor(kept.bg),
  })
} catch (e) {
  step('proof threw', false, { err: String(e && e.stack || e).slice(0, 800) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed}` : 'PASS all', '->', `${OUT}/results.json`)
  process.exit(failed ? 1 : 0)
}
