// HUM-10 (owner, t1 topic 548c17ae, 2026-10-03): "In the topics listing I
// should be able to archive a whole topic by swiping left from the topics
// view. On mobile of course."
//
// Runs against the lde mock (no hub). A 390x844 phone with touch; every
// gesture is a raw CDP touch sequence, the way a thumb drives it.
//   A  the Topics home row offers the swipe (touch-action: pan-y); a short
//      LEFT slide shows the archive strip and snaps back (no archive); a
//      vertical drag never moves the row; a RIGHT slide is not the row's
//   B  a long LEFT slide arms the strip ("Release to archive"); lifting
//      archives the topic: the row leaves, "Archived · Undo" shows and the
//      lift did not open the topic
//   C  the topic is archived when read again (the mock's reload: its data
//      lives in the tab): the Archive page lists its card and a fresh Topics
//      home leaves it out, while the other topic stays
//   D  desktop (1280x800, mouse): the row offers no swipe, a mouse drag
//      archives nothing
// The message cards' own swipe (a topic's messages) is swipe-archive.test.mjs.
//
// Run:
//   node tests/e2e/topic-row-swipe-archive.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/topic-row-swipe-archive.test.mjs   # what CI does
//   OUT=<dir> ... also writes phone screenshots (mid-swipe, armed, snackbar)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const A = 'hum-10-row-swipe'

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

/** the Topics home row of task `id` (the wrap the finger slides) */
const row = (id) => `.topic-row-wrap:has(> a.topic-row[data-key="${id}"])`
const has = (p, sel) => p.evaluate((sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length)), sel)
const toast = '[data-testid=archive-toast]'

const boxOf = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!e) return null
  e.scrollIntoView({ block: 'center' })
  const r = e.getBoundingClientRect()
  return { x: r.left, y: r.top, w: r.width, h: r.height }
}, sel)

/** One finger: down at (x, y), move by (dx, dy), `mid(p)` while down, lift. */
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

/** Slide row `sel` LEFT by `dx` from 60 px inside its end (clear of the menu button). */
async function slideLeft(p, sel, dx, opts = {}) {
  const b = await boxOf(p, sel)
  if (!b) return null
  return drag(p, b.x + b.w - 60, b.y + Math.min(b.h / 2, 30), -dx, opts.dy ?? 0, opts)
}

/** What row `sel` shows mid-gesture. */
const midState = (sel) => (p) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!e) return null
  const strip = e.querySelector('[data-testid=topic-swipe-reveal]')
  const m = getComputedStyle(e).transform
  const tx = m && m !== 'none' ? Number(m.split(',')[4]) || 0 : 0
  return {
    strip: Boolean(strip),
    armed: Boolean(strip && strip.hasAttribute('data-armed')),
    text: strip ? strip.textContent.trim() : '',
    icon: Boolean(strip && strip.querySelector('svg')),
    tx: Math.round(tx),
  }
}, sel)

/** Seed two topics in a channel; return their task ids. The archived one is
    a lone card: the mock's archive moves the card only, so a reply left in
    its list would rebuild the topic there (the hub hides it with its card:
    topic-archive-live.proof.mjs R4). */
const seed = (p) => p.evaluate(async ({ A }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(A).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const keep = await ch.send('HUM-10 row swipe keeps this topic', undefined, undefined, undefined, 1)
  await new Promise((r) => setTimeout(r, 50))
  const gone = await ch.send('HUM-10 row swipe archives this topic', undefined, undefined, undefined, 1)
  return { keep: keep.task_id, gone: gone.task_id, goneMsg: gone.msg_id }
}, { A })

