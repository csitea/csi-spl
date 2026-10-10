// HUM-24 (t1 cd9b0f47): with the discussion open, the topic's options do not
// open from the menu. The middle card's menu still has them. The opener card
// in the topic pane opened a message menu (Open, Copy link, Edit, Delete)
// and hid Archive, Delete the topic, Move to channel and Merge into topic.
// A non-admin member (developer, policy everyone) on their own topic must see
// those four enabled. On someone else's topic the same four stay listed, the
// ones they may not use disabled with the reason (CLE-77891), never dropped.
// A reply in the same pane keeps a message menu. Desktop and phone: on a
// phone the middle pane is hidden, so the pane is the only menu.
// HUM-10 (owner, t1 7de82b71): in the pane Archive topic is on the LATEST
// message only - here the reply, not the opener (topic-archive-latest-only).
//
// Run:
//   node tests/e2e/topic-menu-open-pane.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/topic-menu-open-pane.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'cd9b0f47-a5cb-4a5e-bc92-c3723aecba67'
const R1 = 'cd9b0f47-a5cb-4a5e-bc92-c3723aecba61'
const OTHER_TASK = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
const OTHER = '66666666-6666-4666-8666-666666666666'
const TOPIC_IDS = ['msg-menu-move-channel', 'msg-menu-merge-topic', 'msg-menu-archive', 'msg-menu-delete-topic']
/* the pane's opener of a topic with a reply: the topic options but Archive */
const OPENER_IDS = TOPIC_IDS.filter((id) => id !== 'msg-menu-archive')

const row = (msg_id, min, body, is_parent) => ({
  v: 1, msg_id, task_id: TASK, ts: `2026-10-04T10:0${min}:00Z`, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent, files: [],
})
const EXTRA = [
  row(TASK, 0, 'topic menu opener while the discussion is open', 1),
  row(R1, 1, 'a reply in the open discussion', 0),
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

const paneCard = (id) => `aside.topic article.msg[data-msg-id="${id}"]`
const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`

async function menuItems(p, sel) {
  await p.keyboard.press('Escape').catch(() => {})
  await sleep(120)
  const opened = await p.evaluate((sel) => {
    const el = document.querySelector(sel)
    if (!el || !el.getClientRects().length) return false
    el.click()
    return true
  }, sel)
  if (!opened) return null
  for (let t = 0; t < 25; t++) {
    await sleep(80)
    const items = await p.evaluate(() => {
      const m = document.querySelector('[data-testid=msg-menu]')
      if (!m || getComputedStyle(m).visibility === 'hidden' || !m.getClientRects().length) return []
      return [...m.querySelectorAll('[role=menuitem]')].map((e) => e.getAttribute('data-testid') + (e.getAttribute('aria-disabled') === 'true' ? ':off' : ''))
    })
    if (items.length) return items
  }
  return []
}

function hasEnabled(items, id) {
  return Array.isArray(items) && items.includes(id)
}
function listed(items, id) {
  return Array.isArray(items) && (items.includes(id) || items.includes(id + ':off'))
}

async function openTopic(p, task) {
  await p.goto(`${srv.base}/channel/alerts?topic=${task}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(400)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((extra) => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.archive_policy', 'everyone')
    localStorage.setItem('spool.mock.role', 'developer')
    localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
  }, EXTRA)

  await p.setViewport({ width: 1280, height: 800, isMobile: false, hasTouch: false, deviceScaleFactor: 1 })
  await openTopic(p, TASK)
  const openerThere = await p.waitForSelector(paneCard(TASK), { visible: true, timeout: 15000 }).then(() => true, () => false)
  const replyThere = await p.waitForSelector(paneCard(R1), { visible: true, timeout: 8000 }).then(() => true, () => false)
  ok('desktop: the discussion is open with its opener and a reply', openerThere && replyThere)

  const own = await menuItems(p, `${paneCard(TASK)} [data-testid=msg-menu-btn]`)
  ok('desktop: the opener menu opens', Array.isArray(own) && own.length > 0, own)
  for (const id of OPENER_IDS) ok(`desktop: opener offers ${id} enabled`, hasEnabled(own, id), own)
  ok('desktop: opener (it has a reply) offers no Archive topic', !listed(own, 'msg-menu-archive'), own)
  ok('desktop: opener Delete is the topic, not the one message', hasEnabled(own, 'msg-menu-delete-topic') && !listed(own, 'msg-menu-delete'), own)

  const reply = await menuItems(p, `${paneCard(R1)} [data-testid=msg-menu-btn]`)
  ok('desktop: a reply menu opens', Array.isArray(reply) && reply.length > 0, reply)
  ok('desktop: a reply does not take the opener\'s topic options', OPENER_IDS.every((id) => !listed(reply, id)), reply)
  ok('desktop: the reply, the latest message, offers Archive topic', hasEnabled(reply, 'msg-menu-archive'), reply)
  ok('desktop: a reply still offers Hide from flow', hasEnabled(reply, 'msg-menu-hide-flow'), reply)

  const mid = await menuItems(p, `${midCard(TASK)} [data-testid=msg-menu-btn]`)
  ok('desktop: the middle card still offers the same topic options', TOPIC_IDS.every((id) => hasEnabled(mid, id)), mid)

  await openTopic(p, OTHER_TASK)
  const otherThere = await p.waitForSelector(paneCard(OTHER), { visible: true, timeout: 15000 }).then(() => true, () => false)
  ok('desktop: someone else\'s discussion opens', otherThere)
  const other = await menuItems(p, `${paneCard(OTHER)} [data-testid=msg-menu-btn]`)
  ok('desktop: a non-starter still sees Archive enabled', hasEnabled(other, 'msg-menu-archive'), other)
  ok('desktop: Move, Merge and Delete stay listed, disabled', ['msg-menu-move-channel', 'msg-menu-merge-topic', 'msg-menu-delete-topic'].every((id) => Array.isArray(other) && other.includes(id + ':off')), other)

  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 1 })
  await openTopic(p, TASK)
  const phoneLevel = await p.evaluate(() => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level'))
  ok('phone: the discussion covers the page', phoneLevel === '3', phoneLevel)
  const phone = await menuItems(p, `${paneCard(TASK)} [data-testid=msg-menu-btn]`)
  ok('phone: the opener menu opens', Array.isArray(phone) && phone.length > 0, phone)
  for (const id of OPENER_IDS) ok(`phone: opener offers ${id} enabled`, hasEnabled(phone, id), phone)
  ok('phone: opener (it has a reply) offers no Archive topic', !listed(phone, 'msg-menu-archive'), phone)

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-menu-open-pane: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
