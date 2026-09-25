// The DM list, proved in a REAL browser (owner 2026-09-25):
//
//   "the direct msgs pane shows agents which are not connected .. it should
//    sort the agents and humans so that those which are online should be on
//    the top ... and those to which some msgs have been sent are next"
//   "the right click menu should have the option to delete somebody from the
//    direct msgs list"
//
// Against the mock bundle: every online row sits above every offline one;
// right-click on a DM row opens its menu; "Remove from list" takes the row
// out; a reload keeps it out (this browser's storage), and the other rows stay.
//
// Plant the defect and watch it go red (the proof skips the click, so the
// row is never removed):
//   PROVE_RED=no-hide pnpm run test:e2e:dm-remove
//
// Run:
//   pnpm run test:e2e:dm-remove
//   BASE_URL=<generated bundle> pnpm run test:e2e:dm-remove     # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const RED = process.env.PROVE_RED || ''
const ROWS = '#sidebar-panel-dm a.nav-item[data-key]'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

const dmRows = (p) => p.$$eval(ROWS, (els) => els.map((e) => ({
  key: e.getAttribute('data-key'),
  online: e.getAttribute('data-online') === '1',
})))

async function openDmTab(p) {
  await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: NAV_TIMEOUT })
  await p.click('[data-testid=sidebar-tab-dm]')
  await p.waitForSelector(ROWS, { visible: true, timeout: NAV_TIMEOUT })
  await sleep(300)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => { try { localStorage.removeItem('spool.hidden-dm-peers') } catch {} })
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await openDmTab(p)

  // 1. online above offline
  const before = await dmRows(p)
  const firstOff = before.findIndex((r) => !r.online)
  const lateOn = firstOff < 0 ? -1 : before.findIndex((r, i) => i > firstOff && r.online)
  ok('1 the DM list has rows', before.length >= 2, { n: before.length })
  ok('2 every online peer is above every offline one', lateOn < 0, before)

  // 2. right-click -> menu -> Remove from list
  const target = before[before.length - 1].key
  const rowSel = `#sidebar-panel-dm .nav-row[data-order="${target}"]`
  await p.click(rowSel, { button: 'right' })
  const item = await p.waitForSelector(`${rowSel} [data-testid=sidebar-row-menu-hide]`, { visible: true, timeout: 5000 }).catch(() => null)
  ok('3 right-click opens the row menu with "Remove from list"', Boolean(item), { target })
  if (item && RED !== 'no-hide') await item.click()
  await sleep(400)
  const after = (await dmRows(p)).map((r) => r.key)
  ok('4 the row is gone from the list', !after.includes(target), { target, after })
  ok('5 the other rows stay', after.length === before.length - 1, { before: before.length, after: after.length })

  // 3. a reload keeps it out
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await openDmTab(p)
  const reloaded = (await dmRows(p)).map((r) => r.key)
  ok('6 after a reload the row is still out', !reloaded.includes(target) && reloaded.length === before.length - 1, { reloaded })
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
