// SPL-1024 (specs/045, SC-MV-2): move a topic to a channel and a reply to a
// topic - by drag and from the card menu - with the Undo, and the refusals.
// Runs against the lde mock (no hub): the mock client moves with the hub's
// refusals and the author-only gate (utils/spool-client.mjs mockMove).
//
// Desktop 1440x900 (drag is a desktop pointer gesture; a phone has the menu):
//   1  refusal: another author's card (GRK-03 in #alerts) is not movable -
//      no drag armed, no Move to channel… in its menu (CONTROL for 3)
//   2  a press in a card's TEXT selects text and arms no drag (real mouse)
//   3  topic drag: while an own card is dragged only the channels it may go
//      to light up (not its own, not #lobby); a random drag (no move type)
//      is refused by the target; the drop on #b moves the card out of #a;
//      the toast says "Moved to #b" and Undo brings it back
//   4  a drop on a row that is not a target (the card's own channel) moves nothing
//   5  reply drag: the open topic's reply drags onto another middle card
//      (only other cards light up, its own topic's card does not); the reply
//      leaves the pane and shows "moved from ..." in the target topic
//   6  menu path (keyboard): Move to topic… on the moved reply lists topic
//      one (not its own), a typed filter + Enter moves it back home (stamp
//      cleared); Move to channel… lists #b / #alerts (not #a, not #lobby),
//      Escape moves nothing, filter + Enter moves the topic, and #b shows
//      "moved from #a"
//
// The drag is dispatched as DOM DragEvents carrying a real DataTransfer
// (headless Chrome starts no native drag from synthetic mouse input); the
// press that arms the card is a real pointer press where noted.
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
const MIME = 'application/x-spool-move'

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

/**
 * Arm the source with a mouse press outside its text (the header), then run
 * one DragEvent sequence: dragstart on the source, dragenter/dragover/drop
 * on the target, dragend on the source (when it is still there).
 * `withType: false` is a random drag (plain text, no move type).
 */
