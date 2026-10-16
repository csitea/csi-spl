// SPL-2062 (owner HUM-10, t1 508e17a0 msg ae4f7ceb): "only a whole icon will
// be scrolled at a time ... there will never be a half or non-whole icon on
// the top bar". Plus the tap animations (t1 508e17a0 msg afe08df1 and t1
// 8adfb7f2 msg 6c4ca93d): each section icon and each phone dock button plays
// a short movement when pressed, one shared set, none under reduced motion.
//
//   phone 360x800, 390x844, 412x915 (hasTouch):
//     1 at rest, and at every snap position stepping one control at a time
//       through a whole loop of the strip: every control is fully inside the
//       strip's box or fully outside it (1 px tolerance), each >= 44 px wide,
//       and the whole ones fill the strip
//     2 a free finger swipe that stops between two controls settles on a
//       whole control
//   resize: 412 -> 360 and 390 -> 844x390 -> 390 (a turn of the phone): the
//     widths are recomputed and check 1 holds again; 844x390 is the desktop
//     rail, where the same check holds
//   3 390: each section of the strip, tapped, puts its animation class on
//     its icon and takes it off within 600 ms; no control box or the strip's
//     height changes while it plays
//   4 390: the dock's Send (sends), Attach (opens the picker), Search (enters
//     search mode) and Back (goes back) each animate within 600 ms
//   5 reduced motion: a tap puts no animation class anywhere
//   6 1440 CONTROL: desktop rail has no data-fit and no scroll snap; a tap
//     still animates its icon
//
// Run:
//   pnpm run test:e2e mobile-rail-whole-icons
//   BASE_URL=<generated bundle> pnpm run test:e2e mobile-rail-whole-icons   # what CI does
//   SHOTS=<dir> ... also writes 390 px screenshots (at rest, after a swipe)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const TAP = 44
const ANIM_MAX = 600
const STRIP = '[data-testid=sidebar-rail]'
const FORM = 'form.composer.omnibox--global'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const settle = (p) => p.waitForNetworkIdle({ idleTime: 400, timeout: 15000 }).catch(() => {})

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

async function until(read, want, max = 8000) {
  const end = Date.now() + max
  let s = await read()
  while (!want(s) && Date.now() < end) {
    await sleep(100)
    s = await read()
  }
  return s
}

/* every class change that adds or removes tap-anim, with its time and owner */
function trackTaps() {
  window.__taps = []
  const had = new WeakMap()
  new MutationObserver((list) => {
    for (const m of list) {
      const el = m.target
      if (!(el instanceof Element)) continue
      const on = el.classList.contains('tap-anim')
      if ((had.get(el) || false) === on) continue
      had.set(el, on)
      const owner = el.closest('[data-reorder-id],[data-testid],[data-test]')
      window.__taps.push({
        key: owner ? (owner.getAttribute('data-reorder-id') || owner.getAttribute('data-testid') || owner.getAttribute('data-test')) : '',
        loop: Boolean(el.closest('[data-loop]')),
        on,
        kind: [...el.classList].find((c) => c.startsWith('tap-anim--')) || '',
        t: performance.now(),
      })
    }
  }).observe(document, { attributes: true, subtree: true, attributeFilter: ['class'] })
}

async function newPage(browser, vp, { reduced = false } = {}) {
  const p = await browser.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
  p.__errors = errors
  if (reduced) await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  /* about:blank has no storage: only the app's own documents get the session */
  await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
  await p.evaluateOnNewDocument(trackTaps)
  await p.setViewport(vp)
  return p
}

async function home(p, base) {
  await p.goto(`${base}/`, { waitUntil: 'networkidle2' })
  await p.waitForSelector(STRIP, { visible: true })
  await until(() => p.$eval(STRIP, (e) => getComputedStyle(e).visibility), (v) => v === 'visible')
  await sleep(600)
}

/* the strip at rest: wait until scrollLeft holds still (a snap has landed) */
const rest = (p) => until(async () => {
  const a = await p.$eval(STRIP, (e) => e.scrollLeft)
  await sleep(120)
  const b = await p.$eval(STRIP, (e) => e.scrollLeft)
  return a === b
}, (v) => v, 4000)

/* every control of the strip (the real ones and the endless strip's copies):
   is any of them cut by the strip's edge */
