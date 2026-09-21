// Signed-out /channel/lobby must not GET /v1/view/search/operators (the
// TopBar catalogue fetch). Autocomplete still loads once a member session
// is in. Screenshots + results.json to OUT.
//
//   BASE=https://dev.<domain> OUT=/var/tmp/GRK-3373-proof/operators \
//     [EMAIL=<member> PW_FILE=<0600 file> TENANT=t1] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/operators-session.proof.mjs
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
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [], operators: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const isOps = (u) => /\/v1\/view\/search\/operators(?:\?|$)/.test(String(u || ''))

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox'],
})
let failed = 0
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  p.on('request', (req) => { if (isOps(req.url())) res.operators.push({ when: 'out', url: req.url() }) })

  await p.goto(BASE + '/channel/lobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=top-bar]', { timeout: 20000 }).catch(() => null)
  await sleep(1500)
  const signedOut = res.operators.filter((x) => x.when === 'out')
  step('signed out on /channel/lobby: 0 GET /v1/view/search/operators', signedOut.length === 0, { n: signedOut.length, urls: signedOut.map((x) => x.url) })
  await p.screenshot({ path: `${OUT}/01-signed-out.png` })

  if (process.env.EMAIL && process.env.PW_FILE) {
    const pw = readFileSync(process.env.PW_FILE, 'utf8').trim()
    const before = res.operators.length
    p.on('request', (req) => { if (isOps(req.url())) res.operators.push({ when: 'in', url: req.url() }) })
    await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=native-auth-email]')
    await p.type('[data-test=native-auth-email]', process.env.EMAIL)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
    step('native sign-in', !!trig, { url: p.url().replace(/\?.*/, '') })
    await sleep(2000)
    const signedIn = res.operators.filter((x) => x.when === 'in' || (res.operators.indexOf(x) >= before && isOps(x.url)))
    // after sign-in the catalogue is fetched once so /search autocomplete works without opening /search
    const nIn = res.operators.length - before
    step('signed in: catalogue fetch happens (autocomplete without opening /search)', nIn >= 1, { n: nIn })
    await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=top-bar-omnibox] textarea', { timeout: 15000 })
    await p.click('[data-test=top-bar-omnibox] textarea')
    await p.keyboard.type('/search fr')
    await sleep(300)
    const ops = await p.evaluate(() => [...document.querySelectorAll('[data-test=search-operators] [role=option] code')].map((e) => e.textContent.trim()))
    step('signed in: /search fr autocompletes from:', ops.includes('from:'), { ops })
    await p.screenshot({ path: `${OUT}/02-signed-in-autocomplete.png` })
  } else {
    step('signed-in autocomplete (skipped, no EMAIL/PW_FILE)', true, { skipped: true })
  }
} catch (e) {
  step('proof threw', false, { err: String(e && e.stack || e) })
} finally {
  await browser.close().catch(() => {})
  failed = res.steps.filter((s) => !s.ok).length
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed} step(s)` : `PASS ${res.steps.length}/${res.steps.length}`)
  process.exit(failed ? 1 : 0)
}
