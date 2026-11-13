// CLE-77886 (HUM-24, csitea 7930dfbf: "няма изход от прозорец "проблеми"" -
// there is no exit from the Issues window). On a desktop a section page
// (Issues, Event log, Archive, People, Agents, Boxes, Help, Workspace
// settings) fills the middle; the rail's Channels / Direct messages only
// swapped the left list, so the page stayed and read as a dead end.
// Now: no section page has a close X (owner HUM-10, t1 fc38e637 msg d93462e4:
// "the users should use only the left sections bar to navigate"; SPL-5396,
// SPL-5425, then SPL-5467 for every other view). Channels / Direct messages /
// Flow on the rail bring the conversation the reader left back; Esc closes an
// open issue; browser Back still works. On a phone the section strip is the
// way.
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
/* title: what the page still draws in its header once the X is gone */
const PAGES = [
  { name: 'Issues', tab: '[data-testid=sidebar-tab-issues]', path: '/issues', title: '[data-test=issues-heading]' },
  { name: 'Archive', tab: '[data-testid=sidebar-tab-archive]', path: '/archive', title: '[data-test=archive-page] .archive-title' },
  { name: 'People', tab: '[data-testid=sidebar-tab-people]', path: '/people', title: '[data-test=people-index] .feed-header h2' },
  /* SPL-2075: Agents and Boxes are Monitoring's tabs now; SPL-3250 the Event log too.
     SPL-5396: Monitoring has no X; it closes on another section (below) */
  { name: 'Help', tab: '[data-testid=help-open]', path: '/help', title: '#help-h' },
  { name: 'Workspace settings', tab: '[data-testid=tenant-settings-open]', path: '/tenant-settings', title: '#tenant-settings-h' },
]
/* the other views that had the X, each opened in the app by the router */
const VIEWS = [
  { name: 'Docs', path: '/docs/README.md', title: '#docs-h' },
  { name: 'Embed', path: '/embed', title: '#embed-admin-h' },
  { name: 'Expenses', path: '/expenses', title: '[data-test=expenses-heading]' },
  { name: 'Goal', path: '/goals/G01', title: '[data-test=goal-heading]' },
  { name: 'Notes', path: '/notes', title: '[data-test=notes-heading]' },
  { name: 'Reporting', path: '/reporting', title: '[data-test=reporting-heading]' },
  { name: 'Roadmap', path: '/roadmap', title: '[data-test=roadmap-heading]' },
  { name: 'Calendar', path: '/calendar', title: '[data-test=calendar-view-tabs] [data-test=calendar-range]' },
]
const path = (p) => p.evaluate(() => location.pathname)
const closeX = (p) => p.evaluate(() => [...document.querySelectorAll('.spool-main [data-test=section-close]')]
  .filter((e) => e.getBoundingClientRect().width > 0 && getComputedStyle(e).visibility !== 'hidden').length)
const shown = (p, sel) => p.evaluate((s) => (document.querySelector(s)?.getBoundingClientRect().width || 0) > 0, sel)
/** Read until want() holds on the SAME value for `hold` ms, or `max` runs out;
    returns the last read. */
async function until(read, want = () => true, hold = 300, max = 8000) {
  const end = Date.now() + max
  let key = ''
  let since = 0
  let v = await read()
  while (Date.now() < end) {
    const k = want(v) ? JSON.stringify(v) ?? 'undefined' : ''
    if (!k) { key = ''; since = 0 } else if (k !== key) { key = k; since = Date.now() } else if (Date.now() - since >= hold) return v
    await sleep(100)
    v = await read()
  }
  return v
}

