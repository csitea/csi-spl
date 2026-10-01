// SPL-1147 (owner, prd t1 topic f9b6c844): the deadline calendar is compact.
// In a real browser, mock tenant, the Issues filter row's DeadlinePicker:
//   C1  the field is as wide as its text plus ~2 mm: 8 +-1 px of empty
//       space after "YYYY-MM-DD HH:MM", and the text never scrolls
//   C2  the pop-up is at most 200 px wide (30% under the old 280)
//   C3  the pop-up is fully inside the viewport at 1440x900, 1024x900,
//       830x900 (the last desktop width) and 1024x420 (too short below)
//   C4  near the right edge it opens to the left: its right edge meets the
//       control's right edge instead of running off the screen
//   C5  no Done button: a picked day applies at once (the pop-up stays for
//       the time); the shared close x (SPL-1133) sits top LEFT by default
//       (Mac style) and closes it
//   C6  Esc and an outside click close it too
//   C7  Windows style (close_buttons=windows) puts the x top RIGHT
//
//   pnpm run test:e2e deadline-picker
//   BASE_URL=<generated bundle> pnpm run test:e2e deadline-picker
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const FIELD = '[data-test=issues-filter-deadline-date]'

/* the field, its text's right edge, the control and the pop-up, in px */
const measure = (p) => p.evaluate((sel) => {
  const inp = document.querySelector(sel)
  const cs = getComputedStyle(inp)
  const span = document.createElement('span')
  span.style.cssText = `position:absolute;visibility:hidden;white-space:pre;font-family:${cs.fontFamily};font-size:${cs.fontSize};font-weight:${cs.fontWeight};font-variant-numeric:${cs.fontVariantNumeric};letter-spacing:${cs.letterSpacing}`
  span.textContent = inp.value
  document.body.appendChild(span)
  const text = span.getBoundingClientRect().width
  span.remove()
  const ib = inp.getBoundingClientRect()
  const trailing = (ib.right - parseFloat(cs.borderRightWidth)) - (ib.left + parseFloat(cs.borderLeftWidth) + parseFloat(cs.paddingLeft) + text)
  const pop = document.querySelector('[data-test=deadline-picker]')
  const pb = pop ? pop.getBoundingClientRect() : null
  const ctl = inp.closest('.dlp').getBoundingClientRect()
  return {
    vw: innerWidth, vh: innerHeight, field: Math.round(ib.width), trailing: Math.round(trailing * 10) / 10, scrolls: inp.scrollWidth > inp.clientWidth,
    ctl: { l: Math.round(ctl.left), r: Math.round(ctl.right) },
    pop: pb && { l: Math.round(pb.left), r: Math.round(pb.right), t: Math.round(pb.top), b: Math.round(pb.bottom), w: Math.round(pb.width) },
  }
}, FIELD)

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  for (const [w, h] of [[1440, 900], [1024, 900], [830, 900], [1024, 420]]) {
    await p.setViewport({ width: w, height: h })
    await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector(FIELD, { visible: true, timeout: NAV_TIMEOUT })
    await p.click(FIELD, { clickCount: 3 })
    await p.type(FIELD, '2026-10-01 23:59')
    await p.keyboard.press('Enter')
    await sleep(150)
    await p.click('[data-test=issues-filter-deadline-date-open]')
    await p.waitForSelector('[data-test=deadline-picker]', { visible: true, timeout: 5000 })
    await sleep(150)
    const m = await measure(p)
    if (w === 1440) {
      ok('C1 the field is its text plus ~2 mm (8 +-1 px after the date), never scrolled', Math.abs(m.trailing - 8) <= 1 && !m.scrolls, m)
      ok('C2 the pop-up is at most 200 px wide', m.pop.w <= 200, m.pop)
    }
    const inside = m.pop.l >= 8 && m.pop.r <= m.vw - 8 && m.pop.t >= 8 && m.pop.b <= m.vh - 8
    ok(`C3 ${w}x${h}: the pop-up is fully inside the viewport`, inside, m)
    if (m.ctl.l + m.pop.w > m.vw - 8) ok(`C4 ${w}x${h}: near the right edge it opens to the left`, Math.abs(m.pop.r - m.ctl.r) <= 1 || m.pop.r === m.vw - 8, m)
    await p.keyboard.press('Escape')
  }
  /* C5..C7 at 1440 */
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(FIELD, { visible: true, timeout: NAV_TIMEOUT })
  const openPop = async () => {
    await p.click('[data-test=issues-filter-deadline-date-open]')
    await p.waitForSelector('[data-test=deadline-picker]', { visible: true, timeout: 5000 })
    await sleep(100)
  }
  const xSide = () => p.evaluate(() => {
    const pop = document.querySelector('[data-test=deadline-picker]').getBoundingClientRect()
    const xs = [...document.querySelectorAll('[data-test=deadline-picker] [data-test=deadline-picker-close]')]
    if (xs.length !== 1) return { n: xs.length }
    const x = xs[0].getBoundingClientRect()
    return { n: 1, side: x.left - pop.left < pop.right - x.right ? 'left' : 'right', top: Math.round(x.top - pop.top) }
  })
  await openPop()
  const done = await p.$$eval('[data-test=deadline-picker] button', (bs) => bs.filter((b) => /^\s*done\s*$/i.test(b.textContent) || b.getAttribute('data-test') === 'deadline-picker-done').length)
  const month = await p.$eval('[data-test=deadline-picker-month]', (el) => el.textContent.trim())
  await p.click(`[data-test=deadline-picker-day][data-date="${month}-15"]`)
  await sleep(150)
  const applied = await p.$eval(FIELD, (el) => el.value)
  const stillOpen = Boolean(await p.$('[data-test=deadline-picker]'))
  const mac = await xSide()
  await p.click('[data-test=deadline-picker] [data-test=deadline-picker-close]')
  await sleep(150)
  const closedByX = !(await p.$('[data-test=deadline-picker]'))
  ok('C5 no Done; a picked day applies at once; one x, top left (Mac default), and it closes the pop-up',
    done === 0 && applied.startsWith(`${month}-15 `) && stillOpen && mac.n === 1 && mac.side === 'left' && mac.top < 24 && closedByX, { done, applied, stillOpen, mac, closedByX })
  await openPop()
  await p.keyboard.press('Escape')
  await sleep(100)
  const escClosed = !(await p.$('[data-test=deadline-picker]'))
  await openPop()
  await p.mouse.click(700, 700)
  await sleep(100)
  const outsideClosed = !(await p.$('[data-test=deadline-picker]'))
  ok('C6 Esc and an outside click close the pop-up', escClosed && outsideClosed, { escClosed, outsideClosed })
  await p.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    s.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', close_buttons: 'windows' })
  })
  await sleep(200)
  await openPop()
  const win = await xSide()
  ok('C7 Windows style: the one x sits top right', win.n === 1 && win.side === 'right', win)

  ok('no page errors', errors.length === 0, errors)
} catch (e) {
  ok('harness', false, String(e && e.stack || e))
} finally {
  await browser.close()
  await server.stop?.()
}
const failed = results.filter((r) => !r.ok).length
console.log(`\ndeadline-picker: ${results.length - failed}/${results.length} passed`)
process.exit(failed ? 1 : 0)
