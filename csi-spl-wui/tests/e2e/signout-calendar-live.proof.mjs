// HUM-24 (71e852ab, SPL-4400) live proof against a deployed WUI: signing out
// while on Calendar lands on the sign-in page, not the public calendar
// (pages/calendar.vue, utils/public-calendar.mjs signedOutCalendarTarget).
// The mock bundle never signs out, so the CI e2e cannot drive this door.
//   1. control: a fresh browser (never signed in) opening /calendar lands on
//      /public-calendar (HUM-10 t1 ef57739c, kept)
//   2. native sign-in, /calendar, Sign out from the user menu: the address
//      settles on /login, never /public-calendar
// It reads only: no row is written.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [SETTLE_MS=4000] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/signout-calendar-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const SETTLE_MS = Number(process.env.SETTLE_MS || 4000)
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const path = (p) => new URL(p.url()).pathname
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => null)

  const anon = await browser.createBrowserContext()
  const a = await anon.newPage()
  await a.goto(BASE + '/calendar', { waitUntil: 'networkidle2' })
  await a.waitForSelector('[data-test=public-calendar-heading]', { timeout: 30000 }).catch(() => null)
  step('control: never signed in, /calendar -> /public-calendar', path(a).endsWith('/public-calendar'), { url: a.url() })
  await anon.close()

  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent('/calendar'), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  if (!path(p).endsWith('/calendar')) await p.goto(BASE + '/calendar', { waitUntil: 'networkidle2' })
  const main = await p.waitForSelector('[data-test=calendar-main]', { timeout: 30000 }).catch(() => null)
  step('signed in, on /calendar', !!trig && !!main && path(p).endsWith('/calendar'), { url: p.url() })
  await p.screenshot({ path: `${OUT}/signed-in-calendar.png` })

  await p.click('[data-test=user-menu-trigger]')
  await p.waitForSelector('[data-test=user-menu-signout]', { visible: true, timeout: 10000 })
  const seen = []
  p.on('framenavigated', (f) => { if (f === p.mainFrame()) seen.push(new URL(f.url()).pathname) })
  await p.click('[data-test=user-menu-signout]')
  await sleep(SETTLE_MS)
  await p.waitForNetworkIdle({ timeout: 15000 }).catch(() => {})
  await p.screenshot({ path: `${OUT}/after-signout.png` })
  step('sign out on /calendar -> the sign-in page', path(p).endsWith('/login'), { url: p.url(), navigations: seen })
  step('sign out never passes through /public-calendar', !seen.some((s) => s.endsWith('/public-calendar')), { navigations: seen })
  await ctx.close()
} catch (e) {
  step('proof ran', false, { error: String(e && e.stack || e) })
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
const failed = res.steps.filter((s) => !s.ok).length
console.log(failed ? `\n${failed} FAILED` : '\nall passed')
process.exit(failed ? 1 : 0)
