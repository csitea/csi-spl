// specs/054 (owner 18597eaa): admin "act as a user" via a temporary clone,
// proved in a REAL browser. The owner's flow: the avatar menu has "Act as…"
// above Sign out; it opens a small dialog with a searchable drop-down of
// eligible members; picking one and confirming signs this browser in AS the
// clone (the "Acting as X" banner shows on every route); "Stop" is a SIGN-OUT
// that ends the clone and lands on the login page.
//
// The mock has no hub, so an OPT-IN act-as mock (src/utils/act-as-mock.mjs)
// stands in for the hub's cookie swap: actAsStart records it, me() reports
// act_as from it, actAsExit clears it. It is absent for every other spec, so
// they are untouched.
//
// Run:
//   pnpm run test:e2e:act-as
//   BASE_URL=<generated bundle> pnpm run test:e2e:act-as     # what CI does
//   SHOTS=/var/tmp/shots pnpm run test:e2e:act-as            # write screenshots
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
if (SHOTS) mkdirSync(SHOTS, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const shot = async (p, name) => { if (SHOTS) await p.screenshot({ path: join(SHOTS, name) }) }
const shown = (p, sel) => p.$eval(sel, (e) => !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length)).catch(() => false)
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => '')

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  // Opt into a signed-in mock session (set once; it persists across the reloads
  // below and is cleared by the sign-out). The other e2e specs never set it, so
  // the mock stays signed-out for them. localStorage, not evaluateOnNewDocument,
  // so the post-sign-out /login load is NOT re-seeded.
  await p.evaluate(() => localStorage.setItem('spool.mock.session',
    JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' })))
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })

  // 1. the avatar menu has "Act as…" directly above Sign out (admin, not acting)
  await p.waitForSelector('[data-test=user-menu-trigger]', { visible: true, timeout: NAV_TIMEOUT })
  await p.click('[data-test=user-menu-trigger]')
  await p.waitForSelector('[data-test=user-menu-act-as]', { visible: true, timeout: 5000 })
  const order = await p.$$eval('[data-test=user-menu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-test')))
  const aboveSignOut = order.indexOf('user-menu-act-as') >= 0 && order.indexOf('user-menu-act-as') === order.indexOf('user-menu-signout') - 1
  ok('1 "Act as…" is in the avatar menu directly above Sign out', aboveSignOut, order)
  await shot(p, 'act-as-menu.png')

  // 2. it opens the picker dialog with a searchable member drop-down
  await p.click('[data-test=user-menu-act-as]')
  await p.waitForSelector('[data-test=act-as-select]', { visible: true, timeout: 5000 })
  ok('2 the picker dialog opens with a search box and a drop-down', (await shown(p, '[data-test=act-as-search]')) && (await shown(p, '[data-test=act-as-select]')))
  const opts = await p.$$eval('[data-test=act-as-select] option', (els) => els.map((e) => e.value))
  // the ceiling: you (HUM-1) and the owner (HUM-2) are not offered; a developer
  // and a tester are.
  ok('3 the drop-down excludes yourself and the owner, offers eligible members',
    opts.includes('HUM-3') && opts.includes('HUM-12') && !opts.includes('HUM-1') && !opts.includes('HUM-2'), opts)
  await shot(p, 'act-as-picker.png')

  // 3. pick a member and confirm -> the browser reloads AS the clone
  await p.select('[data-test=act-as-select]', 'HUM-3')
  await Promise.all([
    p.waitForNavigation({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => null),
    p.click('[data-test=act-as-confirm]'),
  ])
  await p.waitForSelector('[data-test=actas-banner]', { visible: true, timeout: NAV_TIMEOUT })
  const banner = await text(p, '[data-test=actas-banner]')
  ok('4 after confirm, the "Acting as X" banner shows the target', /Dev One/.test(banner), { banner })
  await shot(p, 'act-as-banner.png')

  // specs/054 (owner 18597eaa "no of course"): the clone never sees the
  // person's DMs — the DM rail tab is absent while acting (the hub also 403s
  // every DM endpoint for a clone).
  const dmTab = await p.$('[data-testid=sidebar-tab-dm]')
  ok('4b the DM rail tab is absent while acting', dmTab === null)

  // 4. while acting, the menu offers "Stop acting as X" and no "Act as…"
  await p.click('[data-test=user-menu-trigger]')
  await p.waitForSelector('[data-test=user-menu-stop-acting]', { visible: true, timeout: 5000 })
  ok('5 while acting: "Stop acting as X" is offered, "Act as…" is not',
    (await shown(p, '[data-test=user-menu-stop-acting]')) && !(await p.$('[data-test=user-menu-act-as]')))
  await p.keyboard.press('Escape')

  // 5. Stop (the banner button) is a sign-out -> the login page
  await p.waitForSelector('[data-test=actas-stop]', { visible: true, timeout: 5000 })
  await Promise.all([
    p.waitForNavigation({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => null),
    p.click('[data-test=actas-stop]'),
  ])
  await p.waitForFunction(() => /\/login(\?|$)/.test(location.pathname + location.search), { timeout: NAV_TIMEOUT }).catch(() => null)
  ok('6 Stop signs out and lands on the login page', /\/login(\?|$)/.test(new URL(p.url()).pathname + new URL(p.url()).search), p.url())
  ok('7 the banner is gone on the login page', !(await p.$('[data-test=actas-banner]')))
  ok('8 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `act-as: ${failed.length} FAILED` : 'act-as: all OK')
if (failed.length) process.exitCode = 1
