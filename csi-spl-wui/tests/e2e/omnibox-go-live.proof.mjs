// SPL-995 E live proof (topic e0b12a2c): on a phone the omnibox GO floats at
// the vertical middle of the right edge. READ-ONLY - it opens the omnibox
// sheet, runs a /search (a read) and closes the sheet with Back; it never
// sends, saves a preference or changes a tenant.
//
//   BASE=https://e2e.<domain> TENANT=e2e EMAIL=<member> PW_FILE=<0600 file> \
//   OUT=<dir> node tests/e2e/omnibox-go-live.proof.mjs
//
// One native sign-in (10 logins per email per 15 min), then at 360, 390 and
// 820 px with touch emulated, on level 1 (/) and level 2 (/lobby, where the
// M3 composer docks at the bottom): GO is round, >= 44 px, labelled, at the
// middle of the right edge, under no dock; the bar is [tenant] ... [avatar].
// A tap opens the sheet with focus in the field; Back closes it (SPL-994);
// `/search <q>` opens the results. At 1440 px the desktop bar keeps the
// omnibox in the row and no GO floats. Exit 0 = every step PASS.
import { readFileSync, mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'

const need = (k) => { const v = process.env[k]; if (!v) { console.error(`${k} is required`); process.exit(2) } return v }
const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const OUT = need('OUT')
const Q = process.env.QUERY || 'hello'
if (!/^e2e(-.+)?$/.test(TENANT) && !(/^https:\/\/dev\./.test(BASE) && TENANT === 't1')) {
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
async function nav(p, url) {
  for (let i = 0; i < 3; i++) {
    try { await p.goto(url, { waitUntil: 'networkidle2' }); return } catch (e) {
      if (i === 2 || !/ERR_NETWORK_CHANGED|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(1500)
    }
  }
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

  for (const w of [360, 390, 820]) {
    for (const [level, path] of [['1', '/'], ['2', '/lobby']]) {
      await p.setViewport({ width: w, height: 844, isMobile: true, hasTouch: true })
      await nav(p, `${BASE}${path}`)
      await p.waitForSelector('[data-test=top-bar-search-toggle]', { visible: true, timeout: 20000 })
      await sleep(1500)
      const go = await rect(p, '[data-test=top-bar-search-toggle]')
      const bar = await rect(p, '[data-test=top-bar]')
      const tenant = await rect(p, '[data-testid=top-bar-tenant-box]')
      const avatar = await rect(p, '[data-test=user-menu-trigger]')
      const g = await p.evaluate(() => {
        const b = document.querySelector('[data-test=top-bar-search-toggle]')
        const d = document.querySelector('.composer--dock')
        return { round: getComputedStyle(b).borderRadius, label: b.getAttribute('aria-label'), title: b.title, dockTop: d ? Math.round(d.getBoundingClientRect().top) : window.innerHeight, vh: window.innerHeight, level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') }
      })
      step(`${w} L${level}: GO round, >= 44 px, labelled, middle of the right edge, over no dock`,
        go?.shown && go.w >= 44 && go.h >= 44 && g.round === '50%' && g.label === g.title && !!g.title
          && w - go.r <= 16 && Math.abs(go.y + go.h / 2 - g.vh / 2) <= 2 && go.b < g.dockTop && go.y > bar.b,
        { go, g })
      /* SPL-1025: [logo] [tenant] ... [avatar] - the tenant right after the 44 px logo */
      step(`${w} L${level}: the bar is [logo] [tenant] ... [avatar]`, tenant?.shown && tenant.x <= 16 + 44 + 8 && avatar?.shown && w - avatar.r <= 16 && avatar.b <= bar.b, { tenant, avatar })
      await p.screenshot({ path: `${OUT}/go-${w}-L${level}.png` })
    }
    /* level 2: tap -> sheet with focus; Back closes it; /search opens results */
    const before = p.url()
    await p.tap('[data-test=top-bar-search-toggle]')
    await sleep(600)
    const sheet = await rect(p, '[data-test=top-bar-omnibox]')
    const focused = await p.evaluate(() => !!document.activeElement?.closest('[data-test=top-bar-omnibox]'))
    step(`${w}: a tap opens the omnibox sheet, focus in the field`, sheet?.shown && sheet.w === w && focused, { sheet, focused })
    await p.screenshot({ path: `${OUT}/go-${w}-sheet.png` })
    await p.goBack().catch(() => null)
    await sleep(800)
    const closed = !(await rect(p, '[data-test=top-bar-search-close]'))?.shown
    step(`${w}: Back closes the sheet, the page stays`, closed && p.url() === before, { closed, url: p.url() })
    await p.tap('[data-test=top-bar-search-toggle]')
    await sleep(500)
    await p.keyboard.type(`/search ${Q}`)
    await p.keyboard.press('Enter')
    await p.waitForFunction(() => /\/search$/.test(location.pathname), { timeout: 15000 }).catch(() => {})
    await sleep(1500)
    const res = await p.evaluate(() => ({ path: location.pathname, q: new URLSearchParams(location.search).get('q') }))
    step(`${w}: /search ${Q} from the sheet opens the results`, /\/search$/.test(res.path) && res.q === Q, res)
    await p.screenshot({ path: `${OUT}/go-${w}-results.png` })
  }

  await p.setViewport({ width: 1440, height: 900, isMobile: false, hasTouch: false })
  await nav(p, `${BASE}/lobby`)
  await p.waitForSelector('[data-test=top-bar-omnibox] textarea', { timeout: 20000 })
  await sleep(1500)
  const omni = await rect(p, '[data-test=top-bar-omnibox] textarea')
  const go = await rect(p, '[data-test=top-bar-search-toggle]')
  step('1440: the omnibox is in the row, no GO floats', omni?.shown && !go?.shown, { omni, go })
  await p.screenshot({ path: `${OUT}/go-1440.png` })
} catch (e) {
  step('run', false, { error: String(e.message || e) })
} finally {
  await browser.close()
}
const failed = steps.filter((s) => !s.ok)
console.log(`${failed.length ? 'FAIL' : 'PASS'} ${steps.length - failed.length}/${steps.length}`)
process.exit(failed.length ? 1 : 0)
