// SPL-4731 (owner HUM-10, t1 5c657679, msg 725b45b2): "The right click button
// going to the next row is a bug and it should be not allowed". On a phone a
// card with one more chip in its header (a reaction pill beside the smile) put
// the ≡ menu button alone on a second header line, under the avatar.
//
// At 390 and 360 px, phone + touch, every card of #lobby (sender -> recipient,
// "via terminal", replies ">>"), each given 0..4 reaction pills, keeps:
//   1 the menu button on the header's first line (its centre level with the
//     sender's name), at the card's right edge
//   2 the replies link ">>" on that same line
//   3 no sideways scroll
//   4 the time never cut (R7 W1, c-050: "09-…" at 360 px): no part of it
//     clipped sideways; a crowded line drops its HH:MM part whole, the day
//     part always shows, and a card with no recipient shows HH:MM too
//   5 the same with the page clock on the mock's day (R7 W2, c-050): every
//     card is from "today", so its time is the single HH:MM part, and a card
//     not answered yet carries the await-reply hourglass. HH:MM is never cut;
//     on a crowded line the hourglass gives way whole
//
// Run:
//   pnpm run test:e2e card-header-menu-row
//   BASE_URL=<generated bundle> pnpm run test:e2e card-header-menu-row   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per viewport and pill count there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
/* DUMP=1 also prints every header item's width (a probe while tuning) */
const DUMP = Boolean(process.env.DUMP)
const PATH = '/channel/lobby'
const SIZES = [{ width: 390, height: 844 }, { width: 360, height: 740 }]
/* the mock's cards are from 2026-09-18 (utils/mock-data.mjs T0): '' = the
   real clock (older days: "09-18 13:04"), else the page clock starts there */
const CLOCKS = ['', '2026-09-18T12:00:00Z']
/* the menu's 44 px target reaches the card's 4 px padding (SPL-1000) */
const EDGE = 24

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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const cardIds = (p) => p.evaluate(() => [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].map((el) => el.getAttribute('data-msg-id')))

/** Pick the n-th glyph of the emoji sheet on that card: one more reaction pill. */
async function react(p, id, n) {
  /* a click, not a tap: a tap that misses the button opens the card's topic */
  await p.evaluate((id) => {
    const b = document.querySelector(`.spool-main article.msg[data-msg-id="${id}"] [data-testid=msg-emoji-btn]`)
    b?.scrollIntoView({ block: 'center' })
    b?.click()
  }, id)
  for (let t = 0; t < 40; t++) {
    await sleep(100)
    const picked = await p.evaluate((n) => {
      const g = document.querySelectorAll('[data-testid=emoji-picker] .emoji-picker__glyph')[n]
      if (!g) return false
      g.click()
      return true
    }, n)
    if (picked) break
  }
  for (let t = 0; t < 40; t++) {
    await sleep(100)
    if (!(await p.evaluate(() => document.querySelector('[data-testid=emoji-picker]')))) return
  }
}

/** Per card: the menu's and the replies link's centre against the sender's name. */
const headers = (p) => p.evaluate((dump) => {
  const mid = (el) => {
    if (!el || !el.getClientRects().length) return null
    const b = el.getBoundingClientRect()
    return b.top + b.height / 2
  }
  return {
    vw: window.innerWidth,
    scrollW: document.documentElement.scrollWidth,
    cards: [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].map((row) => {
      const r = row.getBoundingClientRect()
      const author = mid(row.querySelector('.msg-meta > .msg-author'))
      const menu = row.querySelector('[data-testid=msg-menu-btn]')
      const replies = row.querySelector('[data-test=topic-replies]')
      const time = row.querySelector('.msg-meta > .msg-time')
      const hour = row.querySelector('.msg-meta [data-test=await-reply]')
      return {
        id: row.getAttribute('data-msg-id').slice(0, 8),
        chips: row.querySelectorAll('[data-testid=msg-reaction]').length,
        menuDy: author == null || mid(menu) == null ? null : Math.round(mid(menu) - author),
        repliesDy: author == null || mid(replies) == null ? null : Math.round(mid(replies) - author),
        menuRight: menu ? Math.round(r.right - menu.getBoundingClientRect().right) : null,
        to: Boolean(row.querySelector('.msg-meta > .avatar--to')),
        text: time ? time.textContent.trim() : null,
        /* each part of the time: 1 whole in its box, 0 wholly out, else cut */
        /* the hourglass: 1 on the header line, 0 given way (or none drawn) */
        await: hour ? (hour.getClientRects().length && time && hour.getBoundingClientRect().top < time.getBoundingClientRect().bottom - 0.5 ? 1 : 0) : null,
        parts: time ? [...(time.querySelector('.msg-time__day, .msg-time__hm') ? time.querySelectorAll('.msg-time__day, .msg-time__hm') : [time])].map((el) => {
          const t = time.getBoundingClientRect()
          const b = el.getBoundingClientRect()
          const inside = b.left >= t.left - 0.5 && b.right <= t.right + 0.5 && b.top >= t.top - 0.5 && b.bottom <= t.bottom + 0.5
          const out = b.top >= t.bottom - 0.5 || b.right <= t.left + 0.5 || b.left >= t.right - 0.5
          return inside ? 1 : out ? 0 : -1
        }) : null,
        timeVis: time ? time.clientWidth : null,
        timeNeed: time ? time.scrollWidth : null,
        items: dump ? [...row.querySelectorAll('.msg-meta > *, .msg-meta > .msg-actions > *')]
          .filter((el) => el.getClientRects().length)
          .map((el) => `${el.className || el.tagName}:${Math.round(el.getBoundingClientRect().width)}`) : undefined,
      }
    }),
  }
}, DUMP)

