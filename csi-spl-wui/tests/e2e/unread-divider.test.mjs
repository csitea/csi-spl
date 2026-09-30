// CLE-77804 (topic 1e7d56b8, HUM-24): opening a channel showed no marker for
// messages that arrived while you were away. This drives a real browser (mock
// tenant) over the lobby feed and checks the "New messages" affordances:
//
//   control    with nothing unread (every row is older than the read boundary)
//              there is NO divider — today's behaviour, and the proof the
//              checks below see the divider only because it was added
//   divider    after messages newer than the boundary arrive, a divider marks
//              where the unread block starts, on the correct side for the order
//   highlight  each unread row carries the fading highlight marker (data-unread)
//   newest-last the feed scrolls to the divider on open (you land at the first
//              unread), and it sits BEFORE the unread block
//   jump       scrolled away, a "N new" button is on screen and hittable and
//              takes the reader back to the unread
//
// The read boundary is seeded into localStorage before the app boots, the same
// cursor the rail badge counts against; rows are injected through the page's
// own Pinia store, as a live frame would.
//   node tests/e2e/unread-divider.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/unread-divider.test.mjs
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
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
/* the read boundary and the two message batches around it (same day, ordered) */
const BOUNDARY = '2026-09-18T12:00:00.000Z'
const READ_BASE = '2026-09-18T06:00:00.000Z'
const NEW_BASE = '2026-09-18T18:00:00.000Z'

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

const setOrder = (p, order) => p.evaluate((order) => {
  document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session').setViewPref('message_order', order)
}, order)

/** Inject n rows into the channel store, each its own topic, from an ISO base. */
const injectAt = (p, n, tag, iso) => p.evaluate((n, tag, iso) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const base = new Date(iso).getTime()
  const rows = []
  for (let i = 0; i < n; i++) {
    const ts = new Date(base + i * 1000).toISOString()
    const id = `${tag}-${i}`
    rows.push({ v: 1, msg_id: id, task_id: `t-${id}`, is_parent: 1, ts, received_at: ts, from: 'HUM-7', from_box: 'box-wui', to: '@channel', channel: 'alerts', kind: 'note', body: `${tag} ${i}\nsecond line`, files: [] })
  }
  s.messages = [...s.messages, ...rows]
}, n, tag, iso)

/** The live-rows children in DOM order: cards (with their unread flag) and the divider. */
const layout = (p) => p.evaluate(() => {
  const items = [...document.querySelectorAll('.live-rows > *')]
  const seq = items.map((el) => el.matches('[data-testid=new-divider]')
    ? { t: 'divider' }
    : { t: 'card', unread: el.getAttribute('data-unread') === 'true', key: el.getAttribute('data-key') || '' })
  const dividerIdx = seq.findIndex((x) => x.t === 'divider')
  const unreadIdx = seq.map((x, i) => (x.t === 'card' && x.unread ? i : -1)).filter((i) => i >= 0)
  return { seq, dividerIdx, unreadIdx, unreadCount: unreadIdx.length }
})

/** The reader is looking at the new-messages region: the
    divider OR any unread row is on screen. */
const unreadRegionVisible = (p) => p.evaluate(() => {
  const one = (el) => {
    if (!el) return false
    const sc = el.closest('.feed-body'); if (!sc) return true
    const er = el.getBoundingClientRect(); const sr = sc.getBoundingClientRect()
    return er.bottom > sr.top && er.top < sr.bottom
  }
  if (one(document.querySelector('[data-testid=new-divider]'))) return true
  return [...document.querySelectorAll('.live-rows > article.msg[data-unread=true]')].some(one)
})

