// SPL-989 (epic SPL-988): the phone shell. At <= 820 px exactly ONE of the
// three panels shows (composables/useMobileStack.ts): the app opens on level
// 1 (sections + list), a list tap pushes level 2 (the page), a topic pushes
// level 3; the Back chevron, browser Back and a swipe right each pop one
// level; deep links open where they point and still walk back 3 -> 2 -> 1.
// At 1440 px nothing of that exists: three panels, no chevron.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/mobile-stack.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const WIDTHS = (process.env.WIDTHS || '360,820').split(',').map(Number)

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

/** Which panels a reader sees, and the level the shell says it is on. */
const state = (p) => p.evaluate(() => {
  const sh = document.querySelector('.spool-shell')
  const vis = (s) => {
    const e = document.querySelector(s)
    if (!e) return false
    const r = e.getBoundingClientRect()
    return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0
  }
  return {
    level: sh ? sh.getAttribute('data-mobile-level') : null,
    side: vis('.spool-shell > .sidebar'),
    main: vis('.spool-shell > .spool-main'),
    topic: vis('.spool-shell > .topic'),
    tab: document.querySelector('.sidebar-tab[aria-selected="true"]')?.getAttribute('data-testid') || '',
    path: location.pathname + location.search,
    xscroll: document.scrollingElement.scrollWidth > innerWidth,
    back: [...document.querySelectorAll('[data-testid=mobile-back]')].filter((e) => e.getBoundingClientRect().width > 0).length,
  }
})
const only = (s, lv) => s.level === String(lv) && s.side === (lv === 1) && s.main === (lv === 2) && s.topic === (lv === 3) && !s.xscroll

/** A topic, opened the way a card click opens it (MessageFeed -> topic store). */
const openTopic = (p) => p.evaluate((id) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const topic = pinia?._s.get('topic')
  if (!topic) return false
  topic.openTopic(id)
  return true
}, TASK)

async function swipeRight(p, width) {
  const cdp = await p.target().createCDPSession()
  const t = (type, x) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y: 420 }] })
  const x0 = Math.round(width * 0.05)
  await t('touchStart', x0)
  for (let i = 1; i <= 6; i++) { await t('touchMove', x0 + i * 25); await sleep(16) }
  await t('touchEnd', x0 + 150)
  await cdp.detach()
}

const srv = await startServer()
const browser = await launch()
try {
  for (const width of WIDTHS) {
    const page = await browser.newPage()
    page.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await page.setViewport({ width, height: 844, isMobile: true, hasTouch: true })
    const at = `${width}px`

    await page.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
    await page.waitForSelector('.spool-shell')
    await sleep(1000)
    let s = await state(page)
    ok(`${at} the app opens on level 1 only`, only(s, 1), s)
    const small = await page.evaluate(() => [...document.querySelectorAll('.sidebar-tab')]
      .map((e) => e.getBoundingClientRect()).filter((r) => r.width < 44 || r.height < 44).length)
    ok(`${at} every section is a >= 44 px target`, small === 0, small)

    await page.click('[data-testid=sidebar-tab-channels]')
    await sleep(400)
    await page.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
    await sleep(1200)
    s = await state(page)
    ok(`${at} a channel tap pushes level 2`, only(s, 2) && s.path.includes('/channel/') && s.back === 1, s)

    await openTopic(page)
    await sleep(1000)
    s = await state(page)
    ok(`${at} a topic pushes level 3`, only(s, 3) && s.back === 1, s)

    await page.goBack()
    await sleep(1000)
    s = await state(page)
    ok(`${at} browser Back: 3 -> 2`, only(s, 2), s)

    await page.click('.spool-main [data-testid=mobile-back]')
    await sleep(1000)
    s = await state(page)
    ok(`${at} the chevron: 2 -> 1, the section the reader left from`, only(s, 1) && s.tab === 'sidebar-tab-channels', s)

    await page.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
    await sleep(1000)
    await swipeRight(page, width)
    await sleep(1000)
    s = await state(page)
    ok(`${at} a swipe right: 2 -> 1`, only(s, 1), s)

    /* a #lobby row opens the OTHER topic store (the live pane): the push
       must leave a history entry too (measured missing on 0.9.7) */
    await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
    await sleep(1200)
    await page.evaluate((id) => {
      const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
      void pinia?._s.get('live-pane')?.open(id)
    }, TASK)
    await sleep(1200)
    s = await state(page)
    ok(`${at} a lobby topic (live pane) pushes level 3`, only(s, 3), s)
    await page.goBack()
    await sleep(1000)
    s = await state(page)
    ok(`${at} browser Back from the lobby topic stays on /lobby, level 2`, only(s, 2) && s.path.startsWith('/lobby'), s)

    await page.goto(`${srv.base}/channel/lobby?topic=${TASK}`, { waitUntil: 'networkidle2' })
    await sleep(1500)
    s = await state(page)
    ok(`${at} a ?topic= deep link opens on level 3`, only(s, 3), s)
    await page.click('.topic [data-testid=mobile-back]')
    await sleep(1000)
    s = await state(page)
    ok(`${at} deep link Back: 3 -> 2 (the channel)`, only(s, 2) && s.path.startsWith('/channel/lobby'), s)
    await page.click('.spool-main [data-testid=mobile-back]')
    await sleep(1000)
    s = await state(page)
    ok(`${at} deep link Back: 2 -> 1`, only(s, 1), s)
    await page.close()
  }

  /* desktop: the 3-pane shell, no chevron, no stack */
  const page = await browser.newPage()
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(`${srv.base}/channel/lobby?topic=${TASK}`, { waitUntil: 'networkidle2' })
  await sleep(1500)
  const s = await state(page)
  ok('1440px desktop keeps all three panels and no Back chevron', s.side && s.main && s.topic && s.back === 0, s)
  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmobile-stack: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
