// CLE-3402 live proof of the top-right user control against a deployed WUI:
// signed out (desktop + mobile: the corner is the sign-in entry, no x-scroll),
// native sign-in through the WUI form, the avatar button (name, member avatar,
// position), the WAI-ARIA keyboard flow, the dropdown items, /settings (desktop
// + mobile), and Sign out from the dropdown. Screenshots + results.json to OUT.
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [LOCALE=en] [DEFAULT_LOCALE=en] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/user-menu-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
// spec 021: the WUI is localised (prefix_except_default). The proof runs in
// LOCALE via its URL prefix and compares labels with THAT locale's catalogue,
// so it holds whatever the unprefixed default locale is.
const LOCALE = process.env.LOCALE || 'en'
const P = LOCALE === (process.env.DEFAULT_LOCALE || 'en') ? '' : '/' + LOCALE
const CAT = JSON.parse(readFileSync(new URL(`../../i18n/locales/${LOCALE}.json`, import.meta.url), 'utf8'))
const esc = (x) => x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
/** The catalogue template of `key` as a regex, each {param} = any text. */
const trRe = (key) => new RegExp('^' + esc(key.split('.').reduce((o, k) => o?.[k], CAT)).replace(/\\\{\w+\\\}/g, '.+') + '$')
const tr = (key, params = {}) => key.split('.').reduce((o, k) => o?.[k], CAT).replace(/\{(\w+)\}/g, (_, k) => params[k] ?? `{${k}}`)
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const xscroll = (p) => p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  const build = await (await fetch(BASE + '/build.json')).json()
  res.build = build
  // 1. signed out
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  for (const [w, h, tag] of [[1280, 800, 'desktop'], [390, 844, 'mobile']]) {
    await p.setViewport({ width: w, height: h })
    await p.goto(BASE + P + '/lobby', { waitUntil: 'networkidle2' })
    const el = await p.waitForSelector('[data-test=user-menu-signin]', { timeout: 20000 }).catch(() => null)
    const href = el ? await el.evaluate((a) => a.getAttribute('href')) : ''
    const name = el ? await el.evaluate((a) => a.getAttribute('aria-label')) : ''
    const box = el ? await el.boundingBox() : null
    const trig = await p.$('[data-test=user-menu-trigger]')
    const xs = await xscroll(p)
    step(`signed-out ${tag}: top-right is the sign-in entry`, !!el && !trig && xs <= 0 && box.x + box.width > w - 80 && box.y < 60,
      { href, name, box, xscroll: xs })
    await p.screenshot({ path: `${OUT}/signed-out-${tag}.png` })
  }
  // 2. native sign-in through the WUI form
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + P + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent(P + '/lobby'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  step('native sign-in lands with the avatar top-right', !!trig, { url: p.url() })
  if (trig) {
    await new Promise((r) => setTimeout(r, 2500))
    const label = await trig.evaluate((b) => b.getAttribute('aria-label'))
    const hasImg = await trig.evaluate((b) => !!b.querySelector('img.spool-avatar'))
    const box = await trig.boundingBox()
    step('avatar button: named, member avatar, top-right', trRe('user_menu.account_menu_for').test(label) && hasImg && box.x + box.width > 1200 && box.y < 60,
      { label: tr('user_menu.account_menu_for', { who: '<user>' }), matched: trRe('user_menu.account_menu_for').test(label), hasImg, box })
    await p.screenshot({ path: `${OUT}/signed-in-desktop.png` })
    // keyboard: focus + Enter opens on Settings, ArrowDown -> Set a status (spec 096), Escape closes back to the button
    await trig.focus()
    await p.keyboard.press('Enter')
    await new Promise((r) => setTimeout(r, 300))
    const a1 = await p.evaluate(() => document.activeElement?.getAttribute('data-test'))
    const exp = await trig.evaluate((b) => b.getAttribute('aria-expanded'))
    await p.screenshot({ path: `${OUT}/signed-in-dropdown.png` })
    await p.keyboard.press('ArrowDown')
    const a2 = await p.evaluate(() => document.activeElement?.getAttribute('data-test'))
    await p.keyboard.press('Escape')
    const a3 = await p.evaluate(() => document.activeElement?.getAttribute('data-test'))
    const exp2 = await trig.evaluate((b) => b.getAttribute('aria-expanded'))
    step('keyboard menu button', a1 === 'user-menu-settings' && exp === 'true' && a2 === 'user-menu-status' && a3 === 'user-menu-trigger' && exp2 === 'false',
      { enter: a1, expanded: exp, arrowDown: a2, escape: a3, expandedAfter: exp2 })
    const roles = await p.evaluate(() => [...document.querySelectorAll('[role=menu] [role=menuitem]')].map((e) => e.textContent.trim()))
    step('dropdown items', JSON.stringify(roles) === JSON.stringify([tr('user_menu.settings'), tr('status.set'), tr('user_menu.sign_out')]), { roles })
    // Settings
    await trig.click()
    await p.click('[data-test=user-menu-settings]')
    // specs/023 §3.4: /settings redirects to /settings/profile; a left nav of sections
    await p.waitForSelector('[data-test=settings-profile]', { timeout: 15000 })
    // locale-neutral: the nav is checked by data-test ids, not by its (translated) labels
    const sections = await p.evaluate(() => [...document.querySelectorAll('[data-test=settings-nav] a')].map((a) => a.getAttribute('data-test')))
    const profileUrl = p.url()
    await p.click('[data-test=settings-nav-security]')
    await p.waitForSelector('[data-test=settings-method]', { timeout: 15000 })
    const method = await p.$eval('[data-test=settings-method]', (e) => e.textContent.trim())
    const pwForm = !!(await p.$('[data-test=change-password]'))
    step('settings page', profileUrl.endsWith('/settings/profile') && p.url().endsWith('/settings/security') &&
      sections.includes('settings-nav-language') && sections.includes('settings-nav-keys') && pwForm && method !== '',
      { url: p.url(), profileUrl, sections, method, changePasswordForm: pwForm, xscroll: await xscroll(p) })
    await p.screenshot({ path: `${OUT}/settings-desktop.png`, fullPage: true })
    await p.setViewport({ width: 390, height: 844 })
    await new Promise((r) => setTimeout(r, 500))
    step('settings mobile no x-scroll', (await xscroll(p)) <= 0, { xscroll: await xscroll(p) })
    await p.screenshot({ path: `${OUT}/settings-mobile.png`, fullPage: true })
    await p.goto(BASE + P + '/lobby', { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 20000 })
    await p.click('[data-test=user-menu-trigger]')
    await new Promise((r) => setTimeout(r, 400))
    step('mobile dropdown no x-scroll', (await xscroll(p)) <= 0, { xscroll: await xscroll(p) })
    await p.screenshot({ path: `${OUT}/signed-in-mobile-dropdown.png` })
    // Sign out from the dropdown -> /login, and the corner is the sign-in entry again
    await p.click('[data-test=user-menu-signout]')
    await p.waitForFunction(() => location.pathname.replace(/^\/[a-z]{2}(?=\/)/, '').startsWith('/login'), { timeout: 15000 })
    await p.goto(BASE + P + '/lobby', { waitUntil: 'networkidle2' })
    const back = await p.waitForSelector('[data-test=user-menu-signin]', { timeout: 20000 }).catch(() => null)
    step('sign out from the dropdown', !!back, { url: p.url() })
  }
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
