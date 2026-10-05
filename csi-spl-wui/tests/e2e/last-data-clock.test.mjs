// Last-updated clock (owner: the time of the latest data the hub returned,
// HH:mm:ss, visible on every page so a snapshot shows it). Owner, t1
// be316fdc: "It must be next to the version on the right side, exactly" -
// on a desktop right of the sidebar footer's version, right-aligned to the
// end of that row (owner, t1 7b48293b), on a phone the strip's version
// right next to the note and the clock flush with the strip's end. A screen that draws no version (rail-only or
// hidden sidebar, a sheet over the phone strip) keeps it in the top bar's
// corner (useClockHost). Exactly one clock per screen, always visible.
//
//   node tests/e2e/last-data-clock.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/last-data-clock.test.mjs
//   OUT=/var/tmp/g-254-shots node tests/e2e/last-data-clock.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const PAGES = [
  ['channels', '/channel/lobby'],
  ['topic', `/t/${TOPIC}`],
  ['thread', `/channel/lobby?topic=${TOPIC}`],
  ['docs', '/docs'],
  ['help', '/help'],
  ['settings', '/settings'],
]
const WIDTHS = [
  { name: '1440', width: 1440, height: 900, touch: false },
  { name: '390', width: 390, height: 844, touch: true },
  { name: '360', width: 360, height: 800, touch: true },
]
const CLOCK = '[data-test=last-data-clock]'

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

// The version text it must sit beside: the sidebar footer's on a desktop,
// the status strip's on a phone (the footer row is not drawn there).
const facts = (p) => p.evaluate((CLOCK) => {
  const seen = (n) => {
    if (!n) return false
    const r = n.getBoundingClientRect()
    const cs = getComputedStyle(n)
    return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
  }
  const all = [...document.querySelectorAll(CLOCK)]
  const el = all.find(seen) || all[0]
  if (!el) return null
  const strip = document.querySelector('[data-test=status-strip]')
  const bar = document.querySelector('[data-test=top-bar]')
  // whichever version is on screen; null when none is
  const ver = [document.querySelector('[data-test=app-version] .vs-ver'), strip && strip.querySelector('.status-strip__ver')].find(seen) || null
  const r = el.getBoundingClientRect()
  const b = bar ? bar.getBoundingClientRect() : null
  const row = el.closest('.foot-row')
  const inStrip = Boolean(strip && strip.contains(el))
  // the footer row ends at its padding; the strip has none (no space to its end)
  const rowEnd = row ? row.getBoundingClientRect().right - parseFloat(getComputedStyle(row).paddingRight || '0')
    : (inStrip ? strip.getBoundingClientRect().right : null)
  const note = inStrip ? strip.querySelector('.notify-chime .notify-glyph, .notify-chime svg') : null
  const n = note ? note.getBoundingClientRect() : null
  const v = ver ? ver.getBoundingClientRect() : null
  const menu = document.querySelector('[data-test=user-menu-panel]')
  return {
    where: strip && strip.contains(el) ? 'strip' : (el.closest('.foot-row') ? 'sidebar-foot' : (bar && bar.contains(el) ? 'top-bar' : 'elsewhere')),
    count: all.length,
    inBarBox: Boolean(b && r.top >= b.top - 1 && r.bottom <= b.bottom + 1),
    text: (el.textContent || '').trim(),
    title: el.getAttribute('title') || '',
    at: el.getAttribute('data-at') || '',
    shown: seen(el),
    verShown: seen(ver),
    // the version is never cut to an ellipsis to make room for the clock
    verFull: Boolean(ver && ver.parentElement && ver.parentElement.scrollWidth <= ver.parentElement.clientWidth + 1),
    gap: v ? Math.round((r.left - v.right) * 10) / 10 : null,
    noteGap: n && v ? Math.round((v.left - n.right) * 10) / 10 : null,
    endGap: rowEnd === null ? null : Math.round((rowEnd - r.right) * 10) / 10,
    dy: v ? Math.round(Math.abs((r.top + r.bottom) / 2 - (v.top + v.bottom) / 2) * 10) / 10 : null,
    onScreen: r.left >= -1 && r.right <= window.innerWidth + 1 && r.top >= -1 && r.bottom <= window.innerHeight + 1,
    scroll: document.scrollingElement.scrollWidth <= window.innerWidth + 1,
    menuOpen: Boolean(menu && menu.getClientRects().length),
  }
}, CLOCK)
// right of the version and flush with its container's end; on the phone strip
// the version also sits right next to the note (glyph to text)
const besideVersion = (f) => Boolean(f && f.shown && f.verShown && f.verFull && f.gap !== null && f.gap >= 0 && f.dy <= 4 && f.onScreen
  && f.endGap !== null && Math.abs(f.endGap) <= 1
  && (f.where !== 'strip' || (f.noteGap !== null && f.noteGap >= 0 && f.noteGap <= 14)))
// right of the version when one is drawn, else in the top bar
const placed = (f) => Boolean(f && (f.verShown ? besideVersion(f) && f.where !== 'top-bar' : f.where === 'top-bar' && f.shown && f.inBarBox && f.onScreen))
const WHERE = []

