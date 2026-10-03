// Owner, t1 (2026-10-02 21:28Z): "Add handle to the omnibox on mobile to be
// able to drag to the top of the screen and to the right". The phone dock
// carries a grip (OmniboxGrip); a TOUCH drag on it snaps the box to the top
// (under the top bar), the bottom-right corner, or back to the bottom; the
// place is kept per browser; a tap or the keyboard opens a menu instead.
//
//   phone (390x844, hasTouch, the mock):
//     1 the grip is on the docked box's top edge, labelled, a 48x24 target;
//       the box starts at the bottom
//     2 touch-drag the grip to the upper screen: the box is right under the
//       top bar, the panes start under it, and an error snackbar slides in
//       OVER it (still readable)
//     3 a reload keeps it at the top
//     4 touch-drag to the right: the box sits in the bottom-right corner,
//       narrower than the screen, the feed's left edge uncovered
//     5 touch-drag back down to the middle bottom: full width at the bottom
//     6 CONTROL: a touch swipe on the feed scrolls the feed and leaves the
//       box where it was (only the grip takes the finger)
//     7 a tap on the grip opens the menu; "Move to top" moves it
//     8 the keyboard: Enter on the grip opens the menu on the current place,
//       ArrowDown + Enter picks the next one
//   desktop (1440x900): 9 CONTROL: no grip, the box where it always was
//   owner, t1 21:53Z "it should be possible to resize it" (phone again):
//     10 the size handle (a 44x24 target at the free edge's LEFT end, owner
//        t1 03128097: "should be put on the left side on mobile"):
//        a touch drag UP at the bottom makes the field taller, the feed's
//        padding follows
//     11 LIMIT: dragging far past the top stops at half the room under the
//        top bar
//     12 a reload keeps the size
//     13 CONTROL: with the large box a swipe on the feed still scrolls it
//     14 at the top: a drag DOWN grows it, back up past one line is one line
//     15 in the corner the handle is on the left edge: LEFT is wider and stops
//        48 px short of the screen, RIGHT is narrower and stops at 280 px
//     16 the menu's Small / Medium / Large set it (ticked), for those who
//        cannot drag; a tap on the size handle opens that menu
//
// Run:
//   pnpm run test:e2e omnibox-grip
//   BASE_URL=<generated bundle> pnpm run test:e2e omnibox-grip   # what CI does
//   SHOTS=<dir> ... also writes the three 390 px positions there, and small
//   and large at the bottom and in the corner
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PHONE = { width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }
const PROBE = 'omnibox-grip-probe'

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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Where the box, its grip and the panes are now. */
const facts = (p) => p.evaluate(() => {
  const f = document.querySelector('form.composer.omnibox--global')
  const g = document.querySelector('[data-testid=omnibox-grip]')
  const z = document.querySelector('[data-testid=omnibox-size]')
  const ta = f && f.querySelector('textarea')
  const bar = document.querySelector('[data-test=top-bar]')
  const shell = document.querySelector('.spool-shell')
  if (!f) return null
  const r = f.getBoundingClientRect()
  const gr = g ? g.getBoundingClientRect() : null
  const zr = z ? z.getBoundingClientRect() : null
  let stored = null
  let size = null
  try {
    stored = localStorage.getItem('spool.omnibox-phone-pos')
    size = JSON.parse(localStorage.getItem('spool.omnibox-phone-size') || 'null')
  } catch { /* denied */ }
  return {
    pos: f.getAttribute('data-phone-pos'),
    docked: f.getAttribute('data-docked') === 'true',
    box: { top: Math.round(r.top), bottom: Math.round(r.bottom), left: Math.round(r.left), right: Math.round(r.right), w: Math.round(r.width), h: Math.round(r.height) },
    grip: gr ? { cx: Math.round(gr.left + gr.width / 2), cy: Math.round(gr.top + gr.height / 2), w: Math.round(gr.width), h: Math.round(gr.height), label: g.getAttribute('aria-label') } : null,
    size: zr ? { cx: Math.round(zr.left + zr.width / 2), cy: Math.round(zr.top + zr.height / 2), w: Math.round(zr.width), h: Math.round(zr.height), label: z.getAttribute('aria-label') } : null,
    field: ta ? Math.round(ta.getBoundingClientRect().height) : null,
    dockPad: Math.round(parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--composer-dock-h')) || 0),
    stored_size: size,
    barBottom: bar ? Math.round(bar.getBoundingClientRect().bottom) : null,
    shellPadTop: shell ? Math.round(parseFloat(getComputedStyle(shell).paddingTop)) : null,
    vw: innerWidth,
    vh: innerHeight,
    stored,
  }
})

/** A finger drag from the grip's (or the size handle's) centre to (x, y), in steps. */
async function dragGrip(p, x, y, handle = 'grip') {
  const f = await facts(p)
  const a = { x: f[handle].cx, y: f[handle].cy }
  /* on the screen: a finger cannot leave it (a target past the edge made the
     next tap on the grip miss on CI, wf11 73706a65) */
  x = Math.min(f.vw - 1, Math.max(1, x))
  y = Math.min(f.vh - 1, Math.max(1, y))
  await p.touchscreen.touchStart(a.x, a.y)
  const n = 12
  for (let i = 1; i <= n; i++) {
    await p.touchscreen.touchMove(a.x + ((x - a.x) * i) / n, a.y + ((y - a.y) * i) / n)
    await sleep(16)
  }
  await p.touchscreen.touchEnd()
  await sleep(500)
  return facts(p)
}

async function toChannel(p) {
  await settle(p)
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(800)
  await p.click('[data-testid=sidebar-tab-channels]')
  await sleep(400)
  await p.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
  await sleep(1200)
  await p.waitForSelector('[data-testid=omnibox-grip]', { timeout: NAV_TIMEOUT })
  await sleep(300)
}

async function phone(browser) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => {
    const s = String(e.stack || e)
    if (!s.includes(PROBE)) errors.push({ at: p.url(), err: s.slice(0, 600) })
  })
  await p.setViewport(PHONE)
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => { try { localStorage.removeItem('spool.omnibox-phone-pos') } catch { /* denied */ } })
  await toChannel(p)

  const f1 = await facts(p)
  ok('390px 1 the grip sits on the docked box\'s top edge, labelled, 48x24; the box at the bottom',
    Boolean(f1 && f1.docked && f1.pos === 'bottom' && f1.grip && f1.grip.label && f1.grip.w >= 44 && f1.grip.h >= 24
      && Math.abs(f1.grip.cy - f1.box.top) <= 4 && f1.box.w === f1.vw && f1.box.bottom >= f1.vh - 60), f1)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-grip-390-bottom.png') })

  /* 2: to the top */
  const f2 = await dragGrip(p, 195, 140)
  /* a page script, so the window error carries its message (as
     snackbar-top-mobile.test.mjs raises one) */
  await p.evaluate((m) => {
    const s = document.createElement('script')
    s.src = URL.createObjectURL(new Blob([`setTimeout(() => { throw new Error('${m}') }, 0)`], { type: 'text/javascript' }))
    document.head.appendChild(s)
  }, PROBE)
  await p.waitForSelector('[data-test=error-snackbar-item]', { timeout: 4000 }).catch(() => {})
  await sleep(500)
  const snack = await p.evaluate(() => {
    const it = document.querySelector('[data-test=error-snackbar-item]')
    if (!it) return null
    const r = it.getBoundingClientRect()
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
    return { top: Math.round(r.top), bottom: Math.round(r.bottom), onTop: Boolean(hit && it.contains(hit)) }
  })
  ok('390px 2 drag up: the box is right under the top bar, the panes start under it, a snackbar is readable over it',
    Boolean(f2 && f2.pos === 'top' && f2.stored === 'top' && Math.abs(f2.box.top - f2.barBottom) <= 2 && f2.box.w === f2.vw
      && Math.abs(f2.shellPadTop - f2.box.h) <= 2 && snack && snack.onTop), { f2, snack })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-grip-390-top.png') })
  await p.evaluate(() => document.querySelector('[data-test=error-snackbar-dismiss]')?.click())
  await sleep(300)

  /* 3: reload keeps it */
  await toChannel(p)
  const f3 = await facts(p)
  ok('390px 3 a reload keeps the box at the top', Boolean(f3 && f3.pos === 'top' && Math.abs(f3.box.top - f3.barBottom) <= 2), f3)

  /* 4: to the right */
  const f4 = await dragGrip(p, 370, 640)
  ok('390px 4 drag right: the bottom-right corner, narrower than the screen, the feed\'s left edge uncovered',
    Boolean(f4 && f4.pos === 'right' && f4.stored === 'right' && f4.box.right === f4.vw && f4.box.left >= 40
      && f4.box.bottom >= f4.vh - 60 && f4.shellPadTop === 0), f4)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-grip-390-right.png') })

  /* 5: back to the bottom */
  const f5 = await dragGrip(p, 160, 800)
  ok('390px 5 drag back down: full width at the bottom again',
    Boolean(f5 && f5.pos === 'bottom' && f5.stored === 'bottom' && f5.box.w === f5.vw && f5.box.left === 0 && f5.box.bottom >= f5.vh - 60), f5)

  /* 6: CONTROL - a swipe on the feed scrolls the feed, the box stays. The
     mock channel is short: 30 filler posts make it scroll */
  await p.evaluate(async () => {
    const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    for (let i = 0; i < 30; i++) await ch.send(`HUM-10 grip filler ${i}`, undefined, undefined, undefined, 1)
  })
  await sleep(1200)
  const body = await p.evaluate(() => {
    const els = [...document.querySelectorAll('.spool-main .feed-body')].filter((e) => e.getClientRects().length && e.scrollHeight > e.clientHeight + 40)
    const el = els[0]
    if (!el) return null
    el.scrollTop = el.scrollHeight
    const r = el.getBoundingClientRect()
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2), before: Math.round(el.scrollTop) }
  })
  let scrolled = null
  if (body) {
    await sleep(300)
    const before = await p.evaluate(() => Math.round([...document.querySelectorAll('.spool-main .feed-body')].find((e) => e.getClientRects().length && e.scrollHeight > e.clientHeight + 40)?.scrollTop ?? -1))
    await p.touchscreen.touchStart(body.x, body.y - 150)
    for (let i = 1; i <= 10; i++) {
      await p.touchscreen.touchMove(body.x, body.y - 150 + i * 30)
      await sleep(16)
    }
    await p.touchscreen.touchEnd()
    await sleep(700)
    const after = await p.evaluate(() => Math.round([...document.querySelectorAll('.spool-main .feed-body')].find((e) => e.getClientRects().length && e.scrollHeight > e.clientHeight + 40)?.scrollTop ?? -1))
    scrolled = { before, after }
  }
  const f6 = await facts(p)
  ok('390px 6 CONTROL: a touch swipe on the feed scrolls it and leaves the box at the bottom',
    Boolean(scrolled && scrolled.after < scrolled.before - 20 && f6.pos === 'bottom'), { scrolled, pos: f6 && f6.pos })

  /* 7: the menu by tap */
  await p.tap('[data-testid=omnibox-grip]')
  await sleep(300)
  const menu = await p.evaluate(() => [...document.querySelectorAll('[data-testid=omnibox-grip-menu] [role=menuitemradio][data-pos]')].map((b) => ({ pos: b.getAttribute('data-pos'), checked: b.getAttribute('aria-checked'), text: b.textContent.trim() })))
  await p.tap('[data-testid=omnibox-grip-menu] [data-pos=top]')
  await sleep(400)
  const f7 = await facts(p)
  ok('390px 7 a tap opens the menu (top / right / bottom, bottom checked); "Move to top" moves it',
    Boolean(menu.length === 3 && menu.find((m) => m.pos === 'bottom')?.checked === 'true' && menu.every((m) => m.text)
      && f7.pos === 'top' && f7.stored === 'top'), { menu, pos: f7.pos })

  /* 8: the keyboard */
  await p.focus('[data-testid=omnibox-grip]')
  await p.keyboard.press('Enter')
  await sleep(300)
  const focused = await p.evaluate(() => document.activeElement?.getAttribute('data-pos'))
  await p.keyboard.press('ArrowDown')
  await p.keyboard.press('Enter')
  await sleep(400)
  const f8 = await facts(p)
  ok('390px 8 keyboard: Enter opens the menu on the current place, ArrowDown + Enter picks the next (right)',
    focused === 'top' && f8.pos === 'right', { focused, pos: f8.pos })

  await sizes(p)

  /* leave the browser at the default */
  await p.evaluate(() => { try { localStorage.removeItem('spool.omnibox-phone-pos'); localStorage.removeItem('spool.omnibox-phone-size') } catch { /* denied */ } })
  ok('390px no page error', errors.length === 0, errors)
  await p.close()
}

