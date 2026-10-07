// Owner, t1 26282b6e: once the omnibox holds more than one line, the left
// element (the mode glyph, and the target chip beside it) moves to a row
// above the text, and the text starts at the field's inline start — the
// same left padding as a one-line box that has no glyph indent.
//
//   desktop 1440, top bar, /channel/alerts, a thread open (the tree glyph):
//     1 one line: the glyph sits on the first line and the text is indented
//     2 Shift+Enter: the glyph (and the chip) sit above the text, the
//       textarea's inline-start padding equals the no-glyph padding, the
//       caret stays in the box at the end of the text
//     3 back to one short line: the indent returns, the text starts after
//       the chip, and the layout holds. "Short" is measured: a narrow room
//       beside a chip can make "hi" a real wrap (wf10 37489221858,
//       2026-10-06, the phone chip since removed by owner msg b2e7c197); the
//       check then takes "i" for the one-line case and asserts "hi" settles
//       multi-line (3b) instead of flipping
//     4 a long line with no newline wraps into the same layout
//   desktop 1440, composer_position bottom: the same two-line layout
//   phone 390, the dock: the same two-line layout
//
// Run:
//   pnpm run test:e2e omnibox-multiline
//   BASE_URL=<generated bundle> pnpm run test:e2e omnibox-multiline
//   SHOT_DIR=<dir> ... writes before/after screenshots there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || join(tmpdir(), 'omnibox-multiline')
mkdirSync(SHOT_DIR, { recursive: true })
console.log(`SHOT_DIR=${SHOT_DIR}`)

const MOCK = { hum: 'HUM-1', name: 'Member', email: 'member@example.com', t: 'mock' }
const LONG = 'm'.repeat(160)

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

function readBox(p) {
  return p.evaluate(() => {
    const vis = (el) => Boolean(el) && el.getClientRects().length > 0
    const f = [...document.querySelectorAll('form.composer.omnibox--global')].find(vis)
    if (!f) return null
    const field = f.querySelector('.omnibox-field')
    const ta = f.querySelector('textarea')
    if (!field || !ta) return null
    const tcs = getComputedStyle(ta)
    const fcs = getComputedStyle(field)
    const tb = ta.getBoundingClientRect()
    const fb = field.getBoundingClientRect()
    const padStart = parseFloat(tcs.paddingInlineStart) || 0
    const padTop = parseFloat(tcs.paddingTop) || 0
    const lh = parseFloat(tcs.lineHeight) || parseFloat(tcs.fontSize) * 1.2
    const textTop = tb.top + padTop
    const textStart = tb.left + padStart
    const fieldStart = fb.left + (parseFloat(fcs.borderLeftWidth) || 0) + (parseFloat(fcs.paddingLeft) || 0)
    const lineMid = textTop + lh / 2
    const indent = parseFloat(tcs.textIndent) || 0
    /* room for text on the first line of the ONE-LINE layout */
    const room = ta.clientWidth - padStart - (parseFloat(tcs.paddingInlineEnd) || 0) - indent
    const chipEl = f.querySelector('[data-test=composer-target-chip]')
    const place = (el) => {
      if (!el || !vis(el)) return null
      const b = el.getBoundingClientRect()
      const mid = b.top + b.height / 2
      return {
        above: b.bottom <= textTop + 1,
        dy: Math.round(mid - lineMid),
        left: Math.round(b.left),
        bottom: Math.round(b.bottom),
        inset: Math.round(b.top - fb.top - (parseFloat(fcs.borderTopWidth) || 0)),
      }
    }
    return {
      multiline: field.getAttribute('data-multiline') === 'true',
      padStart,
      room: Math.round(room * 10) / 10,
      font: tcs.font,
      firstStart: Math.round(tb.left + padStart + indent),
      chipRight: chipEl && vis(chipEl) ? Math.round(chipEl.getBoundingClientRect().right) : null,
      startGap: Math.round((textStart - fieldStart) * 10) / 10,
      focused: document.activeElement === ta,
      caret: ta.selectionStart,
      len: ta.value.length,
      value: ta.value,
      bottom: f.classList.contains('omnibox--bottom'),
      docked: f.getAttribute('data-docked') === 'true',
      glyph: place(f.querySelector('[data-test=composer-mode-glyph]')),
      chip: place(chipEl),
    }
  })
}

async function open(browser, vp, path, session) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify(s))
      /* a previous case's draft must not come back as a multi-line box */
      localStorage.removeItem('spool.drafts')
    } catch { /* private mode */ }
  }, session)
  await p.setViewport(vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('form.composer.omnibox--global textarea', { timeout: NAV_TIMEOUT })
  return { p, errors }
}

