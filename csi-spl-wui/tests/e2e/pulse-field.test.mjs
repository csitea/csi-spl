// Spec 111 section 12 (SPL-6140, owner HUM-10 t1 594bf36a): the theme's
// pulsating colour field behind /blog and /login. In a fresh, signed-out
// browser context:
//   (a) /blog and /login carry the field (canvas[data-test=pulse-field]),
//       aria-hidden, pointer-events none, behind the content (z-index -1):
//       the blog headline and the sign-in card's help link are still what a
//       click hits (the mock bundle's card has links, not buttons); its
//       frame loop runs; its painted pixels lie on the CURRENT theme's
//       accent -> accent-2 -> warn gradient, and after a theme switch on the
//       new theme's (the old one's gradient is the control: it must not
//       match); no sideways scroll; at 1280x800 dark and 390x844 light;
//   (b) /reset-password (same sign-in layout, another page) and /, where it
//       does not land on /login, carry no field and load no field chunk;
//   (c) under prefers-reduced-motion: reduce the field draws a still frame
//       and runs no frame loop (its frame count stays 0 over 30 of the
//       page's own animation frames).
//
// Run:
//   pnpm run test:e2e pulse-field
//   BASE_URL=<generated bundle> pnpm run test:e2e pulse-field
//   SHOT_DIR=<dir> ... also writes a screenshot per page, theme and width
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
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

/** A fresh signed-out page; `chunks` collects every script URL it loads. */
async function freshPage(browser, { width, height, theme, reduced }) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height })
  if (reduced) await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'reduce' }])
  if (theme === 'light') await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool-theme', 'light') } catch { /* none */ } })
  const chunks = []
  p.on('response', (r) => { if (r.request().resourceType() === 'script') chunks.push(r.url()) })
  return { ctx, p, chunks }
}