const cuts = (p) => p.$eval(STRIP, (strip) => {
  const b = strip.getBoundingClientRect()
  const els = [...strip.querySelectorAll(':scope > .sidebar-rail__tabs > *, :scope > a, :scope > button, :scope > [data-loop] > *')]
  const cut = []
  const whole = []
  for (const e of els) {
    const r = e.getBoundingClientRect()
    if (r.width === 0) continue
    const inside = r.left >= b.left - 1 && r.right <= b.right + 1
    const outside = r.right <= b.left + 1 || r.left >= b.right - 1
    if (inside) whole.push(r)
    if (!inside && !outside) cut.push({ id: e.getAttribute('data-reorder-id') || e.getAttribute('data-testid') || e.className, l: Math.round(r.left - b.left), r: Math.round(r.right - b.left) })
  }
  /* the slot each whole control holds: its box plus its margins */
  const slots = whole.length ? Math.max(...whole.map((r) => r.right)) - Math.min(...whole.map((r) => r.left)) : 0
  const real = [...strip.querySelectorAll(':scope > .sidebar-rail__tabs > *, :scope > a, :scope > button')]
  const minW = Math.min(...real.map((e) => e.getBoundingClientRect().width + parseFloat(getComputedStyle(e).marginLeft) * 2))
  return {
    view: Math.round(b.width),
    sl: Math.round(strip.scrollLeft),
    fit: strip.getAttribute('data-fit'),
    whole: whole.length,
    span: Math.round(slots),
    minW: Math.round(minW),
    cut,
  }
})

const isPhone = (vp) => vp.width <= 820

/** 1 + 2 at one viewport */
async function wholeAt(p, label, vp) {
  await rest(p)
  const at = await cuts(p)
  const fills = !isPhone(vp) || Math.abs(at.span - at.view) <= 2
  ok(`${label} 1 at rest: no control cut at either edge, each >= ${TAP} px, the whole ones fill the strip`, at.cut.length === 0 && (!isPhone(vp) || at.minW >= TAP) && fills, at)
  if (!isPhone(vp)) return
  /* one control's step, then a whole loop of the strip and a bit more */
  const step = await p.$eval(STRIP, (s) => {
    const [a, b] = s.querySelectorAll(':scope > .sidebar-rail__tabs > *')
    return b.getBoundingClientRect().left - a.getBoundingClientRect().left
  })
  const n = await p.$eval(STRIP, (s) => s.querySelectorAll(':scope > .sidebar-rail__tabs > *, :scope > a, :scope > button').length)
  const bad = []
  for (let i = 0; i < n + 2; i++) {
    await p.$eval(STRIP, (s, d) => s.scrollBy({ left: d, behavior: 'instant' }), step)
    await rest(p)
    const c = await cuts(p)
    if (c.cut.length) bad.push({ i, ...c })
  }
  ok(`${label} 1 stepping one control at a time (${n + 2} steps of ${Math.round(step)} px): never a cut control`, bad.length === 0, bad.slice(0, 3))
  /* 2: a free swipe that stops part-way between two controls */
  const b = await p.$eval(STRIP, (s) => { const r = s.getBoundingClientRect(); return { x: r.left + r.width * 0.7, y: r.top + r.height / 2 } })
  await p.touchscreen.touchStart(b.x, b.y)
  const dx = Math.round(step * 1.4)
  for (let i = 1; i <= 12; i++) { await p.touchscreen.touchMove(b.x - (dx * i) / 12, b.y); await sleep(16) }
  await p.touchscreen.touchEnd()
  await sleep(300)
  await rest(p)
  const sw = await cuts(p)
  ok(`${label} 2 a free swipe of ${dx} px settles on a whole control`, sw.cut.length === 0, sw)
}

