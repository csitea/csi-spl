// HUM-10 (owner, t1 topic 6fc56905, 2026-10-03): "On mobile in the
// reply/thread messages view, it should be possible to hide a message/card by
// just swiping to the left. That would be just hide, not archive, not delete.
// Just hide that card there and indicate that there is a card by having a
// thicker line between the start and stop messages before and after that
// message. Of course the first message, which is the topic starter message,
// should not be possible to hide." And (t1 topic 3e073a95): "when one clicks
// on that thicker line, the hidden message/card should reappear once again."
//
// Against the lde mock (no hub), a 390x844 phone with touch, raw CDP touch:
//   - the starter offers no hide; a short LEFT slide on it shows the ARCHIVE
//     strip, never the hide one
//   - a long LEFT slide on a reply shows the eye-off (hide) strip, armed; on
//     release the card is gone and ONE thicker line stands between the cards
//     before and after it; nothing is archived
//   - hiding the next reply too keeps ONE line (consecutive hidden cards share it)
//   - a reload keeps the hide (this device's store)
//   - a tap on the line brings both cards back and removes the line
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/swipe-hide.test.mjs
//   OUT=<dir> ... also writes before / after phone screenshots
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
if (OUT) mkdirSync(OUT, { recursive: true })

const TASK = '6f6f6f6f-6f6f-4f6f-8f6f-6f6f6f6f0001'
const R1 = '6f6f6f6f-6f6f-4f6f-8f6f-6f6f6f6f0011'
const R2 = '6f6f6f6f-6f6f-4f6f-8f6f-6f6f6f6f0012'
const R3 = '6f6f6f6f-6f6f-4f6f-8f6f-6f6f6f6f0013'
const R4 = '6f6f6f6f-6f6f-4f6f-8f6f-6f6f6f6f0014'
const row = (msg_id, min, body, is_parent) => ({
  v: 1, msg_id, task_id: TASK, ts: `2026-10-03T10:0${min}:00Z`, from: 'HUM-1', from_box: 'box-wui',
  to: '@channel', to_box: 'box-wui', kind: 'note', body, channel: 'alerts', parent_task_id: null, is_parent, files: [],
})
const EXTRA = [
  row(TASK, 0, 'swipe-hide topic starter', 1),
  row(R1, 1, 'swipe-hide reply one', 0),
  row(R2, 2, 'swipe-hide reply two', 0),
  row(R3, 3, 'swipe-hide reply three', 0),
  row(R4, 4, 'swipe-hide reply four', 0),
]

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

const card = (id) => `.topic article.msg[data-msg-id="${id}"]`
const line = '.topic [data-testid=hidden-cards-line]'
const toast = '[data-testid=archive-toast]'
const has = (p, sel) => p.evaluate((sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length)), sel)
const count = (p, sel) => p.evaluate((sel) => [...document.querySelectorAll(sel)].filter((e) => e.getClientRects().length).length, sel)

const boxOf = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!e) return null
  e.scrollIntoView({ block: 'center' })
  const r = e.getBoundingClientRect()
  return { x: r.left, y: r.top, w: r.width, h: r.height }
}, sel)

async function drag(p, x, y, dx, { steps = 12, mid } = {}) {
  const cdp = await p.target().createCDPSession()
  const at = (px, py) => [{ x: Math.round(px), y: Math.round(py), id: 1, radiusX: 4, radiusY: 4, force: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: at(x, y) })
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: at(x + (dx * i) / steps, y) })
    await sleep(16)
  }
  const seen = mid ? await mid(p) : null
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach().catch(() => {})
  return seen
}

/** Slide `sel` LEFT by `dx` from 20 px inside its end edge. */
async function slideLeft(p, sel, dx, opts = {}) {
  const b = await boxOf(p, sel)
  if (!b) return null
  return drag(p, b.x + b.w - 20, b.y + Math.min(b.h / 2, 30), -dx, opts)
}

const midState = (sel) => (p) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!e) return null
  const hide = e.querySelector('[data-testid=swipe-hide-reveal]')
  const arch = e.querySelector('[data-testid=swipe-archive-reveal]')
  return {
    hide: Boolean(hide),
    archive: Boolean(arch),
    armed: Boolean((hide || arch) && (hide || arch).hasAttribute('data-armed')),
    icon: Boolean(hide && hide.querySelector('svg')),
    text: (hide || arch)?.textContent.trim() || '',
  }
}, sel)

/** The thread's rows in DOM order: a card's msg id, or 'LINE:<ids>'. */
const order = (p) => p.evaluate(() => [...document.querySelectorAll('.topic .live-rows > *')]
  .filter((e) => e.getClientRects().length)
  .map((e) => (e.matches('[data-testid=hidden-cards-line]') ? `LINE:${e.getAttribute('data-hidden-ids')}` : e.getAttribute('data-msg-id') || ''))
  .filter(Boolean))