async function go(p, sel, want) {
  await p.evaluate((s) => document.querySelector(s)?.click(), sel)
  if (want) await p.waitForFunction((w) => location.pathname === w || location.pathname.startsWith(w + '/'), { timeout: 15000 }, want).catch(() => null)
  /* the route has landed and holds, and the page under it has drawn its X (or not) */
  await until(() => p.evaluate(() => [location.pathname, document.querySelectorAll('.spool-main [data-test=section-close]').length]))
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
  await until(() => p.evaluate(() => location.pathname), (v) => v === '/channel/feedback')

  /* SPL-5467 (owner HUM-10, t1 fc38e637 msg d93462e4: "remove the closing x
     from this view - it is not needed and it is confusing ... the users should
     use only the left sections bar to navigate"): no section has the X, its
     title still renders. CONTROL: on cb23af0cc every one but Issues FAILS. */
  for (const s of PAGES) {
    await go(p, s.tab, s.path)
    await p.waitForSelector(s.title, { visible: true, timeout: 8000 }).catch(() => null)
    const here = await path(p)
    const ev = { here, x: await closeX(p), title: await shown(p, s.title) }
    ok(`1440 ${s.name}: no close X, the title renders`, (here === s.path || here.startsWith(s.path + '/')) && ev.x === 0 && ev.title, ev)
    await go(p, '[data-testid=sidebar-tab-channels]', '/channel/feedback')
    ok(`1440 ${s.name} -> rail Channels: back in the channel the reader left`, (await path(p)) === '/channel/feedback', await path(p))
  }

  /* SPL-5425: the Issues header keeps the rest */
  await go(p, '[data-testid=sidebar-tab-issues]', '/issues')
  const iss = await path(p)
  const issX = await p.evaluate(() => document.querySelectorAll('[data-test=issues-page] .issues-head [data-test=section-close]').length)
  ok('1440 Issues: no close X in the header (SPL-5425)', iss === '/issues' && issX === 0 && (await closeX(p)) === 0, { iss, issX, x: await closeX(p) })
  /* the header keeps its title, + and view toggles */
  const kept = await p.evaluate(() => ['issues-heading', 'issues-new', 'issues-views'].filter((t) => document.querySelector(`.issues-head [data-test=${t}]`)?.getBoundingClientRect().width > 0))
  ok('1440 Issues: the header keeps its title, + and view toggles', kept.length === 3, kept)

  /* SPL-5396 (owner HUM-10, t1 9d0d51e9: "the close button ( the x ) is not
     needed, it should [close] whenever one clicks on any other section in the
     section panel"). CONTROL: on master Monitoring draws an X, so the first FAILS there. */
  await go(p, '[data-testid=sidebar-tab-monitoring]', '/monitoring')
  const mon = await path(p)
  ok('1440 Monitoring: no close X on the page (SPL-5396)', mon.startsWith('/monitoring') && (await closeX(p)) === 0, { mon, x: await closeX(p) })
  for (const s of PAGES.filter((q) => q.tab.includes('sidebar-tab-'))) {
    await go(p, '[data-testid=sidebar-tab-monitoring]', '/monitoring')
    await go(p, s.tab, s.path)
    const here = await path(p)
    const left = await p.evaluate(() => !document.querySelector('[data-test=monitoring-page]'))
    ok(`1440 Monitoring -> rail ${s.name}: Monitoring is closed, ${s.name} open`, left && (here === s.path || here.startsWith(s.path + '/')), { here, left })
  }
  await go(p, '[data-testid=sidebar-tab-monitoring]', '/monitoring')
  await go(p, '[data-testid=sidebar-tab-channels]', '/channel/feedback')
  ok('1440 Monitoring -> rail Channels: back in the channel the reader left', (await path(p)) === '/channel/feedback', await path(p))

  /* the rail's Channels / Flow bring the conversation back */
  await go(p, '[data-testid=sidebar-tab-issues]', '/issues')
  await go(p, '[data-testid=sidebar-tab-channels]', '/channel/feedback')
  ok('1440 Issues -> rail Channels: back in the channel the reader left', (await path(p)) === '/channel/feedback', await path(p))
  await go(p, '[data-testid=sidebar-tab-archive]', '/archive')
  await go(p, '[data-testid=sidebar-tab-flow]', '/channel/feedback')
  ok('1440 Archive -> rail Flow: back in the last conversation', (await path(p)) === '/channel/feedback', await path(p))

  /* browser Back still leaves the page */
  await go(p, '[data-testid=sidebar-tab-issues]', '/issues')
  await p.goBack()
  /* the route moved off /issues and holds (staying there times out and fails) */
  await until(() => path(p), (v) => v !== '/issues', 300, 5000)
  ok('1440 browser Back leaves Issues', (await path(p)) !== '/issues', await path(p))

  /* an open issue: Esc closes it, the X on the page is still there */
  await go(p, '[data-testid=sidebar-tab-issues]', '/issues')
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 }).catch(() => null)
  await p.type('[data-test=issues-newrow-title]', 'Exit check')
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-test=issues-row]', { visible: true, timeout: 8000 }).catch(() => null)
  await until(() => p.evaluate(() => document.querySelectorAll('[data-test=issues-row]').length), (n) => n > 0)
  await p.evaluate(() => document.querySelector('[data-test=issues-row] [data-test=issues-row-key], [data-test=issues-row] .issues-key')?.click())
  const opened = await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 8000 }).then(() => true).catch(() => false)
  if (opened) {
    await p.keyboard.press('Escape')
    /* the detail is gone and stays gone (an Esc that does nothing times out) */
    const gone = await until(() => p.evaluate(() => !document.querySelector('[data-test=issues-detail]')), Boolean, 300, 5000)
    ok('1440 Esc closes an open issue, the list stays', gone && (await path(p)) === '/issues', { gone })
  } else {
    ok('1440 an issue opens from its row', false)
  }
  ok('1440 the Issues page still has no close X with the list (SPL-5425)', (await closeX(p)) === 0)
  await p.close()

  /* phone: the strip is the way; no X */
  const m = await browser.newPage()
  await m.evaluateOnNewDocument((s) => localStorage.setItem('spool.mock.session', JSON.stringify(s)), SESSION)
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await m.goto(`${srv.base}/issues`, { waitUntil: 'networkidle2' })
  await m.waitForSelector('[data-test=issues-page]', { visible: true })
  /* the page has drawn and holds still before counting what it lacks */
  await until(() => m.evaluate(() => document.querySelector('[data-test=issues-page]')?.innerHTML.length || 0), (n) => n > 0)
  ok('390 no close X on a phone (the section strip is the way)', (await closeX(m)) === 0)
  await m.close()

  /* SPL-5467: the other views, desktop. Each opens from the channel by the
     router (what a link calls), so the rail's Channels then has the
     conversation to go back to: with the X gone it is the way out.
     CONTROL: on cb23af0cc each view draws an X, and Embed, Goal and Roadmap
     stay put on Channels. */
  const v = await browser.newPage()
  v.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await v.evaluateOnNewDocument((s) => localStorage.setItem('spool.mock.session', JSON.stringify(s)), SESSION)
  await v.setViewport({ width: 1440, height: 900 })
  await v.goto(`${srv.base}/channel/feedback`, { waitUntil: 'networkidle2' })
  await v.waitForSelector('[data-testid=sidebar-tab-channels]', { visible: true })
  await until(() => path(v), (w) => w === '/channel/feedback')
  for (const s of VIEWS) {
    await v.evaluate((to) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to), s.path)
    await v.waitForSelector(s.title, { visible: true, timeout: 8000 }).catch(() => null)
    /* the page has drawn and holds still before counting what it lacks */
    await until(() => v.evaluate(() => [location.pathname, document.querySelectorAll('.spool-main [data-test=section-close]').length]))
    const ev = { here: await path(v), x: await closeX(v), title: await shown(v, s.title) }
    ok(`1440 ${s.name}: no close X, the title renders (SPL-5467)`, ev.here.startsWith(s.path) && ev.x === 0 && ev.title, ev)
    await go(v, '[data-testid=sidebar-tab-channels]', '/channel/feedback')
    ok(`1440 ${s.name} -> rail Channels: back in the channel the reader left`, (await path(v)) === '/channel/feedback', await path(v))
  }
  await v.close()
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
