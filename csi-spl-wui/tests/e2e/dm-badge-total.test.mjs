// CLE-77845 (owner, topic 5dc55d94): "the direct messages should have the
// <<new>> / <<total>> type of rendering of the amount of new msgs vs the amount
// of total msgs". The DM rail badge reads "<new>/<total>", as a topic card does.
// Real browser, mock tenant.
//
//   load      the ?dm=true rows (5 lines, 2 after the stored cursor, 1 our own)
//             give "2/5" on the peer's row
//   live      one more DM from the peer -> "3/6" with no reload
//   channel   the peer's answer in a CHANNEL, addressed to us, moves neither
//             number (the 5dc55d94 phantom badge)
//   read      opening the DM clears the badge
//
// The rows go in through the notification store, as the reload path
// (applyDms) and a live frame (countDmLive + ingest) put them.
//   BASE_URL=http://127.0.0.1:3111 node tests/e2e/dm-badge-total.test.mjs
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
const CURSOR = '2026-09-18T09:00:03.000Z'

const signIn = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!s) return false
  s.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

/** One DM line between us (HUM-1) and the peer, at second `sec`. */
const line = (id, sec, fromPeer, extra = {}) => ({
  v: 1, msg_id: id, task_id: 'dm-topic', kind: 'note', body: id, files: [],
  ts: `2026-09-18T09:00:0${sec}.000Z`, received_at: `2026-09-18T09:00:0${sec}.000Z`,
  from: fromPeer ? 'CLE-11' : 'HUM-1', from_box: fromPeer ? 'box-desk' : 'box-wui',
  to: fromPeer ? 'HUM-1' : 'CLE-11', to_box: fromPeer ? 'box-wui' : 'box-desk', channel: null, ...extra,
})

const badgeOf = (p) => p.evaluate((peer) => {
  const row = [...document.querySelectorAll('a.nav-item')].find((e) => e.getAttribute('data-key') === peer)
  if (!row) return { row: false, text: null }
  const el = row.querySelector('[data-test=dm-badge]')
  return { row: true, text: el ? el.textContent.trim() : '' }
}, PEER)

const notes = (p, fn, ...args) => p.evaluate((fn, args) => {
  const n = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification')
  return n[fn](...args)
}, fn, args)

async function run(browser, base) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1200, height: 760, isMobile: false, hasTouch: false })
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => window.__errs.push(String(e.message || ''))) })
  /* the reader had read the DM up to its third line */
  await p.evaluateOnNewDocument((peer, ts) => { try { localStorage.setItem('spool.read-cursors', JSON.stringify({ [`dm:${peer}`]: { ts, id: 'l3' } })) } catch { /* */ } }, PEER, CURSOR)

  await p.goto(`${base}/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  await signIn(p)
  await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: NAV })
  await p.click('[data-testid=sidebar-tab-dm]')
  await p.waitForFunction((peer) => [...document.querySelectorAll('a.nav-item')].some((e) => e.getAttribute('data-key') === peer), { timeout: NAV }, PEER)

  const topic = {
    task_id: 'dm-topic', count: 5, participants: [PEER, 'HUM-1@box-wui'],
    inline: { messages: [line('l1', 1, true), line('l2', 2, false), line('l3', 3, true), line('l4', 4, true), line('l5', 5, true)] },
  }
  await notes(p, 'applyDms', [topic], 'HUM-1', '')
  await sleep(300)
  const load = await badgeOf(p)
  check('load: 2 new of 5 reads "2/5"', load.text === '2/5', load)

  const live = line('l6', 6, true)
  await notes(p, 'countDmLive', live, 'HUM-1')
  await notes(p, 'ingest', [live], { selfId: 'HUM-1', activeKey: '' }, { hydrate: false })
  await sleep(300)
  const after = await badgeOf(p)
  check('live: one more DM reads "3/6" with no reload', after.text === '3/6', after)

  const answer = line('c1', 7, true, { channel: 'ops', to: 'HUM-1' })
  await notes(p, 'countDmLive', answer, 'HUM-1')
  await notes(p, 'ingest', [answer], { selfId: 'HUM-1', activeKey: '' }, { hydrate: false })
  await sleep(300)
  const chan = await badgeOf(p)
  check('channel: the peer\'s channel answer to us moves neither number', chan.text === '3/6', chan)

  await p.evaluate((peer) => [...document.querySelectorAll('a.nav-item')].find((e) => e.getAttribute('data-key') === peer).click(), PEER)
  await p.waitForFunction(() => location.pathname.includes('/dm/'), { timeout: NAV })
  await sleep(800)
  const read = await badgeOf(p)
  check('read: opening the DM clears the badge', read.text === '', read)

  const errs = await p.evaluate(() => window.__errs || [])
  check('no window error', errs.length === 0, { errs })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  await run(browser, server.base)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ndm-badge-total: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
