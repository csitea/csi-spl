// Owner, t1 747c7e47: the sidebar footer version sits 2 mm (~0.5rem) lower
// and the last-updated clock 4 mm (~1rem) lower than the row lays them out.
// translateY only, so the row height, the bell, the note and the hover card
// stay put, and neither glyph crosses the sidebar's bottom edge.
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

/* layout (transform none) versus the painted shift. Tops are relative to
   the footer row so a viewport change does not hide the delta. */
const measure = (p) => p.evaluate(() => {
  const row = document.querySelector('.sidebar-foot .foot-row')
  const side = row?.closest('.sidebar')
  const ver = document.querySelector('[data-test=app-version]')
  const clock = document.querySelector('.foot-row .foot-row__clock')
  const bell = document.querySelector('.foot-row .notify-alerts')
  const note = document.querySelector('.foot-row .notify-chime')
  if (!row || !side || !ver || !clock || !bell || !note) return { missing: true }
  const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
  const rr = row.getBoundingClientRect()
  const sr = side.getBoundingClientRect()
  const topOf = (el) => Math.round((el.getBoundingClientRect().top - rr.top) * 10) / 10
  const bot = (el) => el.getBoundingClientRect().bottom
  return {
    rem,
    sideW: Math.round(sr.width * 10) / 10,
    rowH: Math.round(rr.height * 10) / 10,
    verTop: topOf(ver),
    clockTop: topOf(clock),
    bellTop: topOf(bell),
    noteTop: topOf(note),
    verPast: Math.round((bot(ver) - sr.bottom) * 10) / 10,
    clockPast: Math.round((bot(clock) - sr.bottom) * 10) / 10,
    verWindow: Math.round((bot(ver) - window.innerHeight) * 10) / 10,
    clockWindow: Math.round((bot(clock) - window.innerHeight) * 10) / 10,
  }
})

/* a sheet, not an inline style: the clock re-renders every second and Vue's
   patch drops an inline transform, so the "before" shot showed the shift. */
const setShift = (p, on) => p.evaluate((on) => {
  document.getElementById('fvc-no-shift')?.remove()
  if (on) return true
  const s = document.createElement('style')
  s.id = 'fvc-no-shift'
  s.textContent = '[data-test=app-version], .foot-row .foot-row__clock { transform: none !important; }'
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

    await setShift(p, false)
    await sleep(50)
    const before = await measure(p)
    await shot(p, `footer-${vp.name}-before`)
    await setShift(p, true)
    await sleep(50)
    const after = await measure(p)
    await shot(p, `footer-${vp.name}-after`)
    console.log(`MEASURE ${vp.name} before ${JSON.stringify(before)}`)
    console.log(`MEASURE ${vp.name} after ${JSON.stringify(after)}`)

    const tag = vp.name
    ok(`${tag}: the footer clock is on screen`, clockReady, errors)
    ok(`${tag}: sidebar is the default 260 px`, near(after.sideW, 260, 1), after)
    ok(`${tag}: version top is 0.5rem lower than its layout`, !before.missing && near(after.verTop - before.verTop, before.rem * 0.5, 1), { before: before.verTop, after: after.verTop, rem: before.rem })
    ok(`${tag}: clock top is 1rem lower than its layout`, !before.missing && near(after.clockTop - before.clockTop, before.rem, 1), { before: before.clockTop, after: after.clockTop, rem: before.rem })
    ok(`${tag}: bell and note stay put`, near(after.bellTop, before.bellTop, 0.6) && near(after.noteTop, before.noteTop, 0.6), { bell: [before.bellTop, after.bellTop], note: [before.noteTop, after.noteTop] })
    ok(`${tag}: footer row height stays put`, near(after.rowH, before.rowH, 0.6), { before: before.rowH, after: after.rowH })
    ok(`${tag}: version and clock stay inside the sidebar and the window`, after.verPast <= 0.5 && after.clockPast <= 0.5 && after.verWindow <= 0.5 && after.clockWindow <= 0.5, { verPast: after.verPast, clockPast: after.clockPast, verWindow: after.verWindow, clockWindow: after.clockWindow })
  }

  await applyViewport(p, { width: 1280, height: 800 })
  await setShift(p, true)
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