async function shot(p, name) {
  const form = await p.$('form.composer.omnibox--global')
  if (form) await form.screenshot({ path: join(SHOT_DIR, `${name}.png`) })
}

async function openThread(p) {
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  const card = await p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const body = el.querySelector('.msg-body') || el
    const r = body.getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) }
  })
  if (!card) return false
  await p.mouse.click(card.x, card.y)
  const shown = await p.waitForSelector('form.composer.omnibox--global [data-test=composer-mode-glyph]', { timeout: 15000 }).then(() => true, () => false)
  await sleep(200)
  return shown
}

async function focusBox(p) {
  /* under load a late re-render can take the focus back; wait until the
     box really holds it before typing */
  for (let i = 0; i < 5; i++) {
    await p.click('form.composer.omnibox--global textarea')
    const held = await p.waitForFunction(() => {
      const ta = document.querySelector('form.composer.omnibox--global textarea')
      return ta && document.activeElement === ta
    }, { timeout: 2000 }).then(() => true, () => false)
    if (held) { await sleep(150); if (await p.evaluate(() => document.activeElement === document.querySelector('form.composer.omnibox--global textarea'))) return }
  }
}

async function replaceText(p, value) {
  await p.evaluate(() => {
    const ta = document.querySelector('form.composer.omnibox--global textarea')
    ta.focus()
    ta.setSelectionRange(0, ta.value.length)
  })
  await p.keyboard.press('Backspace')
  if (value) await p.keyboard.type(value)
}

/** Two lines, then one line, then a wrap. `basePad` is the no-glyph padding. */
async function exercise(p, tag, basePad) {
  await focusBox(p)
  await replaceText(p, '')
  await sleep(80)
  const one = await readBox(p)
  await shot(p, `${tag}-before`)
  ok(`${tag} 1 one line: glyph on the first line, text indented past the no-glyph padding`,
    Boolean(one && one.glyph && !one.multiline && !one.glyph.above && Math.abs(one.glyph.dy) <= 6 && one.padStart >= basePad + 16),
    one && { pad: one.padStart, dy: one.glyph && one.glyph.dy, multi: one.multiline })

  await p.keyboard.type('hello')
  await p.keyboard.down('Shift')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Shift')
  await p.keyboard.type('world')
  await p.waitForFunction(() => {
    const f = document.querySelector('form.composer.omnibox--global .omnibox-field')
    return f && f.getAttribute('data-multiline') === 'true'
  }, { timeout: 5000 }).catch(() => null)
  await sleep(100)
  const two = await readBox(p)
  await shot(p, `${tag}-after`)
  const padBack = two && Math.abs(two.padStart - basePad) <= 0.6
  const above = two && two.glyph && two.glyph.above && two.glyph.dy < -8
  const chipAbove = !two || !two.chip || (two.chip.above && two.chip.dy < -8)
  ok(`${tag} 2 two lines: glyph above the text, left padding equals the no-glyph padding, caret still in the box`,
    Boolean(two && two.multiline && two.value === 'hello\nworld' && above && chipAbove && padBack && two.startGap <= 2 && two.focused && two.caret === two.len),
    two)
  /* the row on top keeps the one-line top padding: the glyph is not
     pressed against (or clipped by) the field's top border */
  ok(`${tag} 2b the glyph row clears the field's top border`,
    Boolean(two && two.glyph && two.glyph.inset >= 4), two && two.glyph && { inset: two.glyph.inset })

  /* the short line is one that fits the one-line room step 1 measured, in
     the box's own font: the chip's width (and so the room) follows the fonts */
  const width = (s) => p.evaluate((font, s) => {
    const c = document.createElement('canvas').getContext('2d')
    c.font = font
    return c.measureText(s).width
  }, one ? one.font : '16px sans-serif', s)
  const room = one ? one.room : 0
  const hiW = await width('hi')
  const short = hiW <= room ? 'hi' : 'i'
  const shortW = short === 'hi' ? hiW : await width('i')
  if (hiW > room + 1) {
    await replaceText(p, 'hi')
    await sleep(100)
    const a = await readBox(p)
    await sleep(400)
    const b = await readBox(p)
    ok(`${tag} 3b a line wider than the room beside the chip settles multi-line`,
      Boolean(a && b && a.multiline && b.multiline && b.value === 'hi'),
      { room, hiW: Math.round(hiW * 10) / 10, multi: [a && a.multiline, b && b.multiline] })
  }
  await replaceText(p, short)
  await sleep(100)
  const back = await readBox(p)
  await sleep(400)
  const held = await readBox(p)
  const clear = (r) => r && (r.chipRight == null || r.firstStart >= r.chipRight)
  ok(`${tag} 3 one short line again: the indent is back, clears the chip, the glyph is on the line`,
    Boolean(shortW <= room && back && held && !back.multiline && !held.multiline && back.value === short &&
      back.glyph && !back.glyph.above && Math.abs(back.glyph.dy) <= 8 && back.padStart >= basePad + 16 &&
      clear(held) && back.focused),
    back && { short, room, shortW: Math.round(shortW * 10) / 10, pad: back.padStart, dy: back.glyph && back.glyph.dy,
      multi: [back.multiline, held && held.multiline], start: held && held.firstStart, chipRight: held && held.chipRight, focused: back.focused })

  await replaceText(p, LONG)
  await p.waitForFunction(() => {
    const f = document.querySelector('form.composer.omnibox--global .omnibox-field')
    return f && f.getAttribute('data-multiline') === 'true'
  }, { timeout: 5000 }).catch(() => null)
  await sleep(100)
  const wrap = await readBox(p)
  await shot(p, `${tag}-wrap`)
  ok(`${tag} 4 a long line with no newline uses the same layout`,
    Boolean(wrap && wrap.multiline && !wrap.value.includes('\n') && wrap.glyph && wrap.glyph.above && Math.abs(wrap.padStart - basePad) <= 0.6 && wrap.focused && wrap.caret === wrap.len),
    wrap && { pad: wrap.padStart, multi: wrap.multiline, dy: wrap.glyph && wrap.glyph.dy, len: wrap.len, focused: wrap.focused })
}

