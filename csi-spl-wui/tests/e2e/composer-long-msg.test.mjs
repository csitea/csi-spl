// Owner, t1 d3bbe2c2 (2026-10-03): "On mobile when I type long messages I
// cannot see the last part of the msg WHERE AM I typing ?!", "For long msgs ,
// there is some kind of strong scroll ?!", "something with the scroll, resets
// it up". A phone keyboard COMPOSES each word (IME); the Omnibox re-fit its
// height on every committed word through `height: auto`, which dropped the
// field's scroll to the top - measured: scrollTop 0, the caret 441 px under
// the box, then the next word scrolled it back down (the "strong scroll").
//
//   phone (390x844, the keyboard up: the viewport 340 px shorter, as
//   interactive-widget=resizes-content does on Android), the mock:
//     1 IME typing past the cap: after every word the caret line (at the end)
//       is inside the box (n=3)
//     2 the box grows to its cap, then scrolls inside: once at the cap its
//       scroll never moves back up, and the page itself never scrolls (n=3)
//     3 the same caret check with plain key events
//   desktop (1440x900): 4 CONTROL: the box grows line by line with the text
//     (no overflow under its cap), the caret in view, no page scroll
//
// Run:
//   pnpm run test:e2e composer-long-msg
//   BASE_URL=<generated bundle> pnpm run test:e2e composer-long-msg   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
const KEYBOARD = 340
const RUNS = 3
const BOX = 'form.composer.omnibox--global textarea'
/* ~1000 characters: about 20 lines at 390 px, well past the phone cap */
const LONG = Array.from({ length: 40 }, (_, i) => `word${i} lorem ipsum dolor`).join(' ')

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The box's size and scroll; `hidden` = px of text under its visible part. */
const sample = (p) => p.evaluate((sel) => {
  const ta = document.querySelector(sel)
  const padB = parseFloat(getComputedStyle(ta).paddingBottom) || 0
  return {
    h: Math.round(ta.getBoundingClientRect().height),
    hidden: Math.max(0, Math.round(ta.scrollHeight - ta.clientHeight - ta.scrollTop - padB)),
    over: ta.scrollHeight - ta.clientHeight,
    atEnd: ta.selectionEnd === ta.value.length,
    y: Math.round(scrollY),
  }
}, BOX)

/** From now on: every scroll of the box (with its height then), and a count
    of every other scroll on the page. */
const record = (p) => p.evaluate((sel) => {
  const ta = document.querySelector(sel)
  window.__longMsg = { box: [], page: 0 }
  ta.addEventListener('scroll', () => window.__longMsg.box.push([Math.round(ta.scrollTop), Math.round(ta.getBoundingClientRect().height)]))
  document.addEventListener('scroll', (e) => { if (e.target !== ta) window.__longMsg.page++ }, true)
}, BOX)

/** Type LONG word by word; an IME composes each word letter by letter first. */
async function typeLong(p, ime) {
  const cdp = ime ? await p.createCDPSession() : null
  const rows = []
  for (const w of LONG.split(/(?<= )/)) {
    if (cdp) {
      for (let k = 1; k <= w.length; k++) await cdp.send('Input.imeSetComposition', { text: w.slice(0, k), selectionStart: k, selectionEnd: k })
      await cdp.send('Input.insertText', { text: w })
    } else {
      await p.keyboard.type(w)
    }
    await sleep(30)
    rows.push(await sample(p))
  }
  const ev = await p.evaluate(() => window.__longMsg)
  return { rows, ev }
}

/* Scroll moves back UP while the box sat at its cap: the box did not grow,
   so nothing but a reset moves its text down. (Under the cap a growing box
   rightly drops its scroll: the text fits again.) */
function backsAtCap(box, cap) {
  let n = 0
  for (let i = 1; i < box.length; i++) if (box[i][1] >= cap && box[i - 1][1] >= cap && box[i][0] < box[i - 1][0]) n++
  return n
}

async function openPhone(browser) {
  const p = await browser.newPage()
  await p.setViewport(PHONE)
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(800)
  await p.click('[data-testid=sidebar-tab-channels]')
  await sleep(400)
  await p.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
  await sleep(1200)
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  await p.focus(BOX)
  /* the keyboard comes up */
  await p.setViewport({ ...PHONE, height: PHONE.height - KEYBOARD })
  await sleep(300)
  await record(p)
  return p
}

async function phone(browser, ime, run) {
  const p = await openPhone(browser)
  const { rows, ev } = await typeLong(p, ime)
  await p.close()
  const cap = Math.max(...rows.map((r) => r.h))
  const lost = rows.filter((r) => r.atEnd && r.hidden > 0)
  const tag = ime ? `IME run ${run}/${RUNS}` : 'keys'
  ok(`390px ${ime ? 1 : 3} ${tag}: after every word the caret line at the end is inside the box`,
    rows.length > 0 && lost.length === 0,
    { words: rows.length, lost: lost.length, worstHiddenPx: Math.max(0, ...rows.map((r) => r.hidden)) })
  if (!ime) return
  const backs = backsAtCap(ev.box, cap)
  ok(`390px 2 ${tag}: the box grows to its cap, then scrolls inside - never back up there, the page never scrolls`,
    rows.some((r) => r.over > 0 && r.h === cap) && backs === 0 && ev.page === 0 && rows.every((r) => r.y === 0),
    { cap, scrollBacksAtCap: backs, pageScrolls: ev.page })
}

async function desktop(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${server.base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  await sleep(400)
  await p.focus(BOX)
  await record(p)
  const { rows, ev } = await typeLong(p, false)
  await p.close()
  const cap = Math.floor(900 * 0.4)
  const heights = [...new Set(rows.map((r) => r.h))]
  ok('1440px 4 CONTROL: the top-bar box grows line by line with the text (no overflow under its cap), caret in view, no page scroll',
    heights.length > 3 && rows.every((r) => (r.h < cap ? r.over === 0 : true) && r.hidden === 0 && r.y === 0) && ev.page === 0,
    { heights, last: rows.at(-1) })
}

const server = await startServer()
const browser = await launch()
try {
  for (let run = 1; run <= RUNS; run++) await phone(browser, true, run)
  await phone(browser, false, 1)
  await desktop(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
