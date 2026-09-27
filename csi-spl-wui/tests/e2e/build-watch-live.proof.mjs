// SPL-1006 - live proof, signed in, against a DEPLOYED WUI: the real bundle
// (it carries its commit in window.__BUILD__) meets a /build.json that names a
// newer commit (request interception - the next deploy, without waiting for
// one). WRITES NOTHING: the draft is typed and never sent.
//
//   1440: build.json is the real one -> no bar, no reload (no-change check)
//   per width 390 / 820 (touch), on /lobby:
//     1 a draft typed in the dock, then "a newer build is live" -> NO reload,
//       the bar shows, the draft is kept          (screenshot <w>-bar.png)
//     2 the draft emptied -> the tab reloads by itself, route kept
//     3 same bundle after the reload (the guard) -> no second reload, the bar
//                                                  (screenshot <w>-guard.png)
//
//   BASE=https://e2e.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=e2e] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/build-watch-live.proof.mjs
// The password is never printed.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 'e2e'
const NEWER = '9999999999999999999999999999999999999999'
mkdirSync(OUT, { recursive: true })

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, checks: [] }
const ok = (name, pass, ev) => {
  res.checks.push({ name, ok: Boolean(pass), ev })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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

const poke = (p) => p.evaluate(() => window.dispatchEvent(new Event('focus')))
const mark = (p) => p.evaluate(() => { window.__bwMark = 1 })
const reloaded = (p) => p.evaluate(() => window.__bwMark !== 1).catch(() => true)
async function waitReload(p, ms) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    await sleep(250)
    if (await reloaded(p)) { await p.waitForSelector('[data-test=top-bar]', { timeout: 30000 }); return true }
  }
  return false
}
const bar = (p) => p.evaluate(() => {
  const b = document.querySelector('[data-test=build-update-bar]')
  if (!b) return null
  const r = b.getBoundingClientRect()
  const btn = b.querySelector('[data-test=build-update-reload]').getBoundingClientRect()
  return { x: Math.round(r.x), r: Math.round(r.right), y: Math.round(r.y), b: Math.round(r.bottom), vw: innerWidth, btnH: Math.round(btn.height), text: b.textContent.trim() }
})
const draftBox = (p) => p.evaluateHandle(() => [...document.querySelectorAll('textarea')]
  .find((t) => t.getClientRects().length && getComputedStyle(t).visibility !== 'hidden' && !t.disabled))

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'] })
let code = 0
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const served = { fake: '' }
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (served.fake && new URL(req.url()).pathname === '/build.json') {
      return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ commit: served.fake, built_at: new Date().toISOString(), run: 'proof' }) })
    }
    req.continue()
  })
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'load' })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.sidebar'), { timeout: 60000 })
  await sleep(1500)
  const live = await p.evaluate(async () => (await (await fetch('/build.json', { cache: 'no-store' })).json()).commit)
  const running = await p.evaluate(() => (window.__BUILD__ && window.__BUILD__.commit) || '')
  res.build = { live, running }
  ok('the deployed bundle carries its commit, and it is the live one', running && running === live, res.build)

  // 1440: no change -> nothing happens
  await mark(p); await poke(p); await sleep(2500)
  ok('1440: same build -> no reload', !(await reloaded(p)))
  ok('1440: same build -> no bar', (await bar(p)) === null)
  await p.screenshot({ path: join(OUT, 'build-watch-1440-none.png') })

  for (const w of [390, 820]) {
    served.fake = ''
    await p.setViewport({ width: w, height: 844, isMobile: true, hasTouch: true })
    await p.goto(BASE + '/lobby', { waitUntil: 'load' })
    await p.waitForSelector('[data-test=top-bar]', { timeout: 30000 })
    await p.evaluate(() => { try { sessionStorage.removeItem('spool.build-reload-for') } catch {} })
    await sleep(1500)
    const ta = await draftBox(p)
    if (!(await ta.evaluate((t) => Boolean(t)))) { ok(`${w}: a visible composer`, false); continue }
    await ta.click()
    await ta.type('draft - never sent (SPL-1006 proof)')
    served.fake = NEWER
    await mark(p); await poke(p); await sleep(4500)
    const b1 = await bar(p)
    const kept = await ta.evaluate((t) => t.value)
    ok(`${w}: a draft + a newer build -> NO reload`, !(await reloaded(p)))
    ok(`${w}: the draft is kept`, kept === 'draft - never sent (SPL-1006 proof)', kept)
    ok(`${w}: the bar shows inside the screen, Reload >= 44 px`, Boolean(b1 && b1.x >= 0 && b1.r <= b1.vw && b1.btnH >= 44), b1)
    await p.screenshot({ path: join(OUT, `build-watch-${w}-bar.png`) })
    const path0 = await p.evaluate(() => location.pathname)
    await ta.evaluate((t) => t.focus())
    await p.keyboard.down('Control'); await p.keyboard.press('a'); await p.keyboard.up('Control')
    await p.keyboard.press('Backspace')
    await p.evaluate(() => document.activeElement && document.activeElement.blur())
    const did = await waitReload(p, 12000)
    ok(`${w}: the draft emptied -> the tab reloads by itself`, did)
    ok(`${w}: the route is kept`, (await p.evaluate(() => location.pathname)) === path0)
    await sleep(1500)
    await mark(p); await poke(p); await sleep(5000)
    const b2 = await bar(p)
    ok(`${w}: same bundle after the reload -> no second reload (guard)`, !(await reloaded(p)))
    ok(`${w}: ... the bar instead`, Boolean(b2), b2)
    await p.screenshot({ path: join(OUT, `build-watch-${w}-guard.png`) })
  }
  await ctx.close()
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
}
writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
const failed = res.checks.filter((c) => !c.ok)
console.log(`\nbuild-watch-live: ${res.checks.length - failed.length}/${res.checks.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
