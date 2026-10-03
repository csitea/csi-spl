// c78fb3ec (owner, t1: "the back button on both the bottom and top bars does
// not work" ... "from time to time ... one has to close the app"): the top
// bar "<" (MobileBack) and the dock Back (MessageComposer) both call
// useMobileStack().pop(), and both went dead on one shape of history.
//
// Root cause: when the URL names the topic BEFORE the topic opens (a link
// to `?topic=` by router.push, or a router.replace writing it on the page's
// own entry), the entry is tagged level 2 with `?topic=` on it, and the
// level-3 push copied that URL. Back landed on a level-2 entry that still
// named the topic. Depending on which async step won, the topic opened
// again (level 3, another push, the same entry on the next Back: stuck
// until the app restarts), or Back spent a press on a duplicate entry.
// Fixed in composables/useMobileStack.ts: the level-3 push takes the topic
// URL and the entry under it keeps its page without the topic, and a
// popstate onto an entry tagged below 3 drops a stale topic from its URL
// before the router reads it (heals histories an older build wrote).
// Cases 2 and 3 use #alerts, whose loaded feed does not hold the topic:
// there the old build stayed on level 3 for every Back (measured 4/4 presses
// per case, both buttons), the shape the owner hit.
//
// Each case runs ROUNDS times (n >= 3), alternating which Back goes first.
// Desktop (1440) is the control: no chevron, no dock Back, and Back / Forward
// over a `?topic=` link keep their URLs byte for byte.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/mobile-back-stuck.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const WIDTHS = (process.env.WIDTHS || '390,820').split(',').map(Number)
const ROUNDS = Number(process.env.ROUNDS || 3)

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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

const state = (p) => p.evaluate(() => {
  const vis = (s) => [...document.querySelectorAll(s)].some((e) => {
    const r = e.getBoundingClientRect()
    return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0
  })
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  return {
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || null,
    path: location.pathname + location.search,
    topic: Boolean(pinia?._s.get('topic')?.open),
    menu: vis('[data-test=user-menu-panel]'),
    chevron: vis('[data-testid=mobile-back]'),
    dock: vis('[data-testid=dock-back]'),
  }
})

/** The Back button as a tap reaches it (element.click: a sheet's backdrop may cover it). */
const press = (p, testid) => p.evaluate((id) => {
  const e = [...document.querySelectorAll(`[data-testid=${id}]`)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e || e.disabled) return false
  e.click()
  return true
}, testid)

async function channel(p, name) {
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await sleep(400)
  return p.evaluate((n) => {
    const row = [...document.querySelectorAll('#sidebar-panel-channels .nav-item')].find((e) => (e.getAttribute('href') || '').endsWith(`/channel/${n}`))
    if (!row) return false
    row.click()
    return true
  }, name)
}

/* the mock bundle has no session: sign a member in through the store (as mobile-overlay does) */
const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  pinia?._s.get('session')?.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
})

/** A link to a topic (a mention, a Topics row, a notification): router.push to ?topic=. */
const linkToTopic = (p) => p.evaluate((id) => {
  const router = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$router
  if (!router) return false
  void router.push({ path: '/channel/lobby', query: { topic: id } })
  return true
}, TASK)

/** A card tap: the topic store opens the topic, the stack pushes level 3. */
const openTopic = (p) => p.evaluate((id) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const topic = pinia?._s.get('topic')
  if (!topic) return false
  topic.openTopic(id)
  return true
}, TASK)

