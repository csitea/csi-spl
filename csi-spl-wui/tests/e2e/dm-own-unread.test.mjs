// CLE-77889 (owner, t1 99905c80): "even if I write some messages in the direct
// messages - those are shown to me as new, which is not the case FOR ME ...
// they should be shown as new for the receiver of those msgs, but not me".
// Real browser, mock tenant, two sessions (two browser contexts):
//
//   A (HUM-1) load   the ?dm=true rows with the agent CLE-11: 2 lines from the
//                    agent, 1 own post, 1 line A TYPED AT THE AGENT'S TERMINAL
//                    (from=CLE-11, typed_by=HUM-1 - drawn as A's own) -> "2/4"
//                    (it read "3/4": the terminal line counted as new)
//   A other tab      A's own DM and own terminal line arriving live (sent from
//                    another tab / device) move the total, never the new part
//   A peer           the agent's next line still raises it: "3/7"
//   A topic card     A's own reply from another tab moves the topic's seen
//                    count with it (no "1/N"), once per msg_id
//   member DM        A and B (HUM-2) on ONE member-to-member DM: each sees only
//                    the OTHER's lines as new
//
//   BASE_URL=http://127.0.0.1:3111 node tests/e2e/dm-own-unread.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const PEER = 'CLE-11@box-desk'

const signIn = (p, hum) => p.evaluate((hum) => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!s) return false
  s.adopt({ hum, email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
}, hum)

/** One DM line at second `sec`: from -> to (ids with their box). */
const line = (id, sec, from, to, extra = {}) => ({
  v: 1, msg_id: id, task_id: 'dm-topic', kind: 'note', body: id, files: [],
  ts: `2026-09-18T09:00:0${sec}.000Z`, received_at: `2026-09-18T09:00:0${sec}.000Z`,
  from: from.split('@')[0], from_box: from.split('@')[1], to: to.split('@')[0], to_box: to.split('@')[1], channel: null, ...extra,
})
const A = 'HUM-1@box-wui'
const B = 'HUM-2@box-wui'

const badgeOf = (p) => p.evaluate((peer) => {
  const row = [...document.querySelectorAll('a.nav-item')].find((e) => e.getAttribute('data-key') === peer)
  if (!row) return { row: false, text: null }
  const el = row.querySelector('[data-test=dm-badge]')
  const tot = row.querySelector('[data-test=dm-total]')
  return { row: true, text: el ? el.textContent.trim() : '', total: tot ? tot.textContent.trim() : '' }
}, PEER)

const notes = (p, fn, ...args) => p.evaluate((fn, args) => {
  const n = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification')
  const out = n[fn](...args)
  return out === undefined ? null : out
}, fn, args)
const unreadOf = (p, key) => p.evaluate((key) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification').unread[key] || 0, key)

async function open(browser, hum, cursors) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1200, height: 760 })
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => window.__errs.push(String(e.message || ''))) })
  /* the rows' own count, as a hub without Flow `keys` draws it (t1 77540e6f:
     with keys, tests/e2e/unread-sum.test.mjs) */
  await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.mock.flow-keys', 'off') } catch { /* */ } })
  await p.evaluateOnNewDocument((c) => { try { localStorage.setItem('spool.read-cursors', JSON.stringify(c)) } catch { /* */ } }, cursors)
  await p.goto(`${BASE}/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  await signIn(p, hum)
  return { ctx, p }
}

let BASE = ''
async function run(browser) {
  /* A: the agent DM, read up to nothing; the DM topic card read at 3 replies */
  const a = await open(browser, 'HUM-1', { 't:dm-topic': { ts: '2026-09-18T09:00:05.000Z', id: '', count: 3 } })
  const p = a.p
  await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: NAV })
  await p.click('[data-testid=sidebar-tab-dm]')
  await p.waitForFunction((peer) => [...document.querySelectorAll('a.nav-item')].some((e) => e.getAttribute('data-key') === peer), { timeout: NAV }, PEER)

  const topic = { task_id: 'dm-topic', count: 4, participants: [PEER, A], inline: { messages: [
    line('l1', 1, PEER, A), line('l2', 2, A, PEER), line('l3', 3, PEER, A, { typed_by: 'HUM-1' }), line('l4', 4, PEER, A),
  ] } }
  await notes(p, 'applyDms', [topic], 'HUM-1', '')
  await sleep(300)
  const load = await badgeOf(p)
  check('A load: own post and own terminal line are not new - "2/4"', load.text === '2/4', load)

  for (const m of [line('l6', 6, A, PEER), line('l7', 7, PEER, A, { typed_by: 'HUM-1' })]) {
    await notes(p, 'countDmLive', m, 'HUM-1')
    await notes(p, 'ingest', [m], { selfId: 'HUM-1', activeKey: '' }, { hydrate: false })
  }
  await sleep(300)
  const other = await badgeOf(p)
  check('A other tab: own live DM + own terminal line move the total only - "2/6"', other.text === '2/6', other)

  const peer = line('l8', 8, PEER, A)
  await notes(p, 'countDmLive', peer, 'HUM-1')
  await notes(p, 'ingest', [peer], { selfId: 'HUM-1', activeKey: '' }, { hydrate: false })
  await sleep(300)
  const next = await badgeOf(p)
  check('A peer: the agent\'s next line is new - "3/7"', next.text === '3/7', next)

  const seen = await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification').topicRead['dm-topic'])
  check('A topic card: own replies from another tab are seen (3 -> 5), not "2/N"', seen === 5, { seen })
  await notes(p, 'ingest', [line('l6', 6, A, PEER)], { selfId: 'HUM-1', activeKey: '' }, { hydrate: false })
  const again = await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification').topicRead['dm-topic'])
  check('A topic card: the same own reply read twice counts once', again === 5, { again })

  /* the member DM, both ends */
  const b = await open(browser, 'HUM-2', {})
  const member = { task_id: 'dm-ab', count: 3, participants: [A, B], inline: { messages: [
    line('m1', 1, A, B, { task_id: 'dm-ab' }), line('m2', 2, B, A, { task_id: 'dm-ab' }), line('m3', 3, A, B, { task_id: 'dm-ab' }),
  ] } }
  await notes(p, 'applyDms', [member], 'HUM-1', '')
  await notes(b.p, 'applyDms', [member], 'HUM-2', '')
  const ua = await unreadOf(p, `dm:${B}`)
  const ub = await unreadOf(b.p, `dm:${A}`)
  check('member DM: the sender A sees only B\'s 1 line as new', ua === 1, { ua })
  check('member DM: the receiver B sees A\'s 2 lines as new', ub === 2, { ub })
  const liveA = line('m4', 4, A, B, { task_id: 'dm-ab' })
  await notes(p, 'ingest', [liveA], { selfId: 'HUM-1', activeKey: '' }, { hydrate: false })
  await notes(b.p, 'ingest', [liveA], { selfId: 'HUM-2', activeKey: '' }, { hydrate: false })
  check('member DM live: A\'s new line is new for B only', (await unreadOf(p, `dm:${B}`)) === 1 && (await unreadOf(b.p, `dm:${A}`)) === 3)

  for (const s of [a, b]) {
    const errs = await s.p.evaluate(() => window.__errs || [])
    check('no window error', errs.length === 0, { errs })
    await s.ctx.close()
  }
}

const server = await startServer()
BASE = server.base
const browser = await launch()
let code = 0
try {
  await run(browser)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ndm-own-unread: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