const server = await startServer()
const browser = await launch()
try {
  const warm = await open(browser, { width: 1440, height: 900 }, '/channel/alerts', MOCK)
  await warm.p.close()

  const desk = await open(browser, { width: 1440, height: 900 }, '/channel/alerts', MOCK)
  const base = await readBox(desk.p)
  ok('1440 the empty new topic has no glyph indent to compare against',
    Boolean(base && !base.glyph && !base.multiline), base && { pad: base.padStart, glyph: base.glyph })
  const basePad = base ? base.padStart : 0
  const opened = await openThread(desk.p)
  ok('1440 a thread shows the tree glyph', opened)
  await exercise(desk.p, '1440-top', basePad)
  ok('1440-top no page error', desk.errors.length === 0, desk.errors)
  await desk.p.close()

  const bottomSession = { ...MOCK, composer_position: 'bottom' }
  const bot = await open(browser, { width: 1440, height: 900 }, '/channel/alerts', bottomSession)
  const atBottom = await bot.p.waitForFunction(() => {
    const f = document.querySelector('form.composer.omnibox--global')
    return f && f.classList.contains('omnibox--bottom')
  }, { timeout: 15000 }).then(() => true, () => false)
  ok('1440-bottom the omnibox is the bottom dock', atBottom)
  const bBase = await readBox(bot.p)
  const openedB = await openThread(bot.p)
  ok('1440-bottom a thread shows the tree glyph', openedB)
  await exercise(bot.p, '1440-bottom', bBase ? bBase.padStart : 0)
  ok('1440-bottom no page error', bot.errors.length === 0, bot.errors)
  await bot.p.close()

  const phone = await open(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, '/channel/alerts', MOCK)
  await phone.p.waitForSelector('form.composer.omnibox--global[data-docked=true]', { timeout: 15000 }).catch(() => null)
  const pBase = await readBox(phone.p)
  ok('390 the dock is showing', Boolean(pBase && pBase.docked), pBase && { docked: pBase.docked })
  const card = await phone.p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const body = el.querySelector('.msg-body') || el
    const r = body.getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(24, r.width / 2)), y: Math.round(r.top + Math.min(12, r.height / 2)) }
  })
  if (card) await phone.p.touchscreen.tap(card.x, card.y)
  const phoneGlyph = await phone.p.waitForSelector('form.composer.omnibox--global [data-test=composer-mode-glyph]', { timeout: 15000 }).then(() => true, () => false)
  ok('390 a thread shows the tree glyph', phoneGlyph)
  await sleep(200)
  await exercise(phone.p, '390-dock', pBase ? pBase.padStart : 0)
  ok('390 no page error', phone.errors.length === 0, phone.errors)
  await phone.p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