/** 3: each section of the strip animates its icon, and nothing moves */
async function railTaps(p) {
  const ids = await p.$$eval(`${STRIP} > .sidebar-rail__tabs > [data-reorder-id]`, (els) => els.map((e) => e.getAttribute('data-reorder-id')))
  const want = { channels: 'bubble', dm: 'bubble', issues: 'pop', calendar: 'flip', monitoring: 'pulse', archive: 'lift' }
  const bad = []
  const moved = []
  for (const id of ids) {
    const t0 = await p.evaluate((id) => {
      window.__taps = []
      const t = performance.now()
      document.querySelector(`[data-testid=sidebar-rail] > .sidebar-rail__tabs > [data-reorder-id="${id}"]`).click()
      return t
    }, id)
    await sleep(120)
    const boxes = () => p.$eval(STRIP, (s) => ({
      h: Math.round(s.getBoundingClientRect().height * 10) / 10,
      items: [...s.querySelectorAll(':scope > .sidebar-rail__tabs > *')].map((e) => {
        const r = e.getBoundingClientRect()
        return [Math.round((r.left - s.getBoundingClientRect().left + s.scrollLeft) * 10) / 10, Math.round(r.width * 10) / 10, Math.round(r.height * 10) / 10]
      }),
    }))
    const during = await boxes()
    await sleep(ANIM_MAX)
    const after = await boxes()
    const taps = (await p.evaluate(() => window.__taps)).filter((x) => x.key === id && !x.loop)
    const on = taps.find((x) => x.on)
    const off = taps.find((x) => !x.on)
    const kind = 'tap-anim--' + (want[id] || 'bounce')
    if (!on || !off || on.kind !== kind || on.t - t0 > 100 || off.t - t0 > ANIM_MAX) bad.push({ id, kind, taps: taps.map((x) => ({ on: x.on, kind: x.kind, ms: Math.round(x.t - t0) })) })
    if (JSON.stringify(during) !== JSON.stringify(after)) moved.push({ id, during, after })
    await settle(p)
    await home(p, p.__base)
  }
  ok(`390 3 each of the ${ids.length} sections animates its icon on a tap and stops within ${ANIM_MAX} ms (bubble, pop, flip, pulse, lift, bounce)`, ids.length >= 5 && bad.length === 0, bad.length ? bad : ids)
  ok('390 3 no control box and not the strip height change while it plays', moved.length === 0, moved.slice(0, 2))
}

/* t0 is the press: an act that does slow work first (Send types its line)
   calls mark() right before its click, so typing time never counts against
   the ANIM_MAX window (SPL-2062 c81086c16: t0 before the typing failed the
   nudge on a loaded box, the nudge itself ~400 ms) */
const dockAnim = async (p, testSel, kind, act) => {
  let t0 = await p.evaluate(() => { window.__taps = []; return performance.now() })
  const mark = async () => { t0 = await p.evaluate(() => performance.now()) }
  const done = await act(mark)
  await sleep(ANIM_MAX + 100)
  const taps = (await p.evaluate(() => window.__taps)).filter((x) => x.key === testSel)
  const on = taps.find((x) => x.on)
  const off = taps.find((x) => !x.on)
  return { anim: Boolean(on && off && on.kind === 'tap-anim--' + kind && off.t - t0 <= ANIM_MAX + 200 && off.t - on.t <= ANIM_MAX), done, taps: taps.map((x) => ({ on: x.on, kind: x.kind, ms: Math.round(x.t - t0) })) }
}

/** 4: the phone dock's four buttons, in a channel (at / with no target a
   Send turns the text into a /search, and the button into Search's GO) */
