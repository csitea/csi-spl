// SPL-1024 + SPL-1134 (specs/045 SC-MV-2, SC-MV-4): move a topic to a
// channel and a reply to a topic - by the card's drag HANDLE and from the
// card menu - with the Undo, the cancel and the refusals.
// Runs against the lde mock (no hub): the mock client moves with the hub's
// refusals and the author-only gate (utils/spool-client.mjs mockMove).
//
// Desktop 1440x900, REAL mouse input (the drag is a pointer stream, so
// puppeteer's mouse drives it end to end):
//   1  refusal: another author's card (GRK-03 in #alerts) has no handle and
//      no Move to channel… in its menu
//   2  hover: the grip + grab cursor show on the 12 px strip only, not on
//      the card body
//   3  a drag from the card BODY selects text and moves nothing (no row lit,
//      no ghost)
//   4  a drag from the strip: a ghost with the title; EXACTLY ONE channel
//      row lit at every step, the one under the pointer; its own channel and
//      the lobby are never lit and say "not allowed"; leaving the rail clears
//      it; the drop on #b moves the card, the toast offers Undo, Undo brings
//      it back
//   5  cancel: a drop outside every row, and Escape mid-drag, move nothing
//   6  reply drag from its handle onto another middle card (only that card
//      lit, its own topic's card never); it leaves the pane and says "moved
//      from ..." in the target topic
//   7  menu path (keyboard): Move to topic… / Move to channel… pickers
// Phone 390x844 (touch):
//   8  the handle is there (12 px); a hold on it opens Move to channel…
//      (a phone has no rail beside the list); a hold on the body opens the
//      card menu instead, and a swipe from the body moves nothing
//
// Run:
//   node tests/e2e/move-by-drag.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/move-by-drag.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
/* the lde mock #alerts card, from GRK-03 (not the viewer HUM-1) */
const OTHER_CARD = '66666666-6666-4666-8666-666666666666'
const A = 'spl-1024-a'
const B = 'spl-1024-b'

if (OUT) mkdirSync(OUT, { recursive: true })

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

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

/** Client-side navigation: a page load would drop the mock tenant's state. */
const go = (p, path) => p.evaluate(async (path) => {
  const r = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router
  await r.push(path)
}, path)

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const paneRow = (id) => `aside[data-pane="topic"] article.msg[data-msg-id="${id}"]`
const railRow = (ch) => `#sidebar-panel-channels .nav-row[data-order="${ch}"]`

const handleOf = (sel) => `${sel} [data-testid=move-handle]`

/** Centre of an element, or null. */
const centre = (p, sel) => p.evaluate((sel) => {
  const e = document.querySelector(sel)
  if (!e) return null
  const r = e.getBoundingClientRect()
  return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height }
}, sel)

/** What the drag layer shows right now: the lit rows, the refusing rows, the ghost. */
const dragState = (p) => p.evaluate(() => ({
  lit: [...document.querySelectorAll('.nav-row--move-over, article.msg.msg--move-over')].map((e) => e.getAttribute('data-order') || e.getAttribute('data-msg-id')),
  denied: [...document.querySelectorAll('.nav-row--move-denied')].map((e) => ({ id: e.getAttribute('data-order'), label: e.getAttribute('data-move-denied-label') })),
  ghost: document.querySelector('[data-testid=move-ghost]')?.textContent || null,
}))

/**
 * A real mouse drag: press at `from` (a point), walk through `via` points
 * (sampling the drag state at each), release at the last. `escape` presses
 * Escape before the release.
 */
async function mouseDrag(p, from, via, { escape = false } = {}) {
  await p.mouse.move(from.x, from.y)
  await p.mouse.down()
  const seen = []
  for (const pt of via) {
    await p.mouse.move(pt.x, pt.y, { steps: 8 })
    await sleep(60)
    seen.push(await dragState(p))
  }
  if (escape) {
    await p.keyboard.press('Escape')
    await sleep(60)
    seen.push(await dragState(p))
  }
  await p.mouse.up()
  await sleep(150)
  return seen
}

/**
 * Open a middle card's topic on the right and wait for `row` there. A move
 * re-reads the channel (the mock's catchUp), which can swap the card element
 * under a click, so the click is retried.
 */
