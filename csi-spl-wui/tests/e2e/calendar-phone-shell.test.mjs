// spec 106 T004: the phone calendar's shell (CalendarPhone.vue) on a phone.
//
// At 360x780, 390x844 and 820x1180, dark and light, font levels 1, 3 and 5,
// in every view:
//   H3  no sideways scroll: documentElement scrollWidth - clientWidth <= 1,
//       no element under the calendar with overflow-x auto / scroll wider
//       than its box, scrollLeft == 0 - also with a 200-character unbroken
//       title, after Tab through the view and after Today
//   H7  controls (header, bottom bar) >= 44x44, <= 48 px tall at level 3;
//       the + button 56x56; under 400 px or at level >= 4 Today is its day
//       number and the segments M / W / D
//   H8  one header row, one bottom bar, each <= 48 px at level 3; the view
//       >= 82 % of the page the app gives the calendar (level 3); no wrap
//       at levels 1 and 5
// Once per width (level 3, dark):
//   H1  each view one tap from the other two (6 pairs, role=radio checked)
//   H2  a touch swipe left / right turns the period by one in each view;
//       the page follows the finger 1:1 and flat while it is down
//   H6  the + and the selected segment are raised (box-shadow); the release
//       snap tilts (rotateY <= 8deg, scale 0.98) and the page rests flat;
//       the leaving page is inert during the turn; reduced motion: no tilt,
//       the swipe still turns
//   FR-002 Week first, then the last view (localStorage)
//   AC-07 a swipe right from the 24 px edge is Back (level 1); one from
//       mid-screen turns back a period and stays on the calendar
// Above 820 px (1440x900) nothing changes, and without the opt-in
// (localStorage spool-calendar-phone = 1, until T011) the phone keeps the
// T009 calendar.
//
// Controls: before T004 there is no [data-test=calendar-phone], so every
// check FAILs; in-run, a planted 2000 px scroller must trip the H3 detector,
// a planted 30 px button the H7 one.
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/var/tmp/shots pnpm run test:e2e calendar-phone-shell
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calIsoDay } from '../../src/utils/calendar-year.mjs'
import { calPhoneRange, calPhoneStep } from '../../src/utils/calendar-phone-nav.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-phone-shell-${name}.png`) })
}

const today = calIsoDay(Date.now())
const VIEWS = ['month', 'week', 'day']
const ROOT = '[data-test=calendar-phone]'
const periodOf = (view, day) => calPhoneRange(view, day)?.from || ''

