// The reset-password card is centred in the viewport, and the sign-in page
// is the front page, look A "Live channel" (spec 116 T3).
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
//
// Look A (/login): the logo shows, the channel hero sits beside the compact
// card on desktop and above it on a phone (390), and no link of the page
// (the frame's Blog footer, the card's help row) ever lies over a "Try the
// demo" button, at 390x844, 1440x900, 2560x1600 and two short desktops
// (1280x800, 1440x640: where the card outgrows the room). The overlap check
// is the control: the absolute footer drew Blog on the demo buttons
// (c-002 msg 673dbb44) and FAILS it. Under prefers-reduced-motion: reduce
// nothing is animating and every channel post shows.
// Spec 116 T4: the features row (1..6 feature-post cards) is in the served
// /login HTML itself (prerendered, not fetched after hydration) and shows
// under the sign-in card at every look A size.
//   SHOT_DIR=/var/tmp/x ... also writes a screenshot per look A case
import { join } from 'node:path'
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
// /login is look A now (its card sits beside the hero, below): see LOOK_A.
const ROUTES = [
  { path: '/reset-password', wait: '[data-test=reset-password]' },
]
const SHOT_DIR = process.env.SHOT_DIR || ''

// Look A: the sizes the brief names, plus the short desktops that overflow.
const LOOK_A = [
  { name: '390x844', width: 390, height: 844, phone: true },
  { name: '1440x900', width: 1440, height: 900 },
  { name: '2560x1600', width: 2560, height: 1600 },
  { name: '1280x800', width: 1280, height: 800 },
  { name: '1440x640', width: 1440, height: 640 },
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

// The page's geometry: logo, hero, card, every visible link, every demo button.
const LOOK_A_MEASURE = `(() => {
  const box = (el) => { if (!el) return null; const r = el.getBoundingClientRect(); return { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height } }
  const shown = (el) => { const b = box(el); return Boolean(b && b.w > 0 && b.h > 0 && getComputedStyle(el).visibility !== 'hidden') }
  const logo = document.querySelector('[data-test=login-front-logo] img')
  const links = [...document.querySelectorAll('a[href]')].filter((a) => !a.closest('.login-bar') && !a.closest('[data-test=demo-intro]') && shown(a))
  return {
    logo: shown(logo) ? box(logo) : null,
    logoLoaded: Boolean(logo && logo.complete && logo.naturalWidth > 0),
    hero: box(document.querySelector('[data-test=login-front-hero]')),
    card: box(document.querySelector('[data-test=login-front-card]')),
    links: links.map((a) => ({ test: a.dataset.test || a.getAttribute('href'), ...box(a) })),
    features: [...document.querySelectorAll('[data-test=login-feature]')].filter(shown).map(box),
    demo: [...document.querySelectorAll('[data-test^=demo-try-]')].filter(shown).map((b) => ({ test: b.dataset.test, ...box(b) })),
    xScroll: document.documentElement.scrollWidth > window.innerWidth + 1,
  }
})()`
const hits = (a, b) => a.l < b.r && b.l < a.r && a.t < b.b && b.t < a.b

async function lookAPage(browser, vp, theme, reduce) {
  const p = await browser.newPage()
  await p.setViewport({ width: vp.width, height: vp.height, isMobile: Boolean(vp.phone), hasTouch: Boolean(vp.phone) })
  await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: reduce ? 'reduce' : 'no-preference' }])
  await p.setRequestInterception(true)
  // the demo intro only shows while GET /v1/demo answers 200 (login-demo-intro)
  p.on('request', (req) => {
    const path = new URL(req.url()).pathname
    if (path.endsWith('/api/v1/auth/providers')) {
      return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ providers: ['google', 'facebook', 'microsoft'], native: true }) })
    }
    if (path.endsWith('/v1/demo')) {
      return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ workspace: 'demo', max_live: 9, max_stay: '3h' }) })
    }
    return req.continue()
  })
  await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
  await p.goto(`${SERVER}/login?redirect=%2F`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((t) => document.documentElement.setAttribute('data-theme', t), theme)
  await p.waitForSelector('[data-test^=demo-try-]', { visible: true, timeout: NAV_TIMEOUT })
  return p
}