async function openTopic(p, cardId, row) {
  for (let i = 0; i < 3; i++) {
    await sleep(300)
    await p.evaluate((sel) => document.querySelector(sel)?.click(), `${midCard(cardId)} .msg-meta .msg-time`)
    if (await p.waitForSelector(row, { timeout: 4000 }).then(() => true, () => false)) return true
  }
  return false
}

const toastText = (p) => p.evaluate(() => document.querySelector('[data-testid=move-toast-text]')?.textContent.trim() || '')

async function openMenu(p, sel) {
  /* the menu mounts lazily: wait for its items (a fixed sleep read [] now and then), click again once */
  /* CLE-77891: a disabled entry (shown with its reason, not hidden) reads 'msg-menu-x:off' */
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid') + (e.getAttribute('aria-disabled') === 'true' ? ':off' : '')))
  for (let i = 0; i < 2; i++) {
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), sel)
    for (let t = 0; t < 20; t++) {
      await sleep(150)
      const got = await items()
      if (got.length) return got
    }
  }
  return []
}

/** Seed two channels and two own topics in #a, a reply on the first (the mock tenant lives per page load). */
const seed = (p) => p.evaluate(async ({ A, B }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(B)
  await ch.createChannel(A)
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const one = await ch.send('SPL-1024 topic one', undefined, undefined, undefined, 1)
  await new Promise((r) => setTimeout(r, 50))
  const two = await ch.send('SPL-1024 topic two', undefined, undefined, undefined, 1)
  const reply = await ch.send('SPL-1024 a reply on one', one.task_id, undefined, undefined, 0)
  return { one: { msg_id: one.msg_id, task_id: one.task_id }, two: { msg_id: two.msg_id, task_id: two.task_id }, reply: { msg_id: reply.msg_id } }
}, { A, B })

