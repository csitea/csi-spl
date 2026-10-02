// HUM-10 (owner, t1 5a410ad5): "One should be able to drag and drop topics
// into other topics on mobile as well." On a phone a long press on a topic
// card lifts it, the finger drags it onto another topic card, and the release
// is the desktop's drop (useMove.land): the same Merge confirm, the same
// merge, the same Undo (the desktop path: merge-by-drag.test.mjs).
// Runs against the lde mock (no hub).
//
// Phone 390x844, REAL touch input (CDP touch events):
//   1  CONTROL: a short touch-and-swipe on a card scrolls the list and lifts
//      nothing (no ghost, no lit card, no confirm)
//   2  long press on topic TWO, drag onto topic ONE: a ghost, only ONE lit;
//      the release opens the merge confirm; Confirm merges (TWO's messages are
//      now in ONE's topic), the toast offers Undo, Undo brings TWO back
//   3  a hold released where it was opens the card menu (with Merge into
//      topic…, the way that needs no drag) and moves nothing
//   4  the finger held near the list's bottom edge scrolls the list
//
// Run:
//   node tests/e2e/merge-by-touch-drag.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/merge-by-touch-drag.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const A = 'touch-merge-a'
const B = 'touch-merge-b'
const FILLER = 12

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

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
/** The middle of a card's body (not its 12 px handle, not a link). */
const bodyOf = (p, id) => p.evaluate((sel) => {
  const e = document.querySelector(sel)
  if (!e) return null
  e.scrollIntoView({ block: 'center' })
  const r = e.getBoundingClientRect()
  return { x: r.left + r.width * 0.6, y: r.top + r.height / 2 }
}, midCard(id))
const state = (p) => p.evaluate(() => ({
  lit: [...document.querySelectorAll('article.msg.msg--move-over')].map((e) => e.getAttribute('data-msg-id')),
  ghost: document.querySelector('[data-testid=move-ghost]')?.textContent || null,
  confirm: Boolean(document.querySelector('[data-testid=merge-confirm-confirm]')),
  menu: Boolean(document.querySelector('[data-testid=msg-menu]')),
}))
/** The scroll position of the box the topic cards scroll in (MessageCard scrollBox). */
const listTop = (p, id) => p.evaluate((sel) => {
  for (let e = document.querySelector(sel)?.parentElement; e; e = e.parentElement) {
    const oy = getComputedStyle(e).overflowY
    if ((oy === 'auto' || oy === 'scroll') && e.scrollHeight > e.clientHeight) return { top: e.scrollTop, room: e.scrollHeight - e.clientHeight }
  }
  const d = document.scrollingElement
  return { top: d.scrollTop, room: d.scrollHeight - d.clientHeight }
}, midCard(id))
const onScreen = (p, id) => p.evaluate((sel) => Boolean(document.querySelector(sel)), midCard(id))
const toastText = (p) => p.evaluate(() => document.querySelector('[data-testid=move-toast-text]')?.textContent.trim() || '')

/** Finger walk from `a` to `b` in `n` steps, `ms` apart. */
async function walk(p, a, b, n, ms) {
  for (let i = 1; i <= n; i++) {
    await p.touchscreen.touchMove(a.x + ((b.x - a.x) * i) / n, a.y + ((b.y - a.y) * i) / n)
    await sleep(ms)
  }
}

const seed = (p) => p.evaluate(async ({ A, B, FILLER }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(B)
  await ch.createChannel(A)
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  for (let i = 0; i < FILLER; i++) await ch.send(`HUM-10 filler topic ${i}`, undefined, undefined, undefined, 1)
  const one = await ch.send('HUM-10 topic one', undefined, undefined, undefined, 1)
  await new Promise((r) => setTimeout(r, 50))
  const two = await ch.send('HUM-10 topic two', undefined, undefined, undefined, 1)
  const reply = await ch.send('HUM-10 a reply on two', two.task_id, undefined, undefined, 0)
  return { one: { msg_id: one.msg_id, task_id: one.task_id }, two: { msg_id: two.msg_id, task_id: two.task_id }, reply: { msg_id: reply.msg_id } }
}, { A, B, FILLER })

