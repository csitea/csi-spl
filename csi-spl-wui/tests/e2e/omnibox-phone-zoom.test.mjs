// SPL-2829 (owner, t1 d8ede89a, Android Chrome): "The omnibox snaps too low.
// It's almost invisible on mobile when moved, and resetting 'moved to bottom'
// doesn't help. It might be related somehow to Android zooming". His
// screenshot: the page zoomed in (~x1.07, the header's right buttons cut off)
// and the docked box under the nav bar, only its top few px on the screen.
// Cause: a fixed `bottom` is the LAYOUT viewport's bottom; zoomed in, the
// screen (the VISUAL viewport) ends above it, and keyboardInset read the gap
// (< 60 px) as a toolbar slide, so nothing lifted the box. Fix: the viewport
// meta refuses the zoom (maximum-scale=1, user-scalable=no), and a forced
// zoom counts every px under the screen.
//
//   phone (Pixel class 412x915, hasTouch, the mock). A zoom is asked for
//   with CDP Emulation.setPageScaleFactor, which honours the viewport meta
//   like a pinch does (headless Chrome drops a synthetic pinch); x1.05 at
//   915 px leaves 44 px under the screen, under the 60 px keyboard floor:
//     1 a zoom does not take: the page stays at x1, the box fully on the
//       screen (the visual viewport)
//     2 a drag on the grip to the bottom of the screen, the zoom asked
//       again: on the screen
//     3 the menu's "Move to bottom", the zoom asked again: on the screen
//     4 a FORCED zoom (the page served without the meta's limit, as
//       Chrome's "force enable zoom" reads it): the box's bottom is still on
//       the screen
//   phone with a 34 px bottom safe-area inset (the home indicator / an
//   edge-to-edge nav bar):
//     5 "Move to bottom" and a drag to the bottom: the box is on the screen
//       and its field and Send end above the inset
//
// Run:
//   pnpm run test:e2e omnibox-phone-zoom
//   BASE_URL=<generated bundle> pnpm run test:e2e omnibox-phone-zoom   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const PIXEL = { width: 412, height: 915, isMobile: true, hasTouch: true, deviceScaleFactor: 2.625 }
const INSET = 34
const ZOOM = 1.05

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const settle = (p) => p.waitForNetworkIdle({ idleTime: 400, timeout: 15000 }).catch(() => {})
/* read until two reads 150 ms apart agree */
async function stable(read, ms = 5000) {
  const t0 = Date.now()
  let prev = JSON.stringify(await read())
  for (;;) {
    await sleep(150)
    const v = await read()
    const now = JSON.stringify(v)
    if (now === prev || Date.now() - t0 > ms) return v
    prev = now
  }
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

/** The box, its field and Send, and the screen (the visual viewport), in layout px. */
const facts = (p) => p.evaluate(() => {
  const f = document.querySelector('form.composer.omnibox--global')
  const g = document.querySelector('[data-testid=omnibox-grip]')
  const vv = window.visualViewport
  if (!f || !vv) return null
  const rect = (el) => {
    if (!el) return null
    const r = el.getBoundingClientRect()
    return { top: Math.round(r.top), bottom: Math.round(r.bottom), left: Math.round(r.left), right: Math.round(r.right) }
  }
  const gr = g && g.getBoundingClientRect()
  return {
    pos: f.getAttribute('data-phone-pos'),
    box: rect(f),
    field: rect(f.querySelector('textarea')),
    send: rect(f.querySelector('button[type=submit]')),
    grip: gr ? { cx: Math.round(gr.left + gr.width / 2), cy: Math.round(gr.top + gr.height / 2) } : null,
    screen: { top: Math.round(vv.offsetTop), left: Math.round(vv.offsetLeft), bottom: Math.round(vv.offsetTop + vv.height), right: Math.round(vv.offsetLeft + vv.width), scale: Math.round(vv.scale * 1000) / 1000 },
    vh: innerHeight,
  }
})

/* fully on the screen: 1 px for the rounding */
const onScreen = (f) => Boolean(f && f.box.top >= f.screen.top - 1 && f.box.bottom <= f.screen.bottom + 1
  && f.box.left >= f.screen.left - 1 && f.box.right <= f.screen.right + 1)

/** A finger drag from the grip to the bottom middle of the screen. */
async function dragToBottom(p) {
  const f = await facts(p)
  const a = { x: f.grip.cx, y: f.grip.cy }
  /* clientX/Y are layout px; the touchscreen takes screen px */
  const toScreen = (x, y) => ({ x: (x - f.screen.left) * f.screen.scale, y: (y - f.screen.top) * f.screen.scale })
  const from = toScreen(a.x, a.y)
  const to = { x: PIXEL.width / 2, y: PIXEL.height - 20 }
  /* off the bottom first, so the drop is a real move to the bottom */
  const mid = { x: PIXEL.width / 2, y: PIXEL.height * 0.25 }
  await p.touchscreen.touchStart(from.x, from.y)
  for (const [s, e] of [[from, mid], [mid, to]]) {
    for (let i = 1; i <= 10; i++) {
      await p.touchscreen.touchMove(s.x + ((e.x - s.x) * i) / 10, s.y + ((e.y - s.y) * i) / 10)
      await sleep(16)
    }
  }
  await p.touchscreen.touchEnd()
  return stable(() => facts(p))
}

/** The menu's "Move to <pos>"; taps the grip again when a tap was lost. */
async function moveTo(p, pos) {
  for (let i = 0; i < 4; i++) {
    if (!(await p.$('[data-testid=omnibox-grip-menu]'))) await p.tap('[data-testid=omnibox-grip]')
    const item = await p.waitForSelector(`[data-testid=omnibox-grip-menu] [data-pos=${pos}]`, { timeout: 2000 }).catch(() => null)
    if (item) {
      await item.tap()
      break
    }
  }
  return stable(() => facts(p))
}

async function toChannel(p) {
  await settle(p)
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => Boolean(document.querySelector('#__nuxt')?.__vue_app__), { timeout: NAV_TIMEOUT })
  await p.click('[data-testid=sidebar-tab-channels]')
  await p.waitForSelector('#sidebar-panel-channels .nav-item', { visible: true, timeout: NAV_TIMEOUT })
  await p.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
  await p.waitForSelector('[data-testid=omnibox-grip]', { timeout: NAV_TIMEOUT })
  return stable(() => facts(p))
}

