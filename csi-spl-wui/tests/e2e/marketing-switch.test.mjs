// The workspace marketing switch (spec 090 §15; owner HUM-10, t1 f0c3927e
// msg 37bcb88b item 4), proved in a REAL browser against the mock bundle
// (tenant-settings-mock.mjs: the mock workspace is allow-listed, its admin
// is HUM-1):
//   1. Tenant settings -> General shows the toggle to the admin, OFF by
//      default (owner msg 5cd2e544: nothing posts until an admin turns it on);
//   2. the admin turns it on, then off again;
//   3. CONTROL: a workspace outside the cnf allow-list (the mock answers 404,
//      as the hub does) shows no toggle at all, while General still renders.
// The hub half (403 for a non-admin, 404 off the allow-list) is
// TestMarketingSwitch in csi-spl-api/.../hub/marketing_switch_test.go.
//
// Plant the defect and watch step 3 go red (the unlisted flag is not set):
//   PROVE_RED=listed node tests/e2e/marketing-switch.test.mjs
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e marketing-switch
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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

const TOGGLE = '[data-test=tenant-marketing-toggle]'
const checked = (p) => p.$eval(TOGGLE, (e) => e.checked)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  // the mock is signed out by default: sign in as its admin (tenant-settings.test.mjs)
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => localStorage.setItem('spool.mock.session',
    JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' })))
  await p.goto(server.base + '/tenant-settings/general', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })

  // 1. the admin of an allow-listed workspace sees the toggle, off
  await p.waitForSelector(TOGGLE, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const shown = Boolean(await p.$(TOGGLE))
  ok('1 General shows the marketing toggle to the admin, off by default', shown && !(await checked(p)), { shown })

  // 2. on, then off again
  if (shown) {
    await p.click(TOGGLE)
    await p.waitForFunction((s) => document.querySelector(s)?.checked === true && !document.querySelector(s)?.disabled, { timeout: 5000 }, TOGGLE).catch(() => null)
    ok('2 the admin turns marketing on', await checked(p))
    await p.click(TOGGLE)
    await p.waitForFunction((s) => document.querySelector(s)?.checked === false && !document.querySelector(s)?.disabled, { timeout: 5000 }, TOGGLE).catch(() => null)
    ok('2b and off again', !(await checked(p)) && !(await p.$('[data-test=tenant-marketing-error]')))
  }

  // 3. CONTROL: outside the allow-list there is no toggle, General still renders
  if (RED !== 'listed') await p.evaluate(() => localStorage.setItem('spool.mock.marketing', 'unlisted'))
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=tenant-general-name]', { visible: true, timeout: NAV_TIMEOUT })
  await new Promise((r) => setTimeout(r, 500))
  ok('3 CONTROL: a workspace off the allow-list shows no toggle', !(await p.$('[data-test=tenant-settings-marketing]')))
  ok('4 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
