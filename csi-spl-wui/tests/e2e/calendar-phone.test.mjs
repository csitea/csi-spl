// spec 089 T009: the Calendar on a phone (AC-08). Owner, t1 2256fe0f: "The
// calendar on mobile is unusable." - at 390 px the 240 px year strip was a
// column and the week seven ~20 px columns.
//
// AC-08 at 390x844 (and the same at 820 px, the widest phone width):
//   - one column: the main view is the whole width, the year strip is not on
//     screen until the header button opens it as a sheet
//   - the section opens on the Day view; Week is a list grouped by day (the
//     seven days one under another, each the full width)
//   - Today / previous / next sit in the lower half (a thumb reaches them)
//     and are >= 44 px; in the Day view they step one day
//   - a day picked in the sheet closes it and shows that day; Back closes
//     the sheet and stays on /calendar (useMobileStack overlay)
//   - the document never scrolls sideways
// At 1440 px nothing changes: the strip is a column, no strip button, the
// week is seven columns in one row.
//
// Control: before T009 the strip is a 240 px column at 390 px, there is no
// [data-test=calendar-strip-open] and no Day view, so the AC-08 checks FAIL.
//
// Run:
//   pnpm run test:e2e calendar-phone
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e calendar-phone
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'
import { calAddDays, calIsoDay, calWeekStart } from '../../src/utils/calendar-year.mjs'

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

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `calendar-phone-${name}.png`) })
}

const today = calIsoDay(Date.now())
const attr = (p, name) => p.$eval('[data-test=calendar-main]', (el, n) => el.getAttribute(n), name).catch(() => '')
const waitAttr = (p, name, want) => p.waitForFunction((n, w) => document.querySelector('[data-test=calendar-main]')?.getAttribute(n) === w, { timeout: 10000 }, name, want).then(() => true, () => false)

/* what is on screen: the strip, its button, the shown days and their boxes */
async function layout(p) {
  return p.evaluate(() => {
    const vis = (el) => {
      if (!el) return null
      const r = el.getBoundingClientRect()
      const st = getComputedStyle(el)
      if (st.display === 'none' || st.visibility === 'hidden' || r.width < 2 || r.height < 2) return null
      return { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) }
    }
    const days = [...document.querySelectorAll('[data-test=calendar-week-day]')]
      .map((el) => ({ day: el.getAttribute('data-day'), box: vis(el) }))
      .filter((d) => d.box)
    return {
      iw: window.innerWidth,
      xScroll: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
      strip: vis(document.querySelector('[data-test=calendar-year-strip]')),
      open: vis(document.querySelector('[data-test=calendar-strip-open]')),
      main: vis(document.querySelector('[data-test=calendar-main]')),
      days,
    }
  })
}

/* a control's box, and whether a thumb reaches it: >= 44 px, lower half */
async function thumb(p, sel) {
  return p.$eval(sel, (el) => {
    const r = el.getBoundingClientRect()
    return { w: Math.round(r.width), h: Math.round(r.height), y: Math.round(r.top), ih: window.innerHeight }
  }).catch(() => null)
}
const reachable = (b) => Boolean(b && b.w >= 43.5 && b.h >= 43.5 && b.y >= b.ih / 2 && b.y + b.h <= b.ih)

async function open(p, vp, path = '/calendar') {
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.waitForSelector('[data-test=calendar-main]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  await p.waitForFunction(() => document.querySelector('[data-test=calendar-main]')?.getAttribute('data-state') === 'ready', { timeout: 10000 }).catch(() => {})
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())
}