/** The Topics home, read afresh from the (mock) api. */
async function topicsHome(p) {
  await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/'))
  await p.waitForSelector('.topic-row-wrap', { visible: true, timeout: 10000 }).catch(() => {})
  await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('viewer').loadTopics())
  await sleep(300)
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
  if (Number(process.env.CPU_THROTTLE) > 1) await (await p.target().createCDPSession()).send('Emulation.setCPUThrottlingRate', { rate: Number(process.env.CPU_THROTTLE) })
  /* warm a throwaway load: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.evaluate(() => { const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel'); ch.refresh = async () => {} })

  const s = await seed(p)
  await topicsHome(p)

  /* ---- A. the row offers the swipe; short, vertical and right do nothing -- */
  ok('A the seeded topic has a row in the Topics home', await has(p, row(s.gone)))
  ok('A the row offers the swipe (data-swipe-archive)', await has(p, `${row(s.gone)}[data-swipe-archive]`))
  ok('A the row leaves the vertical pan to the browser (touch-action: pan-y)',
    await p.evaluate((sel) => getComputedStyle(document.querySelector(sel)).touchAction === 'pan-y', row(s.gone)))

  const short = await slideLeft(p, row(s.gone), 50, { mid: midState(row(s.gone)) })
  await shot(p, 'a-short')
  ok('A a short left slide uncovers the archive strip, not armed', short && short.strip && short.icon && !short.armed && short.tx < 0, short)
  await sleep(400)
  ok('A ... and snaps back: the row stays, no snackbar',
    !(await has(p, `${row(s.gone)} [data-testid=topic-swipe-reveal]`)) && (await has(p, row(s.gone))) && !(await has(p, toast)))

  const vertical = await slideLeft(p, row(s.gone), 10, { dy: 120, mid: midState(row(s.gone)) })
  ok('A a vertical drag never moves the row', vertical && !vertical.strip && vertical.tx === 0, vertical)
  await sleep(300)

  const b0 = await boxOf(p, row(s.gone))
  const right = await drag(p, Math.round(390 * 0.55), b0.y + Math.min(b0.h / 2, 30), 160, 0, { mid: midState(row(s.gone)) })
  ok('A a right slide is not the row\'s: no strip, no move', right && !right.strip && right.tx === 0, right)
  await sleep(400)
  ok('A ... nothing archived', (await has(p, row(s.gone))) && !(await has(p, toast)))
  /* a right swipe may have been the shell's Back: come back to the Topics home */
  await topicsHome(p)

  /* ---- B. the long slide archives the whole topic ------------------------ */
  const urlBefore = await p.evaluate(() => location.pathname + location.search)
  const long = await slideLeft(p, row(s.gone), 260, { mid: async (p) => { const m = await midState(row(s.gone))(p); await shot(p, 'b-armed'); return m } })
  ok('B a long left slide arms the strip ("Release to archive")', long && long.strip && long.armed && /archive/i.test(long.text), long)
  const left = await until(p, (sel) => !document.querySelector(sel), row(s.gone), 6000)
  ok('B lifting archives: the row leaves the Topics home', left)
  ok('B "Archived · Undo" shows', await until(p, (sel) => Boolean(document.querySelector(sel)), toast, 3000))
  await shot(p, 'b-snackbar')
  ok('B the lift did not open the topic', (await p.evaluate(() => location.pathname + location.search)) === urlBefore)
  ok('B the other topic stays', await has(p, row(s.keep)))

  /* ---- C. read again: archived ------------------------------------------ */
  await sleep(2500)
  await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/archive'))
  ok('C the Archive page lists the topic\'s card',
    await until(p, (id) => Boolean(document.querySelector(`[data-test=archive-row][data-msg-id="${id}"]`)), s.goneMsg, 8000))
  await topicsHome(p)
  ok('C a fresh Topics home leaves it out', !(await has(p, row(s.gone))))
  ok('C ... and still lists the other topic', await has(p, row(s.keep)))
  ok('no page errors', errors.length === 0, errors)

  /* ---- D. desktop: a mouse never swipes ---------------------------------- */
  const d = await browser.newPage()
  await d.evaluateOnNewDocument(() => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
  })
  await d.setViewport({ width: 1280, height: 800 })
  await d.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
  await d.waitForSelector('.topic-row-wrap', { visible: true, timeout: NAV_TIMEOUT })
  const first = await d.evaluate(() => document.querySelector('.topic-row-wrap > a.topic-row')?.getAttribute('data-key') || '')
  ok('D desktop: the row offers no swipe', Boolean(first) && await d.evaluate((sel) => !document.querySelector(sel).hasAttribute('data-swipe-archive'), row(first)))
  const db = await boxOf(d, row(first))
  await d.mouse.move(db.x + db.w - 60, db.y + db.h / 2)
  await d.mouse.down()
  await d.mouse.move(db.x + db.w - 360, db.y + db.h / 2, { steps: 12 })
  const dm = await midState(row(first))(d)
  await d.mouse.up()
  await sleep(400)
  ok('D a mouse drag shows no strip and archives nothing', dm && !dm.strip && (await has(d, row(first))) && !(await has(d, toast)), dm)
} finally {
  await browser.close().catch(() => {})
  await srv.stop?.()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-row-swipe-archive: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
