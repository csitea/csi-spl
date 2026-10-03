// HUM-10 (topic c15b557e): a direct message's card menu reads "Open in direct
// msg view" and jumps to that conversation in the DM view, the card at the
// reader's edge - the TOP of the list when they read newest first (prepend),
// the BOTTOM when newest last (append). A topic message stops at the topic
// level (the card selected, nothing opened); a reply opens its topic on the
// right with the reply in it. CONTROL: a channel card reads "Open in channels
// view".
//
//   node tests/e2e/open-in-dm-view.test.mjs          (mock tenant, nuxi dev)
//   BASE_URL=<generated bundle> node tests/e2e/open-in-dm-view.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.DM_VIEW_SHOTS || mkdtempSync(join(tmpdir(), 'spool-dm-view-'))
/* the mock tenant (utils/mock-data.mjs): HUM-1's DM with GRK-03 - its card and a reply */
const PEER = 'GRK-03@box-a'
const DM_TOPIC = '99999999-9999-4999-8999-999999999999'
const DM_CARD = '77777777-7777-4777-8777-777777777777'
const DM_REPLY = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const DM_PATH = '/dm/' + encodeURIComponent(PEER)
/* a #lobby reply, the channel control */
const LOBBY_TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const LOBBY_REPLY = '33333333-3333-4333-8333-333333333333'

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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const signIn = (p, order) => p.evaluate((order) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', message_order: order })
  return true
}, order)

const setOrder = (p, order) => p.evaluate((order) => {
  document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session').setViewPref('message_order', order)
}, order)

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)

/* more cards in the DM, older and newer than the mock card, so the jump has
   to scroll: the card sits in the middle of a list taller than the pane. The
   mock tenant re-reads the DM every 4 s (useSpoolEvents) and the read
   replaces the rows, so that poll is switched off once they are in (a hub
   pushes new rows instead; it never re-reads under the reader). */
const seed = (p) => p.evaluate((peerBox) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const rows = []
  const at = (base, i) => new Date(Date.parse(base) + i * 60e3).toISOString()
  for (let i = 0; i < 12; i++) {
    for (const [tag, base] of [['old', '2026-09-18T08:00:00Z'], ['new', '2026-09-18T11:00:00Z']]) {
      const id = `e2e-${tag}-${i}`
      const ts = at(base, i)
      rows.push({ v: 1, msg_id: id, task_id: `t-${id}`, ts, received_at: ts, from: 'HUM-1', from_box: 'box-wui', to: 'GRK-03', to_box: peerBox, kind: 'note', body: `${tag} DM card ${i}\nsecond line\nthird line`, channel: null, parent_task_id: null, is_parent: 1, files: [] })
    }
  }
  s.messages = [...s.messages, ...rows]
  s.refresh = async () => {}
}, 'box-a')

/* where the card sits against the feed's edges */
const measure = (p, id) => p.evaluate((id) => {
  const card = document.querySelector(`.spool-main article.msg[data-msg-id="${id}"]`)
  const sc = card && card.closest('.feed-body')
  if (!card || !sc) return { found: false }
  const r = card.getBoundingClientRect()
  const s = sc.getBoundingClientRect()
  const pad = parseFloat(getComputedStyle(sc).paddingBottom) || 0
  return {
    found: true,
    n: document.querySelectorAll('.spool-main article.msg').length,
    topGap: Math.round(r.top - s.top),
    bottomGap: Math.round((s.bottom - pad) - r.bottom),
    scrollable: sc.scrollHeight > sc.clientHeight + 20,
    focused: document.activeElement === card && card.matches(':focus-visible'),
    selected: card.getAttribute('data-selected') === 'true',
  }
}, id)

const url = (p) => { const u = new URL(p.url()); return { path: decodeURIComponent(u.pathname), topic: u.searchParams.get('topic'), hash: u.hash } }
const onDm = (u) => u.path.endsWith('/dm/' + PEER)
const dmTab = (p) => p.$eval('[data-testid=sidebar-tab-dm]', (el) => el.getAttribute('aria-selected')).catch(() => null)

async function openMenuOn(p, sel) {
  await p.waitForSelector(sel, { visible: true, timeout: 10000 })
  await (await p.$(`${sel} .msg-body`)).click({ button: 'right' })
  await p.waitForSelector('[data-testid=msg-menu]', { visible: true, timeout: 5000 })
  return p.$eval('[data-testid=msg-menu-parent]', (el) => el.textContent.trim()).catch(() => '')
}

/* the thread of the DM topic, open on the right, from wherever the reader is */
async function openDmThread(p) {
  await go(p, `${DM_PATH}?topic=${DM_TOPIC}`)
  await p.waitForFunction((t) => new URLSearchParams(location.search).get('topic') === t && !location.hash, { timeout: 10000 }, DM_TOPIC)
  await sleep(300)
  await p.waitForSelector(`aside.live-pane [data-msg-id="${DM_REPLY}"]`, { visible: true, timeout: 10000 })
}

