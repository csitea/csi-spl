// 022 §10: "Open original" on a search result, in a real browser
// on the mock tenant. Desktop: a click on a message hit opens the channel it
// was posted in, with its topic open on the right and the hit marked there;
// Back returns to the results; the row's right menu (right-click and the menu
// key) offers Open original, Show here, Copy link; Show here keeps the
// search page. CLE-77884: the hits are the LEFT panel's list. Phone (390 px): a long press opens the menu as a sheet, a tap
// opens the original.
//
//   node tests/e2e/search-original.test.mjs          (mock tenant, nuxi dev)
//   BASE_URL=<generated bundle> node tests/e2e/search-original.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SEARCH_ORIGINAL_SHOTS || mkdtempSync(join(tmpdir(), 'spool-search-original-'))
/* the mock tenant (utils/mock-data.mjs): a #lobby topic and one of its replies */
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const REPLY = '33333333-3333-4333-8333-333333333333'
const Q = 'Applying'
const HIT = '[data-test=search-results] [data-test=search-row][data-type=messages]'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

function atOriginal(href) {
  const url = new URL(href)
  return url.pathname.endsWith('/channel/lobby') && url.searchParams.get('topic') === TOPIC && url.hash === '#' + REPLY
}

const server = await startServer()
const browser = await launch()
mkdirSync(SHOTS, { recursive: true })
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/search?q=' + Q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(HIT, { visible: true, timeout: NAV_TIMEOUT })

  /* 1-3: the menu, from a right-click and from the keyboard's menu key */
  await p.click(HIT, { button: 'right' })
  await p.waitForSelector('[data-testid=search-row-menu]', { visible: true, timeout: 5000 })
  const ids = await p.$$eval('[data-testid=search-row-menu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-testid')))
  const first = await p.$eval('[data-testid=search-row-menu-original]', (el) => el.textContent.trim()).catch(() => '')
  ok('1 right-click: Open original, Show here, Copy link', JSON.stringify(ids) === JSON.stringify(['search-row-menu-original', 'search-row-menu-here', 'search-row-menu-copy']) && first === 'Open original', { ids, first })
  await p.screenshot({ path: `${SHOTS}/1-menu-desktop.png` })
  await p.keyboard.press('Escape')
  await p.waitForSelector('[data-testid=search-row-menu]', { hidden: true, timeout: 5000 })
  ok('2 Escape closes it', true)
  await p.$eval('[data-test=search-results]', (el) => el.focus())
  await p.keyboard.down('Shift')
  await p.keyboard.press('F10')
  await p.keyboard.up('Shift')
  const fromKey = await p.waitForSelector('[data-testid=search-row-menu]', { visible: true, timeout: 5000 }).then(() => true).catch(() => false)
  ok('3 Shift+F10 on the list opens the same menu', fromKey)

  /* 4: Show here = the old preview, the page stays /search */
  await p.click('[data-testid=search-row-menu-here]')
  const here = await p.waitForSelector(`aside.live-pane [data-msg-id="${REPLY}"]`, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  ok('4 Show here opens the thread on the right of the search page', here && new URL(p.url()).pathname.endsWith('/search'), p.url())

  /* 5-7: a plain click = Open original */
  await p.goto(server.base + '/search?q=' + Q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(HIT, { visible: true, timeout: NAV_TIMEOUT })
  await p.click(HIT)
  await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  ok('5 a click opens the channel, the topic open, the hit as the hash', atOriginal(p.url()), p.url())
  const line = `aside.live-pane [data-msg-id="${REPLY}"]`
  const marked = await p.waitForSelector(`${line}.search-focus`, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const inView = marked && await p.$eval(line, (el) => {
    const r = el.getBoundingClientRect()
    const s = el.closest('.feed-body').getBoundingClientRect()
    return r.top >= s.top - 1 && r.top < s.bottom
  })
  ok('6 the hit is in view in the thread pane and marked', Boolean(marked && inView), { marked, inView })
  await p.screenshot({ path: `${SHOTS}/2-original-desktop.png` })
  await p.goBack({ waitUntil: 'networkidle2' })
  const back = await p.waitForSelector(HIT, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  ok('7 Back returns to the results with the query', back && new URL(p.url()).searchParams.get('q') === Q, p.url())

  /* 8: Enter on the active row = Open original */
  await p.$eval('[data-test=search-results]', (el) => el.focus())
  await p.keyboard.press('Enter')
  await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  ok('8 Enter opens the original', atOriginal(p.url()), p.url())

  /* 9-10: phone */
  const m = await browser.newPage()
  m.on('pageerror', (e) => errors.push(String(e && e.message)))
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await m.goto(server.base + '/search?q=' + Q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await m.waitForSelector(HIT, { visible: true, timeout: NAV_TIMEOUT })
  const box = await (await m.$(`${HIT} .side-hit__text`)).boundingBox()
  await m.touchscreen.touchStart(box.x + 20, box.y + 5)
  await sleep(800)
  await m.touchscreen.touchEnd()
  const sheet = await m.waitForSelector('[data-testid=search-row-menu].touch-sheet', { visible: true, timeout: 5000 }).then(() => true).catch(() => false)
  ok('9 phone: a long press opens the menu as a sheet (and does not navigate)', sheet && new URL(m.url()).pathname.endsWith('/search'), { sheet, url: m.url() })
  await m.screenshot({ path: `${SHOTS}/3-sheet-phone.png` })
  await m.tap('[data-testid=search-row-menu-original]')
  await m.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  const phoneLine = await m.waitForSelector(`[data-msg-id="${REPLY}"].search-focus`, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  ok('10 phone: Open original goes to the channel with the hit marked', atOriginal(m.url()) && phoneLine, { url: m.url(), phoneLine })
  await m.screenshot({ path: `${SHOTS}/4-original-phone.png` })

  console.log(`  screenshots ${SHOTS}`)
  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('11 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`search-original: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
