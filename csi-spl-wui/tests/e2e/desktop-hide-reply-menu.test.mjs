// HUM-10 (owner, t1 topic 7d9faaad): on the desktop a reply in the topic
// view offers Hide from flow in the right-click menu. It does what a phone's
// swipe left already does: the card leaves, the thicker hidden line stands
// where it was, and a click on that line brings the card back. The topic
// starter has no such item. The new test id is msg-menu-hide-flow.
//
// Against the lde mock (no hub), a 1280x800 desktop, no touch:
//   - a right-click on the starter opens the menu without msg-menu-hide-flow
//   - a right-click on a reply shows msg-menu-hide-flow, labelled Hide from flow
//   - choosing it hides that reply behind the hidden-cards line
//   - clicking the line restores the reply and removes the line
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/desktop-hide-reply-menu.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = '7d9faaad-e1cc-4080-89ed-8eb30d76a217'
const R1 = '7d9faaad-e1cc-4080-89ed-8eb30d76a211'
const row = (msg_id, min, body, is_parent) => ({
  v: 1, msg_id, task_id: TASK, ts: `2026-10-04T10:0${min}:00Z`, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent, files: [],
})
const EXTRA = [
  row(TASK, 0, 'hide-flow topic starter', 1),
  row(R1, 1, 'hide-flow reply one', 0),
]

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const card = (id) => `.topic article.msg[data-msg-id="${id}"]`
const line = '[data-testid=hidden-cards-line]'
const hideItem = '[data-testid=msg-menu-hide-flow]'
const has = (p, sel) => p.evaluate((sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length)), sel)

async function rightClick(p, sel) {
  return p.evaluate((sel) => {
    const el = document.querySelector(sel)
    if (!el) return false
    el.scrollIntoView({ block: 'center' })
    const r = el.getBoundingClientRect()
    el.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true, cancelable: true, view: window,
      clientX: Math.round(r.left + r.width / 2),
      clientY: Math.round(r.top + Math.min(20, r.height / 2)),
      button: 2, buttons: 2,
    }))
    return true
  }, sel)
}

async function openTopic(p) {
  await p.goto(`${srv.base}/channel/alerts?topic=${TASK}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  return p.waitForSelector(card(TASK), { visible: true, timeout: 15000 }).then(() => true, () => false)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
    } catch { /* private mode */ }
  }, EXTRA)
  await p.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.evaluate(() => { try { localStorage.removeItem('spool.hidden-cards') } catch { /* */ } })

  ok('the topic view opens with its starter and reply', (await openTopic(p)) && (await until(p, (s) => Boolean(document.querySelector(s)), card(R1), 8000)))
  await sleep(400)

  ok('a right-click on the starter opens its menu', (await rightClick(p, `${card(TASK)} .msg-body`)) && (await p.waitForSelector('[data-testid=msg-menu]', { visible: true, timeout: 5000 }).then(() => true, () => false)))
  const starterItems = await p.$$eval('[data-testid=msg-menu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-testid')))
  ok('the starter menu has no msg-menu-hide-flow', !starterItems.includes('msg-menu-hide-flow'), starterItems)
  await p.keyboard.press('Escape')
  await p.waitForSelector('[data-testid=msg-menu]', { hidden: true, timeout: 5000 }).catch(() => {})

  ok('a right-click on the reply opens its menu', (await rightClick(p, `${card(R1)} .msg-body`)) && (await p.waitForSelector(hideItem, { visible: true, timeout: 5000 }).then(() => true, () => false)))
  const present = await p.$eval(hideItem, (el) => ({
    id: el.getAttribute('data-testid'),
    label: el.textContent.trim(),
    icon: Boolean(el.querySelector('svg')),
  })).catch(() => null)
  ok('msg-menu-hide-flow is present, labelled Hide from flow, with its icon', present && present.id === 'msg-menu-hide-flow' && present.label === 'Hide from flow' && present.icon, present)
  await p.click(hideItem)
  ok('clicking msg-menu-hide-flow hides the reply', await until(p, (s) => ![...document.querySelectorAll(s)].some((e) => e.getClientRects().length), card(R1), 4000))
  await sleep(200)
  ok('the hidden line stands in its place and the starter stays', (await has(p, `.topic ${line}`)) && (await has(p, card(TASK))) && !(await has(p, '[data-testid=archive-toast]')))
  await p.click(`.topic ${line}`)
  ok('clicking the hidden line restores the reply', await until(p, (s) => Boolean([...document.querySelectorAll(s)].find((e) => e.getClientRects().length)), card(R1), 4000))
  await sleep(200)
  ok('the hidden line is gone', !(await has(p, `.topic ${line}`)))

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ndesktop-hide-reply-menu: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
