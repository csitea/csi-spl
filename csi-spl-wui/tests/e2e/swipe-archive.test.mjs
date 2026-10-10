// CLE-77906 (owner, t1 topic 73c5d695) archived a topic by a swipe on mobile;
// HUM-10 (owner, t1 topic 2d09e9c2, 2026-10-03): "Let's change the swipe left
// to do the archiving and let's change the swipe right to actually show the
// right-click menu." Back (a right swipe from the left half) stays as it was.
//
// Runs against the lde mock (no hub). A 390x844 phone with touch; every
// gesture is a raw CDP touch sequence (touchStart / touchMove / touchEnd), the
// way a thumb drives it - no mouse is ever moved.
//   A  cards view: a short LEFT slide shows the archive strip and snaps back
//      (no archive); a vertical drag never moves the card; a RIGHT slide from
//      the right half opens the card's menu (the right-click one), a short one
//      snaps back; a long LEFT slide past the threshold archives - the card
//      leaves, "Archived · Undo" shows and is still up 2.5 s later (the touch
//      window); Undo brings it back, selected; a RIGHT swipe from the left
//      edge is still Back (level 2 -> 1), no menu, no archive
//   B  topic view: a RIGHT slide on a reply opens the reply's menu; a short
//      LEFT slide on a reply shows the HIDE strip, never the archive one
//      (the hide itself: swipe-hide.test.mjs); a short LEFT slide on the topic's
//      opening message cancels; a RIGHT swipe from the left edge on it is
//      still Back (3 -> 2); a long LEFT slide archives the topic, closes the
//      topic view and offers Undo, which brings the card back
//   C  desktop (1280x800, mouse): a mouse drag never reveals or archives
//
// Run:
//   node tests/e2e/swipe-archive.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/swipe-archive.test.mjs   # what CI does
//   OUT=<dir> ... also writes phone screenshots (mid-swipe, armed, snackbar, menu)
//   CPU_THROTTLE=4 ... a slow CI runner (Chrome CPU throttling)
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const A = 'cle-77906-a'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const { createRequire } = await import('node:module');
  const { pathToFileURL } = await import('node:url');
  const { mkdirSync } = await import('node:fs');
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
const has = (p, sel) => p.evaluate((sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length)), sel)
const reselected = (p, id) => until(p, (id) => document.activeElement?.matches?.(`article.msg[data-msg-id="${id}"]`), id, 4000)

/** The visible row `sel`, scrolled into view: its box. */
const boxOf = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!e) return null
  e.scrollIntoView({ block: 'center' })
  const r = e.getBoundingClientRect()
  return { x: r.left, y: r.top, w: r.width, h: r.height }
}, sel)

/**
 * One finger: down at (x, y), move by (dx, dy) in `steps`, then `mid(p)`
 * while still down, then lift. Raw CDP touch, as a phone sends it.
 */
async function drag(p, x, y, dx, dy, { steps = 12, mid } = {}) {
  const cdp = await p.target().createCDPSession()
  const at = (px, py) => [{ x: Math.round(px), y: Math.round(py), id: 1, radiusX: 4, radiusY: 4, force: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: at(x, y) })
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: at(x + (dx * i) / steps, y + (dy * i) / steps) })
    await sleep(16)
  }
  const seen = mid ? await mid(p) : null
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach().catch(() => {})
  return seen
}

/** Slide row `sel` LEFT by `dx` from 20 px inside its end edge (archive). */
async function slideLeft(p, sel, dx, opts = {}) {
  const b = await boxOf(p, sel)
  if (!b) return null
  return drag(p, b.x + b.w - 20, b.y + Math.min(b.h / 2, 30), -dx, opts.dy ?? 0, opts)
}

/** Slide row `sel` RIGHT by `dx` from the right half of the screen (menu). */
async function slideRight(p, sel, dx, opts = {}) {
  const b = await boxOf(p, sel)
  if (!b) return null
  const vw = await p.evaluate(() => window.innerWidth)
  return drag(p, Math.round(vw * 0.55), b.y + Math.min(b.h / 2, 30), dx, opts.dy ?? 0, opts)
}

