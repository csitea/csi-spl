// SPL-3785 slice 6 (owner pick B, t1 c3e53990 poll 12414c26; the section
// strip panel file in csi-spl-doc/specs/043-spool-wui-mobile, section 5): on a
// phone the section strip slides away while the reader scrolls a pane down,
// gives its room to the pane, and comes back on a scroll up; it comes back on
// Back too, and a pane that scrolls by itself (a feed jumping to its newest
// row) never hides it.
//
// The routes are read off src/pages/** (tests/e2e/lib/page-routes.mjs) plus
// the drill-downs, as section-strip-every-level does; every one whose pane
// scrolls is checked: a scroll by script leaves the strip painted; a wheel
// down hides it (data-mobile-strip-hidden=1, not painted, inert) and the pane
// grows up into its room; a wheel up paints it again at the same y. A route
// with nothing to scroll in the mock tenant is listed, not counted. Then a
// tapped topic scrolled down and Back: the strip is painted. 390 px dark with
// motion, 360 px light with prefers-reduced-motion (no slide: transition 0s).
//
//   BASE_URL=<generated mock bundle> node tests/e2e/section-strip-scroll-hide.test.mjs
import { createRequire } from 'node:module'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { dirname, join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { pageRoutes } from './lib/page-routes.mjs'

const PAGES_DIR = join(dirname(fileURLToPath(import.meta.url)), '../../src/pages')
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* a sample per route param, from utils/mock-data.mjs (as section-strip-every-level) */
const TOPIC = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const MSG = '11111111-1111-4111-8111-111111111111'
const SAMPLE = { name: 'lobby', peer: 'HUM-2', task_id: TOPIC, id: '', ref: 'v1.0.0' }
const ID_BY_DIR = { agents: 'CLE-07', boxes: 'box-desk', people: 'HUM-2', m: MSG, goals: 'G-1' }
function fill(path) {
  return path.replace(/\/([^/]+)\/:(\w+)/g, (_, dir, param) => `/${dir}/${encodeURIComponent((param === 'id' ? ID_BY_DIR[dir] : SAMPLE[param]) || 'x')}`)
}
const walked = pageRoutes(PAGES_DIR).filter((r) => r.layout === 'default').map((r) => fill(r.path))
const ROUTES = [...new Set([...walked, `/channel/lobby?topic=${TOPIC}`, `/t/${TOPIC}?in=${MSG}`, '/help/getting-started'])]

/* the strip, the shell's flag, and the pane that scrolls most (marked data-e2e-scroller) */
const read = (p) => p.evaluate(() => {
  const strip = document.querySelector('[data-testid=sidebar-rail]')
  const nav = document.querySelector('.spool-shell > .sidebar')
  const shell = document.querySelector('.spool-shell')
  let painted = false
  let top = null
  if (strip) {
    const r = strip.getBoundingClientRect()
    const cs = getComputedStyle(strip)
    if (cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0 && r.bottom > 0) {
      const hit = document.elementFromPoint(Math.min(r.left + r.width / 2, innerWidth - 1), r.top + r.height / 2)
      painted = Boolean(hit) && (strip.contains(hit) || hit.contains(strip))
      top = Math.round(r.top)
    }
  }
  const panes = [...document.querySelectorAll('.spool-shell > .spool-main *, .spool-shell > .topic *')].filter((e) => {
    if (!e.getClientRects().length || e.closest('[role=dialog], dialog')) return false
    const oy = getComputedStyle(e).overflowY
    return (oy === 'auto' || oy === 'scroll') && e.scrollHeight - e.clientHeight >= 200 && e.clientHeight >= 150
  })
  document.querySelectorAll('[data-e2e-scroller]').forEach((e) => e.removeAttribute('data-e2e-scroller'))
  const pane = panes.sort((a, b) => b.clientHeight - a.clientHeight)[0]
  pane?.setAttribute('data-e2e-scroller', '1')
  const pr = pane?.getBoundingClientRect()
  return {
    shell: Boolean(shell),
    level: shell?.getAttribute('data-mobile-level'),
    hidden: shell?.getAttribute('data-mobile-strip-hidden') ?? null,
    inert: Boolean(nav?.inert),
    slide: nav ? getComputedStyle(nav).transitionDuration : null,
    painted,
    top,
    pane: pane ? { x: Math.round(pr.left + pr.width / 2), y: Math.round(pr.top + pr.height / 2), top: Math.round(pr.top), sy: Math.round(pane.scrollTop) } : null,
  }
})

async function settle(p, max = 8000) {
  const end = Date.now() + max
  let prev = ''
  while (Date.now() < end) {
    const s = await read(p)
    const key = JSON.stringify(s)
    if (s.shell && key === prev) return s
    prev = key
    await sleep(200)
  }
  return read(p)
}

const wheel = async (p, at, dy) => {
  await p.mouse.move(at.x, at.y)
  for (let i = 0; i < 3; i++) { await p.mouse.wheel({ deltaY: dy / 3 }); await sleep(60) }
  await sleep(500)
}

const flat = []
const srv = await startServer()
const browsers = []
try {
  /* one browser per width: the wheel is real input, and a background tab of
     a shared browser never gets it (Input.dispatchMouseEvent times out) */
  await Promise.all([[390, 'dark', 'no-preference'], [360, 'light', 'reduce']].map(async ([width, scheme, motion]) => {
    const tag = `${width}px ${scheme} motion=${motion}`
    const browser = await launch()
    browsers.push(browser)
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }, { name: 'prefers-reduced-motion', value: motion }])
    await p.evaluateOnNewDocument(() => localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })))
    await p.setViewport({ width, height: 844, isMobile: true, hasTouch: true })
    /* reduced motion: no slide (the app's reduce rule leaves 1e-05s) */
    const slideOk = (s) => motion === 'reduce' ? parseFloat(s.slide) < 0.01 : parseFloat(s.slide) >= 0.1
    for (const route of ROUTES) {
      await p.goto(`${srv.base}${route}`, { waitUntil: 'networkidle2' }).catch(() => null)
      const s0 = await settle(p)
      if (!s0.pane || !s0.painted) { flat.push(`${tag} ${route}`); continue }
      await p.evaluate(() => { document.querySelector('[data-e2e-scroller]').scrollTop += 150 })
      await sleep(500)
      const byScript = await read(p)
      await p.evaluate(() => { document.querySelector('[data-e2e-scroller]').scrollTop = 0 })
      await sleep(500)
      await wheel(p, s0.pane, 600)
      const down = await read(p)
      await wheel(p, s0.pane, -200)
      const up = await read(p)
      ok(`${tag} ${route}: a scroll by script leaves the strip painted`, byScript.painted && byScript.hidden === null, byScript)
      ok(`${tag} ${route}: wheel down: strip away (hidden=1, not painted, inert), the pane takes its room${motion === 'reduce' ? ', no slide' : ''}`,
        down.hidden === '1' && !down.painted && down.inert && down.pane && down.pane.top < s0.pane.top - 30 && slideOk(down), { before: s0.pane.top, ...down })
      ok(`${tag} ${route}: wheel up: the strip is painted again at the same y`, up.painted && up.hidden === null && !up.inert && up.top === s0.top, { before: s0.top, ...up })
    }
    /* Back brings it back: Help, a tapped help page scrolled down, then Back */
    await p.goto(`${srv.base}/help`, { waitUntil: 'networkidle2' })
    await settle(p)
    const href = await p.evaluate(() => { const a = document.querySelector('.spool-main a[href*="/help/"]'); a?.click(); return a?.getAttribute('href') ?? null })
    const h2 = await settle(p)
    if (h2.pane) await wheel(p, h2.pane, 600)
    const away = await read(p)
    await p.goBack().catch(() => null)
    const back = await settle(p)
    ok(`${tag} a tapped help page (${href}) scrolled down: away; then Back: the strip is painted`, Boolean(h2.pane) && away.hidden === '1' && back.painted && back.hidden === null, { away: away.hidden, ...back })
    await p.close()
  }))
} finally {
  await Promise.all(browsers.map((b) => b.close()))
  await srv.stop()
}

for (const f of flat) console.log(`  FLAT ${f}: nothing scrolls in the mock tenant, not counted`)
const failed = results.filter((r) => !r.ok)
console.log(`\nsection-strip-scroll-hide: ${results.length - failed.length}/${results.length} passed (${ROUTES.length} routes x 2; ${flat.length} with nothing to scroll)`)
process.exit(failed.length || !results.length ? 1 : 0)
