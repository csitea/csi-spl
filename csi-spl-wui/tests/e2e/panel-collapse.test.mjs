// Spec 050 (owner, prd t1 topic d2c03bc9, 2026-09-29): a triangle at the BOTTOM
// corner of each of the 3 vertical panels — channels (left), the topic/messages
// feed (middle), and the thread pane (right) — collapses that panel to a thin
// strip and expands it back. In a real browser, the mock tenant; the fake hub's
// GET /session carries close_buttons so the Win/Mac corner and a reload can be
// proven.
//   D  default (mac): a toggle in each panel's BOTTOM-left corner (start side)
//   C  collapse/expand channels: the sidebar becomes a ~16px strip and back,
//      aria-expanded flips, its content hides
//   T  the middle (topic) feed collapses too (owner: all 3 panels)
//   H  the thread pane collapses AND keeps its header close X (collapse != close)
//   P  the collapsed state survives a reload (localStorage spool.pane-collapsed)
//   W  windows style: the toggle moves to the bottom-RIGHT corner (end side)
//   R  Hebrew: <html dir=rtl>, the toggle still renders (the glyph mirrors via
//      CSS logical borders)
//
//   node tests/e2e/panel-collapse.test.mjs
//   BASE_URL=<generated bundle> OUT=/tmp/shots node tests/e2e/panel-collapse.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const DESKTOP = { name: '1440', width: 1440, height: 900 }

