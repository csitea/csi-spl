// SPL-1005 (epic SPL-988, owner topic 9b58a27b, 2026-09-27): "Remove the play
// button on the mobile in the middle vertically of the screen, but change the
// button on the bottom right with his icon". This reverses the floating GO of
// SPL-995 answer E on phones:
//   - no round GO at the middle of the right edge, on any page or level
//   - the docked composer's bottom-right Send is the GO: the go (play) icon,
//     accent fill, >= 44 px, "Go / Send"
//   - the dock is on EVERY phone level (the section chooser too) and on pages
//     with no send target (/issues, /events), so `/search` is
//     always reachable; `/search <q>` from the dock opens /search?q= from
//     levels 1, 2 and 3
//   - 1440: no dock, no floating button
// CONTROL: before SPL-1005 the floating button existed and level 1 had no
// dock (the 'no floating GO' and 'level 1 dock' checks fail there).
//
// Run:
//   pnpm run test:e2e:mobile-go-dock
//   BASE_URL=<generated bundle> pnpm run test:e2e:mobile-go-dock   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per step there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The dock, its GO and anything floating at the middle of the right edge. */
function look(p) {
  return p.evaluate(() => {
    const vis = (el) => Boolean(el && el.getClientRects().length > 0 && getComputedStyle(el).visibility !== 'hidden')
    const dock = document.querySelector('form.composer.omnibox--global.composer--dock')
    const go = dock && dock.querySelector('[data-testid=send]')
    const r = go ? go.getBoundingClientRect() : null
    const cs = go ? getComputedStyle(go) : null
    const accent = getComputedStyle(document.documentElement).getPropertyValue('--color-accent').trim()
    const probe = document.createElement('span')
    probe.style.color = accent
    document.body.appendChild(probe)
    const accentRgb = getComputedStyle(probe).color
    probe.remove()
    const W = window.innerWidth, H = window.innerHeight
    /* a button painted at the middle of the right edge (the retired floating GO) */
    const mid = document.elementFromPoint(W - 34, Math.round(H / 2))
    const midBtn = mid && mid.closest('button')
    const dr = dock ? dock.getBoundingClientRect() : null
    return {
      level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
      toggle: [...document.querySelectorAll('[data-test=top-bar-search-toggle]')].filter(vis).length,
      midButton: midBtn ? (midBtn.getAttribute('data-test') || midBtn.getAttribute('data-testid') || midBtn.className) : '',
      dock: vis(dock),
      dockBottom: dr ? Math.round(H - dr.bottom) : null,
      goIcon: go ? (go.querySelector('svg[data-icon]')?.getAttribute('data-icon') || '') : '',
      goLabel: go ? go.getAttribute('aria-label') : '',
      goSize: r ? [Math.round(r.width), Math.round(r.height)] : null,
      goRight: r ? Math.round(W - r.right) : null,
      goBg: cs ? cs.backgroundColor : '',
      accentRgb,
    }
  })
}

async function dockSearch(p, q) {
  const ta = 'form.composer.omnibox--global textarea'
  await p.focus(ta)
  await p.type(ta, `/search ${q}`)
  await p.keyboard.press('Enter')
  for (let i = 0; i < 20; i++) {
    await sleep(250)
    const u = new URL(p.url())
    if (u.pathname.endsWith('/search') && u.searchParams.get('q')) return u.searchParams.get('q')
  }
  const u = new URL(p.url())
  return u.pathname.endsWith('/search') ? (u.searchParams.get('q') || '') : null
}

async function open(browser, vp, path) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
  return { p, errors }
}

const goOk = (l) => Boolean(l.dock && l.goIcon === 'go' && l.goSize && l.goSize[0] >= 44 && l.goSize[1] >= 44
  && l.goBg === l.accentRgb && l.goRight !== null && l.goRight <= 24 && l.dockBottom !== null && Math.abs(l.dockBottom) <= 1)

async function phoneCase(browser, width, height) {
  const tag = `${width}px`
  const vp = { width, height, isMobile: true, hasTouch: true }
  /* every level and a page with no send target (CLE-77853: /settings is a
     modal over the lobby now, the dock yields to it, so it is not a page here) */
  for (const [name, path, want] of [['level 1 (sections)', '/', '1'], ['level 2 channel', '/channel/alerts', '2'], ['issues (no send target)', '/issues', '2'], ['events (no send target)', '/events', '2']]) {
    const { p, errors } = await open(browser, vp, path)
    const l = await look(p)
    if (SHOTS) await p.screenshot({ path: join(SHOTS, `mobile-go-dock-${width}-${path.replace(/\W+/g, '_') || 'root'}.png`) })
    ok(`${tag} ${name}: no floating GO at the middle of the right edge`, l.toggle === 0 && !/search-toggle/.test(l.midButton), { level: l.level, midButton: l.midButton })
    ok(`${tag} ${name}: the dock is at the bottom and its bottom-right button is the accent GO (go icon, >= 44 px)`, l.level === want && goOk(l), l)
    ok(`${tag} ${name}: no page error`, errors.length === 0, errors)
    await p.close()
  }
  /* /search from the dock on levels 1, 2, 3 */
  for (const lv of ['1', '2', '3']) {
    const { p, errors } = await open(browser, vp, lv === '1' ? '/' : '/channel/alerts')
    if (lv === '3') {
      const c = await p.evaluate(() => {
        const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
        const b = el && (el.querySelector('.msg-body') || el)
        const r = b && b.getBoundingClientRect()
        return r ? { x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) } : null
      })
      if (c) await p.touchscreen.tap(c.x, c.y)
      await sleep(700)
    }
    const before = (await look(p)).level
    if (SHOTS && lv === '3') await p.screenshot({ path: join(SHOTS, `mobile-go-dock-${width}-level3.png`) })
    const q = await dockSearch(p, `spl1005l${lv}`)
    ok(`${tag} level ${lv}: '/search <q>' typed in the dock opens /search?q=`, before === lv && q === `spl1005l${lv}`, { before, q, url: p.url() })
    ok(`${tag} level ${lv} search: no page error`, errors.length === 0, errors)
    await p.close()
  }
}

async function desktopCase(browser) {
  for (const path of ['/', '/channel/alerts', '/issues']) {
    const { p, errors } = await open(browser, { width: 1440, height: 900 }, path)
    const l = await look(p)
    ok(`1440px ${path}: no dock and no floating GO`, !l.dock && l.toggle === 0, { dock: l.dock, toggle: l.toggle, midButton: l.midButton })
    ok(`1440px ${path}: no page error`, errors.length === 0, errors)
    await p.close()
  }
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  await (await open(browser, { width: 1440, height: 900 }, '/')).p.close()
  await phoneCase(browser, 360, 740)
  await phoneCase(browser, 390, 844)
  await phoneCase(browser, 820, 1180)
  await desktopCase(browser)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