/** The room a height share is of: under the top bar, no keyboard here. */
const room = (f) => f.vh - f.barBottom

/* the menu by tap; waits for it and taps the grip again when a tap was lost */
async function pickMenu(p, sel) {
  for (let i = 0; i < 3; i++) {
    if (!(await p.$('[data-testid=omnibox-grip-menu]'))) await p.tap('[data-testid=omnibox-grip]')
    const item = await p.waitForSelector(`[data-testid=omnibox-grip-menu] ${sel}`, { timeout: 2000 }).catch(() => null)
    if (item) {
      await item.tap()
      break
    }
  }
  await sleep(500)
  return facts(p)
}

/* owner, t1 21:53Z: "it should be possible to resize it" */
async function sizes(p) {
  const f9 = await pickMenu(p, '[data-pos=bottom]')
  /* 10: bottom, drag the size handle up 250 px */
  const h0 = f9.field
  const f10 = await dragGrip(p, f9.size.cx, f9.size.cy - 250, 'size')
  ok('390px 10 the size handle (44x24, labelled, left end of the top edge): a drag up makes the field taller, the panes\' bottom padding follows',
    Boolean(f9.size && f9.size.w >= 44 && f9.size.h >= 24 && f9.size.label && Math.abs(f9.size.cy - f9.box.top) <= 4 && f9.size.cx < f9.vw * 0.25 && f9.size.cx - f9.box.left <= 40
      && f10.pos === 'bottom' && f10.field >= h0 + 200 && f10.stored_size && f10.stored_size.bottom > 0
      && f10.dockPad >= f10.box.h - 2), { f9: f9.size, h0, f10 })
  /* 11: the limit */
  const f11 = await dragGrip(p, f10.size.cx, 0, 'size')
  ok('390px 11 LIMIT: dragged past the top it stops at half the room under the top bar',
    Boolean(f11.stored_size.bottom === 0.5 && Math.abs(f11.field - room(f11) / 2) <= 3 && f11.box.top > f11.barBottom + 100), { field: f11.field, room: room(f11), box: f11.box, stored: f11.stored_size })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-size-390-bottom-large.png') })
  /* 12: reload */
  await toChannel(p)
  const f12 = await facts(p)
  ok('390px 12 a reload keeps the size', Boolean(f12.pos === 'bottom' && Math.abs(f12.field - f11.field) <= 2), { before: f11.field, after: f12.field })
  /* 13: CONTROL, the feed still scrolls */
  await p.evaluate(async () => {
    const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    for (let i = 0; i < 30; i++) await ch.send(`HUM-10 size filler ${i}`, undefined, undefined, undefined, 1)
  })
  await sleep(1200)
  const sc = await p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main .feed-body')].find((e) => e.getClientRects().length && e.scrollHeight > e.clientHeight + 40)
    if (!el) return null
    el.scrollTop = el.scrollHeight
    const r = el.getBoundingClientRect()
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + 20) }
  })
  let scrolled = null
  if (sc) {
    await sleep(300)
    const top = () => p.evaluate(() => Math.round([...document.querySelectorAll('.spool-main .feed-body')].find((e) => e.getClientRects().length && e.scrollHeight > e.clientHeight + 40)?.scrollTop ?? -1))
    const before = await top()
    await p.touchscreen.touchStart(sc.x, sc.y)
    for (let i = 1; i <= 8; i++) {
      await p.touchscreen.touchMove(sc.x, sc.y + i * 25)
      await sleep(16)
    }
    await p.touchscreen.touchEnd()
    await sleep(700)
    scrolled = { before, after: await top() }
  }
  const f13 = await facts(p)
  ok('390px 13 CONTROL: with the large box a swipe on the feed still scrolls it, the size stays',
    Boolean(scrolled && scrolled.after < scrolled.before - 20 && Math.abs(f13.field - f12.field) <= 2), { scrolled, field: f13.field })

  /* 14: at the top */
  const f14a = await pickMenu(p, '[data-pos=top]')
  const f14b = await dragGrip(p, f14a.size.cx, f14a.size.cy + 200, 'size')
  const f14c = await dragGrip(p, f14b.size.cx, f14b.size.cy - 400, 'size')
  ok('390px 14 at the top the handle is on the bottom edge: down is taller, back up is one line again',
    Boolean(f14a.pos === 'top' && Math.abs(f14a.size.cy - f14a.box.bottom) <= 4 && f14b.field >= f14a.field + 150
      && Math.abs(f14b.shellPadTop - f14b.box.h) <= 2 && f14c.stored_size.top === 0 && f14c.field <= 50), { a: f14a.field, b: f14b.field, c: f14c.field, stored: f14c.stored_size })

  /* 15: the corner */
  const f15a = await pickMenu(p, '[data-pos=right]')
  const f15b = await dragGrip(p, 0, f15a.size.cy, 'size')
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-size-390-right-large.png') })
  const f15c = await dragGrip(p, f15b.size.cx + 380, f15b.size.cy, 'size')
  ok('390px 15 in the corner the handle is on the left edge: left is wider (48 px of the feed kept), right is narrower (280 px at least)',
    Boolean(f15a.pos === 'right' && Math.abs(f15a.size.cx - f15a.box.left) <= 4 && f15a.size.h >= 44
      && f15b.box.w === f15b.vw - 48 && f15b.box.right === f15b.vw && Math.abs(f15c.box.w - 280) <= 1 && f15c.box.right === f15c.vw), { a: f15a.box, b: f15b.box, c: f15c.box })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-size-390-right-small.png') })

  /* 16: the menu presets, opened from the size handle */
  /* the tap can land while the corner drag (15) is still settling and be
     lost (gate 11 runs 37129791383, 37130559228): wait for the menu, tap again */
  for (let i = 0; i < 3; i++) {
    if (!(await p.$('[data-testid=omnibox-grip-menu] [data-size=medium]'))) await p.tap('[data-testid=omnibox-size]')
    if (await p.waitForSelector('[data-testid=omnibox-grip-menu] [data-size=medium]', { timeout: 2000 }).catch(() => null)) break
  }
  const items = await p.evaluate(() => [...document.querySelectorAll('[data-testid=omnibox-grip-menu] [data-size]')].map((b) => ({ size: b.getAttribute('data-size'), checked: b.getAttribute('aria-checked'), text: b.textContent.trim() })))
  await p.tap('[data-testid=omnibox-grip-menu] [data-size=medium]')
  await sleep(400)
  const f16a = await facts(p)
  const f16b = await pickMenu(p, '[data-pos=bottom]')
  const f16c = await pickMenu(p, '[data-size=small]')
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-size-390-bottom-small.png') })
  const f16d = await pickMenu(p, '[data-size=large]')
  ok('390px 16 the size handle opens the menu: Small / Medium / Large set the size, the current one ticked',
    Boolean(items.length === 3 && items.every((i) => i.text) && f16a.box.w === Math.round(f16a.vw * 0.84)
      && f16b.field > 300 && f16c.field <= 50 && Math.abs(f16d.field - room(f16d) / 2) <= 3),
    { items, a: f16a.box.w, b: f16b.field, c: f16c.field, d: f16d.field })
}

async function desktop(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${server.base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('form.composer.omnibox--global', { timeout: NAV_TIMEOUT })
  await sleep(400)
  const f = await facts(p)
  ok('1440px 9 CONTROL: no grip on a desktop, the box in the top bar, no phone place',
    Boolean(f && !f.docked && !f.grip && !f.size && f.pos === null && f.box.top < f.barBottom), f)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  await phone(browser)
  await desktop(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
