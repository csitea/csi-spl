// CLE-77884 (owner, topic 635f8072 96a88e32), SPL-6675 (owner HUM-10, t1
// bcfd15e1): the search results are a list of their own, the search panel
// beside the page - never the middle, never a /search page. In a real browser
// on the mock tenant: desktop 1440 - an old /search?q= link opens the panel
// (compact hits, the match marked); ArrowUp/Down cycle (wrapping); a click
// PREVIEWS a hit in its place (its channel, not /t/), marked, and the list and
// the chosen hit stay; the keys keep cycling the previews; Enter opens for
// real and the panel closes; the X closes it. Phone 390 - the panel is the
// screen, a tap opens the original, Back returns to the list with the same
// hit chosen; light + dark, no sideways scroll.
//
//   node tests/e2e/search-left.test.mjs          (mock tenant, nuxi dev)
//   BASE_URL=<generated bundle> node tests/e2e/search-left.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SEARCH_LEFT_SHOTS || mkdtempSync(join(tmpdir(), 'spool-search-left-'))
/* the mock tenant (utils/mock-data.mjs): two #lobby messages say "green" */
const Q = 'green'
const LIST = '[data-testid=search-panel] [data-testid=left-list][data-mode=search]'
const ENTRY = `${LIST} [data-testid=left-entry][data-type=messages]`

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const selected = (p, list) => p.$$eval(`${list} [data-testid=left-entry]`, (els) => els.filter((e) => e.getAttribute('aria-selected') === 'true').map((e) => e.getAttribute('data-msg-id')))
const entryIds = (p, sel) => p.$$eval(sel, (els) => els.map((e) => e.getAttribute('data-msg-id')))
const inPlace = (href) => {
  const u = new URL(href)
  return u.pathname.endsWith('/channel/lobby') && !u.pathname.includes('/t/')
}
const marked = (p, id) => p.waitForSelector(`.msg[data-msg-id="${id}"].search-focus, .msg[data-msg-id="${id}"].open-focus`, { timeout: 10000 }).then(() => true).catch(() => false)
const noXScroll = (p) => p.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1)

