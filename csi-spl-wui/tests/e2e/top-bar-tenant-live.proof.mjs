// SPL-995 live proof: the tenant switcher in the phone top bar on a deployed
// WUI. One native sign-in (the login budget is 10 per email per 15 min), then
// at 390 and 820 px with touch emulated: the drop box sits in the bar right
// before the search icon (>= 44 px), the level-1 strip does not show it (not
// twice), and a press opens the bottom sheet listing the account's tenants.
// At 1440 px the sidebar's drop box is the switcher and the bar has none.
//
// Read-only unless SWITCH_TO names a second tenant of the account: then the
// sheet switches to it, the proof checks the new session tenant, and switches
// back the same way. On a prd host both tenants must be test tenants
// (^e2e(-.+)?$); a dev host (dev.*) is the test estate, where t1 is allowed.
//
//   BASE=https://e2e.<domain> TENANT=e2e EMAIL=<member> PW_FILE=<0600 file> \
//   OUT=<dir> [SWITCH_TO=e2e-2] node tests/e2e/top-bar-tenant-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`${k} is required`); process.exit(2) } return v }
const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const OUT = need('OUT')
const SWITCH_TO = process.env.SWITCH_TO || ''
const DEV = /^https:\/\/dev\./.test(BASE)
const proofTenant = (t) => /^e2e(-.+)?$/.test(t) || (DEV && t === 't1')
if (!proofTenant(TENANT) || (SWITCH_TO && !proofTenant(SWITCH_TO))) {
  console.error('proof tenants only (^e2e(-.+)?$, or t1 on a dev host)')
  process.exit(2)
}
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
  return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height), r: Math.round(r.right), b: Math.round(r.bottom), shown: cs.display !== 'none' && r.width > 0 && r.height > 0 }
}, s)
const claims = (p) => p.evaluate(() => {
  const c = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')?.claims || {}
  return { t: c.t || '', tenants: (c.tenants || []).map((x) => x.tenant_id) }
})
const xscroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth - window.innerWidth)
async function nav(p, url) {
  for (let i = 0; i < 3; i++) {
    try { await p.goto(url, { waitUntil: 'networkidle2' }); return } catch (e) {
      if (i === 2 || !/ERR_NETWORK_CHANGED|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(1500)
    }
  }
}
async function switchVia(p, want) {
  await p.click('[data-testid=top-bar-tenant-box]')
  await p.waitForSelector(`[data-testid=top-bar-tenant-option][data-tenant="${want}"]`, { timeout: 10000 })
  await Promise.all([
    p.waitForNavigation({ waitUntil: 'networkidle2', timeout: 30000 }).catch(() => null),
    p.click(`[data-testid=top-bar-tenant-option][data-tenant="${want}"]`),
  ])
  await p.waitForSelector('[data-testid=top-bar-tenant-box]', { timeout: 30000 })
  await sleep(1500)
  /* SPL-959: with tenant hosts on, a tenant IS its host and the session
     claim keeps the sign-in tenant; without them the claim moves. Either way
     the switcher names the tenant it now shows. */
  const shown = await p.evaluate(async () => {
    document.querySelector('[data-testid=top-bar-tenant-box]')?.click()
    await new Promise((r) => setTimeout(r, 400))
    const sel = document.querySelector('[data-testid=top-bar-tenant-option][aria-selected=true]')?.getAttribute('data-tenant') || ''
    document.querySelector('[data-testid=top-bar-tenant-scrim]')?.click()
    return sel
  })
  return { host: new URL(p.url()).hostname, shown, ...(await claims(p)) }
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--hide-scrollbars'] })
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await nav(p, `${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=${encodeURIComponent('/lobby')}`)
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in', !!trig, { url: p.url().replace(/\?.*/, '') })
  if (!trig) throw new Error('sign-in failed (a 429 means the login budget, not the build)')
  const c0 = await claims(p)
  step(`session tenant is ${TENANT}`, c0.t === TENANT, c0)
  if (c0.t !== TENANT) throw new Error('refusing to go on outside the proof tenant')

  for (const w of [390, 820]) {
    await p.setViewport({ width: w, height: 844, isMobile: true, hasTouch: true })
    /* `/` is level 1 on a phone: the section strip is on screen */
    await nav(p, `${BASE}/`)
    await p.waitForSelector('[data-testid=top-bar-tenant-box]', { timeout: 20000 })
    await sleep(2000)
    const bar = await rect(p, '[data-test=top-bar]')
    const box = await rect(p, '[data-testid=top-bar-tenant-box]')
    const search = await rect(p, '[data-test=top-bar-search-toggle]')
    const strip = await rect(p, '[data-testid=tenant-switcher]')
    const rail = await rect(p, '[data-testid=sidebar-tab-dm]')
    step(`${w}: the tenant box is in the bar, >= 44 px, right before search`, box?.shown && box.w >= 44 && box.h >= 44 && box.b <= bar.b
      && search?.shown && box.r <= search.x + 1 && search.x - box.r <= 8, { bar, box, search })
    step(`${w}: level 1 on screen, the strip does not show the switcher (not twice)`, rail?.shown && !strip?.shown, { rail, strip })
    const n = await p.$$eval('[data-testid=top-bar-tenant-box], [data-testid=tenant-switcher]', (els) => els.filter((e) => e.getBoundingClientRect().width > 0).length)
    step(`${w}: exactly one switcher visible`, n === 1, { n })
    step(`${w}: no horizontal scroll`, (await xscroll(p)) <= 0)
    await p.screenshot({ path: `${OUT}/tenant-${w}-bar.png` })
    await p.click('[data-testid=top-bar-tenant-box]')
    await sleep(600)
    const sheet = await rect(p, '[data-testid=top-bar-tenant-sheet]')
    const rows = await p.$$eval('[data-testid=top-bar-tenant-option]', (els) => els.map((e) => ({ id: e.getAttribute('data-tenant'), sel: e.getAttribute('aria-selected'), h: Math.round(e.getBoundingClientRect().height) })))
    step(`${w}: the tenants open as a bottom sheet, the active one selected`, sheet?.x === 0 && sheet.w === w && sheet.b === 844
      && rows.length >= 1 && rows.some((r) => r.id === TENANT && r.sel === 'true') && rows.every((r) => r.h >= 44), { sheet, rows })
    await p.screenshot({ path: `${OUT}/tenant-${w}-sheet.png` })
    await p.click('[data-testid=top-bar-tenant-scrim]', { offset: { x: 10, y: 10 } })
    await sleep(300)
    step(`${w}: the scrim closes the sheet`, !(await rect(p, '[data-testid=top-bar-tenant-sheet]')))
  }

  if (SWITCH_TO) {
    await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
    await nav(p, `${BASE}/`)
    await p.waitForSelector('[data-testid=top-bar-tenant-box]', { timeout: 20000 })
    const c1 = await switchVia(p, SWITCH_TO)
    const onHost = (c, t) => c.host.startsWith(`${t}.`) || c.t === t
    step(`390: picking ${SWITCH_TO} in the sheet switches the tenant`, c1.shown === SWITCH_TO && onHost(c1, SWITCH_TO), c1)
    await p.screenshot({ path: `${OUT}/tenant-390-switched.png` })
    const c2 = await switchVia(p, TENANT)
    step(`390: and back to ${TENANT}`, c2.shown === TENANT && !c2.host.startsWith(`${SWITCH_TO}.`), c2)
  }

  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  await nav(p, `${BASE}/lobby`)
  await p.waitForSelector('[data-testid=tenant-switcher-select]', { timeout: 20000 })
  await sleep(1500)
  const side = await rect(p, '[data-testid=tenant-switcher]')
  const top = await rect(p, '[data-test=top-bar-tenant]')
  step('1440: the sidebar drop box is the switcher, the bar has none', side?.shown && !top?.shown, { side, top })
  await p.screenshot({ path: `${OUT}/tenant-1440.png` })
} catch (e) {
  step('run', false, { error: String(e.message || e) })
} finally {
  await browser.close()
}
const failed = steps.filter((s) => !s.ok)
console.log(`${failed.length ? 'FAIL' : 'PASS'} ${steps.length - failed.length}/${steps.length}`)
process.exit(failed.length ? 1 : 0)
