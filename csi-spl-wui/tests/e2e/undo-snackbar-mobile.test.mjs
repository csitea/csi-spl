// CLE-77871 (owner, t1 topic f20c6052: "the snack bar should work on mobile as
// well"): the three "<what> · Undo" snackbars on a PHONE - touch only, no
// mouse is ever moved, so nothing can hold the snackbar by hovering it.
//
// Runs against the lde mock (no hub). 390x844, isMobile + hasTouch. Per path:
//   A  Archived · Undo   - the card's ⋯ menu -> Archive
//   B  Archived · Undo   - the card's ⋯ menu -> Delete topic -> "Archive instead"
//   C  Deleted · Undo    - a selected reply + Delete (a tablet's keyboard)
//   D  Moved · Undo      - a reply's ⋯ menu -> "Make it a topic"
// and on each snackbar:
//   - it shows, and is still up 2.5 s later (the desktop window is 0.7 s; a
//     thumb needs more) - control: no pointer ever rested on it
//   - it sits ABOVE the docked composer (old: y 761..826 over "Message…")
//   - Undo is a >= 44 px target and is what a tap at its centre hits
//   - aria-live="polite"
//   - a tap on Undo brings the card / reply back and closes it, and the card
//     that came back is selected (focused) again, as before the action
// A also proves the hold: a finger resting on the snackbar keeps it up past
// its touch window; lifting the finger lets it close on its own.
//
// Run:
//   node tests/e2e/undo-snackbar-mobile.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/undo-snackbar-mobile.test.mjs   # what CI does
//   OUT=<dir> ... also writes a phone-size screenshot per snackbar
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const A = 'cle-77871-a'
/* utils/undo-timer.mjs UNDO_TOUCH_MIN_MS */
const TOUCH_MS = 6000

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

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const card = (id) => `article.msg[data-msg-id="${id}"]`
/* CLE-77871 add-on: after Undo the card that came back is selected (focused) again */
const reselected = (p, id) => until(p, (id) => document.activeElement?.matches?.(`article.msg[data-msg-id="${id}"]`), id, 4000)
const has = (p, sel) => p.evaluate((sel) => Boolean(document.querySelector(sel)), sel)

/** Tap the centre of the first visible element matching `sel`. */
async function tapSel(p, sel) {
  const c = await p.evaluate((sel) => {
    const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
    if (!e) return null
    e.scrollIntoView({ block: 'center' })
    const r = e.getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  }, sel)
  if (!c) return false
  await p.touchscreen.tap(Math.round(c.x), Math.round(c.y))
  return true
}

/** Tap a card's ⋯ and then the menu item `id`. */
async function menuPick(p, cardSel, id) {
  for (let i = 0; i < 3; i++) {
    await tapSel(p, `${cardSel} [data-testid=msg-menu-btn]`)
    if (await until(p, (id) => Boolean(document.querySelector(`[data-testid=msg-menu-${id}]`)), id, 3000)) {
      return tapSel(p, `[data-testid=msg-menu-${id}]`)
    }
  }
  return false
}

/** Seed a channel, one own topic card and two replies; return their ids. */
const seed = (p, tag) => p.evaluate(async ({ A, tag }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(A).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const top = await ch.send(`CLE-77871 ${tag} topic`, undefined, undefined, undefined, 1)
  const r1 = await ch.send(`CLE-77871 ${tag} reply one`, top.task_id, undefined, undefined, 0)
  await new Promise((r) => setTimeout(r, 50))
  const r2 = await ch.send(`CLE-77871 ${tag} reply two`, top.task_id, undefined, undefined, 0)
  return { top: top.msg_id, task: top.task_id, r1: r1.msg_id, r2: r2.msg_id }
}, { A, tag })

/** Open a topic (level 3 on a phone) so its replies are on screen. */
async function openTopic(p, s) {
  await p.evaluate(({ A, task }) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    return app.config.globalProperties.$router.push({ path: '/channel/' + A, query: { topic: task } })
  }, { A, task: s.task })
  return p.waitForSelector(`.topic ${card(s.r2)}`, { visible: true, timeout: 10000 }).then(() => true, () => false)
}

/** Geometry and a11y of the snackbar `tid`, measured where a thumb meets it. */
const measure = (p, tid) => p.evaluate((tid) => {
  const el = document.querySelector(`[data-testid=${tid}]`)
  const undo = document.querySelector(`[data-testid=${tid}-undo]`)
  if (!el || !undo) return null
  const r = el.getBoundingClientRect()
  const u = undo.getBoundingClientRect()
  const dock = [...document.querySelectorAll('.composer--dock')].find((d) => d.getClientRects().length && getComputedStyle(d).visibility !== 'hidden')
  const dr = dock ? dock.getBoundingClientRect() : null
  const hit = document.elementFromPoint(u.left + u.width / 2, u.top + u.height / 2)
  return {
    top: Math.round(r.top), bottom: Math.round(r.bottom), vh: window.innerHeight,
    dockTop: dr ? Math.round(dr.top) : null,
    undoW: Math.round(u.width), undoH: Math.round(u.height),
    hitsUndo: Boolean(hit && undo.contains(hit)),
    live: el.getAttribute('aria-live'),
    touchUi: matchMedia('(pointer: coarse)').matches,
  }
}, tid)