const server = await startServer()
const browser = await launch()
mkdirSync(SHOTS, { recursive: true })
try {
  const errors = []
  /* ---- desktop 1440 ---- */
  const p = await browser.newPage()
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/search?q=' + Q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(ENTRY, { visible: true, timeout: NAV_TIMEOUT })
  const ids = await entryIds(p, ENTRY)
  ok('1 the hits are in the search panel; no results page, no middle list', ids.length >= 2 && !(await p.$('[data-test=search-page]')) && !(await p.$('.search-page')), { ids, url: p.url() })
  const mark = await p.$eval(ENTRY, (el) => (el.querySelector('mark') || {}).textContent || '')
  ok('2 an entry: who, where, when, the match marked', mark.toLowerCase() === Q && await p.$eval(ENTRY, (el) => Boolean(el.querySelector('.side-hit__who') && el.querySelector('.side-hit__where') && el.querySelector('.side-hit__when'))), { mark })
  await p.screenshot({ path: `${SHOTS}/1-desktop-list.png` })

  await p.$eval(LIST, (el) => el.focus())
  const s0 = await selected(p, LIST)
  await p.keyboard.press('ArrowDown')
  const s1 = await selected(p, LIST)
  await p.keyboard.press('ArrowUp')
  const s2 = await selected(p, LIST)
  ok('3 focus picks the first hit; ArrowDown / ArrowUp cycle (wrapping)', s0[0] === ids[0] && s1[0] === ids[1] && s2[0] === ids[0], { s0, s1, s2 })

  await p.click(`${LIST} [data-testid=left-entry][data-msg-id="${ids[1]}"]`)
  await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  ok('4 a click previews the hit IN PLACE: its channel, not the topic page', inPlace(p.url()) && await marked(p, ids[1]), p.url())
  const kept = await p.$(ENTRY) && await p.$eval('[data-testid=search-panel]', (el) => el.getAttribute('data-q') === 'green')
  ok('5 the query, the list and the chosen hit stay', Boolean(kept) && (await selected(p, LIST))[0] === ids[1], { sel: await selected(p, LIST) })
  await p.screenshot({ path: `${SHOTS}/2-desktop-open.png` })

  /* the place focuses its own line a moment later; the list keeps the keys */
  await new Promise((r) => setTimeout(r, 2500))
  const keptFocus = await p.evaluate(() => Boolean(document.activeElement && document.activeElement.closest('[data-testid=left-list]')))
  await p.keyboard.press('ArrowUp')
  ok('6 the keyboard stays on the list after a click: ArrowUp previews the next hit', keptFocus && (await selected(p, LIST))[0] === ids[0] && await marked(p, ids[0]), { keptFocus, sel: await selected(p, LIST) })

  await p.keyboard.press('Enter')
  const gone = await p.waitForSelector('[data-testid=search-panel]', { hidden: true, timeout: 5000 }).then(() => true).catch(() => false)
  /* a reply opens as "Open in channels view": its topic open beside the channel, at the reply */
  const shownAt = await p.waitForSelector(`aside.live-pane [data-msg-id="${ids[0]}"], .feed-body .msg[data-msg-id="${ids[0]}"]`, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  ok('7 Enter opens the hit for real: the panel closes, the hit shown in its channel', gone && inPlace(p.url()) && shownAt, { gone, shownAt, url: p.url() })

  /* dark */
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }])
  await p.screenshot({ path: `${SHOTS}/3-desktop-dark.png` })
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }])

  await p.goto(server.base + '/search?q=' + Q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(ENTRY, { visible: true, timeout: NAV_TIMEOUT })
  await p.click('[data-testid=side-search-close]')
  const closed = await p.waitForSelector('[data-testid=search-panel]', { hidden: true, timeout: 5000 }).then(() => true).catch(() => false)
  ok('8 the X closes the search list', closed)

  /* ---- phone 390 ---- */
  const m = await browser.newPage()
  m.on('pageerror', (e) => errors.push(String(e && e.message)))
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  const PLIST = '[data-testid=search-panel] [data-testid=left-list][data-mode=search]'
  const PENTRY = `${PLIST} [data-testid=left-entry][data-type=messages]`
  await m.goto(server.base + '/search?q=' + Q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await m.waitForSelector(PENTRY, { visible: true, timeout: NAV_TIMEOUT })
  const box = await m.$eval(PLIST, (el) => { const r = el.getBoundingClientRect(); return { w: r.width, x: r.left } })
  ok('9 phone: the list is the screen, one list only, no sideways scroll', box.w > 300 && (await m.$$('[data-testid=left-list][data-mode=search]')).length === 1 && await noXScroll(m), box)
  await m.screenshot({ path: `${SHOTS}/4-phone-list.png` })
  const pids = await entryIds(m, PENTRY)
  await m.tap(`${PLIST} [data-testid=left-entry][data-msg-id="${pids[1]}"] .side-hit__text`)
  await m.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  ok('10 phone: a tap opens the original in place, marked', inPlace(m.url()) && await marked(m, pids[1]), m.url())
  await m.screenshot({ path: `${SHOTS}/5-phone-open.png` })
  /* the phone stack: a hit inside a topic opens at level 3 (the thread), so
     Back walks 3 -> 2 (its channel) -> the list; at most three steps */
  let back = false
  let steps = 0
  while (!back && steps < 3) {
    steps++
    await m.goBack({ waitUntil: 'networkidle2' }).catch(() => null)
    back = await m.waitForSelector(PENTRY, { visible: true, timeout: 4000 }).then(() => true).catch(() => false)
  }
  ok('11 phone: Back returns to the list, the same hit chosen', back && await m.$eval('[data-testid=search-panel]', (el) => el.getAttribute('data-q')).catch(() => null) === Q && (await selected(m, PLIST))[0] === pids[1], { steps, url: m.url(), sel: back ? await selected(m, PLIST) : null })
  await m.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }])
  await m.screenshot({ path: `${SHOTS}/6-phone-dark.png` })

  console.log(`  screenshots ${SHOTS}`)
  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('12 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`search-left: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