const server = await startServer()
const browser = await launch()
try {
  for (const clock of CLOCKS) for (const vp of SIZES) {
    const tag = `${vp.width}px${clock ? ' today' : ''}`
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
    /* the clock keeps running, from that instant */
    if (clock) await p.evaluateOnNewDocument((iso) => {
      const D = Date
      const off = D.parse(iso) - D.now()
      class Shifted extends D {
        constructor(...a) { super(...(a.length ? a : [D.now() + off])) }
        static now() { return D.now() + off }
      }
      globalThis.Date = Shifted
    }, clock)
    await p.setViewport({ ...vp, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
    await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('.spool-main article.msg[data-msg-id] [data-testid=msg-menu-btn]', { timeout: NAV_TIMEOUT })
    await sleep(600)

    const ids = await cardIds(p)
    for (let n = 0; n <= 4; n++) {
      /* one more pill on every card each round: 0, 1, 2, 3, 4 */
      if (n > 0) for (const id of ids) await react(p, id, n - 1)
      await sleep(300)
      const h = await headers(p)
      const at = `${tag} ${n} pills`
      ok(`${at} 0 three or more cards, each with ${n} reaction pills, one with a recipient and a replies link`,
        h.cards.length >= 3 && h.cards.every((c) => c.chips === n) && h.cards.some((c) => c.to && c.repliesDy != null), h.cards)

      const off = h.cards.filter((c) => c.menuDy == null || Math.abs(c.menuDy) > 4)
      ok(`${at} 1 every card: the menu on the header's first line (level with the name)`, h.cards.length > 0 && off.length === 0, off)
      const edge = h.cards.filter((c) => c.menuRight == null || c.menuRight < 0 || c.menuRight > EDGE)
      ok(`${at} 1 every card: the menu at the card's right edge`, edge.length === 0, edge)
      const rep = h.cards.filter((c) => c.repliesDy != null && Math.abs(c.repliesDy) > 4)
      ok(`${at} 2 every card: the replies link ">>" on that line`, rep.length === 0, rep)
      ok(`${at} 3 no sideways scroll`, h.scrollW <= h.vw, { scrollW: h.scrollW, vw: h.vw })
      const cut = h.cards.filter((c) => c.timeVis == null || c.timeVis < c.timeNeed || c.parts.includes(-1) || c.parts[0] !== 1 || (!c.to && c.parts.includes(0)))
      ok(`${at} 4 every card: the time never cut (the day always, HH:MM unless crowded)`, cut.length === 0, cut)
      if (clock) {
        const long = h.cards.filter((c) => c.text == null || c.text.includes(' '))
        ok(`${at} 5 every card from today: its time is HH:MM alone`, long.length === 0, long)
        if (n === 0) ok(`${at} 5 a card from today waits for its reply (the hourglass)`, h.cards.some((c) => c.await != null), h.cards)
      }
      if (DUMP) console.log(JSON.stringify(h.cards.map(({ items, ...c }) => ({ ...c, items: items?.join(' ') }))))
      if (SHOTS) await p.screenshot({ path: join(SHOTS, `card-header-menu-row-${vp.width}${clock ? '-today' : ''}-${n}.png`) })
    }
    ok(`${tag} no page errors`, errors.length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncard-header-menu-row: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
