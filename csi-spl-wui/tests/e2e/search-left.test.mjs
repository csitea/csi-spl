// CLE-77884 (owner, topic 635f8072 96a88e32): the search results are the
// LEFT panel's list, not the middle. In a real browser on the mock tenant:
// desktop 1440 - /search?q= fills the left panel (compact hits, the match
// marked), the middle only points at it; ArrowUp/Down cycle; Enter and a click
// open a hit IN PLACE (its channel, not /t/), and the query + list + chosen hit
// stay while the reader clicks through; the X closes the list. Phone 390 - the
// list is the screen, a tap opens the original, Back returns to the list with
// the same hit chosen; light + dark, no sideways scroll.
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
const LIST = '[data-testid=sidebar-panel-search] [data-testid=left-list][data-mode=search]'
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
const inPlace = (href, id) => {
  const u = new URL(href)
  return u.pathname.endsWith('/channel/lobby') && !u.pathname.includes('/t/') && u.hash === '#' + id
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
  const middleList = await p.$('.search-page [data-testid=left-list]')
  const hint = await p.$('.search-page [data-test=search-left-hint]')
  ok('1 the hits are in the LEFT panel; the middle only points at them', ids.length >= 2 && !middleList && Boolean(hint), { ids })
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

  await p.keyboard.press('ArrowDown')
  await p.keyboard.press('Enter')
  await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  ok('4 Enter opens the hit IN PLACE: its channel, not the topic page', inPlace(p.url(), ids[1]), p.url())
  ok('5 the message is marked where it opened', await marked(p, ids[1]))
  const kept = await p.$(ENTRY) && await p.$eval('[data-testid=sidebar-panel-search]', (el) => el.textContent.includes('green'))
  ok('6 the query, the list and the chosen hit stay', Boolean(kept) && (await selected(p, LIST))[0] === ids[1], { sel: await selected(p, LIST) })
  await p.screenshot({ path: `${SHOTS}/2-desktop-open.png` })

  /* the place focuses its own line a moment later; the list keeps the keys */
  await new Promise((r) => setTimeout(r, 2500))
  const keptFocus = await p.evaluate(() => Boolean(document.activeElement && document.activeElement.closest('[data-testid=left-list]')))
  await p.keyboard.press('ArrowUp')
  ok('6b the keyboard stays on the list after Enter: ArrowUp keeps cycling', keptFocus && (await selected(p, LIST))[0] === ids[0], { keptFocus, sel: await selected(p, LIST) })

  await p.click(`${LIST} [data-testid=left-entry][data-msg-id="${ids[0]}"]`)
  await p.waitForFunction((id) => location.hash === '#' + id, { timeout: 10000 }, ids[0]).catch(() => null)
  ok('7 a click on the next hit opens it; the list is still there', inPlace(p.url(), ids[0]) && Boolean(await p.$(ENTRY)) && (await selected(p, LIST))[0] === ids[0], p.url())

  /* dark */
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'dark' }])
  await p.screenshot({ path: `${SHOTS}/3-desktop-dark.png` })
  await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: 'light' }])

  await p.click('[data-testid=side-search-close]')
  const closed = await p.waitForSelector('[data-testid=sidebar-panel-search]', { hidden: true, timeout: 5000 }).then(() => true).catch(() => false)
  ok('8 the X closes the search list', closed)

  /* ---- phone 390 ---- */
  const m = await browser.newPage()
  m.on('pageerror', (e) => errors.push(String(e && e.message)))
  await m.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  const PLIST = '.search-page [data-testid=left-list][data-mode=search]'
  const PENTRY = `${PLIST} [data-testid=left-entry][data-type=messages]`
  await m.goto(server.base + '/search?q=' + Q, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await m.waitForSelector(PENTRY, { visible: true, timeout: NAV_TIMEOUT })
  const box = await m.$eval(PLIST, (el) => { const r = el.getBoundingClientRect(); return { w: r.width, x: r.left } })
  ok('9 phone: the list is the screen, one list only, no sideways scroll', box.w > 300 && (await m.$$('[data-testid=left-list][data-mode=search]')).length === 1 && await noXScroll(m), box)
  await m.screenshot({ path: `${SHOTS}/4-phone-list.png` })
  const pids = await entryIds(m, PENTRY)
  await m.tap(`${PLIST} [data-testid=left-entry][data-msg-id="${pids[1]}"] .side-hit__text`)
  await m.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  ok('10 phone: a tap opens the original in place, marked', inPlace(m.url(), pids[1]) && await marked(m, pids[1]), m.url())
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
  ok('11 phone: Back returns to the list, the same hit chosen', back && new URL(m.url()).searchParams.get('q') === Q && (await selected(m, PLIST))[0] === pids[1], { steps, url: m.url(), sel: back ? await selected(m, PLIST) : null })
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