async function newPhone(browser) {
  const p = await browser.newPage()
  await p.setViewport(PIXEL)
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => { try { localStorage.removeItem('spool.omnibox-phone-pos') } catch { /* denied */ } })
  return p
}

async function pixel(browser) {
  const p = await newPhone(browser)
  await toChannel(p)
  const cdp = await p.createCDPSession()

  const zoom = async (scale) => {
    await cdp.send('Emulation.setPageScaleFactor', { pageScaleFactor: scale })
    await p.evaluate(() => window.scrollTo(0, 0))
    await sleep(300)
    return stable(() => facts(p))
  }

  /* 1: a zoom asked for, at the page's top as in the owner's screenshot */
  const f1 = await zoom(ZOOM)
  ok(`412px 1 a zoom (x${ZOOM}) does not take; the box lies fully on the screen`,
    Boolean(f1 && f1.screen.scale === 1 && onScreen(f1)), f1)

  /* 2 + 3: the two ways to the bottom, the zoom asked for again after each */
  await moveTo(p, 'top')
  await dragToBottom(p)
  const f2 = await zoom(ZOOM)
  ok('412px 2 a drag to the bottom lands on the screen', Boolean(f2 && f2.pos === 'bottom' && onScreen(f2)), f2)
  await zoom(1)
  await moveTo(p, 'top')
  await moveTo(p, 'bottom')
  const f3 = await zoom(ZOOM)
  ok('412px 3 "Move to bottom" lands on the screen', Boolean(f3 && f3.pos === 'bottom' && onScreen(f3)), f3)

  await cdp.send('Emulation.setPageScaleFactor', { pageScaleFactor: 1 })
  await p.close()
}

/* 4: the page and its scripts (the client head renders the meta again)
   served with the meta's zoom limit cut out; a runtime edit of the meta does
   not lift Chrome's limit */
async function forcedZoom(browser) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  /* the PWA's worker would serve the page from its cache, past the cut */
  await p.setBypassServiceWorker(true)
  let cut = 0
  await p.setRequestInterception(true)
  p.on('request', async (req) => {
    if (!['document', 'script'].includes(req.resourceType())) return req.continue()
    try {
      const res = await fetch(req.url(), { headers: req.headers() })
      const text = await res.text()
      const body = text.replace(/maximum-scale=1, user-scalable=no, /g, '')
      if (body !== text) cut++
      await req.respond({ status: res.status, contentType: res.headers.get('content-type') || 'text/html', body })
    } catch {
      await req.continue()
    }
  })
  await p.setViewport(PIXEL)
  await p.goto(`${server.base}/`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => { try { localStorage.removeItem('spool.omnibox-phone-pos') } catch { /* denied */ } })
  await toChannel(p)
  const cdp = await p.createCDPSession()
  await cdp.send('Emulation.setPageScaleFactor', { pageScaleFactor: ZOOM })
  await p.evaluate(() => window.scrollTo(0, 0))
  await sleep(300)
  const f4 = await stable(() => facts(p))
  ok(`412px 4 forced zoom x${ZOOM}: the box's bottom is still on the screen`,
    Boolean(cut > 0 && f4 && f4.screen.scale > 1 && f4.box.bottom <= f4.screen.bottom + 1 && f4.box.top >= f4.screen.top), { cut, ...f4 })
  await ctx.close()
}

async function insetPhone(browser) {
  const p = await newPhone(browser)
  const cdp = await p.createCDPSession()
  await cdp.send('Emulation.setSafeAreaInsetsOverride', { insets: { top: 0, bottom: INSET, left: 0, right: 0 } })
  await toChannel(p)
  const above = (f) => Boolean(f && f.field && f.send && f.field.bottom <= f.vh - INSET && f.send.bottom <= f.vh - INSET)
  await moveTo(p, 'top')
  const f5a = await moveTo(p, 'bottom')
  ok(`412px +${INSET}px inset 5a "Move to bottom": on the screen, the field and Send above the inset`,
    Boolean(f5a && f5a.pos === 'bottom' && onScreen(f5a) && above(f5a)), f5a)
  await moveTo(p, 'top')
  const f5b = await dragToBottom(p)
  ok(`412px +${INSET}px inset 5b a drag to the bottom: on the screen, the field and Send above the inset`,
    Boolean(f5b && f5b.pos === 'bottom' && onScreen(f5b) && above(f5b)), f5b)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  await pixel(browser)
  await forcedZoom(browser)
  await insetPhone(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
