// A topic id written in a message opens that topic in its channel, on a phone
// and on a desktop. A reply id stays in the right-hand pane and that pane
// scrolls to the reply. The unknown uuid in the same body is the control:
// it stays plain text.
//
// The mock feed is lengthened through the e2e hook
// localStorage `spool.mock.extra-messages`, which the mock client reads on
// load. A later channel reload therefore keeps the same rows. The reply
// list is long enough that the reply starts below the thread pane, and the
// channel list is long enough that the topic card starts below that list.
//
// Run: node tests/e2e/id-links.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const FROM = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TO = 'abababab-abab-4bab-8bab-abababababab'
const REPLY2 = '44444444-4444-4444-8444-444444444444'
const UNKNOWN = '00000000-0000-4000-8000-000000000099'
const BODY = `topic ${TO}\nreply ${REPLY2}\nnot an id ${UNKNOWN}`

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function row(partial) {
  return {
    v: 1,
    files: [],
    channel: 'lobby',
    parent_task_id: null,
    from: 'HUM-1',
    from_box: 'box-wui',
    to: '@channel',
    to_box: 'box-wui',
    kind: 'note',
    is_parent: 1,
    ...partial,
  }
}

const carrier = row({
  msg_id: 'f3010000-0000-4000-8000-000000000001',
  task_id: 'f3020000-0000-4000-8000-000000000001',
  parent_task_id: FROM,
  is_parent: 0,
  body: BODY,
  ts: '2026-12-31T23:59:00Z',
})

function stamped(msgPrefix, taskPrefix, n, parent) {
  const extra = []
  for (let i = 0; i < n; i++) {
    const tail = i.toString(16).padStart(12, '0')
    extra.push(row({
      msg_id: `${msgPrefix}0000-0000-4000-8000-${tail}`,
      task_id: `${taskPrefix}0000-0000-4000-8000-${tail}`,
      parent_task_id: parent,
      is_parent: parent ? 0 : 1,
      body: parent ? 'newer reply' : 'newer card',
      ts: `2026-12-15T12:${String(i).padStart(2, '0')}:00Z`,
    }))
  }
  extra.push(carrier)
  return extra
}

// 24 newer replies keep the target reply below the thread pane, and the
// mock page (30 rows) still holds the original topic and that reply.
const replyRows = stamped('f201', 'f202', 24, FROM)
// 28 newer cards keep the target card below the channel list. The page
// still holds that card and the message the link is written in.
const cardRows = stamped('f101', 'f102', 28, null)

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

const state = (p) => p.evaluate((to, unknown) => {
  const links = [...document.querySelectorAll('a.msg-link')].map((a) => ({
    text: a.textContent || '',
    href: a.getAttribute('href') || '',
  }))
  const pane = document.querySelector('.spool-shell > .topic')
  const box = pane ? pane.getBoundingClientRect() : null
  return {
    pane: !!(pane && box && getComputedStyle(pane).display !== 'none' && box.width > 0 && box.height > 0),
    path: location.pathname + location.search,
    topicLinked: links.some((a) => a.text === to && a.href.includes('topic=' + to) && a.href.includes('/channel/')),
    unknownLinked: links.some((a) => a.text.includes(unknown)),
  }
}, TO, UNKNOWN)

