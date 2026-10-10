// HUM-10 (owner, t1 7de82b71 msg 8d5822b2): "Only the latest message of a
// topic should have the option to archive the whole topic within it. That is
// the latest reply message." Redo of 397d67142, which gated only a swipe on
// the opener (owner, t1 3b755aef: "it does not exist").
//
// Runs against the lde mock (no hub). One own topic card with two replies,
// opened in the topic pane:
//   D  desktop 1440x900: the LATEST reply's menu offers Archive topic, the
//      older reply's and the opening card's do not; Archive topic from the
//      latest reply archives the topic (its card leaves the middle pane)
//   P  phone 390x844 with touch: the latest reply offers the left-swipe
//      archive, the older reply and the opener do not; a long LEFT slide on
//      the latest reply archives the topic ("Archived · Undo" shows)
//   S  a topic with no replies: its opening card offers Archive topic
//
// Run:
//   node tests/e2e/topic-archive-latest-only.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/topic-archive-latest-only.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const CH = 'topic-archive-latest'

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
const inPane = (id) => `.topic ${card(id)}`
const has = (p, sel) => p.evaluate((sel) => Boolean([...document.querySelectorAll(sel)].find((e) => e.getClientRects().length)), sel)
const toast = '[data-testid=archive-toast]'
const menu = '[data-testid=msg-menu]'

/** Seed a channel, one own topic card and `replies` replies; return their ids. */
const seed = (p, tag, replies) => p.evaluate(async ({ CH, tag, replies }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(CH).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + CH)
  await new Promise((r) => setTimeout(r, 500))
  const top = await ch.send(`HUM-10 ${tag} topic`, undefined, undefined, undefined, 1)
  const r = []
  for (let i = 1; i <= replies; i++) {
    await new Promise((res) => setTimeout(res, 50))
    r.push((await ch.send(`HUM-10 ${tag} reply ${i}`, top.task_id, undefined, undefined, 0)).msg_id)
  }
  return { top: top.msg_id, task: top.task_id, replies: r }
}, { CH, tag, replies })

/** Open the topic in the topic pane; wait for `last` there. */
async function openTopic(p, s, last) {
  await p.evaluate(({ CH, task }) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    return app.config.globalProperties.$router.push({ path: '/channel/' + CH, query: { topic: task } })
  }, { CH, task: s.task })
  return p.waitForSelector(inPane(last), { visible: true, timeout: 10000 }).then(() => true, () => false)
}

/** Open the ⋯ menu of `sel` and return its item testids; Escape closes it after. */
async function menuItems(p, sel) {
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  for (let i = 0; i < 2; i++) {
    await p.evaluate((sel) => {
      const e = document.querySelector(sel)
      e?.scrollIntoView({ block: 'center' })
      e?.querySelector('[data-testid=msg-menu-btn]')?.click()
    }, sel)
    for (let t = 0; t < 20; t++) {
      await sleep(150)
      const got = await items()
      if (got.length) return got
    }
  }
  return []
}
async function closeMenu(p) {
  await p.keyboard.press('Escape')
  return until(p, (s) => !document.querySelector(s), menu, 3000)
}

/** One finger LEFT from 20 px inside the end edge of `sel`, by `dx`. Raw CDP touch. */
async function slideLeft(p, sel, dx, mid) {
  const b = await p.evaluate((sel) => {
    const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
    if (!e) return null
    e.scrollIntoView({ block: 'center' })
    const r = e.getBoundingClientRect()
    return { x: r.left, y: r.top, w: r.width, h: r.height }
  }, sel)
  if (!b) return null
  const cdp = await p.target().createCDPSession()
  const at = (px, py) => [{ x: Math.round(px), y: Math.round(py), id: 1, radiusX: 4, radiusY: 4, force: 1 }]
  const x = b.x + b.w - 20
  const y = b.y + Math.min(b.h / 2, 30)
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: at(x, y) })
  for (let i = 1; i <= 12; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: at(x - (dx * i) / 12, y) })
    await sleep(16)
  }
  const seen = mid ? await mid(p) : null
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await cdp.detach().catch(() => {})
  return seen
}
const strips = (sel) => (p) => p.evaluate((sel) => {
  const e = document.querySelector(sel)
  return e && { archive: Boolean(e.querySelector('[data-testid=swipe-archive-reveal]')), hide: Boolean(e.querySelector('[data-testid=swipe-hide-reveal]')) }
}, sel)

