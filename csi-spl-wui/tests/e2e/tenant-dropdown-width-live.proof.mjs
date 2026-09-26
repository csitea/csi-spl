// Tenant drop box width — live proof, signed in, against a deployed WUI.
//
// The closed select is as wide as the widest membership name the member can
// pick, then exactly 3px, then the arrow. Checked at font level 3 and 5
// (spec 023). Needs two memberships whose names render at different widths.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/tenant-dropdown-width-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { TENANT_ARROW_GAP_PX, tenantNameArrowGapPx } from '../../src/utils/tenant-switcher.mjs'

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

// Same probe properties as measureControlText in tenant-switcher.mjs.
const READ_GAP = () => {
  const sel = document.querySelector('[data-testid=tenant-switcher-select]')
  const arrow = document.querySelector('[data-testid=tenant-switcher-arrow]')
  const wrap = document.querySelector('[data-testid=tenant-switcher]')
  if (!(sel instanceof HTMLSelectElement) || !(arrow instanceof Element)) return { missing: true }
  const cs = getComputedStyle(sel)
  const probe = document.createElement('span')
  probe.style.position = 'absolute'
  probe.style.visibility = 'hidden'
  probe.style.whiteSpace = 'nowrap'
  probe.style.padding = '0'
  probe.style.margin = '0'
  probe.style.border = '0'
  probe.style.font = cs.font
  probe.style.letterSpacing = cs.letterSpacing
  probe.style.wordSpacing = cs.wordSpacing
  probe.style.textTransform = cs.textTransform
  probe.style.fontKerning = cs.fontKerning
  probe.style.fontFeatureSettings = cs.fontFeatureSettings
  probe.style.fontVariant = cs.fontVariant
  document.body.appendChild(probe)
  const labels = [...sel.options].map((o) => o.textContent || '')
  const widths = labels.map((text) => { probe.textContent = text; return probe.getBoundingClientRect().width })
  probe.remove()
  const widest = widths.length ? Math.max(...widths) : 0
  const sr = sel.getBoundingClientRect()
  const ar = arrow.getBoundingClientRect()
  return {
    missing: false,
    labels,
    widths,
    widest,
    padStart: parseFloat(cs.paddingInlineStart) || 0,
    selLeft: sr.left,
    selRight: sr.right,
    selWidth: sr.width,
    selHeight: sr.height,
    arrowLeft: ar.left,
    arrowRight: ar.right,
    arrowWidth: ar.width,
    direction: cs.direction,
    fontSize: cs.fontSize,
    attr: document.documentElement.getAttribute('data-font-size') || '',
    styledWidth: sel.style.width,
    hint: wrap instanceof HTMLElement ? wrap.title : '',
    aria: sel.getAttribute('aria-label') || '',
    described: sel.getAttribute('aria-describedby') || '',
    focused: false,
  }
}

function gapOf(raw) {
  if (!raw || raw.missing) return NaN
  return tenantNameArrowGapPx({
    selLeft: raw.selLeft,
    selRight: raw.selRight,
    padStartPx: raw.padStart,
    widestPx: raw.widest,
    arrowLeft: raw.arrowLeft,
    arrowRight: raw.arrowRight,
    direction: raw.direction,
  })
}

async function readGap(p) {
  await p.waitForSelector('[data-testid=tenant-switcher-arrow]', { timeout: 20000 })
  await p.waitForFunction(() => {
    const sel = document.querySelector('[data-testid=tenant-switcher-select]')
    return sel instanceof HTMLSelectElement && sel.style.width.length > 0
  }, { timeout: 20000 })
  await sleep(200)
  return p.evaluate(READ_GAP)
}

async function shoot(p, name) {
  const el = await p.$('[data-testid=tenant-switcher]')
  const path = `${OUT}/${name}.png`
  if (el) await el.screenshot({ path })
  else await p.screenshot({ path })
  return path
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

  await p.goto(BASE + '/settings/appearance', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=font-size-setting]', { visible: true, timeout: 20000 })

  let raw = await readGap(p)
  const distinct = raw.widths ? new Set(raw.widths.map((w) => Math.round(w * 100))).size : 0
  step('2+ tenants whose names render at different widths', !raw.missing && raw.labels.length >= 2 && distinct >= 2,
    { labels: raw.labels, widths: raw.widths })
  step('hover explanation and the select name are still there',
    !raw.missing && raw.hint.length > 40 && raw.aria.length > 0 && raw.described === 'tenant-switcher-hint',
    { hint: raw.hint, aria: raw.aria, described: raw.described })
  await p.focus('[data-testid=tenant-switcher-select]')
  const focused = await p.evaluate(() => document.activeElement === document.querySelector('[data-testid=tenant-switcher-select]'))
  step('the select still takes keyboard focus', focused === true)

  for (const level of [3, 5]) {
    await p.click(`[data-test=font-size-radio-${level}]`)
    await sleep(400)
    raw = await readGap(p)
    const gap = gapOf(raw)
    const shot = await shoot(p, `level-${level}`)
    step(`font level ${level}: arrow is ${TENANT_ARROW_GAP_PX}px after the widest name`,
      raw.attr === String(level) && Number.isFinite(gap) && Math.abs(gap - TENANT_ARROW_GAP_PX) <= 0.5,
      { gap, attr: raw.attr, fontSize: raw.fontSize, widest: raw.widest, arrowWidth: raw.arrowWidth, selWidth: raw.selWidth, styledWidth: raw.styledWidth, labels: raw.labels, shot })
  }

  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  await sleep(400)
  raw = await readGap(p)
  const lobbyGap = gapOf(raw)
  const lobbyShot = await shoot(p, 'lobby-level-5')
  step('lobby keeps level 5 and the 3px gap',
    raw.attr === '5' && Number.isFinite(lobbyGap) && Math.abs(lobbyGap - TENANT_ARROW_GAP_PX) <= 0.5,
    { gap: lobbyGap, attr: raw.attr, fontSize: raw.fontSize, shot: lobbyShot })
} catch (e) {
  step('proof ran', false, { error: String(e && e.stack || e).slice(0, 500) })
} finally {
  try {
    const pages = await browser.pages()
    const p = pages[pages.length - 1]
    if (p) {
      await p.goto(BASE + '/settings/appearance', { waitUntil: 'networkidle2', timeout: 20000 }).catch(() => {})
      await p.click('[data-test=font-size-radio-3]').catch(() => {})
    }
  } catch { /* leave the restore as a best effort */ }
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAIL ${failed} step(s)` : `PASS all ${res.steps.length} steps`, '->', OUT + '/results.json')
process.exit(failed ? 1 : 0)
