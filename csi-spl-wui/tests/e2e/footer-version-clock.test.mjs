// Owner, t1 747c7e47: the sidebar footer's version and last-updated clock sit
// on ONE line, their lowest parts level ("they should be just on one line
// vertically - their lowest parts"). c-414's per-item drops (version 0.5rem,
// clock 1rem) were too much; both now share the row's last-baseline group.
// Rule: their baselines (both are the same mono font and size) and their box
// bottoms differ by <= 1 px; the bell, the note and the row height do not
// move; neither crosses the sidebar's bottom edge; the version card opens.
//
// "before" re-applies c-414's drops with a sheet, for the comparison shot.
//
// Default size is the 260 px sidebar at 1280x800. The short pass is 480 px
// tall, the shortest desktop height this suite already drives.
//
//   SHOT_DIR=/tmp/shots node tests/e2e/footer-version-clock.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/footer-version-clock.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { applyViewport, CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const SHA = '0123456789abcdef0123456789abcdef01234567'
const VIEWPORTS = [
  { name: '1280x800', width: 1280, height: 800 },
  { name: '1280x480', width: 1280, height: 480 },
]

if (SHOT_DIR) mkdirSync(SHOT_DIR, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const near = (got, want, tol) => got !== null && Math.abs(got - want) <= tol

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

/* Positions are relative to the footer row so a viewport change does not
   hide a delta. The baseline is a zero-size inline-block appended for one
   read: its bottom is the line's baseline, where the digits stand. */
const measure = (p) => p.evaluate(() => {
  const row = document.querySelector('.sidebar-foot .foot-row')
  const side = row?.closest('.sidebar')
  const ver = document.querySelector('[data-test=app-version] .vs-ver')
  const clock = document.querySelector('.foot-row .foot-row__clock')
  const bell = document.querySelector('.foot-row .notify-alerts')
  const note = document.querySelector('.foot-row .notify-chime')
  if (!row || !side || !ver || !clock || !bell || !note) return { missing: true }
  const rr = row.getBoundingClientRect()
  const sr = side.getBoundingClientRect()
  const r1 = (n) => Math.round(n * 100) / 100
  const topOf = (el) => r1(el.getBoundingClientRect().top - rr.top)
  const botOf = (el) => r1(el.getBoundingClientRect().bottom - rr.top)
  const baseOf = (el) => {
    const probe = document.createElement('span')
    probe.style.cssText = 'display:inline-block;width:0;height:0;vertical-align:baseline'
    el.appendChild(probe)
    const b = probe.getBoundingClientRect().bottom
    probe.remove()
    return r1(b - rr.top)
  }
  const font = (el) => { const c = getComputedStyle(el); return `${c.fontSize} ${c.fontFamily.split(',')[0]}` }
  const bot = (el) => el.getBoundingClientRect().bottom
  return {
    sideW: r1(sr.width),
    rowH: r1(rr.height),
    verFont: font(ver),
    clockFont: font(clock),
    verBase: baseOf(ver),
    clockBase: baseOf(clock),
    verBot: botOf(ver),
    clockBot: botOf(clock),
    bellTop: topOf(bell),
    noteTop: topOf(note),
    verPast: r1(bot(ver) - sr.bottom),
    clockPast: r1(bot(clock) - sr.bottom),
    verWindow: r1(bot(ver) - window.innerHeight),
    clockWindow: r1(bot(clock) - window.innerHeight),
  }
})

/* a sheet, not an inline style: the clock re-renders every second and Vue's
   patch drops an inline style. "before" is c-414's v1.8.9 footer. */
const setBefore = (p, on) => p.evaluate((on) => {
  document.getElementById('fvc-before')?.remove()
  if (!on) return true
  const s = document.createElement('style')
  s.id = 'fvc-before'
  s.textContent = '.foot-row .vs-wrap, .foot-row .foot-row__clock { align-self: auto !important; }'
    + ' [data-test=app-version] { transform: translateY(0.5rem); }'
    + ' .foot-row .foot-row__clock { transform: translateY(1rem); }'
  document.head.appendChild(s)
  return true
}, on)

const shot = async (p, name) => {
  if (!SHOT_DIR) return
  const row = await p.$('.sidebar-foot')
  if (row) await row.screenshot({ path: join(SHOT_DIR, `${name}.png`) })
  await p.screenshot({ path: join(SHOT_DIR, `${name}-page.png`) })
}

const diagnose = (p) => p.evaluate(() => {
  const clocks = [...document.querySelectorAll('[data-test=last-data-clock]')].map((el) => ({
    cls: String(el.className).slice(0, 80),
    parent: String(el.parentElement?.className || '').slice(0, 80),
    text: (el.textContent || '').trim(),
    w: Math.round(el.getBoundingClientRect().width),
  }))
  return {
    url: location.href,
    iw: window.innerWidth,
    ih: window.innerHeight,
    foot: Boolean(document.querySelector('.sidebar-foot')),
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
    clocks,
    title: document.title,
  }
})

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 240)))
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    try {
      if (new URL(req.url()).pathname === '/build.json') {
        return req.respond({ status: 200, contentType: 'application/json', body: JSON.stringify({ commit: SHA, built_at: '2026-10-06T12:00:00Z', run: '1', version: 'v1.7.5' }) })
      }
    } catch (e) { errors.push('req ' + e.message) }
    return req.continue().catch(() => {})
  })
  for (const vp of VIEWPORTS) {
    await applyViewport(p, { width: vp.width, height: vp.height })
    const show = async () => {
      await p.goto(server.base + '/channel/lobby', { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      return p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT }).then(() => true).catch(() => false)
    }
    if (!await show()) await show()
    await applyViewport(p, { width: vp.width, height: vp.height })
    await signIn(p)
    /* a cold nuxi compile can leave the first document on the loading shell
       (top bar, no footer) until a second navigation. One reload, then wait. */
    let clockReady = await p.waitForSelector('.sidebar-foot .foot-row__clock', { timeout: 20000 }).then(() => true).catch(() => false)
    if (!clockReady) {
      if (!await show()) await show()
      await applyViewport(p, { width: vp.width, height: vp.height })
      await signIn(p)
      clockReady = await p.waitForSelector('.sidebar-foot .foot-row__clock', { timeout: NAV_TIMEOUT }).then(() => true).catch(() => false)
    }
    if (!clockReady) console.log('NO CLOCK ' + JSON.stringify(await diagnose(p)) + ' errors ' + JSON.stringify(errors))
    await p.waitForFunction(() => /^\d{2}:\d{2}:\d{2}$/.test((document.querySelector('.foot-row .foot-row__clock')?.textContent || '').trim()), { timeout: 20000 }).catch(() => null)
    await sleep(200)

    await setBefore(p, true)
    await sleep(50)
    const before = await measure(p)
    await shot(p, `footer-${vp.name}-before`)
    await setBefore(p, false)
    await sleep(50)
    const after = await measure(p)
    await shot(p, `footer-${vp.name}-after`)
    console.log(`MEASURE ${vp.name} before ${JSON.stringify(before)}`)
    console.log(`MEASURE ${vp.name} after ${JSON.stringify(after)}`)

    const tag = vp.name
    ok(`${tag}: the footer clock is on screen`, clockReady, errors)
    ok(`${tag}: sidebar is the default 260 px`, near(after.sideW, 260, 1), after)
    ok(`${tag}: version and clock share one font and size`, !after.missing && after.verFont === after.clockFont, { ver: after.verFont, clock: after.clockFont })
    ok(`${tag}: version and clock baselines level (<= 1 px)`, !after.missing && near(after.verBase, after.clockBase, 1), { ver: after.verBase, clock: after.clockBase })
    ok(`${tag}: version and clock bottoms level (<= 1 px)`, !after.missing && near(after.verBot, after.clockBot, 1), { ver: after.verBot, clock: after.clockBot })
    ok(`${tag}: bell and note stay put`, !before.missing && near(after.bellTop, before.bellTop, 0.6) && near(after.noteTop, before.noteTop, 0.6), { bell: [before.bellTop, after.bellTop], note: [before.noteTop, after.noteTop] })
    ok(`${tag}: footer row height stays put`, near(after.rowH, before.rowH, 0.6), { before: before.rowH, after: after.rowH })
    ok(`${tag}: version and clock stay inside the sidebar and the window`, after.verPast <= 0.5 && after.clockPast <= 0.5 && after.verWindow <= 0.5 && after.clockWindow <= 0.5, { verPast: after.verPast, clockPast: after.clockPast, verWindow: after.verWindow, clockWindow: after.clockWindow })
  }

  await applyViewport(p, { width: 1280, height: 800 })
  await setBefore(p, false)
  await p.click('[data-test=app-version-wrap]').catch(() => null)
  await sleep(300)
  await shot(p, 'footer-1280x800-card')
  const card = await p.evaluate(() => {
    const c = document.querySelector('[data-test=app-version-card]')
    const v = document.querySelector('[data-test=app-version]')
    if (!c || !v) return { none: true }
    const r = c.getBoundingClientRect()
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + Math.min(r.height / 2, 12))
    const ih = window.innerHeight
    const iw = window.innerWidth
    return {
      visible: getComputedStyle(c).visibility === 'visible' && Number(getComputedStyle(c).opacity) > 0.9,
      painted: Boolean(hit && c.contains(hit)),
      above: r.bottom <= v.getBoundingClientRect().top + 1,
      inside: r.top >= -0.5 && r.left >= -0.5 && r.bottom <= ih + 0.5 && r.right <= iw + 0.5 && r.width > 40 && r.height > 16,
      box: { t: Math.round(r.top), b: Math.round(r.bottom), l: Math.round(r.left), r: Math.round(r.right), h: Math.round(r.height) },
    }
  })
  ok('1280x800: the version card opens fully, above the version', !card.none && card.visible && card.painted && card.above && card.inside, card)
} finally {
  await browser.close()
  await server.stop?.()
}
const failed = results.filter((r) => !r.ok)
console.log(`${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