const server = await startServer()
const browser = await launch()
try {
  for (const vp of [{ width: 390, height: 844 }, { width: 820, height: 1180 }]) {
    const w = vp.width
    console.log(`-- ${w}x${vp.height}`)
    const p = await browser.newPage()
    await open(p, vp)
    let l = await layout(p)
    await shot(p, `${w}-day`)
    ok(`AC-08 ${w}: the calendar is level 2 (the section strip on top)`, l.level === '2', l.level)
    ok(`AC-08 ${w}: one column - the main view is the full width`, Boolean(l.main && l.main.w >= l.iw - 2), { main: l.main, iw: l.iw })
    ok(`AC-08 ${w}: the year strip is not on screen`, l.strip === null, l.strip)
    ok(`AC-08 ${w}: a header button opens the year strip`, Boolean(l.open), l.open)
    ok(`AC-08 ${w}: opens on the Day view`, (await attr(p, 'data-view')) === 'day', await attr(p, 'data-view'))
    ok(`AC-08 ${w}: the Day view shows one day, today`, l.days.length === 1 && l.days[0].day === today, l.days.map((d) => d.day))
    ok(`AC-08 ${w}: no sideways scroll`, l.xScroll <= 1, l.xScroll)
    for (const b of ['today', 'prev', 'next']) {
      const box = await thumb(p, `[data-test=calendar-${b}]`)
      ok(`${w}: ${b} is >= 44 px and in the lower half (thumb)`, reachable(box), box)
    }

    /* Day view: previous / next step one day */
    await p.click('[data-test=calendar-next]')
    ok(`${w}: next shows tomorrow`, await waitAttr(p, 'data-day', calAddDays(today, 1)), await attr(p, 'data-day'))
    await p.click('[data-test=calendar-prev]')
    await p.click('[data-test=calendar-prev]')
    ok(`${w}: previous (twice) shows yesterday`, await waitAttr(p, 'data-day', calAddDays(today, -1)), await attr(p, 'data-day'))
    await p.click('[data-test=calendar-today]')
    ok(`${w}: Today goes back to today`, await waitAttr(p, 'data-day', today), await attr(p, 'data-day'))

    /* the strip: a sheet over the view, a pick closes it and shows the day */
    if (l.open) {
      await p.click('[data-test=calendar-strip-open]')
      await p.waitForSelector('[data-test=calendar-year-strip]', { visible: true, timeout: 5000 }).catch(() => null)
      await sleep(200)
      l = await layout(p)
      await shot(p, `${w}-strip`)
      ok(`${w}: the button shows the year strip, the full width`, Boolean(l.strip && l.strip.w >= l.iw - 2), l.strip)
      const cur = await p.$eval('[data-test=calendar-year-strip] [aria-current=date]', (el) => {
        const r = el.getBoundingClientRect()
        return r.top >= 0 && r.bottom <= window.innerHeight
      }).catch(() => false)
      ok(`${w}: the strip opens on this month (today in view)`, cur)
      ok(`${w}: no sideways scroll with the strip open`, l.xScroll <= 1, l.xScroll)
      const later = calAddDays(today, 30)
      await p.$eval(`[data-test=calendar-day][data-day="${later}"]`, (el) => el.scrollIntoView({ block: 'center' }))
      await p.click(`[data-test=calendar-day][data-day="${later}"]`)
      ok(`${w}: a picked day shows in the Day view`, await waitAttr(p, 'data-day', later), await attr(p, 'data-day'))
      await sleep(300)
      l = await layout(p)
      ok(`${w}: the pick closes the strip`, l.strip === null, l.strip)
      ok(`${w}: the URL keeps the day`, new URL(p.url()).searchParams.get('d') === later, p.url())

      /* Back closes the sheet, the page stays */
      await p.click('[data-test=calendar-strip-open]')
      await p.waitForSelector('[data-test=calendar-year-strip]', { visible: true, timeout: 5000 }).catch(() => null)
      await sleep(200)
      await p.evaluate(() => history.back())
      await sleep(600)
      l = await layout(p)
      ok(`${w}: Back closes the strip and stays on /calendar`, l.strip === null && new URL(p.url()).pathname === '/calendar', { strip: l.strip, url: p.url() })
    }

    /* Week: a list grouped by day */
    const weekBtn = await p.$('[data-test=calendar-view-week]')
    ok(`AC-08 ${w}: a Week control`, Boolean(weekBtn))
    if (weekBtn) {
      await weekBtn.click()
      ok(`AC-08 ${w}: Week is shown`, await waitAttr(p, 'data-view', 'week'), await attr(p, 'data-view'))
      l = await layout(p)
      await shot(p, `${w}-week`)
      const stacked = l.days.length === 7 && l.days.every((d, i) => d.box.w >= (l.main?.w || 0) - 40 && (i === 0 || d.box.y > l.days[i - 1].box.y))
      ok(`AC-08 ${w}: Week is a list grouped by day (seven full-width days, one under another)`, stacked, l.days.map((d) => d.box))
      ok(`AC-08 ${w}: the week holding the shown day`, (await attr(p, 'data-week')) === calWeekStart(calAddDays(today, 30)), await attr(p, 'data-week'))
      ok(`AC-08 ${w}: no sideways scroll in Week`, l.xScroll <= 1, l.xScroll)
      await p.click('[data-test=calendar-next]')
      ok(`${w}: in Week, next steps a week`, await waitAttr(p, 'data-week', calAddDays(calWeekStart(calAddDays(today, 30)), 7)), await attr(p, 'data-week'))
    }
    await p.close()
  }

  /* desktop: unchanged */
  console.log('-- 1440x900')
  const p = await browser.newPage()
  await open(p, { width: 1440, height: 900 })
  const l = await layout(p)
  await shot(p, '1440')
  ok('1440: the year strip is a column beside the main view', Boolean(l.strip && l.strip.w < 300 && l.main && l.main.x >= l.strip.x + l.strip.w - 1), { strip: l.strip, main: l.main })
  ok('1440: no year-strip button', l.open === null, l.open)
  ok('1440: Week view', (await attr(p, 'data-view')) === 'week', await attr(p, 'data-view'))
  ok('1440: seven day columns in one row', l.days.length === 7 && new Set(l.days.map((d) => d.box.y)).size === 1, l.days.map((d) => d.box))
  ok('1440: no Day / Week control (T008 brings the desktop one)', !(await p.$('[data-test=calendar-view-week]')))
  await p.click('[data-test=calendar-next]')
  ok('1440: next steps a week', await waitAttr(p, 'data-week', calAddDays(calWeekStart(today), 7)), await attr(p, 'data-week'))
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `calendar-phone: ${failed} FAILED` : `calendar-phone: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
