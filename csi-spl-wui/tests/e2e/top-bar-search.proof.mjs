// 022 proof of the top bar + global search, against a served WUI (a deployed
// dev host, or a local `nuxt generate` bundle behind serve-generated.mjs in
// mock mode): the bar stays on top while the page scrolls, the Omnibox and the
// corner controls live in it, `/search fr` autocompletes operators, a
// `/search <Q>` line opens /search?q=<Q> with grouped results (or an honest
// empty / error state), ArrowDown hands the focus to the results, Enter opens
// the first row, the deep link restores the query, and on a phone the Omnibox
// folds into an icon. Screenshots + results.json to OUT.
//
//   BASE=https://dev.<domain> OUT=<dir> [Q='from:EZB-1 is:task'] \
//     [EMAIL=<invited member> PW_FILE=<0600 file> TENANT=t1] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/top-bar-search.proof.mjs
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
const Q = process.env.Q || 'from:EZB-1 is:task'
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, q: Q, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const xscroll = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
const OMNI = '[data-test=top-bar-omnibox] textarea'

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
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

  // 1. the bar: on top, holds the Omnibox and the corner, and stays when the page scrolls
  const bar = await p.waitForSelector('[data-test=top-bar]', { timeout: 20000 }).catch(() => null)
  const layout = bar && await p.evaluate(() => {
    const b = document.querySelector('[data-test=top-bar]')
    const r = b.getBoundingClientRect()
    return {
      top: r.top, height: r.height, width: r.width,
      omnibox: !!b.querySelector('[data-test=top-bar-omnibox] textarea'),
      corner: !!b.querySelector('[data-test=app-corner] [data-test=user-menu]'),
      shellBelow: (document.querySelector('.spool-shell')?.getBoundingClientRect().top ?? -1) >= r.bottom - 1,
      inlineOmnibox: document.querySelectorAll('.spool-main .composer.omnibox').length,
    }
  })
  step('top bar spans the page with the Omnibox + corner, shell below, no inline page Omnibox',
    !!layout && layout.top === 0 && layout.width >= 1270 && layout.omnibox && layout.corner && layout.shellBelow && layout.inlineOmnibox === 0, layout || {})
  // a tall child must not scroll the window; the lists scroll inside themselves
  await p.evaluate(() => {
    const d = document.createElement('div')
    d.id = 'proof-tall'
    d.style.height = '3000px'
    document.querySelector('.spool-main').appendChild(d)
    window.scrollTo(0, 800)
  })
  await sleep(200)
  const stuck = await p.evaluate(() => ({ top: document.querySelector('[data-test=top-bar]').getBoundingClientRect().top, scrollY: window.scrollY }))
  step('the window does not scroll and the bar stays put', stuck.top === 0 && stuck.scrollY === 0, stuck)
  await p.evaluate(() => { document.getElementById('proof-tall')?.remove(); window.scrollTo(0, 0) })
  await p.screenshot({ path: `${OUT}/01-top-bar-desktop.png` })

  // 2. operator autocomplete
  await p.click(OMNI)
  await p.type(OMNI, '/search fr')
  await sleep(200)
  const ops = await p.evaluate(() => [...document.querySelectorAll('[data-test=search-operators] [role=option] code')].map((e) => e.textContent.trim()))
  const chip = await p.$('[data-test=omnibox-mode]')
  step('/search switches mode; "fr" autocompletes from:', !!chip && ops.includes('from:'), { ops })
  await p.screenshot({ path: `${OUT}/02-operator-autocomplete.png` })
  await p.keyboard.press('Tab')
  const afterTab = await p.$eval(OMNI, (t) => t.value)
  step('Tab picks the operator', afterTab === '/search from:', { value: afterTab })

  // 3. the query → /search?q=
  await p.$eval(OMNI, (t) => { t.value = ''; t.dispatchEvent(new Event('input', { bubbles: true })) })
  await p.type(OMNI, `/search ${Q}`)
  // an open operator list would take the Enter: close it first (Escape then only closes the list)
  if (await p.$('[data-test=search-operators]')) await p.keyboard.press('Escape')
  await p.keyboard.press('Enter')
  await p.waitForFunction(() => location.pathname.endsWith('/search'), { timeout: 10000 }).catch(() => null)
  await p.waitForFunction(() => document.querySelector('[data-test=search-results],[data-test=search-empty],[data-test=search-bad-query],[data-test=search-error],[data-testid=view-door]'), { timeout: 20000 }).catch(() => null)
  const u = new URL(p.url())
  const state = await p.evaluate(() => {
    const has = (s) => !!document.querySelector(s)
    return {
      results: has('[data-test=search-results]'), empty: has('[data-test=search-empty]'),
      bad: has('[data-test=search-bad-query]'), error: has('[data-test=search-error]'), door: has('[data-testid=view-door]'),
      groups: [...document.querySelectorAll('.search-group')].map((g) => `${g.dataset.group}:${g.querySelectorAll('[role=option]').length}`),
      marks: document.querySelectorAll('.search-results mark').length,
      warnings: [...document.querySelectorAll('[data-test=search-warnings] li')].map((l) => l.textContent.trim()),
    }
  })
  step('Enter opens /search?q=<raw query> with a results / empty / error state',
    u.searchParams.get('q') === Q && (state.results || state.empty || state.bad || state.error || state.door), { q: u.searchParams.get('q'), ...state })
  res.searchState = state
  await p.screenshot({ path: `${OUT}/03-search-results.png` })

  // 4. keyboard: ArrowDown in the Omnibox → list; Enter opens the first row
  if (state.results) {
    await p.focus(OMNI)
    await p.$eval(OMNI, (t) => t.setSelectionRange(t.value.length, t.value.length))
    await p.keyboard.press('ArrowDown')
    await sleep(150)
    const focused = await p.evaluate(() => ({ role: document.activeElement?.getAttribute('role'), active: document.activeElement?.getAttribute('aria-activedescendant') }))
    step('ArrowDown in the Omnibox focuses the results listbox on row 0', focused.role === 'listbox' && focused.active === 'sr-0', focused)
    const first = await p.evaluate(() => { const r = document.getElementById('sr-0'); return { type: r?.dataset.type, text: r?.textContent.trim().slice(0, 80) } })
    const beforeUrl = await p.evaluate(() => location.pathname + location.search)
    await p.keyboard.press('Enter')
    await p.waitForSelector('.live-pane .msg.search-focus', { timeout: 5000 }).catch(() => null)
    const after = await p.evaluate(() => ({
      url: location.pathname + location.search,
      pane: !!document.querySelector('.live-pane'),
      focusedMsg: document.querySelector('.live-pane .msg.search-focus')?.getAttribute('data-msg-id') || '',
    }))
    // message / topic / file → the topic pane; robot / user / channel / box → another route or query
    const opened = ['messages', 'topics', 'files'].includes(first.type) ? after.pane : after.url !== beforeUrl
    step('Enter opens the first result (topic pane for a message/topic/file)', opened, { first, ...after })
    if (first.type === 'messages') step('the topic pane scrolls to and marks that message', !!after.focusedMsg, { focusedMsg: after.focusedMsg })
    await p.screenshot({ path: `${OUT}/04-opened-result.png` })
  }

  // 5. deep link restores the query in the Omnibox
  const p2 = await ctx.newPage()
  await p2.setViewport({ width: 1280, height: 800 })
  await p2.goto(BASE + '/search?q=' + encodeURIComponent(Q), { waitUntil: 'networkidle2' })
  await p2.waitForSelector(OMNI, { timeout: 20000 })
  await sleep(500)
  const restored = await p2.$eval(OMNI, (t) => t.value)
  step('deep link /search?q= shows the query in the Omnibox', restored === `/search ${Q}`, { restored })
  await p2.close()

  // 6. phone: the bar stays, the Omnibox folds into an icon, no x-scroll
  await p.setViewport({ width: 390, height: 844 })
  await p.goto(BASE + '/lobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=top-bar]', { timeout: 20000 })
  const folded = await p.evaluate(() => ({
    omniboxShown: getComputedStyle(document.querySelector('[data-test=top-bar-omnibox]')).display !== 'none',
    toggleShown: getComputedStyle(document.querySelector('[data-test=top-bar-search-toggle]')).display !== 'none',
  }))
  const xs1 = await xscroll(p)
  step('phone: Omnibox folded to an icon, no x-scroll', !folded.omniboxShown && folded.toggleShown && xs1 <= 0, { ...folded, xscroll: xs1 })
  await p.screenshot({ path: `${OUT}/05-mobile-folded.png` })
  await p.click('[data-test=top-bar-search-toggle]')
  await sleep(300)
  const open = await p.evaluate(() => ({
    omniboxShown: getComputedStyle(document.querySelector('[data-test=top-bar-omnibox]')).display !== 'none',
    focused: document.activeElement?.tagName,
  }))
  const xs2 = await xscroll(p)
  step('phone: the icon expands the Omnibox, focused, no x-scroll', open.omniboxShown && open.focused === 'TEXTAREA' && xs2 <= 0, { ...open, xscroll: xs2 })
  const covered = await p.evaluate(() => {
    const r = document.querySelector('[data-test=top-bar-omnibox] textarea').getBoundingClientRect()
    const hit = document.elementFromPoint(r.left + 20, r.top + r.height / 2)
    return hit?.tagName === 'TEXTAREA'
  })
  step('phone: the open Omnibox is on top of the corner controls', covered, { textareaHit: covered })
  await p.screenshot({ path: `${OUT}/06-mobile-open.png` })
  await p.click('[data-test=top-bar-search-close]')
  await sleep(200)
  const closed = await p.evaluate(() => getComputedStyle(document.querySelector('[data-test=top-bar-omnibox]')).display === 'none')
  step('phone: the close button folds it back', closed, { closed })
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
const failed = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - failed}/${res.steps.length} steps PASS -> ${OUT}`)
process.exit(failed ? 1 : 0)