/** a fresh page: the opt-in, the theme and the font level in localStorage first */
async function open(browser, vp, { theme = 'dark', level = 3, shell = true, view = '' } = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.evaluateOnNewDocument((s) => {
    try {
      if (sessionStorage.getItem('calphone-seeded')) return
      sessionStorage.setItem('calphone-seeded', '1')
      if (s.shell) localStorage.setItem('spool-calendar-phone', '1')
      localStorage.setItem('spool-theme', s.theme)
      localStorage.setItem('spool-font-size', String(s.level))
      if (s.view) localStorage.setItem('spool-calendar-phone-view', s.view)
    } catch { /* about:blank */ }
  }, { shell, theme, level, view })
  const spec = { ...vp, hasTouch: true }
  await setPageViewport(p, spec)
  await p.goto(server.base + '/calendar', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, spec)
  if (shell && vp.width <= 820) {
    await p.waitForSelector(ROOT, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
    await p.waitForFunction((r) => document.querySelector(r)?.getAttribute('data-state') === 'ready', { timeout: 10000 }, ROOT).catch(() => {})
  } else {
    await p.waitForSelector('[data-test=calendar-page]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
    await sleep(500)
  }
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
  return { p, ctx }
}

const rootAttr = (p, n) => p.$eval(ROOT, (el, a) => el.getAttribute(a), n).catch(() => '')
const waitRoot = (p, n, want) => p.waitForFunction((r, a, w) => document.querySelector(r)?.getAttribute(a) === w, { timeout: 5000 }, ROOT, n, want).then(() => true, () => false)
const level = (p) => p.evaluate(() => document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '')

/* H3: the document and every scroller under the calendar */
async function sideways(p) {
  return p.evaluate((r) => {
    const root = document.querySelector(r)
    const wide = []
    for (const el of root ? root.querySelectorAll('*') : []) {
      const ox = getComputedStyle(el).overflowX
      if ((ox === 'auto' || ox === 'scroll') && el.scrollWidth > el.clientWidth + 1) wide.push(el.className || el.tagName)
      if (el.scrollLeft !== 0) wide.push(`scrollLeft ${el.className || el.tagName}`)
    }
    return { doc: document.documentElement.scrollWidth - document.documentElement.clientWidth, docLeft: document.scrollingElement?.scrollLeft || 0, wide }
  }, ROOT)
}
const flatOk = (s) => s.doc <= 1 && s.docLeft === 0 && s.wide.length === 0

/* the boxes H7 / H8 read */
async function boxes(p) {
  return p.evaluate((r) => {
    const box = (el) => {
      if (!el) return null
      const b = el.getBoundingClientRect()
      return { x: Math.round(b.left), y: Math.round(b.top), w: Math.round(b.width * 10) / 10, h: Math.round(b.height * 10) / 10 }
    }
    const q = (s) => document.querySelector(s)
    const shown = (el) => el && getComputedStyle(el).display !== 'none'
    const controls = [...document.querySelectorAll(`${r} [data-test=calphone-head] button, ${r} [data-test=calphone-bar] button`)]
      .filter((el) => el.offsetParent !== null)
      .map((el) => ({ id: el.getAttribute('data-test') || el.getAttribute('data-testid') || el.className, ...box(el) }))
    const bar = q(`${r} [data-test=calphone-bar]`)
    const kids = bar ? [...bar.children].map((el) => box(el)) : []
    /* the page the app gives: the calendar's box down to the composer dock */
    const dock = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--composer-dock-h')) || 0
    const pg = box(q('[data-test=calendar-page]'))
    if (pg) pg.h = Math.min(pg.y + pg.h, window.innerHeight - dock) - pg.y
    return {
      dock,
      page: pg,
      head: box(q(`${r} [data-test=calphone-head]`)),
      bar: box(bar),
      view: box(q(`${r} [data-test=calphone-view]`)),
      add: box(q(`${r} [data-test=calphone-add]`)),
      controls,
      barRows: kids.length ? Math.max(...kids.map((k) => k.y)) - Math.min(...kids.map((k) => k.y)) : -1,
      todayShort: shown(q(`${r} [data-test=calphone-today] .calphone__short`)),
      segShort: shown(q(`${r} [data-test=calphone-view-week] .calphone__short`)),
      titleText: q(`${r} [data-test=calphone-title]`)?.textContent?.trim() || '',
    }
  }, ROOT)
}
const tapSize = (c) => c.w >= 43.5 && c.h >= 43.5

/** H3 / H7 / H8 on the screen as it is */
async function layoutChecks(p, tag, vp, lvl) {
  const s = await sideways(p)
  ok(`H3 ${tag}: no sideways scroll`, flatOk(s), s)
  const b = await boxes(p)
  const small = b.controls.filter((c) => !tapSize(c))
  ok(`H7 ${tag}: every control >= 44x44`, small.length === 0 && b.controls.length >= 8, small.length ? small : b.controls.length)
  ok(`H7 ${tag}: the + is 56x56`, Boolean(b.add && Math.abs(b.add.w - 56) < 1 && Math.abs(b.add.h - 56) < 1), b.add)
  const compact = vp.width < 400 || lvl >= 4
  ok(`H7 ${tag}: Today ${compact ? 'is its day number' : 'is a word'}, segments ${compact ? 'M / W / D' : 'words'}`, b.todayShort === compact && b.segShort === compact, { todayShort: b.todayShort, segShort: b.segShort })
  ok(`H8 ${tag}: the bottom bar is one row`, b.barRows >= 0 && b.barRows <= 4, b.barRows)
  ok(`H8 ${tag}: the header and the bar fit the width`, Boolean(b.head && b.bar && b.head.w <= vp.width + 0.5 && b.bar.w <= vp.width + 0.5), { head: b.head, bar: b.bar })
  if (lvl === 3) {
    const tall = b.controls.filter((c) => c.h > 48.5)
    ok(`H7 ${tag}: controls <= 48 px tall at level 3`, tall.length === 0, tall)
    ok(`H8 ${tag}: header and bar <= 48 px`, Boolean(b.head && b.bar && b.head.h <= 48.5 && b.bar.h <= 48.5), { head: b.head?.h, bar: b.bar?.h })
    const share = b.page && b.view ? b.view.h / b.page.h : 0
    ok(`H8 ${tag}: the view is >= 82 % of the page`, share >= 0.82, { share: Math.round(share * 1000) / 10, view: b.view?.h, page: b.page?.h, dock: b.dock })
    ok(`H8 ${tag}: the bottom bar ends above the composer dock`, Boolean(b.bar && b.bar.y + b.bar.h <= vp.height - b.dock + 0.5), { bar: b.bar, dock: b.dock })
  }
  return b
}

async function tapView(p, v) {
  await p.click(`${ROOT} [data-test=calphone-view-${v}]`)
  return waitRoot(p, 'data-view', v)
}

/* a finger on the view: down at `from`, `steps` moves to `to`, then up (unless `hold`) */
async function swipe(p, from, to, { hold = false, steps = 10 } = {}) {
  const cdp = await p.createCDPSession()
  const pt = (x, y) => [{ x: Math.round(x), y: Math.round(y), id: 1 }]
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: pt(from.x, from.y) })
  for (let i = 1; i <= steps; i++) {
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: pt(from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps) })
    await sleep(16)
  }
  if (hold) return cdp
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
  await sleep(400)
  return cdp
}
async function viewMid(p) {
  return p.$eval(`${ROOT} [data-test=calphone-view]`, (el) => {
    const r = el.getBoundingClientRect()
    return { x: r.left, w: r.width, y: r.top + r.height / 2 }
  })
}