async function dockTaps(p, base) {
  await home(p, base)
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await p.waitForSelector('#sidebar-panel-channels .nav-item', { visible: true, timeout: 5000 }).catch(() => {})
  await p.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
  const level = () => p.evaluate(() => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level'))
  await until(level, (v) => v === '2')
  await p.waitForSelector(`${FORM} [data-testid=send]`, { visible: true })
  await settle(p)
  const attach = await dockAnim(p, 'attach', 'wiggle', async () => {
    const [chooser] = await Promise.all([p.waitForFileChooser({ timeout: 4000 }).catch(() => null), p.click(`${FORM} [data-testid=attach]`)])
    if (chooser) await chooser.cancel().catch(() => {})
    return Boolean(chooser)
  })
  ok('390 4 Attach: a wiggle, and it still opens the picker', attach.anim && attach.done, attach)
  const line = 'SPL-2062 dock send ' + Date.now()
  const send = await dockAnim(p, 'send', 'nudge', async (mark) => {
    await p.focus(`${FORM} textarea`)
    await p.keyboard.type(line)
    await mark()
    await p.click(`${FORM} [data-testid=send]`)
    const cleared = await until(() => p.$eval(`${FORM} textarea`, (t) => t.value), (v) => v === '', 4000)
    const posted = await until(() => p.evaluate((line) => [...document.querySelectorAll('article.msg')].some((a) => a.textContent.includes(line)), line), (v) => v, 4000)
    return cleared === '' && posted
  })
  ok('390 4 Send: a nudge forward, and it still sends (the box clears, the post shows)', send.anim && send.done, send)
  const search = await dockAnim(p, 'search-syntax-help', 'tilt', async () => {
    await p.click(`${FORM} [data-test=search-syntax-help]`)
    return until(() => p.$eval(`${FORM} [data-test=search-syntax-help]`, (b) => b.getAttribute('aria-pressed')), (v) => v === 'true', 3000).then((v) => v === 'true')
  })
  ok('390 4 Search: the magnifier tilts, and it still enters search mode', search.anim && search.done, search)
  await until(() => p.$eval('[data-testid=dock-back]', (b) => b.disabled), (v) => v === false, 4000)
  const back = await dockAnim(p, 'dock-back', 'hop', async () => {
    await p.click('[data-testid=dock-back]')
    return until(level, (v) => v === '1', 4000).then((v) => v === '1')
  })
  ok('390 4 Back: a short hop left, and it still goes back (level 2 -> 1)', back.anim && back.done, back)
}

const srv = await startServer()
const browser = await launch()
try {
  for (const vp of [{ width: 360, height: 800 }, { width: 390, height: 844 }, { width: 412, height: 915 }]) {
    const p = await newPage(browser, { ...vp, isMobile: true, hasTouch: true })
    p.__base = srv.base
    await home(p, srv.base)
    if (SHOTS && vp.width === 390) await p.screenshot({ path: join(SHOTS, 'mobile-rail-390-rest.png') })
    await wholeAt(p, `${vp.width}x${vp.height}`, vp)
    if (SHOTS && vp.width === 390) await p.screenshot({ path: join(SHOTS, 'mobile-rail-390-after-swipe.png') })
    if (vp.width === 412) {
      await p.setViewport({ width: 360, height: 800, isMobile: true, hasTouch: true })
      await sleep(500)
      await wholeAt(p, 'resize 412 -> 360', { width: 360 })
    }
    if (vp.width === 390) {
      await p.setViewport({ width: 844, height: 390, isMobile: true, hasTouch: true })
      await sleep(600)
      await wholeAt(p, 'turned 844x390', { width: 844 })
      await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
      await sleep(600)
      await wholeAt(p, 'turned back 390x844', { width: 390 })
      await home(p, srv.base)
      await railTaps(p)
      await dockTaps(p, srv.base)
    }
    ok(`${vp.width} no page error`, p.__errors.length === 0, p.__errors)
    await p.close()
  }

  /* 5: reduced motion - a tap animates nothing */
  const r = await newPage(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, { reduced: true })
  await home(r, srv.base)
  await r.evaluate(() => { window.__taps = []; document.querySelector('[data-testid=sidebar-tab-issues]').click() })
  await sleep(ANIM_MAX)
  await home(r, srv.base)
  await r.evaluate(() => { window.__taps = [] })
  await r.click(`${FORM} [data-test=search-syntax-help]`)
  await sleep(ANIM_MAX)
  const still = await r.evaluate(() => window.__taps)
  ok('390 5 reduced motion: no animation class on a rail or dock tap', still.length === 0, still)
  await r.close()

  /* 6: desktop CONTROL */
  const d = await newPage(browser, { width: 1440, height: 900 })
  await d.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
  await d.waitForSelector(STRIP, { visible: true })
  await sleep(600)
  const dd = await d.$eval(STRIP, (s) => ({ fit: s.getAttribute('data-fit'), snap: getComputedStyle(s).scrollSnapType, w: Math.round(s.getBoundingClientRect().width), copies: s.querySelectorAll('[data-loop]').length }))
  ok('1440 6 CONTROL: the desktop rail has no data-fit, no scroll snap, no copies', dd.fit === null && (dd.snap === 'none' || dd.snap === '') && dd.copies === 0, dd)
  await d.evaluate(() => { window.__taps = []; document.querySelector('[data-testid=sidebar-tab-issues]').click() })
  await sleep(ANIM_MAX + 100)
  const dt = (await d.evaluate(() => window.__taps)).filter((x) => x.key === 'issues')
  ok('1440 6 the desktop rail icon animates on a tap too (pop, then off)', dt.some((x) => x.on && x.kind === 'tap-anim--pop') && dt.some((x) => !x.on), dt)
  await d.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((x) => !x.ok)
console.log(`\nmobile-rail-whole-icons: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
