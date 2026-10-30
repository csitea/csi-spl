// SPL-4423 (HUM-10 19d559a5, after SPL-4400 fixed Calendar) live proof
// against a deployed WUI: signing out from ANY rail section or tab lands on
// the sign-in page, not only on Calendar (signout-calendar-live.proof.mjs).
// Per page: a fresh browser context signs in natively, opens the page, signs
// out (the user menu; Settings: its own Sign out button), then the address
// must settle on /login and never pass through /public-calendar.
// Desktop width for every page, phone width (390 px) for a sample.
// It writes no row, but it signs in and out (a session is made and ended
// per page), so it refuses any BASE whose host is not a dev host.
// Native sign-in allows 10 tries per email per 15 min: the pages are paced
// GAP_MS apart (default 100 s, 9 per 15 min). ONLY=<name,...> runs a subset.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [TOPIC=<task id>] [ONLY=lobby,issues] [GAP_MS=100000] \
//     [SETTLE_MS=4000] [CHROME_PATH=...] [PUPPETEER_CORE=<path>] \
//     node tests/e2e/signout-every-page-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every page PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
if (!new URL(BASE).hostname.split('.').includes('dev')) { console.error(`FATAL BASE=${BASE} is not a dev host: this proof signs in and out, dev only`); process.exit(2) }
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const SETTLE_MS = Number(process.env.SETTLE_MS || 4000)
const GAP_MS = Number(process.env.GAP_MS || 100000)
const ONLY = (process.env.ONLY || '').split(',').map((s) => s.trim()).filter(Boolean)
const DESKTOP = { width: 1280, height: 800 }
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true }

/* name, the address opened, the prefix it must stay under once signed in
   (a section may land on its default tab), the viewport, how to sign out.
   path null = the topic: the first row's topic on #lobby, or TOPIC */
const PAGES = [
  { name: 'lobby', path: '/lobby', under: '/lobby' },
  { name: 'channel', path: '/channel/lobby', under: '/channel/' },
  { name: 'topic', path: null, under: '/t/' },
  { name: 'dm', path: '/dm', under: '/dm' },
  { name: 'issues', path: '/issues', under: '/issues' },
  { name: 'docs', path: '/docs', under: '/docs' },
  { name: 'monitoring', path: '/monitoring', under: '/monitoring' },
  { name: 'reporting', path: '/reporting', under: '/reporting' },
  { name: 'settings', path: '/lobby?settings=security', under: '/lobby', signout: '[data-test=settings-signout]' },
  { name: 'calendar', path: '/calendar', under: '/calendar' },
  { name: 'people', path: '/people', under: '/people' },
  { name: 'notes', path: '/notes', under: '/notes' },
  { name: 'archive', path: '/archive', under: '/archive' },
  { name: 'search', path: '/search', under: '/search' },
  { name: 'tenant-settings', path: '/tenant-settings', under: '/tenant-settings' },
  { name: 'roadmap', path: '/roadmap', under: '/roadmap' },
  { name: 'phone-lobby', path: '/lobby', under: '/lobby', phone: true },
  { name: 'phone-channel', path: '/channel/lobby', under: '/channel/', phone: true },
  { name: 'phone-issues', path: '/issues', under: '/issues', phone: true },
  { name: 'phone-calendar', path: '/calendar', under: '/calendar', phone: true },
].filter((p) => !ONLY.length || ONLY.includes(p.name))

mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
const pathOf = (p) => new URL(p.url()).pathname
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })

/* native sign-in through the form; login = the hub's answer (429 = rate limit) */
async function signIn(p, redirect) {
  let login = 0
  p.on('response', (r) => { if (r.url().includes('/auth/login') && r.request().method() === 'POST') login = r.status() })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=' + encodeURIComponent(redirect), { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const trig = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null)
  return { ok: !!trig, login }
}

/* the topic of the first row on #lobby (already open), unless TOPIC names one */
async function findTopic(p) {
  if (process.env.TOPIC) return '/t/' + process.env.TOPIC
  const id = await p.waitForSelector('[data-task-id]', { timeout: 20000 }).then((a) => a.evaluate((el) => el.getAttribute('data-task-id'))).catch(() => '')
  return id ? '/t/' + id : ''
}

async function signOutOn(page) {
  const name = `${page.name}: sign out -> /login`
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  try {
    await p.setViewport(page.phone ? PHONE : DESKTOP)
    const signed = await signIn(p, page.path || '/channel/lobby')
    if (!signed.ok) return step(name, false, { error: 'sign-in failed', login: signed.login, url: p.url() })
    const path = page.path || await findTopic(p)
    if (!path) return step(name, false, { error: 'no topic row on #lobby: set TOPIC' })
    if (!p.url().includes(path)) await p.goto(BASE + path, { waitUntil: 'networkidle2' })
    await sleep(1500)
    const on = pathOf(p)
    const out = page.signout || '[data-test=user-menu-signout]'
    if (!page.signout) await p.click('[data-test=user-menu-trigger]')
    await p.waitForSelector(out, { visible: true, timeout: 15000 })
    const seen = []
    p.on('framenavigated', (f) => { if (f === p.mainFrame()) seen.push(new URL(f.url()).pathname) })
    await p.click(out)
    await sleep(SETTLE_MS)
    await p.waitForNetworkIdle({ timeout: 15000 }).catch(() => {})
    await p.screenshot({ path: `${OUT}/${page.name}-after-signout.png` })
    const end = pathOf(p)
    const ok = on.includes(page.under) && end.endsWith('/login') && !seen.some((s) => s.endsWith('/public-calendar'))
    step(name, ok, { signedInOn: on, end, navigations: seen, width: page.phone ? PHONE.width : DESKTOP.width })
  } catch (e) {
    step(name, false, { error: String(e && e.message || e), url: p.url() })
  } finally {
    await ctx.close()
  }
}

try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => null)
  console.log('build', JSON.stringify(res.build))
  for (const [i, page] of PAGES.entries()) {
    if (i) await sleep(GAP_MS)
    await signOutOn(page)
  }
} catch (e) {
  step('proof ran', false, { error: String(e && e.stack || e) })
} finally {
  await browser.close()
}
writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
const failed = res.steps.filter((s) => !s.ok).length
console.log(failed ? `\n${failed} FAILED` : `\nall ${res.steps.length} passed`)
process.exit(failed ? 1 : 0)
