// SPL-991 (epic SPL-988, lane M3): the message area on a phone, proved in a
// REAL browser with touch emulation, at 360 and 820 px - and the desktop at
// 1440 px unchanged.
//
//   phone (360x740, 820x1180, hasTouch):
//     1 the composer is docked: full width, its bottom on the window's bottom
//       edge, Send / Attach / Camera >= 44 px, 16 px text (no iOS zoom)
//     2 the card header's controls are >= 44 px; the smile / open icons left
//       the row; the page never scrolls sideways
//     3 a LONG PRESS on a card opens the menu as a bottom sheet (its bottom on
//       the window's bottom, full width, every item >= 44 px, Reply first)
//     4 the finger lifting after it did NOT open the topic (URL unchanged)
//     5 a tap on the dimmed page closes the sheet and opens nothing
//     6 Add emoji in the sheet opens the emoji picker as a sheet, 44 px glyphs
//     7 CONTROL: a short tap is not a long press (no sheet)
//    10 a left-panel row's menu (level 1) is a 44 px button opening a sheet
//   desktop (1440x900, mouse):
//     8 the composer is in the top bar, not docked; --composer-dock-h is 0
//     9 a right-click menu is the old popover: no sheet class, no Reply, and
//       the row's menu button is still 32 px
//
// Run:
//   pnpm run test:e2e:mobile-messages
//   BASE_URL=<generated bundle> pnpm run test:e2e:mobile-messages   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per viewport there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/lobby'
const TAP = 44

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function composerFacts(page) {
  return page.evaluate(() => {
    const f = document.querySelector('form.composer.omnibox--global')
    if (!f) return null
    const r = f.getBoundingClientRect()
    const box = (sel) => {
      const el = f.querySelector(sel)
      if (!el) return null
      const b = el.getBoundingClientRect()
      return { w: Math.round(b.width), h: Math.round(b.height) }
    }
    const ta = f.querySelector('textarea')
    return {
      docked: f.getAttribute('data-docked') === 'true',
      left: Math.round(r.left),
      width: Math.round(r.width),
      bottom: Math.round(r.bottom),
      vw: window.innerWidth,
      vh: window.innerHeight,
      send: box('[data-testid=send]'),
      attach: box('[data-testid=attach]'),
      camera: box('[data-testid=attach-camera]'),
      syntax: box('[data-test=search-syntax-help]'),
      field: box('textarea'),
      font: ta ? parseFloat(getComputedStyle(ta).fontSize) : 0,
      dockVar: getComputedStyle(document.documentElement).getPropertyValue('--composer-dock-h').trim(),
    }
  })
}

/** The first card in the list with room to press on, and its header controls. */
function cardFacts(page) {
  return page.evaluate(() => {
    const row = [...document.querySelectorAll('article.msg[data-msg-id]')]
      .find((el) => el.getBoundingClientRect().height > 40 && el.getBoundingClientRect().top > 60)
    if (!row) return null
    const r = row.getBoundingClientRect()
    const size = (sel) => {
      const el = row.querySelector(sel)
      if (!el) return null
      const b = el.getBoundingClientRect()
      return { w: Math.round(b.width), h: Math.round(b.height), shown: getComputedStyle(el).display !== 'none' }
    }
    return {
      id: row.getAttribute('data-msg-id'),
      x: Math.round(r.left + r.width / 2),
      y: Math.round(r.top + Math.min(r.height / 2, 60)),
      menuBtn: size('[data-testid=msg-menu-btn]'),
      menuRight: Math.round(r.right - (row.querySelector('[data-testid=msg-menu-btn]')?.getBoundingClientRect().right ?? 0)),
      emojiBtn: size('[data-testid=msg-emoji-btn]'),
      scrollW: document.scrollingElement.scrollWidth,
      vw: window.innerWidth,
    }
  })
}

function sheetFacts(page, sel) {
  return page.evaluate((s) => {
    const el = document.querySelector(s)
    if (!el) return null
    const r = el.getBoundingClientRect()
    const items = [...el.querySelectorAll('[role=menuitem], .emoji-picker__glyph')]
      .map((b) => Math.round(Math.min(b.getBoundingClientRect().height, b.getBoundingClientRect().width)))
    return {
      sheet: el.classList.contains('touch-sheet'),
      left: Math.round(r.left),
      width: Math.round(r.width),
      bottom: Math.round(r.bottom),
      vw: window.innerWidth,
      vh: window.innerHeight,
      minItem: items.length ? Math.min(...items) : 0,
      ids: [...el.querySelectorAll('[role=menuitem]')].map((b) => b.getAttribute('data-testid')),
      backdrop: Boolean(document.querySelector('[data-testid=sheet-backdrop]')),
    }
  }, sel)
}

async function longPress(page, x, y, ms = 750) {
  await page.touchscreen.touchStart(x, y)
  await sleep(ms)
  await page.touchscreen.touchEnd()
  await sleep(250)
}