const stored = (p) => p.evaluate(() => { try { return JSON.parse(localStorage.getItem('spool.hidden-cards') || '[]') } catch { return null } })

async function openTopic(p) {
  await p.goto(`${srv.base}/channel/alerts?topic=${TASK}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  return p.waitForSelector(card(TASK), { visible: true, timeout: 15000 }).then(() => true, () => false)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
    } catch { /* private mode */ }
  }, EXTRA)
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  /* warm a throwaway load: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.evaluate(() => { try { localStorage.removeItem('spool.hidden-cards') } catch { /* */ } })

  ok('the topic view opens with its starter and replies', (await openTopic(p)) && (await until(p, (s) => Boolean(document.querySelector(s)), card(R4), 8000)))
  await sleep(500)
  await shot(p, 'swipe-hide-before')
  const before = await order(p)

  /* the starter: never hidden */
  ok('the starter offers no hide', !(await has(p, `${card(TASK)}[data-swipe-hide]`)))
  ok('a reply offers it', await has(p, `${card(R2)}[data-swipe-hide]`))
  const st = await slideLeft(p, card(TASK), 60, { mid: midState(card(TASK)) })
  ok('a LEFT slide on the starter shows the ARCHIVE strip, never the hide one', st && st.archive && !st.hide, st)
  await sleep(500)
  ok('... it snaps back: the starter is still there, no line', (await has(p, card(TASK))) && (await count(p, line)) === 0)

  /* a reply: hide */
  const r2 = await slideLeft(p, card(R2), 220, { mid: async (p) => { const s = await midState(card(R2))(p); await shot(p, 'swipe-hide-armed'); return s } })
  ok('a long LEFT slide on a reply arms the hide strip with its eye-off icon', r2 && r2.hide && !r2.archive && r2.armed && r2.icon && r2.text.length > 0, r2)
  ok('releasing hides it: the card is gone', await until(p, (s) => ![...document.querySelectorAll(s)].some((e) => e.getClientRects().length), card(R2), 4000))
  await sleep(300)
  const o1 = await order(p)
  const i1 = o1.indexOf(`LINE:${R2}`)
  ok('ONE thicker line stands where it was, between the cards before and after it',
    (await count(p, line)) === 1 && i1 > 0 && [R1, R3].includes(o1[i1 - 1]) && [R1, R3].includes(o1[i1 + 1]) && o1[i1 - 1] !== o1[i1 + 1], { before, after: o1 })
  ok('the line is thicker than a card border (>= 3 px bar)', await p.evaluate((s) => {
    const b = document.querySelector(`${s} .hidden-cards-line__bar`)
    return Boolean(b) && b.getBoundingClientRect().height >= 3
  }, line))
  ok('nothing is archived (no snackbar), the starter and the other replies stay',
    !(await has(p, toast)) && (await has(p, card(TASK))) && (await has(p, card(R1))) && (await has(p, card(R3))))
  await shot(p, 'swipe-hide-after')

  /* the next reply too: one shared line */
  await slideLeft(p, card(R3), 220)
  ok('hiding the next reply too: that card is gone', await until(p, (s) => ![...document.querySelectorAll(s)].some((e) => e.getClientRects().length), card(R3), 4000))
  await sleep(300)
  const o2 = await order(p)
  ok('... consecutive hidden cards share ONE line', (await count(p, line)) === 1 && o2.some((x) => x.startsWith('LINE:') && x.includes(R2) && x.includes(R3)), o2)
  ok('the hide is kept on this device', JSON.stringify((await stored(p) || []).slice().sort()) === JSON.stringify([R2, R3].sort()), await stored(p))

  /* reload: still hidden */
  ok('after a reload the topic view opens again', await openTopic(p))
  await until(p, (s) => Boolean(document.querySelector(s)), line, 8000)
  await sleep(400)
  ok('... the hidden cards stay hidden behind one line',
    (await count(p, line)) === 1 && !(await has(p, card(R2))) && !(await has(p, card(R3))) && (await has(p, card(R1))) && (await has(p, card(R4))), await order(p))

  /* tap the line: back */
  const lb = await boxOf(p, line)
  if (lb) await p.touchscreen.tap(Math.round(lb.x + lb.w / 2), Math.round(lb.y + lb.h / 2))
  ok('a tap on the line brings the hidden cards back', await until(p, ([a, b]) => Boolean(document.querySelector(a)) && Boolean(document.querySelector(b)), [card(R2), card(R3)], 4000))
  await sleep(300)
  ok('... the line is gone and the order is as before', (await count(p, line)) === 0 && JSON.stringify(await order(p)) === JSON.stringify(before), await order(p))
  ok('... and the store no longer holds them', ((await stored(p)) || []).length === 0, await stored(p))
  await shot(p, 'swipe-hide-restored')

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nswipe-hide: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