/* choose the item: the address moves, then the reveal settles */
async function choose(p) {
  const before = p.url()
  await p.click('[data-testid=msg-menu-parent]')
  await p.waitForFunction((b) => location.href !== b, { timeout: 10000 }, before).catch(() => null)
  await sleep(1200)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  if (!(await signIn(p, 'newest-first'))) throw new Error('no session store')

  /* CONTROL: a channel reply reads Open in channels view */
  await go(p, `/channel/lobby?topic=${LOBBY_TOPIC}`)
  const chLabel = await openMenuOn(p, `aside.live-pane [data-msg-id="${LOBBY_REPLY}"]`)
  ok('1 CONTROL: a channel card reads "Open in channels view"', chLabel === 'Open in channels view', { chLabel })
  await p.keyboard.press('Escape')

  /* from another page: /search -> the DM reply's thread -> the item */
  await go(p, '/search?q=' + encodeURIComponent('Mock DM reply'))
  const hit = '[data-test=search-results] [data-test=search-row][data-type=messages]'
  await p.waitForSelector(hit, { visible: true, timeout: NAV_TIMEOUT })
  await p.click(hit, { button: 'right' })
  await p.waitForSelector('[data-testid=search-row-menu-here]', { visible: true, timeout: 5000 })
  await p.click('[data-testid=search-row-menu-here]')
  const fromSearch = await openMenuOn(p, `aside.live-pane [data-msg-id="${DM_REPLY}"]`)
  await choose(p)
  let u = url(p)
  const card0 = await p.waitForSelector(`.spool-main article.msg[data-msg-id="${DM_CARD}"][data-selected="true"]`, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  ok('2 from /search a DM reply reads "Open in direct msg view" and lands in the DM, the DM tab selected, its topic open, the card selected',
    fromSearch === 'Open in direct msg view' && onDm(u) && u.topic === DM_TOPIC && u.hash === '#' + DM_REPLY && (await dmTab(p)) === 'true' && card0, { fromSearch, u, card0 })

  /* the DM, with more cards around the mock one (the DM reloads its rows
     when the peer changes, so the rest stays in this DM) */
  await go(p, DM_PATH)
  await p.waitForSelector(`.spool-main article.msg[data-msg-id="${DM_CARD}"]`, { visible: true, timeout: 10000 })
  await seed(p)
  await sleep(500)

  /* newest first: a topic message */
  await openDmThread(p)
  const label = await openMenuOn(p, `aside.live-pane [data-msg-id="${DM_CARD}"]`)
  await p.evaluate(() => { const b = document.querySelector('.spool-main .feed-body'); if (b) b.scrollTop = b.scrollHeight })
  await choose(p)
  u = url(p)
  let m = await measure(p, DM_CARD)
  const paneOpen = await p.$('aside.live-pane').then(Boolean)
  ok('3 newest first, topic message: reads "Open in direct msg view"; the DM, no topic opened, the DM tab selected',
    label === 'Open in direct msg view' && onDm(u) && !u.topic && !paneOpen && (await dmTab(p)) === 'true', { label, u, paneOpen })
  ok('4 newest first, topic message: the card is TOPMOST and selected', m.found && m.scrollable && Math.abs(m.topGap) <= 2 && m.focused, m)
  mkdirSync(SHOTS, { recursive: true })
  await p.mouse.move(5, 895)
  await p.screenshot({ path: `${SHOTS}/open-in-dm-view-newest-first-1440.png` })

  /* newest first: a reply - its topic opens on the right with the reply in it */
  await openDmThread(p)
  await openMenuOn(p, `aside.live-pane [data-msg-id="${DM_REPLY}"]`)
  await choose(p)
  u = url(p)
  m = await measure(p, DM_CARD)
  const reply = await p.$(`aside.live-pane [data-msg-id="${DM_REPLY}"]`).then(Boolean)
  ok('5 newest first, reply: the DM with its topic open and the reply as the hash',
    onDm(u) && u.topic === DM_TOPIC && u.hash === '#' + DM_REPLY && reply, u)
  ok('6 newest first, reply: the topic card is TOPMOST and selected', m.found && Math.abs(m.topGap) <= 2 && m.selected, m)

  /* newest last (append): the card is BOTTOMMOST */
  await setOrder(p, 'newest-last')
  await openDmThread(p)
  await openMenuOn(p, `aside.live-pane [data-msg-id="${DM_CARD}"]`)
  await p.evaluate(() => { const b = document.querySelector('.spool-main .feed-body'); if (b) b.scrollTop = 0 })
  await choose(p)
  u = url(p)
  m = await measure(p, DM_CARD)
  ok('7 newest last, topic message: the DM, no topic opened', onDm(u) && !u.topic, u)
  ok('8 newest last, topic message: the card is BOTTOMMOST and selected', m.found && Math.abs(m.bottomGap) <= 2 && m.focused, m)
  await p.mouse.move(5, 895)
  await p.screenshot({ path: `${SHOTS}/open-in-dm-view-newest-last-1440.png` })

  await openDmThread(p)
  await openMenuOn(p, `aside.live-pane [data-msg-id="${DM_REPLY}"]`)
  await choose(p)
  m = await measure(p, DM_CARD)
  ok('9 newest last, reply: the topic card is BOTTOMMOST', m.found && Math.abs(m.bottomGap) <= 2 && m.selected, m)
  console.log(`  screenshots ${SHOTS}`)

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('10 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log(failed.map((r) => r.name).join('\n'))
  process.exit(1)
}