async function openPage(p, base, path) {
  // domcontentloaded: a Vite dev socket never goes network-idle, and the first
  // visit to a route can restart the dev server (the bar then appears on retry).
  const show = async () => {
    await p.goto(base + path, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    return p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT }).then(() => true).catch(() => false)
  }
  if (!await show()) await show()
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  await signIn(p)
  const ready = await p.waitForFunction((CLOCK) => {
    const el = document.querySelector(CLOCK)
    return Boolean(el && /^\d{2}:\d{2}:\d{2}$/.test((el.textContent || '').trim()))
  }, { timeout: 20000 }, CLOCK).then(() => true).catch(() => false)
  return ready
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 240)))

  for (const vp of WIDTHS) {
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.touch, hasTouch: vp.touch, deviceScaleFactor: vp.touch ? 2 : 1 })
    for (const [name, path] of PAGES) {
      const ready = await openPage(p, server.base, path)
      const f = await facts(p)
      const tag = `${vp.name} ${name}`
      WHERE.push(`${tag}=${f ? f.where : 'none'}`)
      ok(`${tag}: clock right of the version, or the top bar where none is drawn`, placed(f) && !f.menuOpen, f)
      ok(`${tag}: exactly one clock`, Boolean(f && f.count === 1 && f.shown), f && { count: f.count, shown: f.shown })
      ok(`${tag}: HH:mm:ss after data`, ready && Boolean(f && /^\d{2}:\d{2}:\d{2}$/.test(f.text)), f && { text: f.text, title: f.title })
      ok(`${tag}: no horizontal scroll`, Boolean(f && f.scroll), f && { scroll: f.scroll })
      ok(`${tag}: tooltip names last updated and the date`, Boolean(f && /last updated/i.test(f.title) && /\d{4}-\d{2}-\d{2}/.test(f.title)), f && f.title)
    }
  }

  console.log('CLOCK_WHERE ' + WHERE.join(' '))
  // the owner's case: the desktop channels screen and every phone channels screen
  ok('the channels screen has it right of the version at every width', WIDTHS.every((vp) => WHERE.includes(`${vp.name} channels=${vp.touch ? 'strip' : 'sidebar-foot'}`)), WHERE)

  await p.setViewport({ width: 1440, height: 900 })
  await openPage(p, server.base, '/channel/lobby')
  const local = await p.evaluate(() => {
    const el = document.querySelector('[data-test=last-data-clock]')
    const iso = el?.getAttribute('data-at') || ''
    if (!iso) return { ok: false }
    const d = new Date(iso)
    const pad = (n) => String(n).padStart(2, '0')
    const want = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
    return { ok: (el.textContent || '').trim() === want, text: (el.textContent || '').trim(), want }
  })
  ok('the painted time is the local HH:mm:ss of data-at', local.ok, local)

  const refused = await p.evaluate(async () => {
    const read = () => document.querySelector('[data-test=last-data-clock]')?.getAttribute('data-at') || ''
    const before = read()
    const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
    const channel = pinia?._s.get('channel')
    let result = 'no-store'
    if (channel) {
      try {
        await channel.deleteChannel('no-such-clock-channel')
        result = 'ok'
      } catch {
        result = 'threw'
      }
    }
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))
    return { before, after: read(), result }
  })
  ok('a refused request does not move the clock', refused.result === 'threw' && refused.before !== '' && refused.before === refused.after, refused)

  const samples = []
  for (let i = 0; i < 5; i++) {
    const row = await p.evaluate(async () => {
      const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
      const channel = pinia?._s.get('channel')
      const read = () => document.querySelector('[data-test=last-data-clock]')?.getAttribute('data-at') || ''
      const barH = () => Math.round(document.querySelector('.foot-row')?.getBoundingClientRect().height || 0)
      const before = read()
      const h0 = barH()
      const t0 = performance.now()
      await channel.refresh()
      let after = before
      const deadline = performance.now() + 1000
      while (performance.now() < deadline) {
        after = read()
        if (after && after !== before) break
        await new Promise((r) => requestAnimationFrame(r))
      }
      return {
        ms: Math.round((performance.now() - t0) * 10) / 10,
        advanced: Boolean(after && after !== before),
        rowHeld: barH() === h0,
      }
    })
    samples.push(row)
    await sleep(8)
  }
  console.log('LAST_DATA_TIMING ' + JSON.stringify(samples))
  ok('five refetches each advance the clock without moving the version row', samples.length === 5 && samples.every((s) => s.advanced && s.rowHeld), samples)

  ok('no page errors', errors.length === 0, errors)

  if (OUT) {
    for (const theme of ['dark', 'light']) {
      await p.evaluate((id) => {
        localStorage.setItem('spool-theme', id)
        document.documentElement.setAttribute('data-theme', id)
      }, theme)
      for (const vp of WIDTHS) {
        await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.touch, hasTouch: vp.touch, deviceScaleFactor: vp.touch ? 2 : 1 })
        await openPage(p, server.base, '/channel/lobby')
        await p.evaluate((id) => document.documentElement.setAttribute('data-theme', id), theme)
        await p.screenshot({ path: `${OUT}/lobby-${vp.name}-${theme}.png` })
        const row = await p.$(vp.touch ? '[data-test=status-strip]' : '.sidebar-foot .foot-row')
        if (row) await row.screenshot({ path: `${OUT}/row-lobby-${vp.name}-${theme}.png` })
      }
      await p.setViewport({ width: 1440, height: 900 })
      for (const path of ['/help', '/settings', '/docs']) {
        await openPage(p, server.base, path)
        await p.evaluate((id) => document.documentElement.setAttribute('data-theme', id), theme)
        const slug = path.replace(/\//g, '') || 'home'
        await p.screenshot({ path: `${OUT}/${slug}-1440-${theme}.png` })
      }
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nlast-data-clock: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
