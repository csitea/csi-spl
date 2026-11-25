// Spec 186 row M3 (owner HUM-10, t1 032d8010, msgs 5fdfff6c and 4b3833e7):
// the select phase on a 390 px phone and on a desktop, against the lde mock.
//   A  390x844 touch: a topic card's menu offers "Select", which ticks the
//      card and puts the selection bar in the header's place; a tap on
//      another card then ticks it instead of opening its topic; a long LEFT
//      swipe does not archive while the selection is not empty; Clear empties
//      it and the bar goes
//   B  1280x800 desktop: a card's box ticks it; Select by title (header,
//      nothing ticked) sends the patterns and the mock hub's topics join; the
//      bar counts "in 2 channels" after a tick on another channel's page; Esc
//      clears; the card's box sits at its left, centred on its height and
//      never on the sender avatar, at 5 rows and in titles (t1 a1329bac),
//      inside a titles card at font sizes 1 and 2 (R7 W2)
//   A' 360 + 390 phone, selecting, rows + titles: the box is off the avatar,
//      the title/body and the next card, inside its card (R7 W1 + W2)
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/topic-select-phone.test.mjs   # what CI does
//   node tests/e2e/topic-select-phone.test.mjs                                 # nuxi dev
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CH_A = 's186-select-a'
const CH_B = 's186-select-b'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const card = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const shown = (p, sel) => p.evaluate((sel) => [...document.querySelectorAll(sel)].some((e) => e.getClientRects().length), sel)
const ticked = (p, id) => p.evaluate((sel) => Boolean(document.querySelector(sel)?.classList.contains('msg--ticked')), card(id))
const barCount = (p) => p.evaluate(() => {
  const b = [...document.querySelectorAll('[data-test=topic-select-bar]')].find((e) => e.getClientRects().length)
  return b ? Number(b.getAttribute('data-count')) : 0
})
const mounted = (p) => until(p, () => Boolean(document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$pinia?._s.get('channel')), null, NAV_TIMEOUT)
/** The visible element `sel`, scrolled into view: its box. */
const boxOf = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
  if (!e) return null
  e.scrollIntoView({ block: 'center' })
  const r = e.getBoundingClientRect()
  return { x: r.left, y: r.top, w: r.width, h: r.height }
}, sel)

/** One finger LEFT across `sel` by `dx`, raw CDP touch (swipe-archive.test.mjs's drag). */
async function slideLeft(p, sel, dx) {
  const b = await boxOf(p, sel)
  if (!b) return
  const cdp = await p.target().createCDPSession()
  const at = (x, y) => [{ x: Math.round(x), y: Math.round(y), id: 1, radiusX: 4, radiusY: 4, force: 1 }]
  const x0 = b.x + b.w - 20
  const y0 = b.y + Math.min(b.h / 2, 30)
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: at(x0, y0) })
  for (let i = 1; i <= 12; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: at(x0 - (dx * i) / 12, y0) })
    await sleep(16)
  }
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach().catch(() => {})
}

/** A channel with three own topics, newest first; their msg ids, oldest first. */
const seed = (p, ch, tag) => p.evaluate(async ({ ch, tag }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const store = app.config.globalProperties.$pinia._s.get('channel')
  await store.createChannel(ch).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + ch)
  await new Promise((r) => setTimeout(r, 500))
  const out = []
  for (const n of [1, 2, 3]) out.push((await store.send(`${tag} topic ${n}`, undefined, undefined, undefined, 1)).msg_id)
  store.refresh = async () => {}
  return out
}, { ch, tag })

const signIn = (p) => p.evaluateOnNewDocument(() => {
  try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
})

/** A topic in the open channel whose body is `n` lines; its msg id. */
const tallTopic = (p, tag, n) => p.evaluate(async ({ tag, n }) => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const body = Array.from({ length: n }, (_, i) => `${tag} line ${i + 1}`).join('\n')
  return (await store.send(body, undefined, undefined, undefined, 1)).msg_id
}, { tag, n })