async function page(browser, viewport) {
  const p = await browser.newPage()
  p.errors = []
  p.on('pageerror', (e) => p.errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument(() => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
  })
  await p.setViewport(viewport)
  /* warm a throwaway load: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  await p.evaluate(() => { const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel'); ch.refresh = async () => {} })
  return p
}
const benign = (e) => /Failed to fetch dynamically imported module/.test(e)

const srv = await startServer()
const browser = await launch()
try {
  /* ---- D. desktop: the message menu ------------------------------------- */
  const d = await page(browser, { width: 1440, height: 900 })
  const s = await seed(d, 'D', 2)
  const [older, latest] = s.replies
  ok('D the topic pane opens on the topic', await openTopic(d, s, latest))
  await sleep(500)
  const lm = await menuItems(d, inPane(latest))
  ok('D the LATEST reply\'s menu offers Archive topic', lm.includes('msg-menu-archive'), lm)
  await shot(d, 'd-latest-menu')
  await closeMenu(d)
  const om = await menuItems(d, inPane(older))
  ok('D an older reply\'s menu has no Archive topic', om.length > 0 && !om.includes('msg-menu-archive'), om)
  await shot(d, 'd-older-menu')
  await closeMenu(d)
  const tm = await menuItems(d, inPane(s.top))
  ok('D the opening card\'s menu (it has replies) has no Archive topic', tm.length > 0 && !tm.includes('msg-menu-archive'), tm)
  await closeMenu(d)
  await menuItems(d, inPane(latest))
  await d.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())
  ok('D Archive topic on the latest reply archives the topic: "Archived · Undo" shows', await until(d, (t) => Boolean(document.querySelector(t)), toast, 4000))
  ok('D ... and the topic\'s card leaves the middle pane',
    await until(d, (sel) => ![...document.querySelectorAll(sel)].some((e) => !e.closest('.topic') && e.getClientRects().length), card(s.top), 5000))

  /* ---- S. a topic with no replies: its opener is the latest -------------- */
  const solo = await seed(d, 'S', 0)
  ok('S the topic pane opens on a topic with no replies', await openTopic(d, solo, solo.top))
  await sleep(500)
  const sm = await menuItems(d, inPane(solo.top))
  ok('S its opening card (the latest message) offers Archive topic', sm.includes('msg-menu-archive'), sm)
  await closeMenu(d)
  ok('no unexpected page errors (desktop)', d.errors.filter((e) => !benign(e)).length === 0, d.errors)
  await d.close()

  /* ---- P. phone: the left swipe ----------------------------------------- */
  const p = await page(browser, { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  const ps = await seed(p, 'P', 2)
  const [pOlder, pLatest] = ps.replies
  ok('P the topic view opens', await openTopic(p, ps, pLatest))
  await sleep(500)
  ok('P the LATEST reply offers the swipe archive', await has(p, `${inPane(pLatest)}[data-swipe-archive]`))
  ok('P an older reply does not', !(await has(p, `${inPane(pOlder)}[data-swipe-archive]`)))
  ok('P the opening card (it has replies) does not', !(await has(p, `${inPane(ps.top)}[data-swipe-archive]`)))
  const os = await slideLeft(p, inPane(pOlder), 50, strips(inPane(pOlder)))
  ok('P a short LEFT slide on an older reply shows the hide strip, never the archive one', os && os.hide && !os.archive, os)
  await sleep(400)
  const ls = await slideLeft(p, inPane(pLatest), 50, strips(inPane(pLatest)))
  ok('P a short LEFT slide on the latest reply shows the archive strip', ls && ls.archive && !ls.hide, ls)
  await sleep(400)
  ok('P ... snaps back and archives nothing', (await has(p, inPane(pLatest))) && !(await has(p, toast)))
  await slideLeft(p, inPane(pLatest), 260, async (p) => { await shot(p, 'p-latest-armed') })
  ok('P a long LEFT slide on the latest reply archives the topic: "Archived · Undo" shows', await until(p, (t) => Boolean(document.querySelector(t)), toast, 4000))
  await shot(p, 'p-snackbar')
  ok('no unexpected page errors (phone)', p.errors.filter((e) => !benign(e)).length === 0, p.errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-archive-latest-only: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