/** The checks every snackbar gets on a phone; returns true when it is up. */
async function checkSnack(p, tid, label) {
  const shown = await until(p, (tid) => Boolean(document.querySelector(`[data-testid=${tid}]`)), tid, 5000)
  ok(`${label}: the snackbar shows`, shown)
  if (!shown) return false
  const t0 = Date.now()
  const m = await measure(p, tid)
  await shot(p, `${tid}-${label.split(' ')[0]}`)
  ok(`${label}: above the composer dock, inside the screen`, m && m.top >= 0 && m.bottom <= m.vh && (m.dockTop === null || m.bottom <= m.dockTop), m)
  ok(`${label}: Undo is a >= 44 px target and a tap at its centre hits it`, m && m.undoW >= 44 && m.undoH >= 44 && m.hitsUndo, m)
  ok(`${label}: aria-live="polite"`, m && m.live === 'polite', m && m.live)
  await sleep(Math.max(0, 2500 - (Date.now() - t0)))
  ok(`${label}: still up 2.5 s later with no hover (desktop window: 0.7 s)`, await has(p, `[data-testid=${tid}]`))
  return true
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument(() => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
  })
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  /* warm a throwaway load: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.evaluate(() => { const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel'); ch.refresh = async () => {} })
  ok('the page is a touch UI (pointer: coarse)', await p.evaluate(() => matchMedia('(pointer: coarse)').matches))

  /* ---- A. card menu -> Archive ------------------------------------------ */
  const a = await seed(p, 'A')
  await p.waitForSelector(card(a.top), { visible: true, timeout: 10000 })
  await sleep(300)
  ok('A the card menu offers Archive and it was tapped', await menuPick(p, card(a.top), 'archive'))
  ok('A the archived card leaves the feed', await until(p, (sel) => !document.querySelector(sel), card(a.top)))
  if (await checkSnack(p, 'archive-toast', 'A archive (card menu)')) {
    /* a finger resting on the text holds it past the touch window */
    const c = await p.evaluate(() => { const r = document.querySelector('[data-testid=archive-toast-text]').getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } })
    const touch = await p.touchscreen.touchStart(Math.round(c.x), Math.round(c.y))
    await sleep(TOUCH_MS + 1000)
    ok('A a finger on the snackbar holds it past its touch window', await has(p, '[data-testid=archive-toast]'))
    if (touch && typeof touch.end === 'function') await touch.end()
    else await p.touchscreen.touchEnd()
    ok('A ... lifting the finger lets it close on its own', await until(p, () => !document.querySelector('[data-testid=archive-toast]'), null, TOUCH_MS + 3000))
    ok('A ... and the card stays archived', !(await has(p, card(a.top))))
  }

  /* ---- A2. tap Undo ------------------------------------------------------ */
  const a2 = await seed(p, 'A2')
  await p.waitForSelector(card(a2.top), { visible: true, timeout: 10000 })
  await sleep(300)
  await menuPick(p, card(a2.top), 'archive')
  await p.waitForSelector('[data-testid=archive-toast-undo]', { timeout: 5000 }).catch(() => {})
  await sleep(1500) /* past the 0.7 s desktop window, as a thumb would be */
  ok('A2 a tap on Undo lands', await tapSel(p, '[data-testid=archive-toast-undo]'))
  ok('A2 Undo brings the card back', await until(p, (sel) => Boolean(document.querySelector(sel)), card(a2.top)))
  ok('A2 the snackbar is gone after Undo', await until(p, () => !document.querySelector('[data-testid=archive-toast]'), null, 3000))
  ok('A2 the card that came back is selected again', await reselected(p, a2.top))

  /* ---- B. Delete topic dialog -> Archive instead ------------------------ */
  const b = await seed(p, 'B')
  await p.waitForSelector(card(b.top), { visible: true, timeout: 10000 })
  await sleep(300)
  ok('B the card menu offers Delete topic and it was tapped', await menuPick(p, card(b.top), 'delete-topic'))
  await p.waitForSelector('[data-testid=topic-delete-archive]', { visible: true, timeout: 5000 }).catch(() => {})
  ok('B the dialog offers Archive instead and it was tapped', await tapSel(p, '[data-testid=topic-delete-archive]'))
  if (await checkSnack(p, 'archive-toast', 'B archive (delete dialog)')) {
    await tapSel(p, '[data-testid=archive-toast-undo]')
    ok('B Undo brings the card back', await until(p, (sel) => Boolean(document.querySelector(sel)), card(b.top)))
    ok('B the card that came back is selected again', await reselected(p, b.top))
  }

  /* ---- C. Delete key on a reply ----------------------------------------- */
  const c = await seed(p, 'C')
  ok('C the topic opens with its replies', await openTopic(p, c))
  await sleep(400)
  await p.evaluate((sel) => document.querySelector(sel)?.focus(), `.topic ${card(c.r2)}`)
  await p.keyboard.press('Delete')
  if (await checkSnack(p, 'delete-toast', 'C delete (Delete key)')) {
    ok('C the reply left the pane', !(await has(p, `.topic ${card(c.r2)}`)))
    await tapSel(p, '[data-testid=delete-toast-undo]')
    ok('C Undo brings the reply back', await until(p, (sel) => Boolean(document.querySelector(sel)), `.topic ${card(c.r2)}`))
    ok('C the reply that came back is selected again', await reselected(p, c.r2))
  }

  /* ---- D. reply menu -> Make it a topic (Moved · Undo) ------------------- */
  const d = await seed(p, 'D')
  ok('D the topic opens with its replies', await openTopic(p, d))
  await sleep(400)
  ok('D the reply menu offers "Make it a topic" and it was tapped', await menuPick(p, `.topic ${card(d.r2)}`, 'promote-topic'))
  if (await checkSnack(p, 'move-toast', 'D move (promote)')) {
    ok('D a tap on Undo lands', await tapSel(p, '[data-testid=move-toast-undo]'))
    ok('D the reply is back in its topic and selected again', await reselected(p, d.r2))
    ok('D the snackbar closes after Undo', await until(p, () => !document.querySelector('[data-testid=move-toast]'), null, 9000))
  }

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nundo-snackbar-mobile: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