/** Owner t1 a1329bac (msg 9ffbd794): card `id`'s select box against its sender avatar and the card, px. */
const boxGeo = (p, id) => p.evaluate((sel) => {
  const c = document.querySelector(sel)
  c.scrollIntoView({ block: 'center' })
  const r = (e) => { const b = e.getBoundingClientRect(); return { t: b.top, b: b.bottom, l: b.left, r: b.right } }
  const hit = (a, e) => a.l < e.r - 0.5 && e.l < a.r - 0.5 && a.t < e.b - 0.5 && e.t < a.b - 0.5
  const box = r(c.querySelector('[data-test=topic-select-box]'))
  const av = r(c.querySelector('.avatar'))
  const cd = r(c)
  const h = c.querySelector('[data-testid=move-handle]')
  return {
    box, av, card: cd,
    overlap: box.l < av.r && av.l < box.r && box.t < av.b && av.t < box.b,
    /* the move handle's strip at the card's left stays grabbable (move-by-drag.test.mjs) */
    clearOfHandle: !h || box.l >= r(h).r - 0.5,
    inside: box.t >= cd.t - 0.5 && box.b <= cd.b + 0.5,
    /* R7 W1 (a-549): never over the card's title or body (everything under the header) */
    overlapBody: [...c.querySelectorAll('.msg-main > :not(.msg-meta)')].map(r).some((e) => e.r > e.l && e.b > e.t && hit(box, e)),
    /* R7 W2: never spilling onto the card below */
    overlapNextCard: (() => { const n = c.nextElementSibling?.closest?.('article.msg'); return Boolean(n) && hit(box, r(n)) })(),
    centreOff: Math.round(((box.t + box.b) / 2 - (cd.t + cd.b) / 2) * 10) / 10,
  }
}, card(id))

/** The card's clip mode (titles / rows / full), through the header control. */
const clipMode = async (p, m) => {
  await p.evaluate((m) => document.querySelector(`[data-testid=card-clip-${m}]`)?.click(), m)
  await until(p, (m) => document.querySelector('[data-testid=card-clip-control]')?.getAttribute('data-mode') === m, m, 3000)
  await sleep(300)
}

/** The box's place on a desktop card: never on the avatar, centred on the card's height. */
async function boxPlace(d, short) {
  const tall = await tallTopic(d, 'desk-tall', 8)
  await d.waitForSelector(card(tall), { visible: true, timeout: 10000 })
  await clipMode(d, 'rows')
  const t5 = await boxGeo(d, tall)
  console.log('  geo 5 rows', JSON.stringify(t5))
  ok('B desktop: 5 rows, the box is off the sender avatar', !t5.overlap, t5)
  ok('B desktop: 5 rows, the box sits on the card\'s vertical centre', Math.abs(t5.centreOff) <= 3, t5)
  ok('B desktop: 5 rows, the box sits at the card\'s left, under the avatar', t5.box.l <= t5.av.r && t5.box.t >= t5.av.b, t5)
  ok('B desktop: 5 rows, the box leaves the move handle\'s strip free', t5.clearOfHandle, t5)
  if (process.env.SHOT_DIR) {
    await d.hover(card(tall))
    await sleep(200)
    await (await d.$(card(tall))).screenshot({ path: `${process.env.SHOT_DIR}/select-box-5-rows.png` })
  }
  const s1 = await boxGeo(d, short)
  console.log('  geo 1 line', JSON.stringify(s1))
  ok('B desktop: a one-line card, the box is off the avatar and inside the card', !s1.overlap && s1.inside, s1)
  await clipMode(d, 'titles')
  const tt = await boxGeo(d, tall)
  console.log('  geo titles', JSON.stringify(tt))
  ok('B desktop: titles, the box is off the avatar and inside the card', !tt.overlap && tt.inside, tt)
  /* R7 W2 (a-549): font sizes 1 and 2 make the titles card shorter */
  for (const lvl of ['1', '2']) {
    await d.evaluate((l) => document.documentElement.setAttribute('data-font-size', l), lvl)
    await sleep(300)
    const g = await boxGeo(d, tall)
    console.log(`  geo titles font ${lvl}`, JSON.stringify(g))
    ok(`B desktop: titles at font size ${lvl}, the box is inside the card, off the avatar and the next card`, g.inside && !g.overlap && !g.overlapNextCard, g)
  }
  await d.evaluate(() => document.documentElement.setAttribute('data-font-size', '3'))
  await clipMode(d, 'rows')
}