function dnd(p, source, target, { drop = true, withType = true, peek = '' } = {}) {
  return p.evaluate(async ({ source, target, drop, withType, peek, MIME }) => {
    const src = document.querySelector(source)
    const dst = document.querySelector(target)
    if (!src || !dst) return { error: 'missing', src: Boolean(src), dst: Boolean(dst) }
    const meta = src.querySelector('.msg-meta') || src
    const r = meta.getBoundingClientRect()
    meta.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, pointerType: 'mouse', button: 0, isPrimary: true, clientX: r.left + 4, clientY: r.top + 4 }))
    meta.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, cancelable: true, pointerType: 'mouse', button: 0, isPrimary: true }))
    await new Promise((res) => setTimeout(res, 50))
    const draggable = src.getAttribute('draggable')
    const dt = new DataTransfer()
    if (withType) {
      src.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: dt }))
    } else {
      dt.setData('text/plain', 'just some text')
    }
    await new Promise((res) => setTimeout(res, 50))
    const lit = peek ? [...document.querySelectorAll(peek)].map((e) => e.getAttribute('data-order') || e.getAttribute('data-msg-id')) : []
    dst.dispatchEvent(new DragEvent('dragenter', { bubbles: true, cancelable: true, dataTransfer: dt }))
    const over = new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt })
    dst.dispatchEvent(over)
    await new Promise((res) => setTimeout(res, 30))
    const overClass = dst.className
    let dropped = false
    if (drop) {
      const ev = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt })
      dst.dispatchEvent(ev)
      dropped = ev.defaultPrevented
    }
    if (src.isConnected) src.dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true, dataTransfer: dt }))
    return { draggable, accepted: over.defaultPrevented, dropped, lit, overClass }
  }, { source, target, drop, withType, peek, MIME })
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
  await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), sel)
  await sleep(300)
  return p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
}

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

  /* ---- 1. another author's card: not movable ------------------------------ */
  const other = await dnd(p, midCard(OTHER_CARD), railRow('alerts'), { drop: false })
  const otherMovable = await p.$eval(midCard(OTHER_CARD), (e) => e.getAttribute('data-movable'))
  ok('1 another author\'s card: no drag armed, not marked movable', other.draggable === null && otherMovable === null, { other, otherMovable })
  const otherMenu = await openMenu(p, midCard(OTHER_CARD))
  ok('1 its menu offers no Move to channel…', otherMenu.length > 0 && !otherMenu.includes('msg-menu-move-channel'), otherMenu)
  await p.keyboard.press('Escape')
  await sleep(200)

  /* ---- seed: two channels, two own topics in #a, a reply on the first ---- */
  const seeded = await p.evaluate(async ({ A, B }) => {
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
  await p.waitForSelector(midCard(seeded.one.msg_id), { timeout: 10000 })
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await sleep(400)
  ok('seed: #a holds two own cards, both marked movable', await p.evaluate((ids) => ids.every((id) => document.querySelector(`.spool-main article.msg[data-msg-id="${id}"]`)?.getAttribute('data-movable') === 'true'), [seeded.one.msg_id, seeded.two.msg_id]))

  /* ---- 2. a press in the text selects, arms nothing ------------------------ */
  const body = await p.$eval(`${midCard(seeded.two.msg_id)} .msg-body`, (e) => { const r = e.getBoundingClientRect(); return { x: r.left + 2, y: r.top + r.height / 2, w: r.width } })
  await p.mouse.move(body.x, body.y)
  await p.mouse.down()
  await p.mouse.move(body.x + Math.min(120, body.w - 4), body.y, { steps: 6 })
  await p.mouse.up()
  const sel = await p.evaluate((sel) => ({ text: String(window.getSelection()), draggable: document.querySelector(sel)?.getAttribute('draggable') }), midCard(seeded.two.msg_id))
  ok('2 a drag across the card text selects it and arms no card drag', sel.text.length > 0 && sel.draggable === null, sel)
  await p.evaluate(() => window.getSelection()?.removeAllRanges())

  /* ---- 3. topic drag onto a rail channel ----------------------------------- */
  const random = await dnd(p, midCard(seeded.one.msg_id), railRow(B), { withType: false, drop: false })
  ok('3 a random drag (no move type) is refused by the channel row', random.accepted === false, random)
  const drag = await dnd(p, midCard(seeded.one.msg_id), railRow(B), { peek: '#sidebar-panel-channels .nav-row[data-move-target="true"]' })
  ok('3 the press outside the text armed the card (draggable)', drag.draggable === 'true', drag)
  ok('3 only the channels it may go to light up: #b and #alerts, not its own #a, not #lobby',
    drag.lit.includes(B) && drag.lit.includes('alerts') && !drag.lit.includes(A) && !drag.lit.includes('lobby'), drag.lit)
  ok('3 the row under the pointer takes the drop', drag.accepted && drag.dropped && /nav-row--move-over/.test(drag.overClass), drag)
  const gone = await until(p, (sel) => !document.querySelector(sel), midCard(seeded.one.msg_id))
  ok('3 the card left #a', gone)
  await p.waitForSelector('[data-testid=move-toast]', { timeout: 5000 }).catch(() => {})
  const t3 = await toastText(p)
  ok('3 the toast says where it went and offers Undo', t3 === `Moved to #${B}` && Boolean(await p.$('[data-testid=move-toast-undo]')), t3)
  await shot(p, '3-topic-dropped')
  await p.click('[data-testid=move-toast-undo]')
  const back = await until(p, (sel) => Boolean(document.querySelector(sel)), midCard(seeded.one.msg_id))
  ok('3 Undo brings the card back to #a', back, await toastText(p))
  const inB = await p.evaluate(async ({ B, id }) => {
    const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    return ch.messages.some((m) => m.msg_id === id && m.channel === B)
  }, { B, id: seeded.one.msg_id })
  ok('3 ... and nothing of it is left in #b', !inB)

  /* ---- 4. a drop on a non-target does nothing ------------------------------- */
  const self = await dnd(p, midCard(seeded.one.msg_id), railRow(A))
  await sleep(400)
  ok('4 its own channel is no target: the drop is refused and the card stays',
    self.accepted === false && self.dropped === false && Boolean(await p.$(midCard(seeded.one.msg_id))), self)

  /* ---- 5. reply drag onto another middle card ------------------------------- */
  await openTopic(p, seeded.one.msg_id, paneRow(seeded.reply.msg_id))
  const paneState = await p.evaluate(({ r, c }) => ({
    reply: document.querySelector(`aside[data-pane="topic"] article.msg[data-msg-id="${r}"]`)?.getAttribute('data-movable'),
    opener: document.querySelector(`aside[data-pane="topic"] article.msg[data-msg-id="${c}"]`)?.getAttribute('data-movable') ?? 'absent',
  }), { r: seeded.reply.msg_id, c: seeded.one.msg_id })
  ok('5 in the open topic the reply is movable, the opening card is not', paneState.reply === 'true' && paneState.opener !== 'true', paneState)
  const rdrag = await dnd(p, paneRow(seeded.reply.msg_id), midCard(seeded.two.msg_id), { peek: '.spool-main article.msg[data-move-target="true"]' })
  ok('5 only the other topic lights up (not the reply\'s own topic)', rdrag.lit.includes(seeded.two.msg_id) && !rdrag.lit.includes(seeded.one.msg_id), rdrag.lit)
  ok('5 the card under the pointer takes the drop', rdrag.draggable === 'true' && rdrag.accepted && rdrag.dropped, rdrag)
  const left = await until(p, (sel) => !document.querySelector(sel), paneRow(seeded.reply.msg_id))
  ok('5 the reply left the open topic', left)
  const t5 = await toastText(p)
  ok('5 the toast names the target topic', /SPL-1024 topic two/.test(t5), t5)
  await openTopic(p, seeded.two.msg_id, paneRow(seeded.reply.msg_id))
  const note = await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-moved]`)?.textContent.trim() || '', paneRow(seeded.reply.msg_id))
  ok('5 in the target topic the reply says where it came from', /moved from/.test(note) && /topic one/.test(note), note)
  await shot(p, '5-reply-dropped')

  /* ---- 6. the menu path ------------------------------------------------------ */
  /* the pane is on topic two, which now holds the reply: Move to topic… takes
     it back into topic one */
  const rmenu = await openMenu(p, paneRow(seeded.reply.msg_id))
  ok('6 the reply\'s menu offers Move to topic…', rmenu.includes('msg-menu-move-topic'), rmenu)
  await p.click('[data-testid=msg-menu-move-topic]')
  await p.waitForSelector('[data-testid=move-picker-topic] [data-testid=move-picker-row]', { timeout: 8000 }).catch(() => {})
  const tchoices = await p.evaluate(() => [...document.querySelectorAll('[data-testid=move-picker-row]')].map((e) => e.getAttribute('data-target')))
  ok('6 the topic picker lists topic one, not the reply\'s own topic', tchoices.includes(seeded.one.task_id) && !tchoices.includes(seeded.two.task_id), tchoices)
  const tfocus = await p.evaluate(() => document.activeElement?.getAttribute('data-testid') || '')
  ok('6 the filter has the focus (keyboard path)', tfocus === 'move-picker-filter', tfocus)
  await shot(p, '6-topic-picker')
  await p.keyboard.type('topic one')
  await p.keyboard.press('Enter')
  const outOfTwo = await until(p, (sel) => !document.querySelector(sel), paneRow(seeded.reply.msg_id))
  ok('6 the pick moves the reply out of topic two', outOfTwo, await toastText(p))
  const homeAgain = await p.evaluate(({ r, t }) => {
    const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    const row = ch.messages.find((m) => m.msg_id === r)
    return { task: row?.task_id === t, moved: row?.moved_at === undefined }
  }, { r: seeded.reply.msg_id, t: seeded.one.task_id })
  ok('6 ... back home in topic one, the stamp cleared', homeAgain.task && homeAgain.moved, homeAgain)

  const menu = await openMenu(p, midCard(seeded.two.msg_id))
  ok('6 an own card\'s menu offers Move to channel…', menu.includes('msg-menu-move-channel'), menu)
  await p.click('[data-testid=msg-menu-move-channel]')
  await p.waitForSelector('[data-testid=move-picker-channel] [data-testid=move-picker-row]', { timeout: 8000 }).catch(() => {})
  const choices = await p.evaluate(() => [...document.querySelectorAll('[data-testid=move-picker-row]')].map((e) => e.getAttribute('data-target')))
  ok('6 the channel picker lists #b and #alerts, not #a or #lobby', choices.includes(B) && choices.includes('alerts') && !choices.includes(A) && !choices.includes('lobby'), choices)
  await shot(p, '6-channel-picker')
  await p.keyboard.press('Escape')
  await sleep(300)
  ok('6 Escape closes the picker, nothing moved', !(await p.$('[data-testid=move-picker-channel]')) && Boolean(await p.$(midCard(seeded.two.msg_id))))
  await openMenu(p, midCard(seeded.two.msg_id))
  await p.click('[data-testid=msg-menu-move-channel]')
  await p.waitForSelector('[data-testid=move-picker-channel] [data-testid=move-picker-row]', { timeout: 8000 }).catch(() => {})
  await p.keyboard.type(B)
  await p.keyboard.press('Enter')
  const moved2 = await until(p, (sel) => !document.querySelector(sel), midCard(seeded.two.msg_id))
  ok('6 the pick moves the topic out of #a', moved2, await toastText(p))
  await go(p, '/channel/' + B)
  const inBnow = await until(p, (sel) => Boolean(document.querySelector(sel)), midCard(seeded.two.msg_id))
  const cardNote = await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-moved]`)?.textContent.trim() || '', midCard(seeded.two.msg_id))
  ok('6 #b shows it with "moved from #a"', inBnow && cardNote === `moved from #${A}`, cardNote)

  ok('no page errors', errors.length === 0, errors)
  await p.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmove-by-drag: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
