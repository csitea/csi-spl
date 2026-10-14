// SPL-1763 (owner HUM-10, t1 0bb05176 msg 5cd1ce7b): "whenever one clicks on
// the "Archived" label, that label is a button which will unarchive the
// topic ... And on mobile first". Real browser, mock tenant, phone 390 first,
// then desktop 1440:
//
//   archive   the fixture topic, from its card menu in #lobby
//   button    its open topic header's Archived badge is a <button> named
//             "Unarchive topic"; on the phone a tap 20 px above or below its
//             centre still hits it (44 px tap area) and turning it into a
//             button moved no other header item (no layout jump)
//   tap       tap it: the badge leaves the header and the card is back in
//             the #lobby feed (live again)
//   control   a live topic's header has no badge at all
//
// A full page load resets the mock, so everything stays on one document.
//
//   BASE_URL=<generated bundle> node tests/e2e/archived-badge-unarchive.test.mjs
//   SHOTS_DIR=<dir> also saves before / after screenshots per width.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const ARCH = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const LIVE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const ARCH_CARD = '22222222-2222-4222-8222-222222222222'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
const SHOTS = process.env.SHOTS_DIR || ''

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  const href = pathToFileURL(require.resolve('puppeteer-core')).href
  const mod = await import(href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    defaultViewport: null,
    args: CHROME_LAUNCH_ARGS,
  })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

async function until(p, fn, ms = 8000, arg) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(150)
  }
  return false
}

/* Archive the fixture topic from its card's menu in #lobby; true once the card left the feed. */
async function archiveFromCard(p) {
  const card = `.spool-main article.msg[data-msg-id="${ARCH_CARD}"]`
  await p.waitForSelector(card, { timeout: 15000 })
  let opened = false
  for (let i = 0; i < 4 && !opened; i++) {
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), card)
    opened = await until(p, () => Boolean(document.querySelector('[data-testid=msg-menu-archive]')), 4000)
  }
  if (!opened) return false
  await p.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())
  return until(p, (sel) => !document.querySelector(sel), 8000, card)
}

/* The open topic header: the badge, what it is, and where every item sits. */
const snap = () => {
  const header = document.querySelector('[data-test=topic-section] header')
  const badge = header && header.querySelector('[data-test=archived-badge]')
  const r = badge ? badge.getBoundingClientRect() : null
  const cx = r ? r.left + r.width / 2 : 0
  const cy = r ? r.top + r.height / 2 : 0
  const hits = (dy) => {
    if (!badge) return false
    const el = document.elementFromPoint(cx, cy + dy)
    return Boolean(el && (el === badge || badge.contains(el)))
  }
  /* relative to the header: the phone pane may still be sliding in */
  const h = header ? header.getBoundingClientRect() : { left: 0, top: 0 }
  const items = header ? [...header.children].filter((el) => el !== badge).map((el) => {
    const b = el.getBoundingClientRect()
    return [Math.round(b.left - h.left), Math.round(b.top - h.top), Math.round(b.width), Math.round(b.height)].join(',')
  }) : []
  return {
    tag: badge ? badge.tagName.toLowerCase() : '',
    name: badge ? badge.getAttribute('aria-label') || '' : '',
    type: badge ? badge.getAttribute('type') || '' : '',
    text: badge ? badge.textContent.replace(/\s+/g, ' ').trim() : '',
    box: r ? [Math.round(r.width), Math.round(r.height)] : [],
    hitUp: hits(-20),
    hitDown: hits(20),
    hitMid: hits(0),
    items: items.join(' | '),
    headerH: header ? Math.round(header.getBoundingClientRect().height) : 0,
    xScroll: document.documentElement.scrollWidth > innerWidth + 1,
  }
}

async function run(browser, base, width) {
  const p = await browser.newPage()
  const phone = width < 600
  await p.setViewport({ width, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  await p.evaluateOnNewDocument((claims) => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
    try { localStorage.setItem('spool.mock.session', JSON.stringify(claims)) } catch { /* */ }
  }, CLAIMS)
  const tag = phone ? `phone ${width}` : `desktop ${width}`
  await p.goto(`${base}/`, { waitUntil: 'load', timeout: NAV })
  const open = (path) => p.evaluate(async (to) => {
    await document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to)
  }, path)
  await p.waitForSelector('[data-testid=sidebar-rail]', { timeout: NAV })
  await open('/lobby')
  check(`${tag}: archived the fixture topic`, await archiveFromCard(p))

  await open(`/lobby?topic=${ARCH}`)
  await until(p, () => Boolean(document.querySelector('[data-test=topic-section] header [data-test=archived-badge]')))
  const label = await p.evaluate(snap)
  /* the hub's answer turns the label into the button; the header must not move */
  const isButton = await until(p, () => document.querySelector('[data-test=topic-section] header [data-test=archived-badge]')?.tagName === 'BUTTON')
  /* the archive's own Undo toast goes first, so the screenshot shows the header alone */
  await until(p, () => !document.querySelector('[data-testid=archive-toast-undo]'), 4000)
  await sleep(300)
  const before = await p.evaluate(snap)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `archived-badge-${width}-before.png`) })
  check(`${tag}: the Archived label is a button named "Unarchive topic"`,
    isButton && before.tag === 'button' && before.type === 'button' && before.name === 'Unarchive topic' && /archived/i.test(before.text), before)
  check(`${tag}: label -> button moved no other header item`,
    label.items === before.items && label.headerH === before.headerH && String(label.box) === String(before.box) && !before.xScroll, { label, before })
  if (phone) {
    check(`${tag}: the tap area is >= 44 px tall (a tap 20 px above / below the centre hits it)`,
      before.hitMid && before.hitUp && before.hitDown, before)
  }

  /* tap (phone) / click (desktop) the label */
  const sel = '[data-test=topic-section] header [data-test=archived-badge]'
  if (phone) await p.tap(sel)
  else await p.click(sel)
  const gone = await until(p, (s) => !document.querySelector(s), 8000, sel)
  await sleep(300)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `archived-badge-${width}-after.png`) })
  check(`${tag}: after the tap the badge is gone from the topic header`, gone, await p.evaluate(snap))

  await open('/lobby')
  const back = await until(p, (id) => Boolean(document.querySelector(`.spool-main article.msg[data-msg-id="${id}"]`)), 8000, ARCH_CARD)
  check(`${tag}: the topic is live again (its card is back in the #lobby feed)`, back,
    await p.evaluate(() => ({ path: location.pathname + location.search, ids: [...document.querySelectorAll('.spool-main article.msg')].map((a) => a.getAttribute('data-msg-id')) })))

  await open(`/lobby?topic=${LIVE}`)
  await until(p, () => Boolean(document.querySelector('[data-test=topic-section] [data-test=topic-heading]')))
  await sleep(400)
  const live = await p.evaluate(snap)
  check(`${tag}: control - a live topic header has no badge, no button`, !live.tag, live)

  const errs = (await p.evaluate(() => window.__errs || [])).filter((e) => !/dynamically imported module/.test(e))
  check(`${tag}: no window error`, errs.length === 0, { errs })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [390, 1440]) await run(browser, server.base, w)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\narchived-badge-unarchive: ${results.length - failed.length}/${results.length} passed`)
if (failed.length || code) process.exit(1)