async function phone(browser, base) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await signIn(p)
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await p.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await mounted(p)
  const [t1, t2, t3] = await seed(p, CH_A, 'phone')
  await p.waitForSelector(card(t3), { visible: true, timeout: 10000 })
  ok('A 390: no box before anything is ticked', !(await shown(p, `${card(t1)} [data-test=topic-select-box]`)))

  await p.evaluate((sel) => { const c = document.querySelector(sel); c.scrollIntoView({ block: 'center' }); c.querySelector('[data-testid=msg-menu-btn]').click() }, card(t1))
  ok('A 390: the card menu offers "Select"', await until(p, () => [...document.querySelectorAll('[data-testid=msg-menu-topic-select]')].some((e) => e.getClientRects().length), null, 4000))
  const item = await boxOf(p, '[data-testid=msg-menu-topic-select]')
  if (item) await p.touchscreen.tap(Math.round(item.x + item.w / 2), Math.round(item.y + item.h / 2))
  ok('A 390: "Select" ticks the card', await until(p, (sel) => document.querySelector(sel)?.classList.contains('msg--ticked'), card(t1), 4000))
  ok('A 390: the selection bar takes the header\'s place, "1 selected"', (await until(p, () => Boolean(document.querySelector('[data-test=topic-select-bar]')), null, 4000)) && (await barCount(p)) === 1 && !(await shown(p, '[data-test=feed-header]')))
  ok('A 390: every card now shows its box', await shown(p, `${card(t2)} [data-test=topic-select-box]`))

  const path0 = await p.evaluate(() => location.pathname + location.search)
  /* scrolled into view, then measured again once the scroll has settled: a tap on a moving card hits its badge */
  await boxOf(p, `${card(t2)} .msg-para`)
  await sleep(400)
  const b2 = await p.evaluate((sel) => { const r = document.querySelector(sel).getBoundingClientRect(); return { x: r.left, y: r.top, w: Math.min(r.width, 60), h: r.height } }, `${card(t2)} .msg-para`)
  if (b2) await p.touchscreen.tap(Math.round(b2.x + b2.w / 2), Math.round(b2.y + b2.h / 2))
  ok('A 390: a tap on another card ticks it', await until(p, (sel) => document.querySelector(sel)?.classList.contains('msg--ticked'), card(t2), 3000))
  await sleep(400)
  ok('A 390: ... instead of opening its topic', (await p.evaluate(() => location.pathname + location.search)) === path0 && !(await shown(p, '.topic article.msg')), { path0, now: await p.evaluate(() => location.pathname + location.search) })
  ok('A 390: the bar reads 2', (await barCount(p)) === 2)

  await slideLeft(p, card(t3), 240)
  await sleep(800)
  ok('A 390: a long LEFT swipe does not archive while the selection is not empty',
    (await shown(p, card(t3))) && !(await shown(p, '[data-testid=archive-toast]')) && !(await shown(p, `${card(t3)} [data-testid=swipe-archive-reveal]`)))

  const clear = await boxOf(p, '[data-test=topic-select-clear]')
  if (clear) await p.touchscreen.tap(Math.round(clear.x + clear.w / 2), Math.round(clear.y + clear.h / 2))
  ok('A 390: Clear empties it; the header is back', (await until(p, () => !document.querySelector('[data-test=topic-select-bar]'), null, 3000)) && !(await ticked(p, t1)) && (await shown(p, '[data-test=feed-header]')))
  ok('A 390: no page errors', errors.length === 0, errors)
  await p.close()
}

/** R7 W1 + W2 (a-549): while selecting on a phone, the box covers neither
 *  the avatar nor the title/body, stays inside its card and off the next one,
 *  at `w` px wide, in clip mode `mode`, on a tall and a one-line topic. */
