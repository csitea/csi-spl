// SPL-990 live proof: the phone top bar on a deployed WUI (READ-ONLY - it
// opens the search sheet and the avatar sheet and closes them; it never
// sends, saves a preference, or changes a tenant).
//
//   BASE=https://e2e.spool-hub.ai TENANT=e2e EMAIL=<member> PW_FILE=<0600 file> \
//   OUT=<dir> node tests/e2e/top-bar-mobile-live.proof.mjs
//
// One native sign-in (the login budget is 10 per email per 15 min), then at
// 390 and 820 px with touch emulated: the one-row bar, the full-screen search
// sheet, the avatar bottom sheet (language, theme, notifications); and the
// 1440 px desktop bar. Screenshots land in OUT. The password is read from
// PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`${k} is required`); process.exit(2) } return v }
const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const OUT = need('OUT')
mkdirSync(OUT, { recursive: true })

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

const steps = []
function step(name, ok, ev) {
  steps.push({ name, ok })
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const rect = (p, s) => p.evaluate((s) => {
  const el = document.querySelector(s)
  if (!el) return null
  const r = el.getBoundingClientRect()
  const cs = getComputedStyle(el)
  return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), b: Math.round(r.bottom), shown: cs.display !== 'none' && r.width > 0 && r.height > 0 }
}, s)
const xscroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth - window.innerWidth)

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--hide-scrollbars'] })
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=${encodeURIComponent('/lobby')}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url().replace(/\?.*/, '') })
  if (!trig) throw new Error('sign-in failed (a 429 means the login budget, not the build)')
  const claimT = await p.evaluate(() => document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')?.claims?.t || '')
  step(`session tenant is ${TENANT}`, claimT === TENANT, { claimT })
  if (claimT !== TENANT) throw new Error('refusing to go on outside the proof tenant')

  for (const w of [390, 820]) {
    await p.setViewport({ width: w, height: 844, isMobile: true, hasTouch: true })
    await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 20000 })
    await sleep(2000)
    const bar = await rect(p, '[data-test=top-bar]')
    const tenant = await rect(p, '[data-test=top-bar-tenant]')
    const search = await rect(p, '[data-test=top-bar-search-toggle]')
    const avatar = await rect(p, '[data-test=user-menu-trigger]')
    const lang = await rect(p, '[data-test=top-bar] [data-test=lang-switcher]')
    step(`${w}: one row - tenant | search | avatar, 44 px targets`, bar.h <= 90 && tenant?.shown && search?.shown && search.w >= 44 && search.h >= 44 && avatar.w >= 44 && avatar.h >= 44 && !lang?.shown,
      { bar, tenant, search, avatar, langInRow: !!lang?.shown })
    step(`${w}: no horizontal scroll`, (await xscroll(p)) <= 0)
    await p.screenshot({ path: `${OUT}/top-bar-${w}-row.png` })

    await p.click('[data-test=top-bar-search-toggle]')
    await sleep(600)
    const sheet = await rect(p, '[data-test=top-bar-omnibox]')
    const go = await rect(p, '[data-test=top-bar-omnibox] .composer-go')
    step(`${w}: search sheet is full screen with GO on screen`, sheet?.x === 0 && sheet.y === 0 && sheet.w === w && sheet.h === 844 && go?.shown && go.b <= 844, { sheet, go })
    await p.screenshot({ path: `${OUT}/top-bar-${w}-search.png` })
    await p.click('[data-test=top-bar-search-close]')
    await sleep(300)

    await p.click('[data-test=user-menu-trigger]')
    await p.waitForSelector('[data-test=user-menu-prefs] [data-test=lang-switcher]', { timeout: 10000 }).catch(() => {})
    await sleep(800)
    const panel = await rect(p, '[data-test=user-menu-panel]')
    const rows = {}
    for (const k of ['language', 'theme', 'notify', 'settings', 'signout']) rows[k] = await rect(p, `[data-test=user-menu-${k}]`)
    step(`${w}: avatar menu is a bottom sheet with language, theme, notifications`, panel?.x === 0 && panel.w === w && panel.b === 844
      && Object.values(rows).every((r) => r?.shown && r.h >= 44), { panel, rows })
    await p.screenshot({ path: `${OUT}/top-bar-${w}-menu.png` })
    await p.keyboard.press('Escape')
    await sleep(300)
  }

  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  await p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
  if (!(await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 20000 }).catch(() => null))) {
    await p.screenshot({ path: `${OUT}/top-bar-1440-FAIL.png` })
    throw new Error(`1440: no avatar at ${p.url().replace(/\?.*/, '')}`)
  }
  await sleep(2000)
  const omni = await rect(p, '[data-test=top-bar-omnibox] textarea')
  const toggle = await rect(p, '[data-test=top-bar-search-toggle]')
  const tenant = await rect(p, '[data-test=top-bar-tenant]')
  const bar = await rect(p, '[data-test=top-bar]')
  step('1440: desktop bar - omnibox in the row, no search icon, no tenant label, 58 px', omni?.shown && !toggle?.shown && !tenant?.shown && bar.h === 58, { omni, toggle, tenant, bar })
  await p.screenshot({ path: `${OUT}/top-bar-1440.png` })
} catch (e) {
  step('run', false, { error: String(e.message || e) })
} finally {
  await browser.close()
}
const failed = steps.filter((s) => !s.ok).length
console.log(`top-bar-mobile-live: ${steps.length - failed}/${steps.length} PASS`)
process.exit(failed ? 1 : 0)
