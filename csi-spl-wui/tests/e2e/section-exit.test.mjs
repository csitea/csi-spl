// CLE-77886 (HUM-24, csitea 7930dfbf: "няма изход от прозорец "проблеми"" -
// there is no exit from the Issues window). On a desktop a section page
// (Issues, Event log, Archive, People, Agents, Boxes, Help, Workspace
// settings) fills the middle; the rail's Channels / Direct messages only
// swapped the left list, so the page stayed and read as a dead end.
// Now: every section page has the close X (the side Settings -> Behaviour
// picks), which goes back to the conversation the reader left; Channels /
// Direct messages / Flow on the rail bring that conversation back too; Esc
// closes an open issue; browser Back still works. On a phone the section
// strip is the way and no X renders.
//
//   node tests/e2e/section-exit.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/section-exit.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const SESSION = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
const PAGES = [
  { name: 'Issues', tab: '[data-testid=sidebar-tab-issues]', path: '/issues' },
  { name: 'Event log', tab: '[data-testid=sidebar-tab-events]', path: '/events' },
  { name: 'Archive', tab: '[data-testid=sidebar-tab-archive]', path: '/archive' },
  { name: 'People', tab: '[data-testid=sidebar-tab-people]', path: '/people' },
  { name: 'Agents', tab: '[data-testid=sidebar-tab-agents]', path: '/agents' },
  { name: 'Boxes', tab: '[data-testid=sidebar-tab-boxes]', path: '/boxes' },
  { name: 'Help', tab: '[data-testid=help-open]', path: '/help' },
  { name: 'Workspace settings', tab: '[data-testid=tenant-settings-open]', path: '/tenant-settings' },
]
const path = (p) => p.evaluate(() => location.pathname)
const closeX = (p) => p.evaluate(() => [...document.querySelectorAll('.spool-main [data-test=section-close]')]
  .filter((e) => e.getBoundingClientRect().width > 0 && getComputedStyle(e).visibility !== 'hidden').length)
async function go(p, sel, want) {
  await p.evaluate((s) => document.querySelector(s)?.click(), sel)
  if (want) await p.waitForFunction((w) => location.pathname === w || location.pathname.startsWith(w + '/'), { timeout: 15000 }, want).catch(() => null)
  await sleep(700)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((s) => localStorage.setItem('spool.mock.session', JSON.stringify(s)), SESSION)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${srv.base}/channel/feedback`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-testid=sidebar-tab-issues]', { visible: true })
  await sleep(1200)

  for (const s of PAGES) {
    await go(p, s.tab, s.path)
    const here = await path(p)
    const x = await closeX(p)
    ok(`1440 ${s.name}: the page shows exactly one close X`, (here === s.path || here.startsWith(s.path + '/')) && x === 1, { here, x })
    await p.evaluate(() => document.querySelector('.spool-main [data-test=section-close]')?.click())
    await p.waitForFunction(() => location.pathname === '/channel/feedback', { timeout: 15000 }).catch(() => null)
    ok(`1440 ${s.name}: the X goes back to the channel the reader left`, (await path(p)) === '/channel/feedback', await path(p))
  }

  /* the rail's Channels / Flow bring the conversation back */
  await go(p, '[data-testid=sidebar-tab-issues]', '/issues')
  await go(p, '[data-testid=sidebar-tab-channels]', '/channel/feedback')
  ok('1440 Issues -> rail Channels: back in the channel the reader left', (await path(p)) === '/channel/feedback', await path(p))
  await go(p, '[data-testid=sidebar-tab-events]', '/events')
  await go(p, '[data-testid=sidebar-tab-flow]', '/channel/feedback')
  ok('1440 Event log -> rail Flow: back in the last conversation', (await path(p)) === '/channel/feedback', await path(p))

  /* browser Back still leaves the page */
  await go(p, '[data-testid=sidebar-tab-issues]', '/issues')
  await p.goBack()
  await sleep(800)
  ok('1440 browser Back leaves Issues', (await path(p)) !== '/issues', await path(p))

  /* an open issue: Esc closes it, the X on the page is still there */
  await go(p, '[data-testid=sidebar-tab-issues]', '/issues')
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 }).catch(() => null)
  await p.type('[data-test=issues-newrow-title]', 'Exit check')
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-test=issues-row]', { visible: true, timeout: 8000 }).catch(() => null)
  await sleep(600)
  await p.evaluate(() => document.querySelector('[data-test=issues-row] [data-test=issues-row-key], [data-test=issues-row] .issues-key')?.click())
  const opened = await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 8000 }).then(() => true).catch(() => false)
  if (opened) {
    await p.keyboard.press('Escape')
    await sleep(800)
    const gone = await p.evaluate(() => !document.querySelector('[data-test=issues-detail]'))
    ok('1440 Esc closes an open issue, the list stays', gone && (await path(p)) === '/issues', { gone })
  } else {
    ok('1440 an issue opens from its row', false)
  }
  ok('1440 the Issues page keeps its close X with the list', (await closeX(p)) === 1)
  await p.close()

  /* phone: the strip is the way; no X */
  const m = await browser.newPage()
  await m.evaluateOnNewDocument((s) => localStorage.setItem('spool.mock.session', JSON.stringify(s)), SESSION)
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await m.goto(`${srv.base}/issues`, { waitUntil: 'networkidle2' })
  await m.waitForSelector('[data-test=issues-page]', { visible: true })
  await sleep(1000)
  ok('390 no close X on a phone (the section strip is the way)', (await closeX(m)) === 0)
  await m.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nsection-exit: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