async function phone(browser, width, height) {
  const tag = `${width}px`
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width, height, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await sleep(400)

  const c = await composerFacts(p)
  ok(`${tag} 1 composer docked at the bottom, full width, 44 px controls, 16 px text`,
    Boolean(c && c.docked && c.left === 0 && c.width === c.vw && Math.abs(c.bottom - c.vh) <= 1
      && c.send && c.send.w >= TAP && c.send.h >= TAP && c.attach && c.attach.h >= TAP
      && c.camera && c.camera.h >= TAP && c.syntax && c.syntax.w >= TAP && c.syntax.h >= TAP
      && c.field && c.field.h >= TAP && c.font >= 16 && c.dockVar !== '0px'), c)

  const card = await cardFacts(p)
  ok(`${tag} 2 card header controls >= 44 px, the menu at the right edge, smile icon off the row, no sideways scroll`,
    Boolean(card && card.menuBtn && card.menuBtn.w >= TAP && card.menuBtn.h >= TAP
      && card.emojiBtn && !card.emojiBtn.shown && card.scrollW <= card.vw
      && card.menuRight >= 0 && card.menuRight <= 24), card)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `mobile-messages-${width}.png`) })
  if (!card) return p.close()

  const url0 = p.url()
  /* 7 CONTROL first: a short tap is not a long press */
  await p.touchscreen.touchStart(card.x, card.y)
  await sleep(80)
  await p.touchscreen.touchEnd()
  await sleep(300)
  const tapped = await sheetFacts(p, '[data-testid=msg-menu]')
  ok(`${tag} 7 CONTROL: a short tap opens no sheet`, tapped === null, tapped)
  /* the tap may have opened the topic (a clickable card): start again clean */
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`article.msg[data-msg-id="${card.id}"]`, { timeout: NAV_TIMEOUT })
  await sleep(300)
  const again = await cardFacts(p)

  await longPress(p, again.x, again.y)
  const m = await sheetFacts(p, '[data-testid=msg-menu]')
  ok(`${tag} 3 long press opens the menu as a bottom sheet, 44 px items, Reply first`,
    Boolean(m && m.sheet && m.left === 0 && m.width === m.vw && Math.abs(m.bottom - m.vh) <= 1
      && m.minItem >= TAP && m.ids[0] === 'msg-menu-reply' && m.ids.includes('msg-menu-react') && m.backdrop), m)
  ok(`${tag} 4 the lifting finger did not open the topic`, p.url() === url0, { before: url0, after: p.url() })
  if (SHOTS && m) await p.screenshot({ path: join(SHOTS, `mobile-messages-${width}-sheet.png`) })

  /* 5: a tap on the dimmed page, well above the sheet */
  await p.touchscreen.tap(Math.round(again.x), 20)
  await sleep(300)
  const closed = await sheetFacts(p, '[data-testid=msg-menu]')
  ok(`${tag} 5 a tap on the backdrop closes the sheet and opens nothing`,
    closed === null && p.url() === url0, { closed, url: p.url() })

  await longPress(p, again.x, again.y)
  await p.tap('[data-testid=msg-menu-react]').catch(() => {})
  await sleep(300)
  const e = await sheetFacts(p, '[data-testid=emoji-picker]')
  ok(`${tag} 6 Add emoji opens the picker as a sheet with 44 px glyphs`,
    Boolean(e && e.sheet && Math.abs(e.bottom - e.vh) <= 1 && e.minItem >= TAP), e)
  /* 10: the left panel (level 1) - a row's menu is a bottom sheet too */
  await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await sleep(400)
  const row = await p.evaluate(() => {
    const b = [...document.querySelectorAll('[data-testid="sidebar-row-menu"]')]
      .find((el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.top > 0 && r.bottom < window.innerHeight })
    if (!b) return null
    const r = b.getBoundingClientRect()
    return { w: Math.round(r.width), h: Math.round(r.height), x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }
  })
  if (row) {
    await p.touchscreen.tap(row.x, row.y)
    await sleep(350)
  }
  const side = await p.evaluate(() => {
    const el = [...document.querySelectorAll('[data-testid="sidebar-row-menu-panel"]')].find((n) => getComputedStyle(n).display !== 'none')
    if (!el) return null
    const r = el.getBoundingClientRect()
    const items = [...el.querySelectorAll('[role=menuitem]')].map((b) => Math.round(b.getBoundingClientRect().height))
    return { sheet: el.classList.contains('touch-sheet'), inBody: el.parentElement === document.body, width: Math.round(r.width), bottom: Math.round(r.bottom), vw: window.innerWidth, vh: window.innerHeight, minItem: items.length ? Math.min(...items) : 0 }
  })
  ok(`${tag} 10 a left-panel row menu: 44 px button, opens a bottom sheet with 44 px items`,
    Boolean(row && row.w >= TAP && row.h >= TAP && side && side.sheet && side.inBody && side.width === side.vw
      && Math.abs(side.bottom - side.vh) <= 1 && side.minItem >= TAP), { row, side })
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

async function desktop(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await sleep(300)
  const c = await composerFacts(p)
  ok('1440px 8 composer stays in the top bar (not docked, --composer-dock-h 0)',
    Boolean(c && !c.docked && c.bottom < 120 && (c.dockVar === '0px' || c.dockVar === '')), c)
  const card = await cardFacts(p)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'mobile-messages-1440.png') })
  await p.mouse.click(card.x, card.y, { button: 'right' })
  await sleep(300)
  const m = await sheetFacts(p, '[data-testid=msg-menu]')
  ok('1440px 9 right-click menu is the old popover: no sheet, no Reply; menu button 32 px',
    Boolean(m && !m.sheet && !m.backdrop && !m.ids.includes('msg-menu-reply') && m.ids[0] === 'msg-menu-open'
      && card.menuBtn && card.menuBtn.w === 32 && card.emojiBtn && card.emojiBtn.shown), { m, card })
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  await phone(browser, 360, 740)
  await phone(browser, 820, 1180)
  await desktop(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