/* the one stored value the fake hub keeps (undefined = never picked = mac) */
let stored

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  const cors = { 'access-control-allow-origin': new URL(server.base).origin, 'access-control-allow-credentials': 'true' }
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    const u = req.url()
    if (req.method() === 'PUT' && u.includes('/api/v1/auth/preferences')) {
      const body = JSON.parse(req.postData() || '{}')
      if ('close_buttons' in body) stored = body.close_buttons
      return req.respond({ status: 200, contentType: 'application/json', headers: cors, body: JSON.stringify(body) })
    }
    if (req.method() === 'GET' && u.includes('/api/v1/auth/session')) {
      const claims = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', close_buttons: stored ?? null }
      return req.respond({ status: 200, contentType: 'application/json', headers: cors, body: JSON.stringify(claims) })
    }
    return req.continue()
  })

  const load = async (path) => {
    await setPageViewport(p, DESKTOP)
    await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, DESKTOP)
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
    await sleep(600)
  }
  const shot = (name) => (OUT ? p.screenshot({ path: `${OUT}/panel-collapse-${name}.png` }) : null)

  /* a toggle's placement + its panel's width + whether the panel's non-toggle
     content is visible right now */
  const paneState = (paneSel, toggleSel) => p.evaluate((paneSel, toggleSel) => {
    const pane = document.querySelector(paneSel)
    const btn = pane?.querySelector(toggleSel)
    if (!pane || !btn) return { found: false }
    const pr = pane.getBoundingClientRect()
    const br = btn.getBoundingClientRect()
    /* a direct-child of the pane that is NOT the toggle, and whether it shows */
    const content = [...pane.children].find((el) => el !== btn)
    const contentShown = Boolean(content && content.getBoundingClientRect().width > 0 && getComputedStyle(content).display !== 'none')
    return {
      found: true,
      width: Math.round(pr.width),
      expanded: btn.getAttribute('aria-expanded'),
      side: btn.getAttribute('data-collapse-side'),
      /* the toggle centre in the bottom half + the left/right half of its pane */
      bottom: br.top + br.height / 2 > pr.top + pr.height / 2,
      left: br.left + br.width / 2 < pr.left + pr.width / 2,
      contentShown,
    }
  }, paneSel, toggleSel)

  const clickToggle = async (paneName) => {
    await p.click(`[data-test=pane-collapse-${paneName}]`)
    await sleep(400)
  }
  const openThread = async () => {
    const r = await p.evaluate((id) => {
      const topic = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('topic')
      if (!topic) return 'no-store'
      topic.openTopic(id)
      return 'ok'
    }, TASK)
    await p.waitForSelector('[data-test=topic-section] header', { visible: true, timeout: 5000 }).catch(() => {})
    await sleep(500)
    return r
  }

  /* D: default mac = the toggles in the bottom-LEFT (start) corner */
  await load('/channel/lobby')
  let s = await paneState('.sidebar', '[data-test=pane-collapse-channels]')
  ok('D1 channels toggle: bottom-left corner, start side, expanded', s.found && s.bottom && s.left && s.side === 'start' && s.expanded === 'true', s)
  let m = await paneState('.spool-main', '[data-test=pane-collapse-topic]')
  ok('D2 middle toggle: bottom-left corner, start side, expanded', m.found && m.bottom && m.left && m.side === 'start' && m.expanded === 'true', m)
  await shot('1440-mac-open')

  /* C: collapse then expand the channels sidebar */
  const openW = s.width
  await clickToggle('channels')
  s = await paneState('.sidebar', '[data-test=pane-collapse-channels]')
  ok('C1 collapsed: the sidebar is a thin strip, aria-expanded=false, content hidden', s.width <= 30 && s.expanded === 'false' && s.contentShown === false, { ...s, openW })
  await shot('1440-mac-channels-collapsed')
  await clickToggle('channels')
  s = await paneState('.sidebar', '[data-test=pane-collapse-channels]')
  ok('C2 expanded again: the sidebar is back to a full width, aria-expanded=true', s.width > 100 && s.expanded === 'true' && s.contentShown === true, s)

  /* T: the middle (topic/messages) feed collapses too */
  await clickToggle('topic')
  m = await paneState('.spool-main', '[data-test=pane-collapse-topic]')
  ok('T1 the middle feed collapses to a strip', m.width <= 30 && m.expanded === 'false' && m.contentShown === false, m)
  await clickToggle('topic')
  m = await paneState('.spool-main', '[data-test=pane-collapse-topic]')
  ok('T2 the middle feed expands again', m.width > 100 && m.expanded === 'true', m)

  /* H: the thread pane collapses AND keeps its header close X (collapse != close) */
  ok('H0 open a thread', (await openThread()) === 'ok')
  let h = await paneState('.topic', '[data-test=pane-collapse-threads]')
  ok('H1 thread toggle present, expanded', h.found && h.bottom && h.expanded === 'true', h)
  await clickToggle('threads')
  h = await paneState('.topic', '[data-test=pane-collapse-threads]')
  const xStill = await p.evaluate(() => Boolean(document.querySelector('[data-test=topic-pane-close]')))
  ok('H2 thread collapses to a strip but the topic (and its close X) stay', h.width <= 30 && h.expanded === 'false' && xStill === true, { ...h, xStill })
  await clickToggle('threads')

  /* P: the collapsed state survives a reload */
  await clickToggle('channels')
  await load('/channel/lobby')
  s = await paneState('.sidebar', '[data-test=pane-collapse-channels]')
  ok('P1 after a reload the sidebar is still collapsed', s.width <= 30 && s.expanded === 'false', s)
  await clickToggle('channels') // leave it open for the next case
  s = await paneState('.sidebar', '[data-test=pane-collapse-channels]')
  ok('P2 re-expanded', s.expanded === 'true', s)

  /* W: windows style moves the toggle to the bottom-RIGHT (end) corner */
  stored = 'windows'
  await load('/channel/lobby')
  s = await paneState('.sidebar', '[data-test=pane-collapse-channels]')
  ok('W1 windows: the channels toggle is bottom-right, end side', s.found && s.bottom && !s.left && s.side === 'end', s)
  await shot('1440-windows-open')
  stored = 'mac'

  /* R: Hebrew is RTL; the toggle renders (its glyph mirrors via CSS) */
  await load('/he/channel/lobby')
  const dir = await p.evaluate(() => document.documentElement.getAttribute('dir'))
  const rtlToggle = await paneState('.sidebar', '[data-test=pane-collapse-channels]')
  ok('R1 he locale: <html dir=rtl> and the channels toggle renders', dir === 'rtl' && rtlToggle.found, { dir, found: rtlToggle.found })
  await shot('1440-he-rtl')

  ok('no page errors', errors.length === 0, errors.slice(0, 3))
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\npanel-collapse: ${results.length - failed.length}/${results.length} OK`)
process.exit(failed.length ? 1 : 0)
