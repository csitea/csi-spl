// HUM-10 (owner, t1 86698d8a): "On mobile there is the option to copy the
// whole text of a card but there is no option to actually have the regular
// behavior that you see in browsers: you just keep your thumb pressed ... and
// then a pop-up appears. You will be able to select text and copy just part of
// the text."
// On a phone a long press on a card's TEXT is the browser's own: it selects a
// word (handles, the native copy pop-up). The rest of the card (the header)
// keeps the card's long press: the menu, or the topic lift.
// Runs against the lde mock (no hub).
//
// Headless desktop Chrome never runs the phone's own long-press selection
// (a plain page with no script selects nothing either), so the two halves of
// it are proven apart, on a phone viewport 390x844 with REAL touch input:
//   1  the text is selectable: the browser's own selection (a drag across the
//      first word) leaves a non-empty selection inside the text. Before the
//      fix the whole card was user-select: none at <= 820 px
//   2  CONTROL: a thumb held on the card's header (its time) still opens the
//      card menu and selects nothing
//   3  a thumb held on a topic card's text opens no card menu and lifts
//      nothing, and the contextmenu Android fires during that hold is left to
//      the browser (not default-prevented): its selection pop-up shows
//
// Run:
//   node tests/e2e/phone-longpress-select.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/phone-longpress-select.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const CH = 'longpress-select'
const TEXT = 'Longpress selectable words in this phone card body'

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

const cardSel = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
/** The start of the second word of a card's body text, or its header's time. */
const pointOf = (p, sel, part) => p.evaluate((sel, part) => {
  const card = document.querySelector(sel)
  if (!card) return null
  card.scrollIntoView({ block: 'center' })
  if (part === 'time') {
    const r = card.querySelector('.msg-time').getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  }
  const body = card.querySelector('.msg-body')
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT)
  let node = walker.nextNode()
  while (node && !node.textContent.trim()) node = walker.nextNode()
  /* the SECOND word: the first starts under the card's 12 px move handle */
  const word = /\S+\s+(\S+)/.exec(node.textContent)
  const at = word.index + word[0].length - word[1].length
  const range = document.createRange()
  range.setStart(node, at)
  range.setEnd(node, at + 4)
  const r = range.getBoundingClientRect()
  if (part === 'word') return { x0: r.left + 1, x1: r.right - 1, y: r.top + r.height / 2 }
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
}, sel, part)
const state = (p, sel) => p.evaluate((sel) => {
  const s = window.getSelection()
  const body = document.querySelector(sel)?.querySelector('.msg-body')
  return {
    selection: s ? String(s).trim() : '',
    inBody: Boolean(s && s.rangeCount && body && body.contains(s.getRangeAt(0).commonAncestorContainer)),
    menu: Boolean(document.querySelector('[data-testid=msg-menu]')),
    ghost: Boolean(document.querySelector('[data-testid=move-ghost]')),
  }
}, sel)

/** A thumb held still for `ms`; `during` runs while it is down. */
async function hold(cdp, pt, ms, during) {
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: pt.x, y: pt.y }] })
  await sleep(ms)
  const got = during ? await during() : undefined
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await sleep(400)
  return got
}
/** Android's contextmenu of a long press, at the text under the thumb. */
const androidContextMenu = (p, sel, pt) => p.evaluate((sel, { x, y }) => {
  const el = document.elementFromPoint(x, y)
  const ev = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: x, clientY: y })
  el.dispatchEvent(ev)
  const body = document.querySelector(sel)?.querySelector('.msg-body')
  return { prevented: ev.defaultPrevented, onText: Boolean(body && body.contains(el)) }
}, sel, pt)
/** Back to the card when a step's click opened the topic (the fix's absence). */
async function backToChannel(p, sel) {
  await sleep(600)
  const away = await p.evaluate((sel) => {
    const card = document.querySelector(sel)
    if (!card) return true
    const r = card.getBoundingClientRect()
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + Math.min(r.height / 2, 20))
    return !card.contains(hit)
  }, sel)
  if (away) {
    await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic')?.close())
    await p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), '/channel/' + CH)
    await sleep(800)
  }
  return away
}

const seed = (p) => p.evaluate(async ({ CH, TEXT }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(CH)
  await app.config.globalProperties.$router.push('/channel/' + CH)
  await new Promise((r) => setTimeout(r, 500))
  const top = await ch.send(TEXT, undefined, undefined, undefined, 1)
  return { msg_id: top.msg_id }
}, { CH, TEXT })

const srv = await startServer()
const browser = await launch()
try {
  const m = await browser.newPage()
  const errors = []
  m.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  m.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await m.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await m.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  const cdp = await m.createCDPSession()
  const s = await seed(m)
  const card = cardSel(s.msg_id)
  await m.waitForSelector(card, { timeout: 10000 })
  await sleep(600)

  /* ---- 1. the text is selectable ------------------------------------------ */
  const word = await pointOf(m, card, 'word')
  await m.mouse.move(word.x0, word.y)
  await m.mouse.down()
  await m.mouse.move(word.x1, word.y, { steps: 6 })
  await m.mouse.up()
  await sleep(200)
  const s1 = await state(m, card)
  await shot(m, '1-card-text-select')
  ok('1 the browser selects part of the card\'s text', s1.selection && s1.inBody && TEXT.includes(s1.selection) && s1.selection.length < TEXT.length, s1)
  await m.evaluate(() => window.getSelection()?.removeAllRanges())
  ok('1 ...and the click that ends it does not open the topic', !(await backToChannel(m, card)))

  /* ---- 2. CONTROL: the header keeps the card's long press ------------------ */
  await hold(cdp, await pointOf(m, card, 'time'), 900)
  const s2 = await state(m, card)
  await shot(m, '2-header-hold')
  ok('2 a thumb held on the card\'s header still opens the card menu', s2.menu, s2)
  ok('2 ...and selects no text', !s2.selection, s2)
  /* the sheet closes on a tap on its backdrop, above it */
  await m.touchscreen.tap(195, 40)
  await sleep(500)
  ok('2 ...and the sheet closes again', !(await state(m, card)).menu)
  await backToChannel(m, card)

  /* ---- 3. a thumb on the text is the browser's ---------------------------- */
  /* LAST: headless Chrome sends a click when this finger lifts (a phone's own
     long press does not), and on a topic card that click opens the topic */
  const at = await pointOf(m, card, 'text')
  const cm = await hold(cdp, at, 900, async () => ({ ...(await androidContextMenu(m, card, at)), ...(await state(m, card)) }))
  const s3 = await state(m, card)
  await shot(m, '3-card-text-hold')
  ok('3 a thumb held on a card\'s text opens no card menu and lifts nothing', cm.onText && !cm.menu && !cm.ghost && !s3.menu && !s3.ghost, { cm, s3 })
  ok('3 ...and its contextmenu is left to the browser (selection pop-up)', cm.onText && cm.prevented === false, cm)

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} checks pass`)
process.exit(failed.length ? 1 : 0)
