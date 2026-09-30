// CLE-77796 (owner HUM-10, prd t1 da0c0e98): "add on hover what each emoji
// represents ... some kind of simple text". Proved in a REAL browser (mock
// tenant): every glyph in the picker carries a short, plain name on both its
// title (the mouse hover) and its aria-label (the screen reader), the name is
// a word and not the glyph, and a long-press on touch reveals that name (there
// is no hover on a phone).
//
// Run:
//   node tests/e2e/emoji-names.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/emoji-names.test.mjs   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { EMOJI_CHOICES } from '../../src/utils/emoji.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PATH = '/lobby'

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function openPicker(page, touch) {
  await page.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const sel = 'article.msg[data-msg-id] [data-testid=msg-emoji-btn]'
  await page.waitForSelector(sel, { timeout: NAV_TIMEOUT })
  await sleep(300)
  if (touch) await page.tap(sel).catch(() => {})
  else await page.click(sel).catch(() => {})
  await page.waitForSelector('[data-testid=emoji-picker] .emoji-picker__glyph', { timeout: NAV_TIMEOUT })
  await sleep(300)
}

const server = await startServer()
const browser = await launch()
try {
  /* desktop: the title and aria-label name every glyph */
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await openPicker(p, false)

  const glyphs = await p.evaluate(() => [...document.querySelectorAll('[data-testid=emoji-picker] .emoji-picker__glyph')]
    .map((b) => ({ emoji: b.getAttribute('data-emoji'), title: b.getAttribute('title'), aria: b.getAttribute('aria-label') })))

  ok('every glyph is present', glyphs.length === EMOJI_CHOICES.length, { n: glyphs.length })
  const noTitle = glyphs.filter((g) => !g.title || !g.title.trim())
  ok('every glyph has a non-empty title', noTitle.length === 0, noTitle.map((g) => g.emoji))
  const mismatch = glyphs.filter((g) => g.title !== g.aria)
  ok('title and aria-label carry the same name', mismatch.length === 0, mismatch.slice(0, 5))
  const glyphAsName = glyphs.filter((g) => g.title === g.emoji)
  ok('the name is a word, never the glyph itself', glyphAsName.length === 0, glyphAsName.map((g) => g.emoji))
  const check = glyphs.find((g) => g.emoji === '✅')
  const fire = glyphs.find((g) => g.emoji === '🔥')
  ok('✅ is named "Done", 🔥 is named "Fire" (en)', check?.title === 'Done' && fire?.title === 'Fire', { check: check?.title, fire: fire?.title })

  /* long-press on touch reveals the name (no hover on a phone) */
  const held = await p.evaluate(async () => {
    const btn = [...document.querySelectorAll('[data-testid=emoji-picker] .emoji-picker__glyph')].find((b) => b.getAttribute('data-emoji') === '✅')
    if (!btn) return { err: 'no ✅ button' }
    btn.dispatchEvent(new Event('touchstart', { bubbles: true }))
    await new Promise((r) => setTimeout(r, 450))
    const el = document.querySelector('[data-testid=emoji-name]')
    const text = el ? el.textContent.trim() : ''
    btn.dispatchEvent(new Event('touchend', { bubbles: true }))
    return { text }
  })
  ok('a long-press shows the glyph name ("Done")', held.text === 'Done', held)
  ok('no page error', errors.length === 0, errors)
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
