// Font size (CLE-3495, specs/023 §3.5) — live proof, signed in, against a
// deployed WUI.
//
//   0. a fresh browser (nothing stored) opens at the default level 3: the
//      level-3 radio is checked and body font-size is above the old 16px;
//   1. /settings/appearance: click each radio 1..5 — computed body font-size
//      strictly increases level to level;
//   2. from 5, + is disabled; − steps 5 -> 4 -> ... -> 1, one level per click,
//      and is disabled at 1; + steps 1 -> ... -> 5 and is disabled at 5;
//   3. pick level 2, reload: level 2 is still checked and the size is level 2's;
//      navigate to the lobby: the size holds there too.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/font-size-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
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
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/** The control's state and the page's computed sizes. */
const READ = () => {
  const px = (el) => (el ? parseFloat(getComputedStyle(el).fontSize) : 0)
  const checked = document.querySelector('[data-test^=font-size-radio-]:checked')
  const smaller = document.querySelector('[data-test=font-size-smaller]')
  const bigger = document.querySelector('[data-test=font-size-bigger]')
  return {
    level: checked ? Number(checked.value) : 0,
    attr: document.documentElement.getAttribute('data-font-size') || '',
    html: px(document.documentElement),
    body: px(document.body),
    smallerDisabled: smaller ? smaller.disabled : null,
    biggerDisabled: bigger ? bigger.disabled : null,
    stored: (() => { try { return localStorage.getItem('spool-font-size') } catch { return 'ERR' } })(),
  }
}

async function read(p) { return p.evaluate(READ) }

async function openAppearance(p) {
  await p.goto(BASE + '/settings/appearance', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=font-size-setting]', { visible: true, timeout: 20000 })
  await sleep(300)
}

async function click(p, sel) {
  await p.click(sel)
  await sleep(250)
  return read(p)
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 60000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=en-GB'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))

  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const signedIn = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', signedIn, { url: p.url().replace(BASE, '') })
  if (!signedIn) throw new Error('not signed in')

  // 0. default
  await openAppearance(p)
  let s = await read(p)
  step('0 fresh browser opens at level 3, body above the old 16px', s.level === 3 && s.body > 16 && s.stored === null,
    { level: s.level, body: s.body, html: s.html, stored: s.stored })
  await p.screenshot({ path: `${OUT}/0-default.png` })

  // 1. each radio, sizes strictly increase
  const sizes = []
  for (let n = 1; n <= 5; n++) {
    s = await click(p, `[data-test=font-size-radio-${n}]`)
    sizes.push(s.body)
    step(`1 radio ${n} checks level ${n} and stores it`, s.level === n && s.attr === String(n) && s.stored === String(n),
      { level: s.level, attr: s.attr, stored: s.stored, body: s.body })
  }
  const strictly = sizes.every((v, i) => i === 0 || v > sizes[i - 1])
  step('1 body font-size strictly increases level 1 -> 5', strictly, { sizes })
  await p.screenshot({ path: `${OUT}/1-level-5.png` })

  // 2. − and + move one level and stop at the ends
  s = await read(p)
  step('2 at level 5 + is disabled, − is enabled', s.biggerDisabled === true && s.smallerDisabled === false, s)
  for (let want = 4; want >= 1; want--) {
    s = await click(p, '[data-test=font-size-smaller]')
    step(`2 − moves to level ${want}`, s.level === want && s.body === sizes[want - 1], { level: s.level, body: s.body })
  }
  step('2 at level 1 − is disabled, + is enabled', s.smallerDisabled === true && s.biggerDisabled === false, s)
  await p.click('[data-test=font-size-smaller]').catch(() => {})
  await sleep(250)
  s = await read(p)
  step('2 − at level 1 stays at 1', s.level === 1, { level: s.level })
  for (let want = 2; want <= 5; want++) {
    s = await click(p, '[data-test=font-size-bigger]')
    step(`2 + moves to level ${want}`, s.level === want && s.body === sizes[want - 1], { level: s.level, body: s.body })
  }
  step('2 at level 5 + is disabled again', s.biggerDisabled === true, { biggerDisabled: s.biggerDisabled })

  // 3. survives a reload and holds on another page
  await click(p, '[data-test=font-size-radio-2]')
  await p.reload({ waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=font-size-setting]', { visible: true, timeout: 20000 })
  await sleep(300)
  s = await read(p)
  step('3 level 2 survives a reload', s.level === 2 && s.body === sizes[1] && s.attr === '2', { level: s.level, body: s.body, attr: s.attr })
  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  await sleep(500)
  s = await read(p)
  step('3 the lobby carries level 2', s.attr === '2' && s.html === (await p.evaluate(() => parseFloat(getComputedStyle(document.documentElement).fontSize))) && s.body === sizes[1],
    { attr: s.attr, html: s.html, body: s.body })
  await p.screenshot({ path: `${OUT}/3-lobby-level-2.png` })

  // leave the member's browser state at the default for the next reader
  await openAppearance(p)
  await click(p, '[data-test=font-size-radio-3]')
} catch (e) {
  step('proof ran', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAIL ${failed} step(s)` : `PASS all ${res.steps.length} steps`, '->', OUT + '/results.json')
process.exit(failed ? 1 : 0)
