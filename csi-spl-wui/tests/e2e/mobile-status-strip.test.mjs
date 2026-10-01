// CLE-77888 (owner, t1 topic 1701ae89): "the last 5mm [strip] at the bottom
// should contain the connectivity icon, the bell icon and the note icon and
// the version icon as they are in the desktop app" - "the bottom bar will get
// as a whole some 5mm upper, but its content should not change".
//
//   phone (390x844, isMobile + hasTouch, touch only):
//     1 the strip is at the very bottom, ~5 mm (20..26 px) tall, full width
//     2 it holds the 4 desktop footer icons: dot, bell, note, version
//     3 the docked composer sits ON it (dock bottom = strip top), its content
//       unchanged (Send / Attach still 44 px), nothing overlaps
//     4 --composer-dock-h = dock + strip, so the panes and the snackbars
//       (CLE-77871, which read it) clear both
//     5 the last card of the feed scrolls clear of the dock and the strip
//     6 tap the note = the desktop note: the chime flips (and back)
//     7 tap the bell = the desktop bell: the alerts switch flips (and back)
//     8 tap the dot opens the connection card; a tap outside closes it
//     9 tap the version opens the version card (the version / commit)
//   desktop (1440x900):
//    10 no strip; the sidebar footer row still has dot, bell, note, version;
//       --composer-dock-h 0
//
// Run:
//   node tests/e2e/mobile-status-strip.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/mobile-status-strip.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per viewport
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const PATH = '/lobby'
const TAP = 44

if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

/** Tap the centre of the first visible element matching `sel`. */
async function tapSel(p, sel) {
  const c = await p.evaluate((sel) => {
    const e = [...document.querySelectorAll(sel)].find((x) => x.getClientRects().length)
    if (!e) return null
    const r = e.getBoundingClientRect()
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
  }, sel)
  if (!c) return false
  await p.touchscreen.tap(Math.round(c.x), Math.round(c.y))
  return true
}

const facts = (p) => p.evaluate(() => {
  const box = (el) => {
    if (!el || !el.getClientRects().length) return null
    const r = el.getBoundingClientRect()
    return { top: Math.round(r.top), bottom: Math.round(r.bottom), left: Math.round(r.left), width: Math.round(r.width), h: Math.round(r.height), w: Math.round(r.width) }
  }
  const strip = document.querySelector('[data-test=status-strip]')
  const dock = document.querySelector('form.composer.composer--dock')
  const q = (sel) => box(strip ? strip.querySelector(sel) : null)
  const root = getComputedStyle(document.documentElement)
  return {
    vw: window.innerWidth,
    vh: window.innerHeight,
    strip: box(strip),
    dock: box(dock),
    health: q('[data-test=status-strip-health]'),
    bell: q('[data-testid=notify-alerts]'),
    note: q('[data-testid=notify-chime]'),
    version: q('[data-test=status-strip-version]'),
    versionText: strip?.querySelector('[data-test=status-strip-version]')?.textContent?.trim() || '',
    send: box(dock?.querySelector('[data-testid=send]')),
    attach: box(dock?.querySelector('[data-testid=attach]')),
    dockVar: parseInt(root.getPropertyValue('--composer-dock-h'), 10) || 0,
    stripVar: parseInt(root.getPropertyValue('--status-strip-h'), 10) || 0,
  }
})

