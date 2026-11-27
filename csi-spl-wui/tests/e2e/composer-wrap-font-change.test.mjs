// p19-02 (SPL-6654), R7 a-560 W1 + W2: the top-bar draft's one-line width is
// measured with a cached canvas font (useComposerWrap.ts useDraftMeter). A
// font change with no focus, chip, glyph, dock or viewport change must still
// re-judge the wrap (owner, t1 26282b6e: more than one line lifts the glyph
// onto a row above the text):
//
//   1440 top bar, a thread open, the field focused:
//     W1 a code fence typed after a word (`.in-code`: monospace) makes a draft
//        that fit in the sans font wider than the room: the field is
//        multi-line at once, the same answer a blur and a refocus give (the
//        word goes first: the first key brings the target chip, whose own
//        re-judge reads the font afresh and would hide a stale cache)
//   390 phone dock, a thread open (no target chip, owner msg b2e7c197):
//     W2 the font-size setting 3 -> 5 (html data-font-size) while focused: a
//        draft that fit at 3 and does not at 5 is multi-line at once
//
// Each draft is sized in the page from the field's own fonts and room, so it
// is a real wrap in one font and none in the other; the blur + refocus answer
// is the oracle, and it must be multi-line too or the case proves nothing.
//
// Run:
//   pnpm run test:e2e composer-wrap-font-change
//   BASE_URL=<generated bundle> pnpm run test:e2e composer-wrap-font-change
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const MOCK = { hum: 'HUM-1', name: 'Member', email: 'member@example.com', t: 'mock' }
const BOX = 'form.composer.omnibox--global'

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

async function open(browser, vp) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((s) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify(s))
      localStorage.removeItem('spool.drafts')
    } catch { /* private mode */ }
  }, MOCK)
  await p.setViewport(vp)
  await p.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`${BOX} textarea`, { timeout: NAV_TIMEOUT })
  return { p, errors }
}

async function openThread(p, touch) {
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  const card = await p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const r = (el.querySelector('.msg-body') || el).getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(24, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) }
  })
  if (!card) return false
  if (touch) await p.touchscreen.tap(card.x, card.y)
  else await p.mouse.click(card.x, card.y)
  const shown = await p.waitForSelector(`${BOX} [data-test=composer-mode-glyph]`, { timeout: 15000 }).then(() => true, () => false)
  await sleep(200)
  return shown
}

async function focusBox(p) {
  for (let i = 0; i < 5; i++) {
    await p.click(`${BOX} textarea`)
    const held = await p.waitForFunction((sel) => document.activeElement === document.querySelector(sel), { timeout: 2000 }, `${BOX} textarea`)
      .then(() => true, () => false)
    if (held) { await sleep(150); return true }
  }
  return false
}

/** The field's font and one-line room now, and whether it is focused and multi-line. */
function readField(p) {
  return p.evaluate((sel) => {
    const f = document.querySelector(sel)
    const ta = f && f.querySelector('textarea')
    if (!ta) return null
    const cs = getComputedStyle(ta)
    return {
      font: `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`,
      room: ta.clientWidth - (parseFloat(cs.paddingInlineStart) || 0) - (parseFloat(cs.paddingInlineEnd) || 0),
      inCode: ta.classList.contains('in-code'),
      multi: f.querySelector('.omnibox-field')?.getAttribute('data-multiline') === 'true',
      focused: document.activeElement === ta,
      value: ta.value,
    }
  }, BOX)
}

/** The shortest `prefix + ch * n` wider than the room in font `wide` and narrower than it in font `narrow`. */
function sizeDraft(p, prefix, ch, narrow, wide) {
  return p.evaluate((prefix, ch, narrow, wide) => {
    const ctx = document.createElement('canvas').getContext('2d')
    const w = (font, s) => { ctx.font = font; return ctx.measureText(s).width }
    for (let n = 1; n < 400; n++) {
      const s = prefix + ch.repeat(n)
      if (w(wide.font, s) > wide.room + 8) return w(narrow.font, s) < narrow.room - 8 ? s : null
    }
    return null
  }, prefix, ch, narrow, wide)
}