async function phoneGeo(browser, base, w, mode) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await signIn(p)
  await p.setViewport({ width: w, height: 800, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await p.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await mounted(p)
  const [s1, s2] = await seed(p, CH_A, `ph${w}${mode}`)
  const tall = await tallTopic(p, `ph${w}${mode}-tall`, 8)
  await p.waitForSelector(card(tall), { visible: true, timeout: 10000 })
  await clipMode(p, mode)
  await p.evaluate((sel) => { const c = document.querySelector(sel); c.scrollIntoView({ block: 'center' }); c.querySelector('[data-testid=msg-menu-btn]').click() }, card(s2))
  await until(p, () => [...document.querySelectorAll('[data-testid=msg-menu-topic-select]')].some((e) => e.getClientRects().length), null, 4000)
  const item = await boxOf(p, '[data-testid=msg-menu-topic-select]')
  if (item) await p.touchscreen.tap(Math.round(item.x + item.w / 2), Math.round(item.y + item.h / 2))
  await until(p, () => Boolean(document.querySelector('[data-test=topic-select-bar]')), null, 4000)
  await sleep(400)
  for (const [name, id] of [['tall', tall], ['one-line', s1]]) {
    const g = await boxGeo(p, id)
    console.log(`  geo ${w} ${mode} ${name}`, JSON.stringify(g))
    ok(`A ${w} ${mode}: ${name} card while selecting, the box is off the avatar, the title/body and the next card, inside its card`,
      !g.overlap && !g.overlapBody && g.inside && !g.overlapNextCard, g)
  }
  if (process.env.SHOT_DIR) await (await p.$(card(tall))).screenshot({ path: `${process.env.SHOT_DIR}/phone-${w}-${mode}-selecting.png` })
  await p.close()
}

async function desktop(browser, base) {
  const d = await browser.newPage()
  const errors = []
  d.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  d.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await signIn(d)
  await d.setViewport({ width: 1280, height: 800 })
  await d.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await d.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await mounted(d)
  const [, , b3] = await seed(d, CH_B, 'desk-b')
  const [a1] = await seed(d, CH_A, 'desk-a')
  await d.waitForSelector(card(a1), { visible: true, timeout: 10000 })
  await boxPlace(d, a1)

  /* Select by title from the header, nothing ticked yet: the mock hub resolves it */
  await d.click('[data-test=feed-header] [data-test=topic-select-by-title]')
  await d.waitForSelector('[data-test=topic-select-patterns-field]', { visible: true, timeout: 5000 })
  await d.type('[data-test=topic-select-patterns-field]', '^desk-a topic [12]$')
  await d.click('[data-test=topic-select-apply]')
  ok('B desktop: Select by title adds the two topics the hub matched', await until(d, () => Number(document.querySelector('[data-test=topic-select-bar]')?.getAttribute('data-count')) === 2, null, 5000), { count: await barCount(d) })

  await d.evaluate((ch) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/channel/' + ch), CH_B)
  await d.waitForSelector(card(b3), { visible: true, timeout: 10000 })
  ok('B desktop: the selection is still there on channel B\'s page', (await barCount(d)) === 2)
  await d.hover(card(b3))
  await d.click(`${card(b3)} [data-test=topic-select-box]`)
  ok('B desktop: a box ticks the card; the bar reads 3 in 2 channels', await until(d, () => {
    const b = document.querySelector('[data-test=topic-select-bar]')
    return b && b.getAttribute('data-count') === '3' && b.getAttribute('data-channels') === '2'
  }, null, 3000))
  await d.keyboard.press('Escape')
  ok('B desktop: Esc clears', await until(d, () => !document.querySelector('[data-test=topic-select-bar]'), null, 3000))
  ok('B desktop: no page errors', errors.length === 0, errors)
  await d.close()
}

const srv = await startServer()
const browser = await launch()
try {
  await phone(browser, srv.base)
  for (const w of [360, 390]) for (const m of ['rows', 'titles']) await phoneGeo(browser, srv.base, w, m)
  await desktop(browser, srv.base)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-select-phone: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)