const inChannel = (p, id, ch) => p.evaluate(({ id, ch }) => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  return store.messages.find((m) => m.msg_id === id)?.channel === ch
}, { id, ch })

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector(midCard(OTHER_CARD), { timeout: NAV_TIMEOUT })
  await sleep(600)

  /* ---- 1. another author's card: no handle ------------------------------- */
  const other = await p.evaluate((sel) => ({
    handle: Boolean(document.querySelector(`${sel} [data-testid=move-handle]`)),
    movable: document.querySelector(sel)?.getAttribute('data-movable') ?? null,
    draggable: document.querySelector(sel)?.getAttribute('draggable') ?? null,
  }), midCard(OTHER_CARD))
  ok('1 another author\'s card: no handle, not movable, no HTML5 draggable', !other.handle && other.movable === null && other.draggable === null, other)
  const otherMenu = await openMenu(p, midCard(OTHER_CARD))
  ok('1 its menu: Move to channel… disabled', otherMenu.includes('msg-menu-move-channel:off'), otherMenu)
  await p.keyboard.press('Escape')
  await sleep(200)

  const seeded = await seed(p)
  await p.waitForSelector(midCard(seeded.one.msg_id), { timeout: 10000 })
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await sleep(400)
  ok('seed: #a holds two own cards, both with a handle', await p.evaluate((ids) => ids.every((id) => document.querySelector(`.spool-main article.msg[data-msg-id="${id}"] [data-testid=move-handle]`)), [seeded.one.msg_id, seeded.two.msg_id]))

  /* ---- 2. hover: the affordance on the strip only ------------------------- */
  const card1 = await p.$eval(midCard(seeded.one.msg_id), (e) => { const r = e.getBoundingClientRect(); return { left: r.left, top: r.top, w: r.width, h: r.height } })
  const hsel = handleOf(midCard(seeded.one.msg_id))
  const look = () => p.$eval(hsel, (e) => { const cs = getComputedStyle(e); const r = e.getBoundingClientRect(); return { img: cs.backgroundImage, cursor: cs.cursor, w: Math.round(r.width), left: Math.round(r.left) } })
  await p.mouse.move(card1.left + card1.w / 2, card1.top + card1.h / 2)
  await sleep(150)
  const onBody = await look()
  await p.mouse.move(card1.left + 5, card1.top + card1.h / 2)
  await sleep(150)
  const onStrip = await look()
  ok('2 the handle is the card\'s first 12 px', onStrip.w === 12 && Math.abs(onStrip.left - Math.round(card1.left)) <= 1, onStrip)
  ok('2 hover on the strip shows the grip and the grab cursor', onStrip.img !== 'none' && onStrip.cursor === 'grab', onStrip)
  ok('2 hover on the card body shows no grip (control)', onBody.img === 'none', onBody)
  await shot(p, '2-hover-strip')

  /* ---- 3. a drag from the card body moves nothing -------------------------- */
  const b1 = await centre(p, railRow(B))
  const bodyPt = await p.$eval(`${midCard(seeded.one.msg_id)} .msg-body`, (e) => { const r = e.getBoundingClientRect(); return { x: r.left + 2, y: r.top + r.height / 2 } })
  const fromBody = await mouseDrag(p, bodyPt, [{ x: bodyPt.x + 80, y: bodyPt.y }, b1])
  await sleep(300)
  ok('3 a drag from the card body lights nothing and shows no ghost', fromBody.every((s) => s.lit.length === 0 && s.ghost === null), fromBody)
  ok('3 ... and the card stays in #a', Boolean(await p.$(midCard(seeded.one.msg_id))) && await inChannel(p, seeded.one.msg_id, A))
  await p.evaluate(() => window.getSelection()?.removeAllRanges())

  /* ---- 4. a drag from the strip: exactly one lit, drop moves, Undo -------- */
  const start = { x: card1.left + 5, y: card1.top + card1.h / 2 }
  const aRow = await centre(p, railRow(A))
  const alertsRow = await centre(p, railRow('alerts'))
  const lobbyRow = await centre(p, railRow('lobby'))
  const middle = { x: card1.left + card1.w / 2, y: card1.top + card1.h + 40 }
  const path = [aRow, alertsRow, lobbyRow, middle, b1].filter(Boolean)
  await p.mouse.move(start.x, start.y)
  await p.mouse.down()
  const steps = []
  for (const pt of path) {
    await p.mouse.move(pt.x, pt.y, { steps: 8 })
    await sleep(80)
    steps.push({ at: pt === aRow ? A : pt === alertsRow ? 'alerts' : pt === lobbyRow ? 'lobby' : pt === middle ? 'middle' : B, ...(await dragState(p)) })
  }
  /* what the eye sees, not only the classes: rows that draw an outline or a
     ring while #b is lit. A ring is a box-shadow layer with a SPREAD; the
     selected row's raise (CLE-77812: a 1 px inset bevel plus the zero-spread
     var(--focus-3d) drop shadow, and the older 3 px inset left bar) has none,
     so the current channel's own marker is not read as a target. */
  const drawn = await p.evaluate(() => [...document.querySelectorAll('#sidebar-panel-channels .nav-row')].filter((r) => {
    const els = [r, r.querySelector('.nav-item')].filter(Boolean)
    const ring = (shadow) => shadow !== 'none' && shadow.split(/,(?![^(]*\))/).some((layer) => {
      const px = layer.replace(/rgba?\([^)]*\)/g, '').match(/-?[\d.]+px/g) || []
      return px.length >= 4 && parseFloat(px[3]) > 0
    })
    return els.some((e) => { const cs = getComputedStyle(e); return (cs.outlineStyle !== 'none' && parseFloat(cs.outlineWidth) > 0) || ring(cs.boxShadow) })
  }).map((r) => r.getAttribute('data-order') + ' ' + (() => { const e = r.querySelector('.nav-item'); const cs = getComputedStyle(e); const rs = getComputedStyle(r); return [rs.outlineStyle, rs.boxShadow, cs.outlineStyle, cs.boxShadow, cs.borderStyle, document.activeElement === e].join('|') })()))
  ok('4 on screen only #b is drawn as the target', drawn.length === 1 && drawn[0].startsWith(B + ' '), drawn)
  await shot(p, '4-one-lit')
  const byAt = Object.fromEntries(steps.map((s) => [s.at, s]))
  ok('4 at most ONE row is lit at every step', steps.every((s) => s.lit.length <= 1), steps.map((s) => [s.at, s.lit]))
  ok('4 the ghost carries the title', steps.every((s) => /SPL-1024 topic one/.test(s.ghost || '')), steps.map((s) => s.ghost))
  ok('4 its own channel is never lit and says "not allowed"', byAt[A].lit.length === 0 && byAt[A].denied.some((d) => d.id === A && d.label === 'not allowed'), byAt[A])
  ok('4 #alerts under the pointer is the one lit row', byAt.alerts.lit.length === 1 && byAt.alerts.lit[0] === 'alerts', byAt.alerts)
  ok('4 the lobby is never lit', !lobbyRow || (byAt.lobby.lit.length === 0), byAt.lobby || 'no lobby row in the rail')
  /* 714c7028: leaving the rail clears every CHANNEL highlight; a topic dragged
     over another topic's card lights THAT card as a merge target (not a rail row). */
  const CHANS = new Set([A, B, 'alerts', 'lobby', 'general'])
  ok('4 leaving the rail clears the channel highlight', byAt.middle.lit.every((id) => !CHANS.has(id)) && byAt.middle.denied.length === 0, byAt.middle)
  ok('4 #b under the pointer is the one lit row', byAt[B].lit.length === 1 && byAt[B].lit[0] === B, byAt[B])
  await p.mouse.up()
  const gone = await until(p, (sel) => !document.querySelector(sel), midCard(seeded.one.msg_id))
  ok('4 the drop on #b moved the card out of #a', gone)
  ok('4 after the drop nothing stays lit and the ghost is gone', await p.evaluate(() => !document.querySelector('.nav-row--move-over, .nav-row--move-denied, [data-testid=move-ghost]')))
  await p.waitForSelector('[data-testid=move-toast]', { timeout: 5000 }).catch(() => {})
  const t4 = await toastText(p)
  ok('4 the toast says where it went and offers Undo', t4 === `Moved to #${B}` && Boolean(await p.$('[data-testid=move-toast-undo]')), t4)
  await shot(p, '4-topic-dropped')
  await p.click('[data-testid=move-toast-undo]')
  const back = await until(p, (sel) => Boolean(document.querySelector(sel)), midCard(seeded.one.msg_id))
  ok('4 Undo brings the card back to #a', back && await inChannel(p, seeded.one.msg_id, A), await toastText(p))
  await sleep(400)
  await p.evaluate(() => document.querySelector('[data-testid=move-toast]') && document.querySelector('[data-testid=move-toast] button:not([data-testid=move-toast-undo])')?.click())

  /* ---- 5. cancel: a drop outside, and Escape ------------------------------- */
  const card1b = await p.$eval(midCard(seeded.one.msg_id), (e) => { const r = e.getBoundingClientRect(); return { x: r.left + 5, y: r.top + r.height / 2, cx: r.left + r.width / 2, bottom: r.bottom } })
  const b2 = await centre(p, railRow(B))
  /* 714c7028: the "outside" drop must miss every rail row AND every topic card
     (a topic dropped on a card is now a merge) - the empty right pane is both. */
  const outside = await mouseDrag(p, { x: card1b.x, y: card1b.y }, [b2, { x: 1290, y: 450 }])
  await sleep(400)
  ok('5 the drag lit #b on the way (control: the drag was live)', outside[0].lit.length === 1 && outside[0].lit[0] === B, outside[0])
  ok('5 a drop outside every row moves nothing', await inChannel(p, seeded.one.msg_id, A) && Boolean(await p.$(midCard(seeded.one.msg_id))), outside[1])
  const esc = await mouseDrag(p, { x: card1b.x, y: card1b.y }, [b2], { escape: true })
  await sleep(400)
  ok('5 Escape over a lit #b clears it and the release moves nothing', esc[0].lit[0] === B && esc[1].lit.length === 0 && esc[1].ghost === null && await inChannel(p, seeded.one.msg_id, A), esc)

  /* ---- 6. reply drag from its handle onto another middle card ------------- */
  await openTopic(p, seeded.one.msg_id, paneRow(seeded.reply.msg_id))
  const paneState = await p.evaluate(({ r, c }) => ({
    reply: Boolean(document.querySelector(`aside[data-pane="topic"] article.msg[data-msg-id="${r}"] [data-testid=move-handle]`)),
    opener: Boolean(document.querySelector(`aside[data-pane="topic"] article.msg[data-msg-id="${c}"] [data-testid=move-handle]`)),
  }), { r: seeded.reply.msg_id, c: seeded.one.msg_id })
  ok('6 in the open topic the reply has a handle, the opening card has none', paneState.reply && !paneState.opener, paneState)
  const rStart = await p.$eval(handleOf(paneRow(seeded.reply.msg_id)), (e) => { const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })
  const ownCard = await centre(p, midCard(seeded.one.msg_id))
  const twoCard = await centre(p, midCard(seeded.two.msg_id))
  const rsteps = await mouseDrag(p, rStart, [ownCard, twoCard])
  ok('6 its own topic\'s card is never lit', rsteps[0].lit.length === 0, rsteps[0])
  ok('6 the other topic under the pointer is the one lit card', rsteps[1].lit.length === 1 && rsteps[1].lit[0] === seeded.two.msg_id, rsteps[1])
  const left = await until(p, (sel) => !document.querySelector(sel), paneRow(seeded.reply.msg_id))
  ok('6 the reply left the open topic', left)
  const t6 = await toastText(p)
  ok('6 the toast names the target topic', /SPL-1024 topic two/.test(t6), t6)
  await openTopic(p, seeded.two.msg_id, paneRow(seeded.reply.msg_id))
  const note = await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-moved]`)?.textContent.trim() || '', paneRow(seeded.reply.msg_id))
  ok('6 in the target topic the reply says where it came from', /moved from/.test(note) && /topic one/.test(note), note)
  /* the narrow right pane squeezed the note to 0 px while it sat in the no-wrap author row (live, 2026-09-28) */
  const noteW = await p.evaluate((sel) => Math.round(document.querySelector(`${sel} [data-testid=msg-moved]`)?.getBoundingClientRect().width || 0), paneRow(seeded.reply.msg_id))
  ok('6 ... and the note is visible in the narrow right pane (>= 60 px wide)', noteW >= 60, noteW)
  await shot(p, '6-reply-dropped')

  /* ---- 7. the menu path ------------------------------------------------------ */
  /* the pane is on topic two, which now holds the reply: Move to topic… takes
     it back into topic one */
  const rmenu = await openMenu(p, paneRow(seeded.reply.msg_id))
  ok('7 the reply\'s menu offers Move to topic…', rmenu.includes('msg-menu-move-topic'), rmenu)
  await p.click('[data-testid=msg-menu-move-topic]')
  await p.waitForSelector('[data-testid=move-picker-topic] [data-testid=move-picker-row]', { timeout: 8000 }).catch(() => {})
  const tchoices = await p.evaluate(() => [...document.querySelectorAll('[data-testid=move-picker-row]')].map((e) => e.getAttribute('data-target')))
  ok('7 the topic picker lists topic one, not the reply\'s own topic', tchoices.includes(seeded.one.task_id) && !tchoices.includes(seeded.two.task_id), tchoices)
  const tfocus = await p.evaluate(() => document.activeElement?.getAttribute('data-testid') || '')
  ok('7 the filter has the focus (keyboard path)', tfocus === 'move-picker-filter', tfocus)
  await shot(p, '7-topic-picker')
  await p.keyboard.type('topic one')
  await p.keyboard.press('Enter')
  const outOfTwo = await until(p, (sel) => !document.querySelector(sel), paneRow(seeded.reply.msg_id))
  ok('7 the pick moves the reply out of topic two', outOfTwo, await toastText(p))
  const homeAgain = await p.evaluate(({ r, t }) => {
    const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    const row = ch.messages.find((m) => m.msg_id === r)
    return { task: row?.task_id === t, moved: row?.moved_at === undefined }
  }, { r: seeded.reply.msg_id, t: seeded.one.task_id })
  ok('7 ... back home in topic one, the stamp cleared', homeAgain.task && homeAgain.moved, homeAgain)

  const menu = await openMenu(p, midCard(seeded.two.msg_id))
  ok('7 an own card\'s menu offers Move to channel…', menu.includes('msg-menu-move-channel'), menu)
  await p.click('[data-testid=msg-menu-move-channel]')
  await p.waitForSelector('[data-testid=move-picker-channel] [data-testid=move-picker-row]', { timeout: 8000 }).catch(() => {})
  const choices = await p.evaluate(() => [...document.querySelectorAll('[data-testid=move-picker-row]')].map((e) => e.getAttribute('data-target')))
  ok('7 the channel picker lists #b and #alerts, not #a or #lobby', choices.includes(B) && choices.includes('alerts') && !choices.includes(A) && !choices.includes('lobby'), choices)
  await shot(p, '7-channel-picker')
  await p.keyboard.press('Escape')
  await sleep(300)
  ok('7 Escape closes the picker, nothing moved', !(await p.$('[data-testid=move-picker-channel]')) && Boolean(await p.$(midCard(seeded.two.msg_id))))
  await openMenu(p, midCard(seeded.two.msg_id))
  await p.click('[data-testid=msg-menu-move-channel]')
  await p.waitForSelector('[data-testid=move-picker-channel] [data-testid=move-picker-row]', { timeout: 8000 }).catch(() => {})
  await p.keyboard.type(B)
  await p.keyboard.press('Enter')
  const moved2 = await until(p, (sel) => !document.querySelector(sel), midCard(seeded.two.msg_id))
  ok('7 the pick moves the topic out of #a', moved2, await toastText(p))
  await go(p, '/channel/' + B)
  const inBnow = await until(p, (sel) => Boolean(document.querySelector(sel)), midCard(seeded.two.msg_id))
  const cardNote = await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-moved]`)?.textContent.trim() || '', midCard(seeded.two.msg_id))
  ok('7 #b shows it with "moved from #a"', inBnow && cardNote === `moved from #${A}`, cardNote)

  ok('no page errors (desktop)', errors.length === 0, errors)
  await p.close()

  /* ---- 8. phone 390: hold the handle -> the picker ------------------------ */
  const m = await browser.newPage()
  const merr = []
  m.on('pageerror', (e) => merr.push(String(e).slice(0, 200)))
  m.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await m.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await m.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  const ms = await seed(m)
  await m.waitForSelector(midCard(ms.one.msg_id), { timeout: 10000 })
  await sleep(400)
  const mh = await m.$eval(handleOf(midCard(ms.one.msg_id)), (e) => { const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2, w: Math.round(r.width), touch: getComputedStyle(e).touchAction } })
  ok('8 phone: the card has the 12 px handle (touch-action none)', mh.w === 12 && mh.touch === 'none', mh)
  await m.touchscreen.touchStart(mh.x, mh.y)
  await sleep(700)
  await m.touchscreen.touchEnd()
  await m.waitForSelector('[data-testid=move-picker-channel]', { timeout: 4000 }).catch(() => {})
  const picker = await m.evaluate(() => [...document.querySelectorAll('[data-testid=move-picker-row]')].map((e) => e.getAttribute('data-target')))
  ok('8 a hold on the handle opens Move to channel… (only allowed channels)', picker.includes(B) && !picker.includes(A) && !picker.includes('lobby'), picker)
  await shot(m, '8-phone-picker')
  await m.keyboard.press('Escape')
  await sleep(400)
  ok('8 closing it moves nothing', await inChannel(m, ms.one.msg_id, A) && !(await m.$('[data-testid=move-picker-channel]')))
  const mb = await m.$eval(`${midCard(ms.one.msg_id)} .msg-body`, (e) => { const r = e.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })
  await m.touchscreen.touchStart(mb.x, mb.y)
  await sleep(700)
  await m.touchscreen.touchEnd()
  await sleep(400)
  const bodyHold = await m.evaluate(() => ({ menu: Boolean(document.querySelector('[data-testid=msg-menu]')), picker: Boolean(document.querySelector('[data-testid=move-picker-channel]')), ghost: Boolean(document.querySelector('[data-testid=move-ghost]')) }))
  ok('8 a hold on the card body opens the card menu, not a move (control)', bodyHold.menu && !bodyHold.picker && !bodyHold.ghost, bodyHold)
  ok('no page errors (phone)', merr.length === 0, merr)
  await m.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmove-by-drag: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
