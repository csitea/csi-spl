// Topic c6994436, lane A: Settings -> Behaviour "Message order" in a real
// browser (mock tenant). Each risk of the evaluation that a browser can show
// is one check; the default account is the control that proves the checks
// see the order at all.
//
//   control   no claim: newest first, Load more under the last row
//   A4        newest last: oldest at the top, newest at the bottom, Load more
//             above the first row, the window still holds the newest rows
//   A2        the feed opens at its bottom, and stays there when a card grows
//             after render (late markdown / picture / clip mode)
//   A5        at the bottom a new row is followed, no pill
//   A1 / A5   scrolled up: the row in view stays put, a "↓ N new" pill is on
//             screen and hittable, and it jumps to the bottom
//   A13       flipping the setting on an open feed re-renders it at the
//             newest end without a reload
//   settings  Settings -> Behaviour checks the effective choice of both keys
// Runs at 1440 and 820 (desktop and tablet widths), and 360 (phone, the
// SPL-1005 dock: the newest row sits above the dock, not under it).
//
// Rows are injected through the page's own Pinia store, as a live frame would.
//   node tests/e2e/message-order.test.mjs
//   BASE_URL=http://127.0.0.1:3000 OUT=/tmp/shots node tests/e2e/message-order.test.mjs
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

/** Sign in as a member; `order` undefined = never picked (the claim is absent). */
const signIn = (p, order, position) => p.evaluate((order, position) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  const c = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
  if (order !== undefined) c.message_order = order
  if (position !== undefined) c.composer_position = position
  session.adopt(c)
  return true
}, order, position)

const setOrder = (p, order) => p.evaluate((order) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
  s.setViewPref('message_order', order)
}, order)

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

let clock = Date.now() - 3600e3
const inject = (p, n, tag) => p.evaluate((n, tag, base) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('live-main')
  const rows = []
  for (let i = 0; i < n; i++) {
    const ts = new Date(base + i * 1000).toISOString()
    /* each its own topic: #lobby pane 2 lists topic starters only (a later
       message of the lobby task is a reply and stays in pane 3) */
    const id = `${tag}-${i}-${Date.now()}`
    rows.push({ v: 1, msg_id: id, task_id: `t-${id}`, ts, received_at: ts, from: 'HUM-7', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body: `${tag} ${i}\nsecond line\nthird line`, files: [] })
  }
  s.messages = [...s.messages, ...rows]
}, n, tag, (clock += 120e3))

/** The feed's scroller, its distance from the bottom, the row order and the sentinel place. */
const measure = (p) => p.evaluate(() => {
  let sc = null
  for (let n = document.querySelector('.live-feed'); n; n = n.parentElement) {
    const oy = getComputedStyle(n).overflowY
    if (oy === 'auto' || oy === 'scroll') { sc = n; break }
  }
  sc = sc || document.scrollingElement
  window.__sc = sc
  const rows = [...document.querySelectorAll('.live-rows > article.msg')]
  const ts = rows.map((r) => r.getAttribute('data-ts') || '')
  const more = document.querySelector('[data-testid=load-more]')
  const list = document.querySelector('.live-rows')
  const pos = more && list ? (more.compareDocumentPosition(list) & Node.DOCUMENT_POSITION_FOLLOWING ? 'above' : 'below') : 'none'
  const last = rows[rows.length - 1]
  const dock = document.querySelector('[data-docked="true"], .composer--dock')
  const dockTop = dock ? dock.getBoundingClientRect().top : Infinity
  return {
    n: rows.length,
    asc: ts.every((t, i) => i === 0 || !t || !ts[i - 1] || ts[i - 1] <= t),
    desc: ts.every((t, i) => i === 0 || !t || !ts[i - 1] || ts[i - 1] >= t),
    firstBody: rows[0]?.textContent?.slice(0, 40) ?? '',
    lastBody: last?.textContent?.slice(0, 40) ?? '',
    fromBottom: Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight),
    top: Math.round(sc.scrollTop),
    more: pos,
    order: list?.getAttribute('data-order') || 'newest-first',
    lastAboveDock: last ? last.getBoundingClientRect().bottom <= dockTop + 1 : false,
  }
})

