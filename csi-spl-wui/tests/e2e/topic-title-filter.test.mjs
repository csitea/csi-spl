// SPL-6613 (owner HUM-10, t1 f7b53cf8, msg 5b8f9db2: "make the search by
// title part of the filter and the select the one which actually selects
// either all , but the already listed / filtered"; spec 186 7.1.6), against
// the lde mock, on a 1280x800 desktop and a 390x844 phone:
//   1  the Filter popover holds a Title field; a pattern there narrows the
//      channel's topic list to the topics the (mock) hub matched, and the
//      filter icon shows its dot
//   2  the header's tick then selects exactly the topics listed (the
//      filtered ones), nothing else; Esc clears
//   3  an empty field lists every topic again, and the tick selects all of
//      them
//   4  a bad pattern is named under the field
//   5  the header has no Select by title button; on the phone the field fits
//      the screen
// Red on origin/master a464b5399: there is no Title field and no header tick
// (the header's button opened the pattern box, which ADDED matches to the
// selection without narrowing the list).
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/topic-title-filter.test.mjs   # what CI does
//   node tests/e2e/topic-title-filter.test.mjs                                 # nuxi dev
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)

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

const CARD = '.spool-main article.msg[data-msg-id]'
const mounted = (p) => until(p, () => Boolean(document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$pinia?._s.get('channel')), null, NAV_TIMEOUT)
/** the msg ids of the topic cards listed in the middle pane */
const listed = (p) => p.evaluate((sel) => [...document.querySelectorAll(sel)].filter((e) => e.getClientRects().length).map((e) => e.getAttribute('data-msg-id')).sort(), CARD)
/** the selection: its task ids, sorted */
const picked = (p) => p.evaluate(() => [...document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topicSelect').keys].sort())
const visible = (p, sel) => p.evaluate((sel) => [...document.querySelectorAll(sel)].some((e) => e.getClientRects().length), sel)

/** A new channel with four own topics; [msg_id, task_id] of each, oldest first. */
const seed = (p, ch, tag) => p.evaluate(async ({ ch, tag }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const store = app.config.globalProperties.$pinia._s.get('channel')
  await store.createChannel(ch).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + ch)
  await new Promise((r) => setTimeout(r, 500))
  const out = []
  for (const n of [1, 2, 3, 4]) {
    const m = await store.send(`${tag} topic ${n}`, undefined, undefined, undefined, 1)
    out.push({ msg: m.msg_id, task: m.task_id })
  }
  store.refresh = async () => {}
  return out
}, { ch, tag })

const signIn = (p) => p.evaluateOnNewDocument(() => {
  try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
})

/** opens the Filter popover (if shut) and puts `text` in its Title field */
async function typeTitle(p, text) {
  if (!(await visible(p, '[data-testid=topic-list-filter-title]'))) await p.click('[data-testid=topic-list-filter]')
  await p.waitForSelector('[data-testid=topic-list-filter-title]', { visible: true, timeout: 5000 })
  /* select the whole text (a triple click can miss it), then one Backspace empties it */
  await p.$eval('[data-testid=topic-list-filter-title]', (e) => { e.focus(); e.select() })
  await p.keyboard.press('Backspace')
  if (text) await p.type('[data-testid=topic-list-filter-title]', text)
}

/** a click on the channel title closes the popover (a click outside it) */
const closePop = (p) => p.click('.feed-header__title')

async function run(browser, base, { tag, width, height, phone }) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await signIn(p)
  if (phone) await p.emulate({ viewport: { width, height, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }, userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1' })
  else await p.setViewport({ width, height })
  await p.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await mounted(p)
  const ch = `s6613-${tag}`
  const t = await seed(p, ch, `tf${tag}`)
  const all = t.map((x) => x.msg).sort()
  ok(`${tag}: the channel lists its 4 topics`, await until(p, (n) => document.querySelectorAll('.spool-main article.msg[data-msg-id]').length === n, 4, 10000), await listed(p))

  ok(`${tag}: the header has no Select by title button`, !(await visible(p, '[data-test=topic-select-by-title]')))

  await typeTitle(p, 'topic [13]$')
  const want = [t[0].msg, t[2].msg].sort()
  ok(`${tag}: a title pattern in the filter narrows the list to the hub's matches`, await until(p, (ids) => {
    const got = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].filter((e) => e.getClientRects().length).map((e) => e.getAttribute('data-msg-id')).sort()
    return JSON.stringify(got) === JSON.stringify(ids)
  }, want, 6000), await listed(p))
  ok(`${tag}: the filter icon shows its dot`, await visible(p, '[data-testid=topic-list-filter-dot]'))
  if (phone) {
    const fit = await p.evaluate(() => {
      const r = document.querySelector('[data-testid=topic-list-filter-title]').getBoundingClientRect()
      return { l: r.left, r: r.right, vw: window.innerWidth }
    })
    ok(`${tag}: the title field fits the ${width} px screen`, fit.l >= 0 && fit.r <= fit.vw, fit)
  }
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/title-filter-${tag}.png` })
  await closePop(p)

  await p.click('[data-test=topic-select-listed]')
  ok(`${tag}: the tick selects exactly the 2 topics listed`, await until(p, () => Number(document.querySelector('[data-test=topic-select-bar]')?.getAttribute('data-count')) === 2, null, 4000) &&
    JSON.stringify(await picked(p)) === JSON.stringify([t[0].task, t[2].task].sort()), await picked(p))
  ok(`${tag}: the list stays filtered while the bar shows`, JSON.stringify(await listed(p)) === JSON.stringify(want), await listed(p))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/title-filter-${tag}-ticked.png` })
  await p.keyboard.press('Escape')
  ok(`${tag}: Esc clears`, await until(p, () => !document.querySelector('[data-test=topic-select-bar]'), null, 3000))

  await typeTitle(p, '^(')
  ok(`${tag}: a bad pattern is named under the field`, await until(p, () => /1/.test(document.querySelector('[data-testid=topic-list-filter-title-note]')?.textContent || ''), null, 4000))

  await typeTitle(p, '')
  ok(`${tag}: an empty title field lists every topic again`, await until(p, (n) => [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].filter((e) => e.getClientRects().length).length === n, 4, 4000), await listed(p))
  ok(`${tag}: no title, no dot`, !(await visible(p, '[data-testid=topic-list-filter-dot]')))
  await closePop(p)
  await p.click('[data-test=topic-select-listed]')
  ok(`${tag}: unfiltered, the tick selects all 4 topics listed`, await until(p, () => Number(document.querySelector('[data-test=topic-select-bar]')?.getAttribute('data-count')) === 4, null, 4000) &&
    JSON.stringify(await listed(p)) === JSON.stringify(all), await picked(p))
  await p.keyboard.press('Escape')
  ok(`${tag}: no page errors`, errors.length === 0, errors)
  await p.close()
}

const srv = await startServer()
const browser = await launch()
try {
  await run(browser, srv.base, { tag: 'desk', width: 1280, height: 800, phone: false })
  await run(browser, srv.base, { tag: 'phone', width: 390, height: 844, phone: true })
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-title-filter: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