/** Swipe RIGHT on row `sel` from the left edge (5% of the screen): Back. */
async function edgeSwipe(p, sel, opts = {}) {
  const b = await boxOf(p, sel)
  if (!b) return null
  const vw = await p.evaluate(() => window.innerWidth)
  return drag(p, Math.round(vw * 0.05), b.y + Math.min(b.h / 2, 30), 160, 0, opts)
}

/** What the row `sel` shows mid-gesture: the strip, armed, the content offset. */
const midState = (sel) => (p) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!e) return null
  const strip = e.querySelector('[data-testid=swipe-archive-reveal]')
  const menuStrip = e.querySelector('[data-testid=swipe-menu-reveal]')
  const m = getComputedStyle(e).transform
  const tx = m && m !== 'none' ? Number(m.split(',')[4]) || 0 : 0
  return {
    strip: Boolean(strip),
    menuStrip: Boolean(menuStrip),
    tx: Math.round(tx),
    armed: Boolean((strip || menuStrip) && (strip || menuStrip).hasAttribute('data-armed')),
    stripW: strip ? Math.round(strip.getBoundingClientRect().width) : 0,
    icon: Boolean(strip && strip.querySelector('svg')),
    shifted: Boolean(m && m !== 'none' && !/matrix\(1, 0, 0, 1, 0, 0\)/.test(m)),
  }
}, sel)

/** Seed a channel, one own topic card and two replies; return their ids. */
const seed = (p, tag) => p.evaluate(async ({ A, tag }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(A).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const top = await ch.send(`CLE-77906 ${tag} topic`, undefined, undefined, undefined, 1)
  const r1 = await ch.send(`CLE-77906 ${tag} reply one`, top.task_id, undefined, undefined, 0)
  await new Promise((r) => setTimeout(r, 50))
  const r2 = await ch.send(`CLE-77906 ${tag} reply two`, top.task_id, undefined, undefined, 0)
  return { top: top.msg_id, task: top.task_id, r1: r1.msg_id, r2: r2.msg_id }
}, { A, tag })

/** Open a topic (level 3 on a phone) so its opening message and replies show. */
async function openTopic(p, s) {
  await p.evaluate(({ A, task }) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    return app.config.globalProperties.$router.push({ path: '/channel/' + A, query: { topic: task } })
  }, { A, task: s.task })
  return p.waitForSelector(`.topic ${card(s.r2)}`, { visible: true, timeout: 10000 }).then(() => true, () => false)
}

const menu = '[data-testid=msg-menu]'
const innerW = 390
/** Back pops a history entry: count them (the level alone cannot tell a
    Back from channel A to channel B, both level 2) */
const pops = (p) => p.evaluate(() => window.__swipePops || 0)
/** Close the phone's menu sheet the way a thumb does: a tap on the dimmed page above it. */
async function closeMenu(p) {
  const shown = (s) => [...document.querySelectorAll(s)].some((e) => e.getClientRects().length)
  for (let i = 0; i < 3; i++) {
    /* the sheet slides up: read its top once it has settled */
    await sleep(400)
    const top = await p.evaluate((s) => {
      const e = [...document.querySelectorAll(s)].find((x) => x.getClientRects().length)
      return e ? e.getBoundingClientRect().top : -1
    }, menu)
    if (top < 0) return true
    await p.touchscreen.tap(Math.round(innerW / 2), Math.max(8, Math.round(top / 2)))
    if (await until(p, (s) => ![...document.querySelectorAll(s)].some((e) => e.getClientRects().length), menu, 1500)) return true
  }
  return !(await p.evaluate(shown, menu))
}

const level = (p) => p.evaluate(() => document.querySelector('[data-mobile-level]')?.getAttribute('data-mobile-level') || '')
const toast = '[data-testid=archive-toast]'