async function run(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: 800, isMobile: touch, hasTouch: touch })
  const tag = `${width}px`
  /* prd e2e 2026-09-28: a scroll inside the ResizeObserver callback raised
     "ResizeObserver loop completed with undelivered notifications" as a
     window error, and the error snackbar showed it to the reader */
  await p.evaluateOnNewDocument(() => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
  })

  /* control: never picked = newest first */
  await p.goto(`${base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await p.waitForSelector('.live-rows > article.msg', { timeout: NAV })
  await inject(p, 40, 'seed')
  await sleep(600)
  let m = await measure(p)
  check(`${tag} control: no claim draws newest first, Load more under the rows`, m.order === 'newest-first' && m.desc && !m.asc && m.more === 'below', m)

  /* A13 + A4 + A2: flip to newest last on the open feed */
  await setOrder(p, 'newest-last')
  await sleep(800)
  m = await measure(p)
  check(`${tag} A4: newest last draws oldest first, Load more above the rows`, m.order === 'newest-last' && m.asc && !m.desc && m.more === 'above', m)
  check(`${tag} A13/A2: the flip lands the open feed at its bottom`, m.fromBottom <= 2, m)
  check(`${tag} A4: the newest row is the last one drawn`, /seed 39/.test(m.lastBody), m)
  if (touch) check(`${tag} phone dock: the newest row sits above the docked Omnibox`, m.lastAboveDock, m)
  if (process.env.OUT) await p.screenshot({ path: `${process.env.OUT}/message-order-newest-last-${width}.png` })

  /* A5: at the bottom a new row is followed */
  await inject(p, 2, 'follow')
  await sleep(900)
  m = await measure(p)
  const pill0 = await p.$('[data-testid=new-pill]')
  check(`${tag} A5: at the bottom new rows are followed, no pill`, m.fromBottom <= 2 && /follow 1/.test(m.lastBody) && !pill0, m)

  /* A2: a card that grows after render keeps the reader at the bottom */
  await p.evaluate(() => {
    const rows = document.querySelectorAll('.live-rows > article.msg')
    const last = rows[rows.length - 1]
    const pad = document.createElement('div')
    pad.style.height = '240px'
    pad.setAttribute('data-e2e-late', '1')
    last.appendChild(pad)
  })
  await sleep(500)
  m = await measure(p)
  check(`${tag} A2: a late height change is followed at the bottom`, m.fromBottom <= 2, m)
  await p.evaluate(() => document.querySelector('[data-e2e-late]')?.remove())
  await sleep(300)

  /* A2 (prd e2e 2026-09-28): content grows AND a scroll event fires while the
     view is far from the bottom but scrollTop did not move up (the dock
     padding / a late picture). That is not the reader leaving the bottom. */
  await p.evaluate(() => {
    const sc = window.__sc
    const rows = document.querySelectorAll('.live-rows > article.msg')
    const pad = document.createElement('div')
    pad.style.height = '240px'
    pad.setAttribute('data-e2e-late2', '1')
    rows[rows.length - 1].appendChild(pad)
    sc.scrollTop = sc.scrollTop + 40
  })
  await sleep(600)
  m = await measure(p)
  check(`${tag} A2: growth with a scroll event far from the bottom still follows`, m.fromBottom <= 2, m)
  await p.evaluate(() => document.querySelector('[data-e2e-late2]')?.remove())

  /* A1/A5: scrolled up, the row in view stays put and the pill counts below */
  const before = await p.evaluate(() => {
    const sc = window.__sc
    sc.scrollTop = Math.max(0, sc.scrollTop - 600)
    const edge = sc === document.scrollingElement ? 0 : sc.getBoundingClientRect().top
    const row = [...document.querySelectorAll('.live-rows > article.msg')].find((r) => r.getBoundingClientRect().top >= edge + 40)
    window.__anchor = row
    return { y: row ? Math.round(row.getBoundingClientRect().top) : null }
  })
  await sleep(400)
  await inject(p, 2, 'below')
  await sleep(1000)
  const after = await p.evaluate(() => {
    const el = document.querySelector('[data-testid=new-pill]')
    const r = el ? el.getBoundingClientRect() : null
    const at = r ? document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) : null
    return {
      y: window.__anchor ? Math.round(window.__anchor.getBoundingClientRect().top) : null,
      pill: el ? el.textContent.trim() : '',
      hit: Boolean(el && at && (at === el || el.contains(at))),
      onScreen: Boolean(r && r.top >= 0 && r.bottom <= window.innerHeight),
    }
  })
  check(`${tag} A1/A5: scrolled up, the row in view stays put`, before.y !== null && after.y !== null && Math.abs(after.y - before.y) < 2, { before, after })
  check(`${tag} A5: a "↓ N new" pill is on screen and hittable`, after.pill.startsWith('↓') && after.hit && after.onScreen, after)
  if (process.env.OUT) await p.screenshot({ path: `${process.env.OUT}/message-order-pill-${width}.png` })
  if (after.hit) {
    await p.click('[data-testid=new-pill]')
    await sleep(1200)
    m = await measure(p)
    const gone = !(await p.$('[data-testid=new-pill]'))
    check(`${tag} A5: the pill jumps to the newest row at the bottom and goes away`, m.fromBottom <= 2 && gone && /below 1/.test(m.lastBody), m)
  }

  /* A1: an older page loaded above does not move the row in view */
  /* the scroll up and the click in ONE task: the scroll event is not delivered
     yet when Load more runs (CI 10 gate, 820 px, 2026-09-28: the view jumped
     to the bottom, y 233 -> -997) */
  const olderBefore = await p.evaluate(() => {
    const sc = window.__sc
    sc.scrollTop = Math.max(0, Math.round(sc.scrollHeight / 2))
    const edge = sc === document.scrollingElement ? 0 : sc.getBoundingClientRect().top
    const row = [...document.querySelectorAll('.live-rows > article.msg')].find((r) => r.getBoundingClientRect().top >= edge + 40)
    window.__anchor = row
    const b = document.querySelector('[data-testid=load-more]')
    if (b) b.click()
    return { y: row ? Math.round(row.getBoundingClientRect().top) : null, n: document.querySelectorAll('.live-rows > article.msg').length, clicked: Boolean(b) }
  })
  const clicked = olderBefore.clicked
  await sleep(1000)
  const olderAfter = await p.evaluate(() => ({ y: window.__anchor ? Math.round(window.__anchor.getBoundingClientRect().top) : null, n: document.querySelectorAll('.live-rows > article.msg').length }))
  check(`${tag} A1: Load more above adds older rows without moving the row in view`,
    clicked && olderAfter.n > olderBefore.n && olderBefore.y !== null && Math.abs(olderAfter.y - olderBefore.y) < 2, { clicked, olderBefore, olderAfter })

  /* A6: a thread in newest last - the root on top, replies oldest to newest,
     opened at its bottom, and a new reply is followed there */
  if (!touch) {
    await p.evaluate(() => document.querySelector('.live-rows > article.msg')?.click())
    await p.waitForSelector('[data-pane="topic"] .feed-body', { timeout: 10000 })
    /* the pane's own read must land first, or it replaces the injected rows */
    await p.waitForFunction(() => {
      const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('live-pane')
      return s && s.taskId && !s.loading
    }, { timeout: 10000 })
    await sleep(800)
    const replyTo = (n, tag) => p.evaluate((n, tag, base) => {
      const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('live-pane')
      const rows = []
      for (let i = 0; i < n; i++) {
        const ts = new Date(base + i * 1000).toISOString()
        rows.push({ v: 1, msg_id: `${tag}-${i}-${Date.now()}`, task_id: s.taskId, ts, received_at: ts, from: 'HUM-7', from_box: 'box-wui', to: 'ALL-0', kind: 'note', body: `${tag} ${i}\nsecond line\nthird line`, files: [] })
      }
      s.messages = [...s.messages, ...rows]
    }, n, tag, (clock += 120e3))
    await replyTo(20, 'reply')
    await sleep(900)
    const thread = () => p.evaluate(() => {
      const sc = document.querySelector('[data-pane="topic"] .feed-body')
      const rows = [...sc.querySelectorAll('.live-rows > article.msg')]
      const ts = rows.map((r) => r.getAttribute('data-ts') || '')
      return {
        n: rows.length,
        asc: ts.every((t, i) => i === 0 || !t || !ts[i - 1] || ts[i - 1] <= t),
        last: rows[rows.length - 1]?.getAttribute('data-key') ?? '',
        fromBottom: Math.round(sc.scrollHeight - sc.scrollTop - sc.clientHeight),
        scrolls: sc.scrollHeight > sc.clientHeight + 1,
      }
    })
    let th = await thread()
    check(`${tag} A6: the thread reads oldest to newest and sits at its bottom`, th.asc && /^reply-19-/.test(th.last) && th.fromBottom <= 2 && th.scrolls, th)
    await replyTo(1, 'late')
    await sleep(900)
    th = await thread()
    check(`${tag} A6: at the bottom of a thread a new reply is followed`, /^late-0-/.test(th.last) && th.fromBottom <= 2, th)
    if (process.env.OUT) await p.screenshot({ path: `${process.env.OUT}/message-order-thread-${width}.png` })
    await p.click('[data-test=live-topic-close]')
    await sleep(500)
  }

  /* A13: back to newest first on the open feed */
  await setOrder(p, 'newest-first')
  await sleep(800)
  m = await measure(p)
  check(`${tag} A13: flipping back draws newest first at the top`, m.order === 'newest-first' && m.desc && m.top <= 2, m)

  const errs = await p.evaluate(() => window.__errs || [])
  const snack = await p.evaluate(() => [...document.querySelectorAll('[data-test=error-snackbar-item]')].map((el) => el.innerText))
  check(`${tag} no ResizeObserver error in the error snackbar`, !snack.some((m) => /ResizeObserver/.test(m)), { snack, windowErrors: errs.length })

  /* Settings -> Behaviour reflects both claims */
  await signIn(p, 'newest-last', 'bottom')
  await go(p, '/settings/behaviour')
  await p.waitForSelector('[data-test=view-prefs-setting]', { timeout: 10000 })
  const checked = await p.$$eval('[data-test=view-prefs-setting] input[type=radio]:checked', (els) => els.map((e) => e.value))
  check(`${tag} settings: both radios show the account's choices`, checked.join(',') === 'newest-last,bottom', { checked })
  await signIn(p)
  await sleep(200)
  const checkedDefault = await p.$$eval('[data-test=view-prefs-setting] input[type=radio]:checked', (els) => els.map((e) => e.value))
  check(`${tag} settings: never picked shows the defaults checked`, checkedDefault.join(',') === 'newest-first,top', { checkedDefault })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, touch] of [[1440, false], [820, true], [360, true]]) await run(browser, server.base, w, touch)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nmessage-order: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
