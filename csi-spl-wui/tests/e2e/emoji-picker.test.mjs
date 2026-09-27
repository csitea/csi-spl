// SPL-1002 (owner, prd t1 topic 9c10b31f): "The angry emoji is displayed
// twice - there seem to be other emoji's which are twice in the emoji picker"
// and "there are 2 empty emoji places ... remove the duplicates and add 4".
// Proved in a REAL browser, with a remembered 'recent' list seeded first
// (the duplicates were the recent glyphs shown a second time):
//
//   360x740 and 820x1180 (touch, the bottom sheet), 1440x900 (mouse, popover):
//     1 every glyph in the picker is shown ONCE (the recent ones included)
//     2 the picker offers every EMOJI_CHOICES glyph, and nothing else
//     3 the grid ends full: no empty cell in its last row
//     4 every glyph draws ink with the page's own font (no blank cell)
//     5 1440 px: the popover keeps its 8 columns and shows every row
//
// Run:
//   pnpm run test:e2e:emoji-picker
//   BASE_URL=<generated bundle> pnpm run test:e2e:emoji-picker   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per viewport there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { EMOJI_CHOICES } from '../../src/utils/emoji.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/lobby'
const RECENT = ['😡', '👍', '🔥']

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

function pickerFacts(page) {
  return page.evaluate(() => {
    const el = document.querySelector('[data-testid=emoji-picker]')
    if (!el) return null
    const glyphs = [...el.querySelectorAll('.emoji-picker__glyph')]
    const shown = glyphs.map((b) => b.getAttribute('data-emoji') || '')
    const grids = [...el.querySelectorAll('.emoji-picker__grid')].map((g) => {
      const cols = getComputedStyle(g).gridTemplateColumns.split(' ').filter(Boolean).length
      const n = g.querySelectorAll('.emoji-picker__glyph').length
      return { id: g.getAttribute('data-testid'), cols, n, empty: cols ? (cols - (n % cols)) % cols : -1 }
    })
    /* ink: draw each glyph with the button's own font; a blank cell draws nothing */
    const cv = document.createElement('canvas')
    cv.width = 64
    cv.height = 64
    const cx = cv.getContext('2d', { willReadFrequently: true })
    const blank = []
    for (const b of glyphs) {
      const cs = getComputedStyle(b)
      cx.clearRect(0, 0, 64, 64)
      cx.font = `32px ${cs.fontFamily}`
      cx.textBaseline = 'middle'
      cx.fillStyle = '#000'
      cx.fillText(b.textContent || '', 8, 32)
      const d = cx.getImageData(0, 0, 64, 64).data
      let ink = 0
      for (let i = 3; i < d.length; i += 4) if (d[i]) ink++
      if (ink < 20) blank.push(b.getAttribute('data-emoji'))
    }
    const r = el.getBoundingClientRect()
    return {
      sheet: el.classList.contains('touch-sheet'),
      shown,
      grids,
      blank,
      w: Math.round(r.width),
      h: Math.round(r.height),
      scrollH: el.scrollHeight,
      clientH: el.clientHeight,
    }
  })
}

async function openPicker(page, touch) {
  await page.evaluateOnNewDocument((list) => {
    try { localStorage.setItem('spool.emoji-recent', JSON.stringify(list)) } catch { /* private */ }
  }, RECENT)
  await page.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const sel = 'article.msg[data-msg-id] [data-testid=msg-emoji-btn]'
  await page.waitForSelector(sel, { timeout: NAV_TIMEOUT })
  await sleep(300)
  if (touch) await page.tap(sel).catch(() => {})
  else await page.click(sel).catch(() => {})
  await sleep(400)
  return pickerFacts(page)
}

function check(tag, f) {
  const seen = new Map()
  for (const e of (f ? f.shown : [])) seen.set(e, (seen.get(e) || 0) + 1)
  const twice = [...seen].filter(([, n]) => n > 1).map(([e]) => e)
  ok(`${tag} 1 every glyph is shown once (recent ${RECENT.join(' ')} seeded)`, Boolean(f) && twice.length === 0, { twice, n: f && f.shown.length })
  const want = new Set(EMOJI_CHOICES)
  const got = new Set(f ? f.shown : [])
  const missing = EMOJI_CHOICES.filter((e) => !got.has(e))
  const extra = [...got].filter((e) => !want.has(e))
  ok(`${tag} 2 the picker offers every choice (${EMOJI_CHOICES.length}) and nothing else`, Boolean(f) && !missing.length && !extra.length, { missing, extra })
  const holes = f ? f.grids.filter((g) => g.empty !== 0) : []
  ok(`${tag} 3 the grid ends full, no empty cell`, Boolean(f) && f.grids.length > 0 && holes.length === 0, f && f.grids)
  ok(`${tag} 4 every glyph draws ink`, Boolean(f) && f.blank.length === 0, f && f.blank)
}

async function phone(browser, width, height) {
  const tag = `${width}px`
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width, height, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  const f = await openPicker(p, true)
  ok(`${tag} 0 Add emoji opens the picker as a bottom sheet`, Boolean(f && f.sheet), f && { w: f.w, h: f.h })
  check(tag, f)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `emoji-picker-${width}.png`) })
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

async function desktop(browser) {
  const tag = '1440px'
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  const f = await openPicker(p, false)
  ok(`${tag} 0 Add emoji opens the popover (not a sheet)`, Boolean(f && !f.sheet), f && { w: f.w, h: f.h })
  check(tag, f)
  ok(`${tag} 5 the popover keeps 8 columns and shows every row without scrolling`,
    Boolean(f && f.grids.every((g) => g.cols === 8) && f.scrollH <= f.clientH + 1), f && { grids: f.grids, scrollH: f.scrollH, clientH: f.clientH })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'emoji-picker-1440.png') })
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