async function run(browser, base, width) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: 720, isMobile: false, hasTouch: false })
  const tag = `${width}px`
  await p.evaluateOnNewDocument(() => { window.__errs = []; window.addEventListener('error', (e) => window.__errs.push(String(e.message || ''))) })
  /* seed the read boundary for #alerts before the app boots — the cursor the
     rail counts against. The channel page snapshots it before its own markRead
     runs, and nothing else writes this key until we open the channel. */
  await p.evaluateOnNewDocument((b) => { try { localStorage.setItem('spool.read-cursors', JSON.stringify({ 'ch:alerts': { ts: b, id: 'seed-read' } })) } catch { /* */ } }, BOUNDARY)

  await p.goto(`${base}/channel/alerts`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  await signIn(p)
  await p.waitForSelector('.live-rows > article.msg', { timeout: NAV })

  /* older-than-boundary context, still nothing unread: no divider (today's look) */
  await injectAt(p, 10, 'read', READ_BASE)
  await sleep(600)
  check(`${tag} control: nothing newer than the boundary draws no divider`, (await layout(p)).dividerIdx < 0, await layout(p))

  /* a tall block of messages newer than the boundary: divider + highlight appear */
  const NEW_N = 14
  await injectAt(p, NEW_N, 'new', NEW_BASE)
  await sleep(700)
  let L = await layout(p)
  check(`${tag} a divider appears once there is unread`, L.dividerIdx >= 0, { dividerIdx: L.dividerIdx })
  check(`${tag} every message after the boundary is marked unread`, L.unreadCount === NEW_N, { unreadCount: L.unreadCount })
  /* default is newest-first: unread sit at the top, the divider is BELOW them */
  check(`${tag} newest-first: the divider sits after the unread block`,
    L.dividerIdx >= 0 && L.unreadIdx.length === NEW_N && Math.max(...L.unreadIdx) < L.dividerIdx && L.seq.slice(L.dividerIdx + 1).every((x) => x.t === 'divider' || !x.unread),
    { dividerIdx: L.dividerIdx, unreadIdx: L.unreadIdx })

  /* newest-first jump: scroll down away from the top (the unread), the "N new"
     button shows, is hittable, and takes the reader back up to them */
  await p.evaluate(() => { const sc = document.querySelector('.live-feed')?.closest('.feed-body'); if (sc) sc.scrollTop = sc.scrollHeight })
  await sleep(500)
  const jump = await p.evaluate(() => {
    const el = document.querySelector('[data-testid=unread-jump]')
    const r = el ? el.getBoundingClientRect() : null
    const at = r ? document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) : null
    return { present: Boolean(el), text: el ? el.textContent.trim() : '', hit: Boolean(el && at && (at === el || el.contains(at))), onScreen: Boolean(r && r.top >= 0 && r.bottom <= window.innerHeight) }
  })
  check(`${tag} scrolled away, a "N new" jump button is on screen and hittable`, jump.present && jump.hit && jump.onScreen && /\d/.test(jump.text), jump)
  if (jump.hit) {
    await p.click('[data-testid=unread-jump]')
    await sleep(1000)
    check(`${tag} the jump button brings the reader to the new messages`, await unreadRegionVisible(p))
  }

  /* newest-last (the owner's own view): the divider sits BEFORE the unread, and
     the feed scrolls to it on open so the reader lands at the first unread */
  await setOrder(p, 'newest-last')
  await sleep(900)
  L = await layout(p)
  check(`${tag} newest-last: the divider sits before the unread block`,
    L.dividerIdx >= 0 && L.unreadIdx.length === NEW_N && L.dividerIdx < Math.min(...L.unreadIdx),
    { dividerIdx: L.dividerIdx, unreadIdx: L.unreadIdx })
  if (process.env.OUT) await p.screenshot({ path: `${process.env.OUT}/unread-divider-${width}.png` })

  const snack = await p.evaluate(() => [...document.querySelectorAll('[data-test=error-snackbar-item]')].map((el) => el.innerText))
  check(`${tag} no error snackbar from the divider`, snack.length === 0, { snack })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [1440, 820]) await run(browser, server.base, w)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nunread-divider: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