/* watch a turn frame by frame: the track's computed transform, its
   animation keyframes, and whether the current page went inert */
function recordTurn(p) {
  return p.evaluate((r) => new Promise((resolve) => {
    const track = document.querySelector(`${r} [data-test=calphone-track]`)
    const out = { samples: [], frames: [], inert: false, pages: 0 }
    const t0 = performance.now()
    const tick = () => {
      const tf = track ? getComputedStyle(track).transform : ''
      out.samples.push(tf)
      const a = track?.getAnimations?.()[0]
      if (a && !out.frames.length) out.frames = a.effect.getKeyframes().map((k) => k.transform)
      const cur = document.querySelector(`${r} [data-test=calphone-page][data-dir="0"]`)
      if (cur && cur.inert) out.inert = true
      out.pages = Math.max(out.pages, document.querySelectorAll(`${r} [data-test=calphone-page]`).length)
      if (performance.now() - t0 < 600) requestAnimationFrame(tick)
      else resolve(out)
    }
    requestAnimationFrame(tick)
  }), ROOT)
}
const maxTilt = (frames) => Math.max(0, ...frames.map((f) => Math.abs(Number((String(f).match(/rotateY\((-?[\d.]+)deg\)/) || [])[1] || 0))))

const server = await startServer()
const browser = await launch()
const PHONES = [{ width: 360, height: 780 }, { width: 390, height: 844 }, { width: 820, height: 1180 }]
try {
  /* ---- the matrix: H3 / H7 / H8 in every view, theme and level ---- */
  for (const vp of PHONES) {
    for (const theme of ['dark', 'light']) {
      for (const lvl of [1, 3, 5]) {
        const tag = `${vp.width} ${theme} L${lvl}`
        console.log(`-- ${tag}`)
        const { p, ctx } = await open(browser, vp, { theme, level: lvl })
        ok(`${tag}: the phone shell renders`, Boolean(await p.$(ROOT)))
        for (const v of VIEWS) {
          ok(`${tag} ${v}: one tap shows it`, await tapView(p, v))
          await layoutChecks(p, `${tag} ${v}`, vp, lvl)
          if (vp.width === 390 && lvl === 3) await shot(p, `${vp.width}-${theme}-${v}`)
        }
        await ctx.close()
      }
    }
  }

  /* ---- the interactions, once per width (level 3, dark) ---- */
  for (const vp of PHONES) {
    const w = vp.width
    console.log(`-- ${w}x${vp.height} interactions`)
    let { p, ctx } = await open(browser, vp)
    ok(`FR-002 ${w}: opens on Week`, (await rootAttr(p, 'data-view')) === 'week', await rootAttr(p, 'data-view'))
    ok(`${w}: the calendar is level 2`, (await level(p)) === '2', await level(p))

    /* H1: six pairs, one tap each; the segments are a radiogroup */
    const pairs = []
    for (const a of VIEWS) {
      for (const b of VIEWS) {
        if (a === b) continue
        await tapView(p, a)
        pairs.push({ a, b, ok: await tapView(p, b) })
      }
    }
    ok(`H1 ${w}: each view is one tap from the other two (6 pairs)`, pairs.length === 6 && pairs.every((x) => x.ok), pairs.filter((x) => !x.ok))
    const aria = await p.evaluate((r) => {
      const g = document.querySelector(`${r} [data-test=calphone-views]`)
      const on = [...(g?.querySelectorAll('[role=radio]') || [])].filter((b) => b.getAttribute('aria-checked') === 'true')
      return { role: g?.getAttribute('role'), checked: on.map((b) => b.getAttribute('data-view')), live: document.querySelector(`${r} [aria-live=polite]`)?.textContent || '' }
    }, ROOT)
    ok(`S4-2 ${w}: segments are a radiogroup, the shown view checked`, aria.role === 'radiogroup' && aria.checked.length === 1 && aria.checked[0] === (await rootAttr(p, 'data-view')), aria)

    /* H6: raised + and selected segment */
    const raised = await p.evaluate((r) => ['[data-test=calphone-add]', '.calphone__seg-btn--on'].map((s) => { const el = document.querySelector(`${r} ${s}`); return el ? getComputedStyle(el).boxShadow : '' }), ROOT)
    ok(`H6 ${w}: the + and the selected segment are raised`, raised.every((s) => s && s !== 'none'), raised)

    /* < / >: one period, with the 3D release snap; the page rests flat */
    for (const v of VIEWS) {
      await tapView(p, v)
      const before = await rootAttr(p, 'data-period')
      const day = await rootAttr(p, 'data-day')
      const rec = recordTurn(p)
      await p.click(`${ROOT} [data-test=calphone-next]`)
      const turnRec = await rec
      const after = await rootAttr(p, 'data-period')
      ok(`${w} ${v}: > turns one period`, after === periodOf(v, calPhoneStep(v, day, 1)) && after !== before, { day, before, after })
      if (v === 'week') {
        const tilt = maxTilt(turnRec.frames)
        ok(`H6 ${w}: the release snap tilts, rotateY <= 8deg, scale 0.98`, tilt > 0 && tilt <= 8 && turnRec.frames.some((f) => /scale\(0\.98\)/.test(f)), turnRec.frames)
        ok(`H6 ${w}: a 3D transform is on screen during the snap`, turnRec.samples.some((s) => s.startsWith('matrix3d')), turnRec.samples.slice(0, 4))
        ok(`S4-2 ${w}: the leaving page is inert during the turn, two pages at most`, turnRec.inert && turnRec.pages === 2, { inert: turnRec.inert, pages: turnRec.pages })
        const rest = await p.$eval(`${ROOT} [data-test=calphone-track]`, (el) => getComputedStyle(el).transform)
        ok(`H6 ${w}: at rest the page is flat (transform none)`, rest === 'none', rest)
        const live = await p.$eval(`${ROOT} [aria-live=polite]`, (el) => el.textContent.trim())
        const title = (await boxes(p)).titleText
        ok(`S4-2 ${w}: the new period is announced`, live !== '' && live === title, { live, title })
      }
      await p.click(`${ROOT} [data-test=calphone-prev]`)
      ok(`${w} ${v}: < turns back`, await waitRoot(p, 'data-period', before), await rootAttr(p, 'data-period'))
    }

    /* H2: swipes in every view; 1:1 flat while the finger is down */
    for (const v of VIEWS) {
      await tapView(p, v)
      const before = await rootAttr(p, 'data-period')
      const day = await rootAttr(p, 'data-day')
      const m = await viewMid(p)
      await swipe(p, { x: m.x + m.w * 0.8, y: m.y }, { x: m.x + m.w * 0.2, y: m.y + 4 })
      const next = await rootAttr(p, 'data-period')
      ok(`H2 ${w} ${v}: swipe left = next period`, next === periodOf(v, calPhoneStep(v, day, 1)) && next !== before, { day, before, next })
      await swipe(p, { x: m.x + m.w * 0.3, y: m.y }, { x: m.x + m.w * 0.85, y: m.y + 4 })
      ok(`H2 ${w} ${v}: swipe right from mid-screen = previous, still on the calendar`, (await rootAttr(p, 'data-period')) === before && (await level(p)) === '2', { period: await rootAttr(p, 'data-period'), level: await level(p) })
    }
    {
      const m = await viewMid(p)
      const cdp = await swipe(p, { x: m.x + m.w * 0.7, y: m.y }, { x: m.x + m.w * 0.7 - 80, y: m.y }, { hold: true })
      await sleep(80)
      const drag = await p.$eval(`${ROOT} [data-test=calphone-track]`, (el) => ({ inline: el.style.transform, computed: getComputedStyle(el).transform }))
      const tx = Number((drag.computed.match(/^matrix\(([^)]*)\)$/) || ['', ''])[1].split(',')[4])
      ok(`H2 ${w}: while the finger is down the page follows 1:1, flat`, /^translateX\(-80px\)$/.test(drag.inline) && drag.computed.startsWith('matrix(') && Math.abs(tx + 80) < 1, drag)
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
      await sleep(400)
      await p.click(`${ROOT} [data-test=calphone-prev]`)
      await sleep(400)
    }

    /* H3 with a 200-character unbroken title, after Tab, after Today */
    const long = 'x'.repeat(200)
    await p.evaluate((r, t) => {
      document.querySelector(`${r} .calphone__title-text`).textContent = t
      const list = document.querySelector(`${r} [data-test=calphone-page][data-dir="0"] .calphone__slot`)
      const row = document.createElement('div')
      row.className = 'calphone__slot-row'
      row.textContent = t
      list?.appendChild(row)
    }, ROOT, long)
    const longS = await sideways(p)
    const longB = await boxes(p)
    ok(`H3 ${w}: a 200-character title widens nothing`, flatOk(longS) && longB.head.h <= 48.5, { s: longS, head: longB.head })
    for (let i = 0; i < 12; i++) await p.keyboard.press('Tab')
    ok(`H3 ${w}: scrollLeft == 0 after Tab through the view`, flatOk(await sideways(p)), await sideways(p))
    await p.click(`${ROOT} [data-test=calphone-next]`)
    await sleep(400)
    await p.click(`${ROOT} [data-test=calphone-today]`)
    ok(`${w}: Today goes back to today's period`, await waitRoot(p, 'data-period', periodOf(await rootAttr(p, 'data-view'), today)), await rootAttr(p, 'data-period'))
    ok(`H3 ${w}: scrollLeft == 0 after Today`, flatOk(await sideways(p)), await sideways(p))

    /* controls: the detectors have teeth */
    if (w === 390) {
      await p.evaluate((r) => {
        const s = document.createElement('div')
        s.id = 'plant-wide'
        s.style.cssText = 'overflow-x:auto;width:100px'
        s.innerHTML = '<div style="width:2000px;height:4px"></div>'
        document.querySelector(`${r} .calphone__slot`).appendChild(s)
        const b = document.createElement('button')
        b.id = 'plant-small'
        b.style.cssText = 'width:30px;height:30px;min-width:0;min-height:0;padding:0'
        document.querySelector(`${r} [data-test=calphone-bar]`).appendChild(b)
      }, ROOT)
      ok('control: a planted 2000 px scroller trips H3', !flatOk(await sideways(p)))
      ok('control: a planted 30 px button trips H7', (await boxes(p)).controls.some((c) => !tapSize(c)))
    }

    /* FR-002: the last view comes back */
    await tapView(p, 'day')
    await p.reload({ waitUntil: 'networkidle2' })
    await p.waitForSelector(ROOT, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
    ok(`FR-002 ${w}: reopens on the last view (Day)`, (await rootAttr(p, 'data-view')) === 'day', await rootAttr(p, 'data-view'))

    /* AC-07: a swipe right from the 24 px edge is Back */
    {
      const m = await viewMid(p)
      await swipe(p, { x: 10, y: m.y }, { x: Math.min(m.w - 10, 230), y: m.y + 4 })
      await sleep(300)
      ok(`AC-07 ${w}: a swipe from the left edge goes Back to level 1`, (await level(p)) === '1', await level(p))
    }
    await ctx.close()

    /* H6 reduced motion: no tilt, the swipe still turns */
    ;({ p, ctx } = await open(browser, vp))
    await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
    {
      const before = await rootAttr(p, 'data-period')
      const day = await rootAttr(p, 'data-day')
      const rec = recordTurn(p)
      await p.click(`${ROOT} [data-test=calphone-next]`)
      const r = await rec
      ok(`H6 ${w}: reduced motion - no 3D during a turn`, r.frames.length === 0 && r.samples.every((s) => !s.startsWith('matrix3d')), { frames: r.frames })
      ok(`H6 ${w}: reduced motion - > still turns`, (await rootAttr(p, 'data-period')) === periodOf('week', calPhoneStep('week', day, 1)))
      const m = await viewMid(p)
      await swipe(p, { x: m.x + m.w * 0.3, y: m.y }, { x: m.x + m.w * 0.85, y: m.y })
      ok(`H6 ${w}: reduced motion - the swipe still turns`, (await rootAttr(p, 'data-period')) === before, await rootAttr(p, 'data-period'))
    }
    await ctx.close()
  }

  /* ---- untouched: desktop, and a phone without the opt-in ---- */
  {
    const { p, ctx } = await open(browser, { width: 1440, height: 900 })
    const d = await p.evaluate(() => ({ shell: Boolean(document.querySelector('[data-test=calendar-phone]')), main: Boolean(document.querySelector('[data-test=calendar-main]')), strip: Boolean(document.querySelector('[data-test=calendar-year-strip]')) }))
    ok('FR-011 1440: the desktop calendar, no phone shell', !d.shell && d.main && d.strip, d)
    await ctx.close()
  }
  {
    const { p, ctx } = await open(browser, { width: 390, height: 844 }, { shell: false })
    const d = await p.evaluate(() => ({ shell: Boolean(document.querySelector('[data-test=calendar-phone]')), main: Boolean(document.querySelector('[data-test=calendar-main]')) }))
    ok('390 without the opt-in: the T009 phone calendar (until T011)', !d.shell && d.main, d)
    await ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ncalendar-phone-shell: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