const srv = await startServer()
const browser = await launch()
try {
  for (const width of WIDTHS) {
    const page = await browser.newPage()
    page.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await page.setViewport({ width, height: 844, isMobile: true, hasTouch: true })
    for (let r = 1; r <= ROUNDS; r++) {
      const at = `${width}px #${r}`
      const [first, second] = r % 2 ? ['mobile-back', 'dock-back'] : ['dock-back', 'mobile-back']
      await page.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
      await page.waitForSelector('.spool-shell')
      await sleep(1000)
      await signIn(page)

      /* 1. a link to ?topic= from another channel */
      await channel(page, 'alerts')
      await sleep(1200)
      let s = await state(page)
      ok(`${at} setup: #alerts on level 2`, s.level === '2' && s.path === '/channel/alerts', s)
      await linkToTopic(page)
      await sleep(1500)
      s = await state(page)
      ok(`${at} a link to ?topic= opens level 3`, s.level === '3' && s.topic && s.path.includes(`topic=${TASK}`), s)
      await press(page, first)
      await sleep(1200)
      s = await state(page)
      ok(`${at} ${first} from the linked topic: 3 -> 2, its channel, the topic stays closed`, s.level === '2' && !s.topic && s.path === '/channel/lobby', s)
      await press(page, second)
      await sleep(1200)
      s = await state(page)
      ok(`${at} ${second}: back to #alerts, where the link was`, s.level === '2' && !s.topic && s.path === '/channel/alerts', s)
      await press(page, first)
      await sleep(1200)
      s = await state(page)
      ok(`${at} ${first}: 2 -> 1`, s.level === '1', s)

      /* 2. the URL names the topic first, on the page's own entry (router.replace),
         for a topic the loaded feed does not hold (older than its first page, or
         another channel's): the old build stayed on level 3 for every Back */
      await channel(page, 'alerts')
      await sleep(1200)
      await page.evaluate((id) => {
        const router = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$router
        void router?.replace({ query: { topic: id } })
      }, TASK)
      await sleep(1500)
      s = await state(page)
      ok(`${at} setup: ?topic= written first opens level 3`, s.level === '3' && s.topic, s)
      await press(page, second)
      await sleep(1200)
      s = await state(page)
      ok(`${at} ${second}: 3 -> 2, the topic stays closed`, s.level === '2' && !s.topic && s.path === '/channel/alerts', s)
      await press(page, first)
      await sleep(1200)
      s = await state(page)
      ok(`${at} ${first}: 2 -> 1`, s.level === '1', s)

      /* 3. an entry an older build left tagged 2 with ?topic= still on it */
      await channel(page, 'alerts')
      await sleep(1200)
      await page.evaluate((id) => { window.history.replaceState(window.history.state, '', `${location.pathname}?topic=${id}`) }, TASK)
      await openTopic(page)
      await sleep(1200)
      s = await state(page)
      ok(`${at} setup: a topic over a stale level-2 ?topic= entry`, s.level === '3' && s.topic, s)
      await press(page, second)
      await sleep(1200)
      s = await state(page)
      ok(`${at} ${second} over the stale entry: 3 -> 2, the topic stays closed`, s.level === '2' && !s.topic && !s.path.includes('topic='), s)
      await press(page, first)
      await sleep(1200)
      s = await state(page)
      ok(`${at} ${first}: 2 -> 1`, s.level === '1', s)

      /* 4. an open overlay goes first, then the level */
      await channel(page, 'lobby')
      await sleep(1200)
      await openTopic(page)
      await sleep(1200)
      await page.evaluate(() => document.querySelector('[data-test=user-menu-trigger]')?.click())
      await sleep(800)
      s = await state(page)
      ok(`${at} setup: the avatar sheet over level 3`, s.level === '3' && s.menu, s)
      await press(page, first)
      await sleep(1200)
      s = await state(page)
      ok(`${at} ${first} closes the sheet, level 3 stays`, s.level === '3' && !s.menu && s.topic, s)
      await press(page, second)
      await sleep(1200)
      s = await state(page)
      ok(`${at} ${second}: then 3 -> 2`, s.level === '2' && !s.topic, s)
    }
    await page.close()
  }

  /* desktop control: no phone Back, and history over a ?topic= link is untouched */
  const page = await browser.newPage()
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await sleep(1500)
  await linkToTopic(page)
  await sleep(1500)
  let s = await state(page)
  ok('1440px a link to ?topic= opens the topic, no chevron, no dock Back', s.topic && s.path.includes(`topic=${TASK}`) && !s.chevron && !s.dock, s)
  await page.goBack()
  await sleep(1200)
  s = await state(page)
  ok('1440px browser Back returns to #alerts', s.path === '/channel/alerts', s)
  await page.goForward()
  await sleep(1200)
  s = await state(page)
  ok('1440px Forward lands on the ?topic= URL unchanged', s.path === `/channel/lobby?topic=${TASK}` && s.topic, s)
  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmobile-back-stuck: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
