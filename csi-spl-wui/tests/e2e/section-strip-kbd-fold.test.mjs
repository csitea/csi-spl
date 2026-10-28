// SPL-3785 slice 3 (csi-spl-doc/specs/043-spool-wui-mobile, the
// strip behaviour doc, section 5): on a phone the section strip is on
// top at levels 2 and 3, and it folds away while the on-screen keyboard is
// up, so the field and the composer keep the room.
//
// At 390 px dark and 360 px light, on a channel (level 2) and a topic
// (level 3): the strip is painted; focus the composer and shrink the visual
// viewport by a keyboard (as tests/e2e/kb-inset.test.mjs does): the shell
// says data-mobile-kbd="1" and the strip is not painted; close the keyboard
// and blur: the strip is painted again at the same y.
// The Android shape (owner, t1 c3e53990 msg d4459f4c): the viewport meta's
// interactive-widget=resizes-content makes Android Chrome shrink the whole
// window for the keyboard (innerHeight AND visualViewport.height drop
// together), done here by resizing the page's viewport after the focus.
//
//   BASE_URL=<generated mock bundle> node tests/e2e/section-strip-kbd-fold.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const KB = 300
const TOPIC = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* the strip painted (shown AND topmost at its centre), its top, the shell's flags */
const read = (p) => p.evaluate(() => {
  const strip = document.querySelector('[data-testid=sidebar-rail]')
  const shell = document.querySelector('.spool-shell')
  let painted = false
  let top = null
  if (strip) {
    const r = strip.getBoundingClientRect()
    const cs = getComputedStyle(strip)
    if (cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0) {
      const hit = document.elementFromPoint(Math.min(r.left + r.width / 2, innerWidth - 1), r.top + r.height / 2)
      painted = Boolean(hit) && (strip.contains(hit) || hit.contains(strip))
      top = Math.round(r.top)
    }
  }
  return { level: shell?.getAttribute('data-mobile-level'), kbd: shell?.getAttribute('data-mobile-kbd') ?? null, painted, top }
})

/* a keyboard: the visual viewport KB px shorter (open) or the real one (close) */
const keyboard = (p, open) => p.evaluate(async (kb, open) => {
  const proto = Object.getPrototypeOf(window.visualViewport)
  if (open) {
    window.__realVvHeight ??= Object.getOwnPropertyDescriptor(proto, 'height')
    Object.defineProperty(proto, 'height', { configurable: true, get() { return window.innerHeight - kb } })
  } else if (window.__realVvHeight) {
    Object.defineProperty(proto, 'height', window.__realVvHeight)
  }
  window.visualViewport.dispatchEvent(new Event('resize'))
  for (let i = 0; i < 3; i++) await new Promise((r) => requestAnimationFrame(r))
}, KB, open)

/* the Android keyboard: the whole window KB px shorter (open) or back (close) */
async function androidKeyboard(p, width, open) {
  await p.setViewport({ width, height: open ? 844 - KB : 844, isMobile: true, hasTouch: true })
  await p.evaluate(async () => { for (let i = 0; i < 3; i++) await new Promise((r) => requestAnimationFrame(r)) })
}

const focusComposer = (p, on) => p.evaluate((on) => {
  const ta = [...document.querySelectorAll('.composer textarea')].filter((e) => e.getClientRects().length).pop()
  if (!ta) return false
  if (on) ta.focus(); else ta.blur()
  return true
}, on)

const srv = await startServer()
const browser = await launch()
try {
  for (const [width, scheme] of [[390, 'dark'], [360, 'light']]) {
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }])
    await p.evaluateOnNewDocument(() => localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })))
    await p.setViewport({ width, height: 844, isMobile: true, hasTouch: true })
    for (const [what, route] of [['a channel', '/channel/lobby'], ['a topic', `/channel/lobby?topic=${TOPIC}`]]) {
      const tag = `${width}px ${scheme} ${what}`
      await p.goto(`${srv.base}${route}`, { waitUntil: 'networkidle2' })
      await p.waitForSelector('[data-testid=sidebar-rail]', { visible: true, timeout: 15000 }).catch(() => null)
      await p.waitForSelector('.composer textarea', { visible: true, timeout: 15000 }).catch(() => null)
      const before = await read(p)
      ok(`${tag}: the strip is painted before the keyboard (level ${before.level})`, before.painted && before.kbd === null, before)
      const focused = await focusComposer(p, true)
      await keyboard(p, true)
      const up = await read(p)
      ok(`${tag}: composer focused, keyboard up: the strip folds (data-mobile-kbd=1, not painted)`, focused && up.kbd === '1' && !up.painted, { focused, ...up })
      await keyboard(p, false)
      await focusComposer(p, false)
      const down = await read(p)
      ok(`${tag}: keyboard down: the strip is back at the same y`, down.painted && down.kbd === null && down.top === before.top, { before: before.top, ...down })
      /* Android: the window itself KB px shorter while the composer has the focus */
      const aFocused = await focusComposer(p, true)
      await androidKeyboard(p, width, true)
      const aUp = await read(p)
      ok(`${tag}: Android (window ${KB}px shorter), composer focused: the strip folds (data-mobile-kbd=1, not painted)`, aFocused && aUp.kbd === '1' && !aUp.painted, { focused: aFocused, ...aUp })
      await androidKeyboard(p, width, false)
      const aBack = await read(p)
      ok(`${tag}: Android keyboard down (field still focused, Back): the strip is back at the same y`, aBack.painted && aBack.kbd === null && aBack.top === before.top, { before: before.top, ...aBack })
      await focusComposer(p, false)
    }
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nsection-strip-kbd-fold: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length || !results.length ? 1 : 0)
