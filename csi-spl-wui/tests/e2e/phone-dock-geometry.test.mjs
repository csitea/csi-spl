// Owner, t1 842e581f (HUM-10): "on mobile, the OmniBox could be 2 mm bigger
// on the right, but the back arrow could be 1 mm on the right, and the other
// controls should stay in the same place."
//
// The phone dock (bottom and top places), at 390x844 and 360x740:
//   1 the omnibox field's right edge sits 42 px left of Attach's left edge
//     (it was 50: 2 mm ~ 8 px wider; its left edge is unchanged)
//   2 the Back arrow's glyph centre sits 20 px left of Attach's left edge
//     (it was 24: 1 mm ~ 4 px to the right); Back stays a 44 px tall target
//   3 Attach and Send keep their place: Send's right edge 16 px (bottom) or
//     8 px (top) from the viewport's right edge, Attach 2 px left of Send,
//     each 44 px, and Attach is the element on top at its own centre and at
//     its left edge (Back reaches 2 px under it)
//   4 the field's left edge stays 8 px from the viewport's left edge
// CONTROL: the old CSS fails 1 and 2 (50 and 24).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e phone-dock-geometry
//   SHOTS=<dir> ... also writes the 390x844 screenshots there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const TAP = 44
const POS_KEY = 'spool.omnibox-phone-pos'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const near = (a, b, tol = 0.5) => typeof a === 'number' && Math.abs(a - b) <= tol

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

/** Every box the owner's sentence names, in viewport px. */
const geometry = (p) => p.evaluate(() => {
  const f = document.querySelector('form.composer.composer--dock')
  if (!f) return null
  const box = (sel) => {
    const el = f.querySelector(sel)
    if (!el || !el.getClientRects().length) return null
    const r = el.getBoundingClientRect()
    return { left: r.left, right: r.right, top: r.top, w: r.width, h: r.height, cx: r.left + r.width / 2 }
  }
  /* who gets the tap: Attach at its centre and 1 px inside its left edge
     (Back reaches 2 px under it), Back at its arrow */
  const hit = (sel, x, y) => {
    const el = f.querySelector(sel)
    const h = document.elementFromPoint(x, y)
    return Boolean(el && h && el.contains(h))
  }
  const ar = f.querySelector('[data-testid=attach]')?.getBoundingClientRect()
  const gr = f.querySelector('.dock-back__glyph')?.getBoundingClientRect()
  const ay = ar ? ar.top + ar.height / 2 : 0
  return {
    attachHit: Boolean(ar) && hit('[data-testid=attach]', ar.left + ar.width / 2, ay)
      && hit('[data-testid=attach]', ar.left + 1, ay),
    backHit: Boolean(gr) && hit('[data-testid=dock-back]', gr.left + gr.width / 2, gr.top + gr.height / 2),
    vw: document.documentElement.clientWidth,
    pos: f.getAttribute('data-phone-pos'),
    field: box('.omnibox-field'),
    search: box('.search-syntax-btn'),
    back: box('[data-testid=dock-back]'),
    glyph: box('.dock-back__glyph'),
    attach: box('[data-testid=attach]'),
    send: box('.composer-go'),
  }
})

async function place(browser, width, height, pos) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  await p.setViewport({ width, height, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await p.evaluateOnNewDocument((k, v) => { try { localStorage.setItem(k, v) } catch { /* denied */ } }, POS_KEY, pos)
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-testid=dock-back]', { timeout: NAV_TIMEOUT }).catch(() => {})
  await sleep(600)
  const g = await geometry(p)
  const tag = `${width}x${height} ${pos}`
  if (process.env.MEASURE) console.log(`MEASURE ${tag} ${JSON.stringify(g)}`)
  const ready = Boolean(g && g.pos === pos && g.field && g.back && g.glyph && g.attach && g.send)
  ok(`${tag} 0 the dock is docked in that place with every control`, ready, g && { pos: g.pos })
  if (ready) {
    const a = g.attach.left
    ok(`${tag} 1 field right edge 42 px left of Attach (was 50)`, near(a - g.field.right, 42),
      { gap: a - g.field.right })
    ok(`${tag} 2 Back glyph centre 20 px left of Attach (was 24), 44 px tall`,
      near(a - g.glyph.cx, 20) && g.back.h >= TAP, { gap: a - g.glyph.cx, h: g.back.h })
    const edge = pos === 'top' ? 8 : 16
    ok(`${tag} 3 Send and Attach in place: Send ${edge} px from the right, Attach 2 px left of it, 44 px, on top`,
      near(g.vw - g.send.right, edge) && near(g.send.left - g.attach.right, 2)
        && g.attach.w >= TAP && g.send.w >= TAP && g.attachHit,
      { sendR: g.vw - g.send.right, gap: g.send.left - g.attach.right, aw: g.attach.w, sw: g.send.w, hit: g.attachHit })
    ok(`${tag} 4 field left edge in place, 8 px from the left`, near(g.field.left, 8), { left: g.field.left })
    ok(`${tag} 5 Back is a 44 px target from the field's edge, on top at its arrow`,
      g.back.left >= g.field.right - 0.5 && g.back.w >= TAP && g.backHit,
      { backL: g.back.left, fieldR: g.field.right, w: g.back.w, hit: g.backHit })
  }
  if (SHOTS && width === 390) await p.screenshot({ path: join(SHOTS, `phone-dock-geometry-${width}-${pos}.png`) })
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const [w, h] of [[390, 844], [360, 740]]) {
    for (const pos of ['bottom', 'top']) await place(browser, w, h, pos)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