/** The share of opaque painted pixels that lie on a token gradient (accent -> accent-2 -> warn). */
function onGradient(p, tokens) {
  return p.evaluate((tokens) => {
    const c = document.querySelector('[data-test=pulse-field]')
    const css = getComputedStyle(document.documentElement)
    const hex = (s) => { const m = /#([0-9a-f]{6})/i.exec(s); return m ? [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16)) : null }
    const stops = (tokens || ['--color-accent', '--color-accent-2', '--color-warn'].map((t) => css.getPropertyValue(t))).map(hex)
    if (!c || stops.some((s) => !s)) return { share: 0, painted: 0, stops: tokens }
    const seg = (q, a, b) => {
      const ab = a.map((v, i) => b[i] - v)
      const len = ab.reduce((s, v) => s + v * v, 0) || 1
      const t = Math.max(0, Math.min(1, q.reduce((s, v, i) => s + (v - a[i]) * ab[i], 0) / len))
      return Math.hypot(...q.map((v, i) => v - (a[i] + ab[i] * t)))
    }
    const data = c.getContext('2d').getImageData(0, 0, c.width, c.height).data
    let painted = 0
    let near = 0
    for (let i = 0; i < data.length; i += 4 * 7) {
      if (data[i + 3] < 100) continue
      painted++
      const q = [data[i], data[i + 1], data[i + 2]]
      if (Math.min(seg(q, stops[0], stops[1]), seg(q, stops[1], stops[2])) < 24) near++
    }
    return { share: painted ? near / painted : 0, painted, stops: stops.map(String) }
  }, tokens)
}

/** Wait for n of the page's own animation frames, then read the field's frame count. */
const framesAfter = (p, n) => p.evaluate((n) => new Promise((resolve) => {
  let left = n
  const tick = () => (--left <= 0 ? resolve(document.querySelector('[data-test=pulse-field]')?.pulseFrames ?? null) : requestAnimationFrame(tick))
  requestAnimationFrame(tick)
}), n)

const hitIs = (p, sel) => p.$eval(sel, (el) => {
  el.scrollIntoView({ block: 'center' })
  const r = el.getBoundingClientRect()
  const hit = document.elementFromPoint(r.left + r.width / 2, r.top + Math.min(r.height / 2, 10))
  return Boolean(hit && (hit === el || el.contains(hit)))
}).catch(() => false)

const PAGES = [
  { route: '/blog', ready: '[data-test=blog-page] main h1', hit: '[data-test=blog-page] main h1' },
  { route: '/login', ready: '[data-test=login-front-card]', hit: '[data-test=login-front-card] [data-test=login-help]' },
]

async function fieldPage(browser, server, page, size, theme) {
  const label = `${page.route} ${size.width}x${size.height} ${theme}`
  const { ctx, p } = await freshPage(browser, { ...size, theme })
  await p.goto(server.base + page.route, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(page.ready, { visible: true, timeout: 15000 }).catch(() => null)
  const canvas = await p.waitForSelector('[data-test=pulse-field][data-state=running]', { timeout: 15000 }).catch(() => null)
  ok(`${label}: (a) the field is there and running`, Boolean(canvas))
  const look = await p.$eval('[data-test=pulse-field]', (el) => { const s = getComputedStyle(el); return { hidden: el.getAttribute('aria-hidden'), pe: s.pointerEvents, z: s.zIndex, pos: s.position } }).catch(() => null)
  ok(`${label}: aria-hidden, pointer-events none, fixed behind (z -1)`, Boolean(look && look.hidden === 'true' && look.pe === 'none' && look.z === '-1' && look.pos === 'fixed'), look)
  const f0 = await framesAfter(p, 1)
  const f1 = await p.waitForFunction((f0) => (document.querySelector('[data-test=pulse-field]')?.pulseFrames ?? 0) >= f0 + 3, { timeout: 10000 }, f0 || 0).then(() => true, () => false)
  ok(`${label}: its frame loop runs`, f1, f0)
  ok(`${label}: a click still lands on ${page.hit}`, await hitIs(p, page.hit))
  const g = await onGradient(p)
  ok(`${label}: the painted dashes lie on the theme's accent gradient`, g.painted > 50 && g.share > 0.9, g)
  const wide = await p.evaluate(() => [document.documentElement, document.querySelector('.blog-page'), document.querySelector('.login-body')].filter(Boolean).map((e) => e.scrollWidth - e.clientWidth))
  ok(`${label}: no sideways scroll`, wide.every((d) => d <= 0), wide)
  if (SHOT_DIR) await p.screenshot({ path: join(SHOT_DIR, `pulse-field${page.route.replace('/', '-')}-${theme}-${size.width}.png`) })
  return { ctx, p, label }
}

/** The theme switch: the colours follow the new theme; the old gradient is the control. */
async function themeSwitch(p, label) {
  const old = await p.evaluate(() => ['--color-accent', '--color-accent-2', '--color-warn'].map((t) => getComputedStyle(document.documentElement).getPropertyValue(t)))
  await p.evaluate(() => document.documentElement.setAttribute('data-theme', 'light-green'))
  await framesAfter(p, 10)
  await p.waitForFunction((f) => (document.querySelector('[data-test=pulse-field]')?.pulseFrames ?? 0) >= f + 2, { timeout: 10000 }, await framesAfter(p, 1) || 0).catch(() => null)
  const now = await onGradient(p)
  ok(`${label}: after a switch to light-green the dashes take its gradient`, now.painted > 50 && now.share > 0.9, now)
  const stale = await onGradient(p, old)
  ok(`${label}: control: they no longer match the old theme's gradient`, stale.share < 0.5, stale)
}

async function absent(browser, server, route, ready) {
  const { ctx, p, chunks } = await freshPage(browser, { width: 1280, height: 800, theme: 'dark' })
  await p.goto(server.base + route, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const landed = new URL(p.url()).pathname
  if (/^\/(login|blog)/.test(landed)) {
    console.log(`  (${route} lands on ${landed}, a field page: its absence check does not apply)`)
  } else {
    await p.waitForSelector(ready, { timeout: 15000 }).catch(() => null)
    await framesAfter(p, 10)
    ok(`(b) ${route} (landed ${landed}) has no field`, (await p.$('[data-test=pulse-field]')) === null)
    /* the chunk name is a hash: read each loaded script for the field's own marker */
    const loaded = []
    for (const u of chunks) if ((await fetch(u).then((r) => r.text(), () => '')).includes('pulseFrames')) loaded.push(u)
    ok(`(b) ${route} loads no field chunk (of ${chunks.length} scripts)`, chunks.length > 0 && loaded.length === 0, loaded)
  }
  await ctx.close()
}

async function reducedMotion(browser, server, route, ready) {
  const { ctx, p } = await freshPage(browser, { width: 1280, height: 800, theme: 'dark', reduced: true })
  await p.goto(server.base + route, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(ready, { visible: true, timeout: 15000 }).catch(() => null)
  const still = await p.waitForSelector('[data-test=pulse-field][data-state=static]', { timeout: 15000 }).catch(() => null)
  ok(`(c) ${route} reduced motion: the field is a still frame`, Boolean(still))
  const frames = await framesAfter(p, 30)
  ok(`(c) ${route} reduced motion: no frame loop ran (0 frames over 30 page frames)`, frames === 0, frames)
  const g = await onGradient(p)
  ok(`(c) ${route} reduced motion: the still frame is drawn`, g.painted > 50, g.painted)
  await ctx.close()
}

const server = await startServer()
const browser = await launch()
try {
  for (const page of PAGES) {
    for (const [size, theme] of [[{ width: 1280, height: 800 }, 'dark'], [{ width: 390, height: 844 }, 'light']]) {
      const { ctx, p, label } = await fieldPage(browser, server, page, size, theme)
      if (theme === 'dark') await themeSwitch(p, label)
      await ctx.close()
    }
    if (SHOT_DIR) {
      for (const [size, theme] of [[{ width: 390, height: 844 }, 'dark'], [{ width: 1280, height: 800 }, 'light']]) {
        const { ctx } = await fieldPage(browser, server, page, size, theme)
        await ctx.close()
      }
    }
    await reducedMotion(browser, server, page.route, page.ready)
  }
  await absent(browser, server, '/reset-password', '.login-card')
  await absent(browser, server, '/', 'body')
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `pulse-field: ${failed} FAILED` : `pulse-field: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