const server = await startServer()
const browser = await launch()
try {
  /* ---------------- phone ---------------- */
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true, deviceScaleFactor: 2 })
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await until(p, () => Boolean(document.querySelector('[data-test=status-strip]')), null, 15000)
  await sleep(400)
  const f = await facts(p)
  if (OUT) await p.screenshot({ path: `${OUT}/phone-390.png` })

  ok('390 1 the strip is at the very bottom, ~5 mm tall, full width',
    Boolean(f.strip && Math.abs(f.strip.bottom - f.vh) <= 1 && f.strip.h >= 20 && f.strip.h <= 26 && f.strip.left === 0 && f.strip.width === f.vw), f.strip)
  ok('390 2 it holds the dot, the bell, the note and the version',
    Boolean(f.health && f.bell && f.note && f.version && f.versionText), { health: f.health, bell: f.bell, note: f.note, version: f.version, text: f.versionText })
  ok('390 2b each icon lies inside the strip, in desktop order (dot, bell, note, version)',
    Boolean(f.health && f.bell && f.note && f.version
      && [f.health, f.bell, f.note, f.version].every((b) => b.top >= f.strip.top && b.bottom <= f.strip.bottom + 1)
      && f.health.left < f.bell.left && f.bell.left < f.note.left && f.note.left < f.version.left), null)
  ok('390 3 the composer dock sits on the strip (no overlap), its controls unchanged',
    Boolean(f.dock && f.strip && Math.abs(f.dock.bottom - f.strip.top) <= 1 && f.send && f.send.h >= TAP && f.attach && f.attach.h >= TAP), { dock: f.dock, strip: f.strip })
  ok('390 4 --composer-dock-h counts the dock and the strip (snackbars and panes clear both)',
    Boolean(f.dock && f.strip && Math.abs(f.dockVar - (f.dock.h + f.strip.h)) <= 2 && f.stripVar === f.strip.h), { dockVar: f.dockVar, stripVar: f.stripVar })

  const last = await p.evaluate(() => {
    const body = [...document.querySelectorAll('.feed-body')].find((b) => b.getClientRects().length)
    if (!body) return null
    body.scrollTop = body.scrollHeight
    return new Promise((r) => setTimeout(() => {
      const cards = [...body.querySelectorAll('article.msg[data-msg-id]')]
      const c = cards[cards.length - 1]
      const dock = document.querySelector('form.composer.composer--dock')
      r(c && dock ? { cardBottom: Math.round(c.getBoundingClientRect().bottom), dockTop: Math.round(dock.getBoundingClientRect().top) } : null)
    }, 300))
  })
  ok('390 5 the last card scrolls clear of the dock and the strip', Boolean(last && last.cardBottom <= last.dockTop + 1), last)

  const chime0 = await p.evaluate(() => document.querySelector('[data-test=status-strip] [data-testid=notify-chime]')?.getAttribute('aria-pressed'))
  await tapSel(p, '[data-test=status-strip] [data-testid=notify-chime]')
  const chimeFlipped = await until(p, (c0) => document.querySelector('[data-test=status-strip] [data-testid=notify-chime]')?.getAttribute('aria-pressed') !== c0, chime0, 3000)
  await tapSel(p, '[data-test=status-strip] [data-testid=notify-chime]')
  const chimeBack = await until(p, (c0) => document.querySelector('[data-test=status-strip] [data-testid=notify-chime]')?.getAttribute('aria-pressed') === c0, chime0, 3000)
  ok('390 6 a tap on the note flips the chime, a second tap flips it back', chimeFlipped && chimeBack, { chime0 })

  const bellState = () => p.evaluate(() => {
    const b = document.querySelector('[data-test=status-strip] [data-testid=notify-alerts]')
    return b ? `${b.classList.contains('on')}|${b.getAttribute('aria-label')}` : ''
  })
  const bell0 = await bellState()
  await tapSel(p, '[data-test=status-strip] [data-testid=notify-alerts]')
  let bell1 = bell0
  for (let i = 0; i < 30 && bell1 === bell0; i++) { await sleep(100); bell1 = await bellState() }
  await tapSel(p, '[data-test=status-strip] [data-testid=notify-alerts]')
  let bell2 = bell1
  for (let i = 0; i < 30 && bell2 !== bell0; i++) { await sleep(100); bell2 = await bellState() }
  ok('390 7 a tap on the bell flips the alerts switch, a second tap flips it back', bell0 !== bell1 && bell2 === bell0, { bell0, bell1, bell2 })

  await tapSel(p, '[data-test=status-strip-health]')
  const healthCard = await until(p, () => {
    const c = document.querySelector('[data-test=status-strip-health-card]')
    return Boolean(c && c.getClientRects().length && c.textContent.trim() && c.getBoundingClientRect().bottom <= document.querySelector('[data-test=status-strip]').getBoundingClientRect().top)
  }, null, 3000)
  if (OUT) await p.screenshot({ path: `${OUT}/phone-390-health.png` })
  ok('390 8 a tap on the dot opens the connection card above the strip', healthCard)
  await p.touchscreen.tap(200, 300)
  ok('390 8b a tap outside closes it', await until(p, () => !document.querySelector('[data-test=status-strip-health-card]'), null, 3000))

  await tapSel(p, '[data-test=status-strip-version]')
  const verCard = await until(p, () => {
    const c = document.querySelector('[data-test=status-strip-version-card]')
    if (!c || !c.getClientRects().length) return false
    const r = c.getBoundingClientRect()
    return Boolean(c.textContent.trim()) && r.left >= 0 && r.right <= window.innerWidth
  }, null, 3000)
  if (OUT) await p.screenshot({ path: `${OUT}/phone-390-version.png` })
  ok('390 9 a tap on the version opens the version card, inside the screen', verCard)
  await tapSel(p, '[data-test=status-strip-version]')
  ok('390 9b a second tap closes it', await until(p, () => !document.querySelector('[data-test=status-strip-version-card]'), null, 3000))

  ok('390 no page errors', errors.length === 0, errors)
  await p.close()

  /* ---------------- desktop ---------------- */
  const d = await browser.newPage()
  await d.setViewport({ width: 1440, height: 900 })
  await d.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await d.waitForSelector('article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await sleep(400)
  const g = await d.evaluate(() => {
    const row = document.querySelector('.sidebar-foot .foot-row')
    const vis = (sel) => { const e = row?.querySelector(sel); return Boolean(e && e.getClientRects().length) }
    return {
      strip: Boolean(document.querySelector('[data-test=status-strip]')),
      dot: vis('[data-testid=connection-health]'),
      bell: vis('[data-testid=notify-alerts]'),
      note: vis('[data-testid=notify-chime]'),
      version: vis('[data-test=app-version]'),
      dockVar: getComputedStyle(document.documentElement).getPropertyValue('--composer-dock-h').trim() || '0px',
    }
  })
  if (OUT) await d.screenshot({ path: `${OUT}/desktop-1440.png` })
  ok('1440 10 no strip; the sidebar footer keeps dot, bell, note and version; dock height 0',
    !g.strip && g.dot && g.bell && g.note && g.version && g.dockVar === '0px', g)
  await d.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmobile-status-strip: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