async function openChannel(p, base, extra) {
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  p.on('console', (msg) => { if (msg.type() === 'error') errors.push(msg.text().slice(0, 300)) })
  await p.evaluateOnNewDocument((rows) => {
    try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)) } catch { /* private mode */ }
  }, extra)
  let shell = false
  for (let attempt = 0; attempt < 2 && !shell; attempt++) {
    await p.goto(`${base}/channel/lobby?topic=${FROM}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    shell = await p.waitForSelector('.spool-shell', { timeout: attempt === 0 ? 20000 : NAV_TIMEOUT }).then(() => true, () => false)
  }
  if (!shell) {
    const info = await p.evaluate(() => ({
      url: location.href,
      text: (document.body && document.body.innerText || '').slice(0, 400),
    })).catch((e) => ({ eval: String(e).slice(0, 200) }))
    throw new Error('no shell ' + JSON.stringify({ ...info, errors: errors.slice(0, 4) }))
  }
  const linkSel = `a.msg-link[href*="topic=${TO}"]`
  await p.waitForSelector(linkSel, { visible: true, timeout: 15000 })
  // A generated bundle reloads once while the shell settles. The link is
  // visible before that reload and missing during it, so a fixed pause
  // lands on the blank document. Count the link only after it stays, or
  // after the reload has brought it back.
  await p.evaluate(() => { window.__idLinkBoot = 1 })
  const reloaded = await p.waitForFunction(
    () => window.__idLinkBoot !== 1, { timeout: 2000 },
  ).then(() => true, () => false)
  if (reloaded) {
    await p.waitForSelector('.spool-shell', { timeout: 15000 })
    await p.waitForSelector(linkSel, { visible: true, timeout: 15000 })
  }
}

async function waitUntil(p, fn, arg, ms = 8000) {
  const start = Date.now()
  let last
  while (Date.now() - start < ms) {
    last = await p.evaluate(fn, arg)
    if (last && last.ok) return last
    await sleep(150)
  }
  return last
}

const srv = await startServer()
const browser = await launch()
try {
  const phone = await browser.newPage()
  phone.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await phone.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await openChannel(phone, srv.base, replyRows)
  let s = await state(phone)
  ok('390px the topic id is a link and the unknown id is not', s.topicLinked && !s.unknownLinked && s.pane, s)

  await phone.tap(`a.msg-link[href*="topic=${TO}"]`)
  const phoneOpen = await waitUntil(phone, (to) => {
    const path = location.pathname + location.search
    const pane = document.querySelector('aside.topic, .spool-shell > .topic')
    const paneVis = !!(pane && pane.getBoundingClientRect().width > 0)
    const topicPage = path.includes('/t/')
    return {
      ok: path.includes('/channel/') && path.includes('topic=' + to) && !topicPage && paneVis,
      path, paneVis, topicPage,
    }
  }, TO)
  ok('390px a tap on the topic id opens that topic in the channel', phoneOpen && phoneOpen.ok, phoneOpen)
  await phone.close()

  const desk = await browser.newPage()
  desk.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await desk.setViewport({ width: 1440, height: 900 })
  await openChannel(desk, srv.base, replyRows)
  s = await state(desk)
  ok('1440px the topic id is a link and the unknown id is not', s.topicLinked && !s.unknownLinked, s)

  const replyBefore = await desk.evaluate((id) => {
    const row = document.querySelector(`aside.live-pane article.msg[data-msg-id="${id}"]`)
    const scroller = row && row.closest('.feed-body')
    const threadCount = document.querySelectorAll('aside.live-pane article.msg').length
    if (!row || !scroller) return { ok: false, reason: 'missing', threadCount }
    const r = row.getBoundingClientRect()
    const box = scroller.getBoundingClientRect()
    return {
      ok: threadCount > 10 && r.top >= box.bottom - 1,
      top: Math.round(r.top), paneBottom: Math.round(box.bottom), threadCount,
    }
  }, REPLY2)
  ok('1440px the reply starts below the thread pane', replyBefore && replyBefore.ok, replyBefore)

  await desk.click(`a.msg-link[href*="#${REPLY2}"]`)
  const replyOpen = await waitUntil(desk, (id) => {
    const row = document.querySelector(`aside.live-pane article.msg[data-msg-id="${id}"]`)
    const scroller = row && row.closest('.feed-body')
    const mainCount = document.querySelectorAll('.spool-main article.msg').length
    const threadCount = document.querySelectorAll('aside.live-pane article.msg').length
    const path = location.pathname + location.search + location.hash
    let gap = null
    if (row && scroller) gap = Math.round(row.getBoundingClientRect().top - scroller.getBoundingClientRect().top)
    const inMain = !!(row && row.closest('.spool-main'))
    const shown = !!(row && scroller && row.getBoundingClientRect().bottom > scroller.getBoundingClientRect().top && row.getBoundingClientRect().top < scroller.getBoundingClientRect().bottom)
    return {
      ok: path.includes('/channel/lobby') && path.includes('#' + id) && !path.includes('/t/') && !inMain && mainCount > 0 && threadCount > 10 && shown && gap !== null && gap >= -2 && gap <= 24,
      path, gap, inMain, mainCount, threadCount, shown,
    }
  }, REPLY2)
  ok('1440px a reply id opens in the right pane, scrolled to that reply', replyOpen && replyOpen.ok, replyOpen)
  await desk.close()

  const cards = await browser.newPage()
  cards.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await cards.setViewport({ width: 1440, height: 900 })
  await openChannel(cards, srv.base, cardRows)
  const cardBefore = await cards.evaluate((to) => {
    const card = document.querySelector(`.spool-main article.msg[data-task-id="${to}"]`)
    const scroller = card && card.closest('.feed-body')
    const n = document.querySelectorAll('.spool-main article.msg').length
    if (!card || !scroller) return { ok: false, reason: 'missing', n }
    const r = card.getBoundingClientRect()
    const box = scroller.getBoundingClientRect()
    return { ok: r.top >= box.bottom - 1, top: Math.round(r.top), paneBottom: Math.round(box.bottom), n }
  }, TO)
  ok('1440px the topic card starts below the channel list', cardBefore && cardBefore.ok, cardBefore)

  await cards.click(`a.msg-link[href*="topic=${TO}"]`)
  const topicOpen = await waitUntil(cards, (to) => {
    const path = location.pathname + location.search
    const card = document.querySelector(`.spool-main article.msg[data-task-id="${to}"]`)
    const scroller = card && card.closest('.feed-body')
    const pane = document.querySelector('aside.topic')
    const paneBox = pane ? pane.getBoundingClientRect() : null
    const paneVis = !!(paneBox && paneBox.width > 0 && paneBox.height > 0)
    const main = document.querySelector('.spool-main')
    const mainBox = main ? main.getBoundingClientRect() : null
    const mainVis = !!(mainBox && mainBox.width > 0 && mainBox.height > 0)
    let gap = null
    if (card && scroller) gap = Math.round(card.getBoundingClientRect().top - scroller.getBoundingClientRect().top)
    const selected = !!(card && (card.classList.contains('selected') || card.getAttribute('data-selected') === 'true'))
    return {
      ok: path.includes('/channel/lobby') && path.includes('topic=' + to) && !path.includes('/t/') && paneVis && mainVis && selected && gap !== null && gap >= -2 && gap <= 24,
      path, gap, selected, paneVis, mainVis,
    }
  }, TO)
  ok('1440px a click on the topic id keeps the channel and scrolls that card', topicOpen && topicOpen.ok, topicOpen)
  await cards.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nid-links: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
