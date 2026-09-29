// The sign-in / reset-password card is centred in the viewport.
//
// The card (.login-card) must sit on the viewport centre, measured from its
// getBoundingClientRect in headless Chrome — a real geometry probe, not a CSS
// grep. Horizontal centring broke when 0c8a68d6 turned the login body from
// `place-items: center` (both axes) into a column flex with only the vertical
// axis centred, leaving the fixed-width card pinned to the left. This gate is
// the control: it FAILS on that build and passes once the card is centred.
//
//   node tests/e2e/login-centred.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/login-centred.test.mjs
//
// Starts `nuxi dev` with NUXT_PUBLIC_USE_MOCK=1 when BASE_URL is unset.
// Uses puppeteer-core (a committed devDependency); a missing driver is a
// failure, never a silent skip.
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const CHROME = process.env.CHROME_PATH || '/usr/bin/google-chrome'
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 30000)
const TOL = 2 // px: the tolerance the brief sets for centre vs centre

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// Desktop + tablet: the card is centred on both axes of the viewport.
// The phone width only needs horizontal centring (a keyboard top-aligns it).
const DESKTOP = [
  { name: '1440x900', width: 1440, height: 900, axes: 'both' },
  { name: '1024x768', width: 1024, height: 768, axes: 'both' },
]
const PHONE = { name: '390x844', width: 390, height: 844, axes: 'x' }
// The keyboard shrinks the visual viewport; a short phone stands in for it.
// The card no longer fits, so `safe center` top-aligns it (the top sits at the
// body's content top, clear of the bar, and the body scrolls) instead of
// centring it into the bar / off the top edge.
const PHONE_KB = { name: '390x300-kb', width: 390, height: 300 }
const THEMES = ['dark', 'light']
const ROUTES = [
  { path: '/login', wait: '.login-card' },
  { path: '/reset-password', wait: '[data-test=reset-password]' },
]

const results = []
const ok = (name, extra) => {
  results.push({ name, ok: true })
  console.log(`  OK   ${name}${extra ? ' ' + extra : ''}`)
}
const fail = (name, msg) => {
  results.push({ name, ok: false, msg })
  console.log(`  FAIL ${name}: ${msg}`)
}

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      let href = spec
      if (!spec.startsWith('file:') && !spec.includes('://')) {
        try { href = pathToFileURL(require.resolve(spec)).href }
        catch { if (spec.startsWith('/')) href = pathToFileURL(spec).href }
      }
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      if (typeof puppeteer.launch === 'function') return puppeteer
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable (a committed devDependency; run pnpm install)')
}

// The card's rect, the viewport, and the login-body content region — all read
// after the theme is set and the layout settled.
const MEASURE = (waitSel) => `(() => {
  const card = document.querySelector('.login-card')
  const body = document.querySelector('.login-body')
  if (!card || !body) return { ready: false }
  const c = card.getBoundingClientRect()
  const bs = getComputedStyle(body)
  const bTop = body.getBoundingClientRect().top + parseFloat(bs.paddingTop || '0')
  return {
    ready: !!document.querySelector(${JSON.stringify(waitSel)}),
    cx: c.left + c.width / 2,
    cy: c.top + c.height / 2,
    top: c.top,
    innerWidth: window.innerWidth,
    innerHeight: window.innerHeight,
    bodyContentTop: bTop,
  }
}) ()`

async function measure(page, route) {
  const t0 = Date.now()
  let m
  while (Date.now() - t0 < NAV_TIMEOUT) {
    m = await page.evaluate(new Function('return ' + MEASURE(route.wait)))
    if (m?.ready) break
    await sleep(150)
  }
  if (!m?.ready) throw new Error(`selector ${route.wait} not found`)
  return m
}

async function withCard(page, vp, theme, route) {
  await page.setViewport({ width: vp.width, height: vp.height, isMobile: vp.width < 800, hasTouch: vp.width < 800 })
  await page.goto(`${SERVER}${route.path}`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
  await page.waitForSelector(route.wait, { timeout: NAV_TIMEOUT })
  await page.evaluate((t) => {
    document.documentElement.setAttribute('data-theme', t)
    try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ }
  }, theme)
  await sleep(120)
  return measure(page, route)
}

let SERVER = ''

;(async () => {
  const puppeteer = await loadPuppeteer()
  const server = await startServer()
  SERVER = server.base
  console.log(`login-centred E2E against ${server.base}`)
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: CHROME_LAUNCH_ARGS,
  })
  try {
    const page = await browser.newPage()
    for (const theme of THEMES) {
      for (const route of ROUTES) {
        // Desktop + tablet: both axes on the viewport centre.
        for (const vp of DESKTOP) {
          const label = `${theme} ${vp.name} ${route.path}`
          try {
            const m = await withCard(page, vp, theme, route)
            const dx = m.cx - m.innerWidth / 2
            const dy = m.cy - m.innerHeight / 2
            const detail = `dx=${dx.toFixed(1)} dy=${dy.toFixed(1)}`
            if (Math.abs(dx) <= TOL && Math.abs(dy) <= TOL) ok(label, detail)
            else fail(label, `card off viewport centre (${detail}, tol ${TOL})`)
          } catch (e) { fail(label, e.message) }
        }
        // Phone: horizontal on the viewport centre; vertical is the frame's own.
        {
          const vp = PHONE
          const label = `${theme} ${vp.name} ${route.path}`
          try {
            const m = await withCard(page, vp, theme, route)
            const dx = m.cx - m.innerWidth / 2
            if (Math.abs(dx) <= TOL) ok(label, `dx=${dx.toFixed(1)}`)
            else fail(label, `card off horizontal centre (dx=${dx.toFixed(1)}, tol ${TOL})`)
          } catch (e) { fail(label, e.message) }
        }
      }
    }
    // Keyboard open (a short phone): still centred horizontally, and top-aligned
    // — the card's top sits at the body's content top, clear of the bar.
    for (const theme of THEMES) {
      const label = `${theme} ${PHONE_KB.name} /login`
      try {
        const m = await withCard(page, PHONE_KB, theme, ROUTES[0])
        const dx = m.cx - m.innerWidth / 2
        const topGap = m.top - m.bodyContentTop
        const centredX = Math.abs(dx) <= TOL
        const topAligned = topGap >= -TOL && topGap <= TOL
        if (centredX && topAligned) ok(label, `dx=${dx.toFixed(1)} topGap=${topGap.toFixed(1)}`)
        else fail(label, `dx=${dx.toFixed(1)} (tol ${TOL}), topGap=${topGap.toFixed(1)} (want ~0)`)
      } catch (e) { fail(label, e.message) }
    }
  } finally {
    await browser.close().catch(() => {})
    await server.stop()
  }

  const failed = results.filter((r) => !r.ok).length
  console.log(`\n${results.length - failed}/${results.length} checks passed (${failed} failed)`)
  process.exit(failed === 0 ? 0 : 1)
})().catch((e) => {
  console.error(e)
  process.exit(1)
})