const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument(() => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
  })
  await p.evaluateOnNewDocument(() => {
    window.__swipePops = 0
    addEventListener('popstate', () => { window.__swipePops++ })
  })
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  /* CPU_THROTTLE=4 reproduces a slow CI runner locally */
  if (Number(process.env.CPU_THROTTLE) > 1) await (await p.target().createCDPSession()).send('Emulation.setCPUThrottlingRate', { rate: Number(process.env.CPU_THROTTLE) })
  /* warm a throwaway load: a cold nuxi dev drops the first dynamic import */
  const srv = await startServer()
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.evaluate(() => { const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel'); ch.refresh = async () => {} })
  ok('the page is a touch UI (pointer: coarse)', await p.evaluate(() => matchMedia('(pointer: coarse)').matches))

  /* ---- A. cards view ------------------------------------------------------ */
  const a = await seed(p, 'A')
  await p.waitForSelector(card(a.top), { visible: true, timeout: 10000 })
  await sleep(400)
  ok('A the card offers the swipe (data-swipe-archive)', await has(p, `${card(a.top)}[data-swipe-archive]`))
  ok('A the card leaves the vertical pan to the browser (touch-action: pan-y)',
    await p.evaluate((sel) => getComputedStyle(document.querySelector(sel)).touchAction === 'pan-y', card(a.top)))

  const short = await slideLeft(p, card(a.top), 50, { mid: midState(card(a.top)) })
  ok('A a short LEFT slide moves the card left and shows the archive strip with its icon',
    short && short.strip && short.icon && short.shifted && short.tx < 0 && !short.armed, short)
  await sleep(400)
  ok('A ... below the threshold it snaps back: no strip, card kept, no snackbar',
    !(await has(p, `${card(a.top)} [data-testid=swipe-archive-reveal]`)) && (await has(p, card(a.top))) && !(await has(p, toast)))

  const vert = await slideLeft(p, card(a.top), 4, { dy: -120, mid: midState(card(a.top)) })
  ok('A a vertical drag (a scroll) never moves the card', vert && !vert.strip && !vert.menuStrip && !vert.shifted, vert)
  await sleep(300)
  ok('A ... and archives nothing', (await has(p, card(a.top))) && !(await has(p, toast)))

  const rshort = await slideRight(p, card(a.top), 40, { mid: midState(card(a.top)) })
  ok('A a short RIGHT slide shows the menu strip, never the archive one', rshort && rshort.menuStrip && !rshort.strip && rshort.tx > 0, rshort)
  await sleep(400)
  ok('A ... snaps back: no menu, card kept, no snackbar',
    !(await has(p, menu)) && (await has(p, card(a.top))) && !(await has(p, toast)))

  const right = await slideRight(p, card(a.top), 150, { mid: midState(card(a.top)) })
  ok('A a RIGHT slide past the threshold arms the menu strip', right && right.menuStrip && right.armed && !right.strip, right)
  ok('A releasing opens the card\'s menu (the right-click one)', await until(p, (s) => [...document.querySelectorAll(s)].some((e) => e.getClientRects().length), menu, 3000))
  ok('A ... the menu offers Archive (it is this card\'s menu)', await has(p, '[data-testid=msg-menu-archive]'))
  await shot(p, 'swipe-cards-menu')
  ok('A ... and archives nothing, the card is back in place',
    (await has(p, card(a.top))) && !(await has(p, toast)) && !(await midState(card(a.top))(p)).shifted)
  ok('A the menu closes', await closeMenu(p))

  const long = await slideLeft(p, card(a.top), 240, {
    mid: async (p) => { const s = await midState(card(a.top))(p); await shot(p, 'swipe-cards-armed'); return s },
  })
  ok('A past the threshold the strip is armed ("Release to archive")', long && long.armed && long.stripW >= 150 && long.tx < 0, long)
  ok('A releasing archives: the card leaves the feed', await until(p, (sel) => !document.querySelector(sel), card(a.top)))
  ok('A "Archived · Undo" shows', await until(p, (s) => Boolean(document.querySelector(s)), toast, 4000))
  await shot(p, 'swipe-cards-snackbar')
  await sleep(2500)
  ok('A ... still up 2.5 s later (the 6 s touch window, not 0.7 s)', await has(p, toast))
  await p.evaluate(() => { const e = document.querySelector('[data-testid=archive-toast-undo]'); e?.scrollIntoView({ block: 'center' }) })
  const u = await boxOf(p, '[data-testid=archive-toast-undo]')
  if (u) await p.touchscreen.tap(Math.round(u.x + u.w / 2), Math.round(u.y + u.h / 2))
  ok('A Undo brings the card back', await until(p, (sel) => Boolean(document.querySelector(sel)), card(a.top)))
  ok('A the card that came back is selected again', await reselected(p, a.top))
  await until(p, (s) => !document.querySelector(s), toast, 8000)

  const alv = await level(p)
  const apops = await pops(p)
  const edge = await edgeSwipe(p, card(a.top), { mid: midState(card(a.top)) })
  ok('A a RIGHT swipe from the left edge does not move the card (it is Back)', edge && !edge.strip && !edge.menuStrip && !edge.shifted, edge)
  ok('A ... the phone goes Back (one history entry popped)', alv === '2' && (await until(p, (n) => (window.__swipePops || 0) > n, apops, 3000)), { level: alv, after: await level(p), pops: [apops, await pops(p)] })
  ok('A ... no menu, no archive', !(await has(p, menu)) && !(await has(p, toast)))

  /* ---- B. topic view ------------------------------------------------------ */
  const b = await seed(p, 'B')
  ok('B the topic view opens', await openTopic(p, b))
  await sleep(500)
  const opener = `.topic ${card(b.top)}`
  ok('B the topic view shows its opening message, which offers the swipe', await has(p, `${opener}[data-swipe-archive]`))
  ok('B a reply does not offer it', !(await has(p, `.topic ${card(b.r2)}[data-swipe-archive]`)))
  const rreply = await slideRight(p, `.topic ${card(b.r2)}`, 150, { mid: midState(`.topic ${card(b.r2)}`) })
  ok('B a RIGHT slide on a reply arms the menu strip', rreply && rreply.menuStrip && rreply.armed, rreply)
  ok('B ... and opens the reply\'s menu', await until(p, (s) => [...document.querySelectorAll(s)].some((e) => e.getClientRects().length), menu, 3000))
  await shot(p, 'swipe-reply-menu')
  ok('B ... the menu closes', await closeMenu(p))
  const reply = await slideLeft(p, `.topic ${card(b.r2)}`, 50, {
    mid: (p) => p.evaluate((sel) => {
      const e = document.querySelector(sel)
      return e && { archive: Boolean(e.querySelector('[data-testid=swipe-archive-reveal]')), hide: Boolean(e.querySelector('[data-testid=swipe-hide-reveal]')) }
    }, `.topic ${card(b.r2)}`),
  })
  ok('B a short LEFT slide on a reply shows the hide strip, never the archive one', reply && reply.hide && !reply.archive, reply)
  await sleep(400)
  ok('B ... snaps back and archives nothing', (await has(p, opener)) && (await has(p, `.topic ${card(b.r2)}`)) && !(await has(p, toast)))

  const lv0 = await level(p)
  const bpops = await pops(p)
  const bshort = await slideLeft(p, opener, 100, { mid: midState(opener) })
  ok('B a 100 px LEFT slide on the opening message shows the strip, not armed', bshort && bshort.strip && !bshort.armed, bshort)
  await sleep(500)
  ok('B ... snaps back, and the phone did NOT change level',
    (await has(p, opener)) && (await level(p)) === lv0 && !(await has(p, toast)), { before: lv0, after: await level(p) })

  const bedge = await edgeSwipe(p, opener, { mid: midState(opener) })
  ok('B a RIGHT swipe from the left edge on the opening message does not move it', bedge && !bedge.strip && !bedge.menuStrip && !bedge.shifted, bedge)
  ok('B ... the phone goes Back (level 3 -> 2), no menu, no archive',
    lv0 === '3' && (await until(p, () => document.querySelector('[data-mobile-level]')?.getAttribute('data-mobile-level') === '2', null, 3000)) && !(await has(p, menu)) && !(await has(p, toast)),
    { before: lv0, after: await level(p), pops: [bpops, await pops(p)] })
  /* Back's popstate settles first (a slow runner): then open it again, retried */
  await until(p, () => document.querySelector('[data-mobile-level]')?.getAttribute('data-mobile-level') === '2', null, 5000)
  await sleep(600)
  let again = false
  for (let i = 0; i < 3 && !again; i++) {
    again = await openTopic(p, b)
    if (!again) {
      await p.evaluate(({ A }) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/channel/' + A), { A })
      await sleep(800)
    }
  }
  ok('B the topic view opens again', again, { level: await level(p) })
  await sleep(500)

  await slideLeft(p, opener, 260, {
    mid: async (p) => { await shot(p, 'swipe-topic-armed') },
  })
  ok('B releasing archives the topic: "Archived · Undo" shows', await until(p, (s) => Boolean(document.querySelector(s)), toast, 4000))
  ok('B the topic view closed (the archived topic is not left open)', await until(p, (sel) => !document.querySelector(sel), opener, 4000))
  /* the phone steps back to the cards (level 3 -> 2) and the feed's leave
     transition runs: wait for both before reading the list (slow runners) */
  const gone = await until(p, (sel) => ![...document.querySelectorAll(sel)].some((e) => e.getClientRects().length), card(b.top), 5000)
  ok('B the card left the cards view', gone, { level: await level(p), toast: await has(p, toast) })
  await sleep(600)
  await shot(p, 'swipe-topic-snackbar')
  const back = (sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length))
  let came = false
  for (let i = 0; i < 3 && !came; i++) {
    if (!(await has(p, '[data-testid=archive-toast-undo]'))) break
    const u2 = await boxOf(p, '[data-testid=archive-toast-undo]')
    if (u2) await p.touchscreen.tap(Math.round(u2.x + u2.w / 2), Math.round(u2.y + u2.h / 2))
    came = await until(p, back, card(b.top), 3000)
  }
  ok('B Undo brings the card back', came || (await until(p, back, card(b.top), 3000)), { level: await level(p), toast: await has(p, toast) })

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors (phone)', errors.filter((e) => !benign(e)).length === 0, errors)
  await p.close()

  /* ---- C. desktop: a mouse never swipes ---------------------------------- */
  const d = await browser.newPage()
  await d.evaluateOnNewDocument(() => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
  })
  await d.setViewport({ width: 1280, height: 800 })
  await d.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await d.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await d.evaluate(() => { const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel'); ch.refresh = async () => {} })
  const c = await seed(d, 'C')
  await d.waitForSelector(card(c.top), { visible: true, timeout: 10000 })
  await sleep(400)
  ok('C desktop: the card offers no swipe and keeps its default touch-action',
    await d.evaluate((sel) => { const e = document.querySelector(sel); return !e.hasAttribute('data-swipe-archive') && getComputedStyle(e).touchAction !== 'pan-y' }, card(c.top)))
  const cb = await boxOf(d, `${card(c.top)} .msg-main`)
  await d.mouse.move(cb.x + 40, cb.y + 10)
  await d.mouse.down()
  for (let i = 1; i <= 10; i++) await d.mouse.move(cb.x + 40 + i * 30, cb.y + 10)
  const dm = await midState(card(c.top))(d)
  await d.mouse.up()
  ok('C desktop: a mouse drag shows no strip', dm && !dm.strip && !dm.shifted, dm)
  await sleep(400)
  ok('C desktop: ... and archives nothing', (await has(d, card(c.top))) && !(await has(d, toast)))
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nswipe-archive: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