const taskOf = (p, id) => p.evaluate((id) => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  return store.messages.find((m) => m.msg_id === id)?.task_id || ''
}, id)

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
  const s = await seed(m)
  await m.waitForSelector(midCard(s.two.msg_id), { timeout: 10000 })
  await sleep(600)

  /* ---- 1. CONTROL: a quick swipe scrolls and lifts nothing --------------- */
  const t0 = await listTop(m, s.two.msg_id)
  const f0 = await bodyOf(m, s.two.msg_id)
  const before = await listTop(m, s.two.msg_id)
  await m.touchscreen.touchStart(f0.x, f0.y)
  const mid = []
  for (let i = 1; i <= 6; i++) {
    await m.touchscreen.touchMove(f0.x, f0.y - i * 30)
    await sleep(16)
  }
  mid.push(await state(m))
  await m.touchscreen.touchEnd()
  await sleep(500)
  const after = await listTop(m, s.two.msg_id)
  const s1 = await state(m)
  ok('1 control: a short touch-and-swipe lifts nothing (no ghost, no lit card)', mid.concat([s1]).every((x) => !x.ghost && x.lit.length === 0), mid.concat([s1]))
  ok('1 control: ... opens no confirm and leaves both topics', !s1.confirm && await onScreen(m, s.one.msg_id) && await onScreen(m, s.two.msg_id))
  ok('1 control: ... and the list scrolled', before.room === 0 || after.top !== before.top, { t0, before, after })

  /* ---- 2. long press TWO, drag onto ONE, confirm, Undo -------------------- */
  const from = await bodyOf(m, s.two.msg_id)
  const to = await m.evaluate((sel) => { const r = document.querySelector(sel).getBoundingClientRect(); return { x: r.left + r.width * 0.6, y: r.top + r.height / 2 } }, midCard(s.one.msg_id))
  await m.touchscreen.touchStart(from.x, from.y)
  await sleep(700)
  const lifted = await state(m)
  ok('2 the long press lifts the card (the ghost carries its title)', /HUM-10 topic two/.test(lifted.ghost || ''), lifted)
  await walk(m, from, to, 10, 30)
  await sleep(150)
  const over = await state(m)
  ok('2 over topic ONE: exactly that card is lit', over.lit.length === 1 && over.lit[0] === s.one.msg_id, over)
  await shot(m, '2-over-one')
  await m.touchscreen.touchEnd()
  await sleep(400)
  const dropped = await state(m)
  ok('2 the release opens the merge confirm (the desktop drop\'s confirm)', dropped.confirm && !dropped.ghost && dropped.lit.length === 0, dropped)
  await shot(m, '2-confirm')
  await m.evaluate(() => document.querySelector('[data-testid=merge-confirm-confirm]')?.click())
  await sleep(700)
  const merged = await toastText(m)
  ok('2 the toast reports the merge and offers Undo', /merge/i.test(merged) && Boolean(await m.$('[data-testid=move-toast-undo]')), { merged })
  ok('2 topic TWO leaves the list', !(await onScreen(m, s.two.msg_id)))
  const moved = await taskOf(m, s.two.msg_id)
  ok('2 TWO\'s opening message now sits under topic ONE (a reply there)', moved === s.one.task_id, { moved, one: s.one.task_id })
  await shot(m, '2-merged')
  const undo = await m.evaluate(() => { const b = document.querySelector('[data-testid=move-toast-undo]'); if (b) { b.click(); return true } return false })
  await sleep(800)
  ok('2 Undo brings topic TWO back', undo && await onScreen(m, s.two.msg_id) && (await taskOf(m, s.two.msg_id)) === s.two.task_id)

  /* ---- 3. a hold released in place: the menu, nothing moves --------------- */
  await sleep(500)
  const h = await bodyOf(m, s.one.msg_id)
  await m.touchscreen.touchStart(h.x, h.y)
  await sleep(700)
  await m.touchscreen.touchEnd()
  await sleep(500)
  const s3 = await state(m)
  const items = await m.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  ok('3 a hold released in place opens the card menu, no ghost, no confirm', s3.menu && !s3.ghost && !s3.confirm, s3)
  ok('3 ... and the menu offers Merge into topic… (no drag needed)', items.includes('msg-menu-merge-topic'), items)
  /* the sheet closes on a press outside it (usePointMenu) */
  await m.evaluate(() => document.body.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true })))
  await sleep(400)
  ok('3 ... a press outside closes it, nothing moved', !(await state(m)).menu && (await taskOf(m, s.one.msg_id)) === s.one.task_id)

  /* ---- 4. near the bottom edge the list scrolls --------------------------- */
  const g = await bodyOf(m, s.one.msg_id)
  const sc0 = await listTop(m, s.one.msg_id)
  await m.touchscreen.touchStart(g.x, g.y)
  await sleep(700)
  await walk(m, g, { x: g.x, y: 838 }, 8, 30)
  await sleep(900)
  const sc1 = await listTop(m, s.one.msg_id)
  const s4 = await state(m)
  /* back to the middle and let go there: a release on a card asks, Cancel */
  await walk(m, { x: g.x, y: 838 }, { x: g.x, y: 420 }, 6, 30)
  await m.touchscreen.touchEnd()
  await sleep(400)
  if ((await state(m)).confirm) await m.evaluate(() => document.querySelector('[data-testid=merge-confirm-cancel]')?.click())
  await sleep(300)
  ok('4 the finger near the bottom edge scrolls the list down', s4.ghost && (sc0.room === 0 || sc1.top > sc0.top), { sc0, sc1, s4 })
  ok('4 ... and nothing merged', await onScreen(m, s.one.msg_id) && (await taskOf(m, s.one.msg_id)) === s.one.task_id)

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmerge-by-touch-drag: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
