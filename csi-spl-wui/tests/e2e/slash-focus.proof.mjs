// Headless-Chrome proof: `/` focuses the top Omnibox (Gmail/GitHub) without
// inserting the slash; `/` inside a composer types a literal slash; Escape
// restores the previous focus. Screenshots + results.json to OUT.
//
//   BASE=https://dev.<domain> OUT=/var/tmp/GRK-3373-proof \
//     [EMAIL=<invited member> PW_FILE=<0600 file> TENANT=t1] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/slash-focus.proof.mjs
//
// EMAIL/PW_FILE is optional: on a view-door-off host `/lobby` already shows
// the top bar. The password is never printed. Exit 0 = every step PASS.
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
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const OMNI = '[data-test=top-bar-omnibox] textarea'
const xscroll = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)

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

  if (process.env.EMAIL && process.env.PW_FILE) {
    const pw = readFileSync(process.env.PW_FILE, 'utf8').trim()
    await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=native-auth-email]')
    await p.type('[data-test=native-auth-email]', process.env.EMAIL)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
    step('native sign-in', !!trig, { url: p.url().replace(/\?.*/, '') })
  } else {
    await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  }

  const bar = await p.waitForSelector('[data-test=top-bar]', { timeout: 20000 }).catch(() => null)
  step('top bar present on /lobby', !!bar, { url: p.url() })
  await p.waitForSelector(OMNI, { timeout: 20000 })

  // blur anything the page auto-focused
  await p.evaluate(() => {
    const a = document.activeElement
    if (a && a !== document.body && typeof a.blur === 'function') a.blur()
    const brand = document.querySelector('.top-bar__brand')
    if (brand) brand.focus()
  })
  await sleep(100)

  const before = await p.evaluate((sel) => {
    const ta = document.querySelector(sel)
    return {
      active: document.activeElement && document.activeElement.tagName,
      inOmni: document.activeElement === ta,
      value: ta ? ta.value : null,
      badge: !!document.querySelector('[data-test=slash-badge]'),
      hint: (document.querySelector('[data-test=slash-shortcut-hint]') || {}).textContent || '',
      aria: ta ? ta.getAttribute('aria-keyshortcuts') : null,
    }
  }, OMNI)
  step('/ badge + aria note visible before the shortcut', before.badge && before.hint.length > 0 && before.aria === '/', before)
  await p.screenshot({ path: `${OUT}/01-before-slash.png` })

  await p.keyboard.press('/')
  await sleep(80)
  const afterSlash = await p.evaluate((sel) => {
    const ta = document.querySelector(sel)
    return {
      inOmni: document.activeElement === ta,
      value: ta ? ta.value : null,
      tag: document.activeElement && document.activeElement.tagName,
    }
  }, OMNI)
  step('/ on /lobby focuses the Omnibox and does not insert the slash',
    afterSlash.inOmni && afterSlash.value !== '/', afterSlash)

  await p.keyboard.type('hello')
  const typed = await p.$eval(OMNI, (t) => t.value)
  step('typing after / lands in the Omnibox', typed.includes('hello') && !typed.startsWith('/hello'), { typed })
  await p.screenshot({ path: `${OUT}/02-typed-in-omnibox.png` })

  // already in the composer (the Omnibox textarea): `/` is a literal slash
  await p.keyboard.press('/')
  await sleep(50)
  const literal = await p.$eval(OMNI, (t) => t.value)
  step('/ inside the composer inserts a literal slash', literal.includes('/'), { literal })

  // restore: focus the brand, press /, Escape returns to the brand
  await p.evaluate(() => {
    const ta = document.querySelector('[data-test=top-bar-omnibox] textarea')
    if (ta) ta.blur()
    const brand = document.querySelector('.top-bar__brand')
    if (brand) brand.focus()
  })
  await sleep(50)
  await p.keyboard.press('/')
  await sleep(50)
  const jumped = await p.evaluate((sel) => document.activeElement === document.querySelector(sel), OMNI)
  await p.keyboard.press('Escape')
  await sleep(50)
  const restored = await p.evaluate(() => {
    const a = document.activeElement
    return {
      isBrand: !!(a && a.classList && a.classList.contains('top-bar__brand')),
      tag: a && a.tagName,
      className: a && a.className,
    }
  })
  step('Escape blurs the Omnibox and restores the previous focus', jumped && restored.isBrand, { jumped, ...restored })
  await p.screenshot({ path: `${OUT}/03-escape-restored.png` })

  // CONTROL: a typing target keeps `/`
  await p.evaluate(() => {
    const ta = document.querySelector('[data-test=top-bar-omnibox] textarea')
    if (ta) ta.blur()
    let inp = document.getElementById('proof-input')
    if (!inp) {
      inp = document.createElement('input')
      inp.id = 'proof-input'
      inp.type = 'text'
      document.body.appendChild(inp)
    }
    inp.value = ''
    inp.focus()
  })
  await p.keyboard.press('/')
  await sleep(50)
  const inInput = await p.evaluate(() => {
    const inp = document.getElementById('proof-input')
    const ta = document.querySelector('[data-test=top-bar-omnibox] textarea')
    return { value: inp.value, inOmni: document.activeElement === ta, inInput: document.activeElement === inp }
  })
  step('/ inside an input types a literal slash and does not steal focus',
    inInput.value === '/' && inInput.inInput && !inInput.inOmni, inInput)

  // CONTROL: open modal (CLE-3423 UiDialog shape) — `/` does not jump
  await p.evaluate(() => {
    const d = document.createElement('div')
    d.id = 'proof-modal'
    d.setAttribute('role', 'dialog')
    d.setAttribute('aria-modal', 'true')
    const btn = document.createElement('button')
    btn.id = 'proof-modal-btn'
    btn.textContent = 'ok'
    d.appendChild(btn)
    document.body.appendChild(d)
    btn.focus()
  })
  await p.keyboard.press('/')
  await sleep(50)
  const inModal = await p.evaluate((sel) => {
    const ta = document.querySelector(sel)
    return {
      inOmni: document.activeElement === ta,
      onBtn: document.activeElement && document.activeElement.id === 'proof-modal-btn',
    }
  }, OMNI)
  step('/ inside an open aria-modal dialog does not focus the Omnibox', !inModal.inOmni && inModal.onBtn, inModal)
  await p.evaluate(() => document.getElementById('proof-modal')?.remove())

  // CONTROL: modifiers
  await p.evaluate(() => {
    const ta = document.querySelector('[data-test=top-bar-omnibox] textarea')
    if (ta) ta.blur()
    const brand = document.querySelector('.top-bar__brand')
    if (brand) brand.focus()
  })
  await p.keyboard.down('Control')
  await p.keyboard.press('/')
  await p.keyboard.up('Control')
  await sleep(50)
  const withCtrl = await p.evaluate((sel) => document.activeElement === document.querySelector(sel), OMNI)
  step('Ctrl+/ does not focus the Omnibox', !withCtrl, { withCtrl })

  const xsDesk = await xscroll(p)
  step('desktop no x-scroll', xsDesk <= 0, { xscroll: xsDesk })

  // mobile: the Omnibox is folded; `/` must not steal (mobile unaffected)
  await p.setViewport({ width: 390, height: 844 })
  await sleep(150)
  await p.evaluate(() => {
    const a = document.activeElement
    if (a && typeof a.blur === 'function') a.blur()
  })
  await p.keyboard.press('/')
  await sleep(80)
  const mobile = await p.evaluate((sel) => {
    const wrap = document.querySelector('[data-test=top-bar-omnibox]')
    const ta = document.querySelector(sel)
    const shown = wrap ? getComputedStyle(wrap).display !== 'none' : false
    return {
      shown,
      inOmni: document.activeElement === ta,
      badgeDisplay: (() => {
        const b = document.querySelector('[data-test=slash-badge]')
        return b ? getComputedStyle(b).display : null
      })(),
    }
  }, OMNI)
  const xsMob = await xscroll(p)
  step('mobile: / does not expand/focus the Omnibox, badge hidden, no x-scroll',
    !mobile.shown && !mobile.inOmni && mobile.badgeDisplay === 'none' && xsMob <= 0,
    { ...mobile, xscroll: xsMob })
  await p.screenshot({ path: `${OUT}/04-mobile.png` })
} catch (e) {
  step('proof threw', false, { err: String(e && e.stack || e) })
} finally {
  await browser.close().catch(() => {})
  failed = res.steps.filter((s) => !s.ok).length
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed} step(s)` : `PASS ${res.steps.length}/${res.steps.length}`)
  process.exit(failed ? 1 : 0)
}