async function lookA(browser) {
  // 116-T4: the cards come with the page's HTML, before any script runs
  try {
    const html = await (await fetch(`${SERVER}/login`)).text()
    const n = (html.match(/data-test="login-feature"/g) || []).length
    if (n >= 1 && n <= 6) ok('/login HTML features', `${n} cards in the served HTML`)
    else fail('/login HTML features', `${n} cards in the served HTML, want 1..6`)
  } catch (e) { fail('/login HTML features', e.message) }
  for (const theme of THEMES) {
    for (const vp of LOOK_A) {
      const label = `look A ${theme} ${vp.name} /login`
      let p
      try {
        p = await lookAPage(browser, vp, theme, false)
        await sleep(300)
        const m = await p.evaluate(new Function('return ' + LOOK_A_MEASURE))
        if (m.logo && m.logoLoaded) ok(`${label} logo`)
        else fail(`${label} logo`, `logo not shown (${JSON.stringify(m.logo)}, loaded ${m.logoLoaded})`)
        if (!m.hero || !m.card) fail(`${label} layout`, 'no hero or no card')
        else if (vp.phone) {
          if (m.card.t >= m.hero.b - 1) ok(`${label} layout`, 'card under the channel')
          else fail(`${label} layout`, `card top ${m.card.t} above the hero bottom ${m.hero.b}`)
        } else if (m.card.l >= m.hero.r - 1 && m.card.w <= 400) ok(`${label} layout`, `card ${Math.round(m.card.w)} px beside the channel`)
        else fail(`${label} layout`, `card ${JSON.stringify(m.card)} not beside hero ${JSON.stringify(m.hero)}`)
        if (m.xScroll) fail(`${label} x-scroll`, 'the page scrolls sideways')
        if (!m.features.length || m.features.length > 6) fail(`${label} features`, `${m.features.length} feature cards, want 1..6`)
        else if (m.card && m.features.some((f) => f.t < m.card.b - 1)) fail(`${label} features`, 'a feature card lies above the sign-in card bottom')
        else ok(`${label} features`, `${m.features.length} cards under the card`)
        if (!m.demo.length) fail(`${label} overlap`, 'no demo button shown')
        else {
          const over = []
          for (const l of m.links) for (const d of m.demo) if (hits(l, d)) over.push(`${l.test} on ${d.test}`)
          if (over.length) fail(`${label} overlap`, over.join(', '))
          else ok(`${label} overlap`, `${m.links.length} links clear of ${m.demo.length} demo buttons`)
        }
        // the channel plays about 8 s once; the picture is its still end
        if (SHOT_DIR) { await sleep(9000); await p.screenshot({ path: join(SHOT_DIR, `login-look-a-${vp.name}-${theme}.png`) }) }
      } catch (e) { fail(label, e.message) }
      finally { await p?.close().catch(() => {}) }
    }
  }
  // C5: reduced motion, nothing animates and the finished channel shows
  for (const vp of [LOOK_A[0], LOOK_A[1]]) {
    const label = `look A reduced motion ${vp.name}`
    let p
    try {
      p = await lookAPage(browser, vp, 'dark', true)
      await sleep(300)
      const r = await p.evaluate(() => ({
        running: document.getAnimations().filter((a) => a.playState === 'running').map((a) => `${a.animationName || a.constructor.name} on ${a.effect?.target?.className || '?'}`),
        posts: [...document.querySelectorAll('[data-test=login-front-post]')].filter((el) => getComputedStyle(el).display !== 'none').map((el) => getComputedStyle(el).opacity),
      }))
      if (r.running.length) fail(label, `still animating: ${r.running.join('; ')}`)
      else if (!r.posts.length || r.posts.some((o) => o !== '1')) fail(label, `channel not finished: opacities ${r.posts.join(',')}`)
      else ok(label, `${r.posts.length} posts shown, nothing running`)
    } catch (e) { fail(label, e.message) }
    finally { await p?.close().catch(() => {}) }
  }
}

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
      const label = `${theme} ${PHONE_KB.name} ${ROUTES[0].path}`
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
    await lookA(browser)
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