/** The answer a blur and a refocus give: the font is read afresh. */
async function oracle(p) {
  await p.evaluate((sel) => document.querySelector(sel).blur(), `${BOX} textarea`)
  await sleep(150)
  await p.evaluate((sel) => document.querySelector(sel).focus(), `${BOX} textarea`)
  await sleep(250)
  return readField(p)
}

const server = await startServer()
const browser = await launch()
try {
  const warm = await open(browser, { width: 1440, height: 900 })
  await warm.p.close()

  // W1: 1440, `.in-code` toggled by typing while focused
  const desk = await open(browser, { width: 1440, height: 900 })
  ok('1440 a thread shows the tree glyph', await openThread(desk.p, false))
  ok('1440 the field holds the focus', await focusBox(desk.p))
  /* the word first: its first key brings the target chip and that chip's own
     re-judge; the draft is sized in the room the chip leaves */
  const word = 'note '
  await desk.p.keyboard.type(word)
  await sleep(300)
  const sans = await readField(desk.p)
  ok('1440 W1 the word alone is one line, not in code', Boolean(sans && !sans.multi && !sans.inCode && sans.value === word), sans)
  /* the mono font as `.in-code` gives it; the class is put back at once */
  const mono = await desk.p.evaluate((sel) => {
    const ta = document.querySelector(sel)
    ta.classList.add('in-code')
    const cs = getComputedStyle(ta)
    const out = { font: `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`, room: ta.clientWidth - (parseFloat(cs.paddingInlineStart) || 0) - (parseFloat(cs.paddingInlineEnd) || 0) }
    ta.classList.remove('in-code')
    return out
  }, `${BOX} textarea`)
  await sleep(200)
  const code = sans && await sizeDraft(desk.p, word + '```', 'i', sans, mono)
  ok('1440 W1 a draft that fits in sans and wraps in mono exists', Boolean(code), { sans, mono, len: code && code.length })
  if (code) {
    await desk.p.keyboard.type(code.slice(word.length))
    await sleep(300)
    const typed = await readField(desk.p)
    const truth = await oracle(desk.p)
    ok('1440 W1 the oracle (blur + refocus) is multi-line, in code', Boolean(truth && truth.multi && truth.inCode && truth.value === code), truth)
    ok('1440 W1 typing the fence re-judges at once: multi-line while still focused',
      Boolean(typed && typed.inCode && typed.focused && typed.multi), typed)
  }
  ok('1440 no page error', desk.errors.length === 0, desk.errors)
  await desk.p.close()

  // W2: 390 dock, the font-size setting 3 -> 5 while focused
  const phone = await open(browser, { width: 390, height: 844, isMobile: true, hasTouch: true })
  await phone.p.waitForSelector(`${BOX}[data-docked=true]`, { timeout: 15000 }).catch(() => null)
  ok('390 a thread shows the tree glyph', await openThread(phone.p, true))
  const setSize = (n) => phone.p.evaluate((n) => document.documentElement.setAttribute('data-font-size', String(n)), n)
  await setSize(3)
  await sleep(200)
  ok('390 the field holds the focus', await focusBox(phone.p))
  const at3 = await readField(phone.p)
  await setSize(5)
  await sleep(200)
  const at5 = await readField(phone.p)
  await setSize(3)
  await sleep(200)
  const big = at3 && at5 && await sizeDraft(phone.p, '', 'm', at3, at5)
  ok('390 W2 a draft that fits at size 3 and wraps at size 5 exists', Boolean(big), { at3, at5, len: big && big.length })
  if (big) {
    await phone.p.keyboard.type(big)
    await sleep(300)
    const before = await readField(phone.p)
    ok('390 W2 at size 3 the draft is one line', Boolean(before && !before.multi && before.value === big), before)
    await setSize(5)
    await sleep(300)
    const after = await readField(phone.p)
    const truth = await oracle(phone.p)
    ok('390 W2 the oracle (blur + refocus) is multi-line at size 5', Boolean(truth && truth.multi), truth)
    ok('390 W2 the size change re-judges at once: multi-line while still focused',
      Boolean(after && after.focused && after.multi), after)
  }
  ok('390 no page error', phone.errors.length === 0, phone.errors)
  await phone.p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
