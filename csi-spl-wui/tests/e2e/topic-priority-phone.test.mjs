// SPL-5288 (owner HUM-10, t1 2fafde5c, msgs b6a2468d and 0b66d67c): "The size
// of the priority bar with 1, 2, 3, 4, 5 should be 70% smaller on mobile, and
// it should be center-aligned." "And the label next to it should not be called
// "priority" but just "prio"." Real browser, mock tenant:
//
//   phone 360, 390  the topic pane's 1..5 bar is drawn at 30% (+-3%) of its old
//                   width and height (222 x 46 px), centred in its row (left
//                   and right gaps equal +-2 px), the label "Prio" beside it;
//                   each value is tapped and saves, also 15 px above its drawn
//                   cell (the 44 px tall target the radio keeps)
//   phone 390       the open note's bar has the same drawn size and saves
//   desktop 1440    the bar keeps its old size (159.5 x 29.6 px)
//
//   BASE_URL=<generated bundle> node tests/e2e/topic-priority-phone.test.mjs
//   SHOT_DIR=<dir> also writes topic-priority-phone-<width>.png
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const LIVE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
const CHOOSER = '[data-test=topic-section] [data-testid=topic-priority]'
/* the bar before SPL-5288, measured on c10b3ce97 with this file's probe */
const OLD_PHONE = { w: 222, h: 46 }
const OLD_DESKTOP = { w: 159.5, h: 29.6 }
const SHARE = 0.30
const SHARE_TOL = 0.03

const results = []
function check(name, pass, ev) {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  const href = pathToFileURL(require.resolve('puppeteer-core')).href
  const mod = await import(href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    defaultViewport: null,
    args: CHROME_LAUNCH_ARGS,
  })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)

async function openPage(browser, base, width) {
  const p = await browser.newPage()
  const phone = width < 600
  await p.setViewport({ width, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  await p.evaluateOnNewDocument((claims) => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
    try { localStorage.setItem('spool.mock.session', JSON.stringify(claims)) } catch { /* about:blank */ }
  }, CLAIMS)
  await p.goto(`${base}/`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-testid=sidebar-rail]', { timeout: NAV })
  return p
}

async function openTopic(p) {
  await p.evaluate(async (to) => {
    await document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to)
  }, `/lobby?topic=${LIVE}`)
  await p.waitForSelector(`${CHOOSER} input[type=radio]`, { timeout: 15000 })
  await sleep(400)
}

/* the drawn bar, its row, its label, and each value's cell and radio */
const shape = (sel) => {
  const c = document.querySelector(sel)
  if (!c) return null
  const R = (e) => { const r = e.getBoundingClientRect(); return { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height } }
  const g = R(c.querySelector('[role=radiogroup]'))
  const row = R(c.parentElement)
  const label = c.querySelector('[id$=-label]')
  return {
    bar: g,
    gapL: g.l - row.l,
    gapR: row.r - g.r,
    label: label ? label.textContent.trim() : '',
    labelLeftOfBar: label ? R(label).r <= g.l + 1 : false,
    cells: [...c.querySelectorAll('label')].map((e) => R(e)),
    radios: [...c.querySelectorAll('input[type=radio]')].map((e) => R(e)),
  }
}

const within = (v, old) => v >= old * (SHARE - SHARE_TOL) && v <= old * (SHARE + SHARE_TOL)
const checked = (p, sel) => p.$eval(sel, (c) => c.querySelector('input[type=radio]:checked')?.value || '')

/* a finger on value n: the drawn cell's centre, moved dy px */
async function tapValue(p, sel, n, dy = 0) {
  const s = await p.evaluate(shape, sel)
  const c = s.cells[n - 1]
  await p.touchscreen.tap(c.l + c.w / 2, c.t + c.h / 2 + dy)
}

async function phoneTopic(browser, base, width) {
  const tag = `phone ${width}`
  const p = await openPage(browser, base, width)
  await openTopic(p)
  const s = await p.evaluate(shape, CHOOSER)
  const ev = { w: s.bar.w, h: s.bar.h, oldW: OLD_PHONE.w, oldH: OLD_PHONE.h }
  check(`${tag}: the bar is drawn at 30% (+-3%) of its old width`, within(s.bar.w, OLD_PHONE.w), ev)
  check(`${tag}: the bar is drawn at 30% (+-3%) of its old height`, within(s.bar.h, OLD_PHONE.h), ev)
  check(`${tag}: the bar is centred in its row (gaps equal +-2 px)`, Math.abs(s.gapL - s.gapR) <= 2, { gapL: s.gapL, gapR: s.gapR })
  check(`${tag}: the label reads "Prio", beside the bar`, s.label === 'Prio' && s.labelLeftOfBar, { label: s.label, left: s.labelLeftOfBar })
  check(`${tag}: each value's radio is a 44 px tall target`, s.radios.every((r) => r.h >= 44), s.radios.map((r) => r.h))
  for (const n of [1, 2, 4, 5, 3]) {
    await tapValue(p, CHOOSER, n)
    const ok = await p.waitForFunction((sel, n) => {
      const el = document.querySelector(sel)
      return el?.getAttribute('data-priority') === String(n) && new RegExp(`Priority set to ${n}\\.`).test(el.textContent || '')
    }, { timeout: 8000 }, CHOOSER, n).then(() => true, () => false)
    check(`${tag}: a tap on ${n} checks it and saves`, ok && (await checked(p, CHOOSER)) === String(n), await checked(p, CHOOSER))
  }
  await tapValue(p, CHOOSER, 2, -15)
  const above = await p.waitForFunction((sel) => document.querySelector(sel)?.getAttribute('data-priority') === '2', { timeout: 8000 }, CHOOSER).then(() => true, () => false)
  check(`${tag}: a tap 15 px above the drawn 2 still takes 2`, above, await checked(p, CHOOSER))
  check(`${tag}: no sideways scroll`, await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/topic-priority-phone-${width}.png` })
  const errs = (await p.evaluate(() => window.__errs || [])).filter((e) => !/dynamically imported module/.test(e))
  check(`${tag}: no window error`, errs.length === 0, { errs })
  await p.close()
}

async function phoneNote(browser, base, width) {
  const tag = `phone ${width} note`
  const sel = '[data-test=note-priority]'
  const p = await openPage(browser, base, width)
  await p.goto(`${base}/notes?note=mock-note-1`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector(`${sel} input[type=radio]`, { timeout: 15000 })
  await sleep(400)
  const s = await p.evaluate(shape, sel)
  const ev = { w: s.bar.w, h: s.bar.h }
  check(`${tag}: the bar is drawn at 30% (+-3%) of the old width and height`, within(s.bar.w, OLD_PHONE.w) && within(s.bar.h, OLD_PHONE.h), ev)
  check(`${tag}: each value's radio is a 44 px tall target`, s.radios.every((r) => r.h >= 44), s.radios.map((r) => r.h))
  const before = await checked(p, sel)
  const n = before === '2' ? 4 : 2
  await tapValue(p, sel, n)
  const ok = await p.waitForFunction((sel, n) => document.querySelector(sel)?.getAttribute('data-priority') === String(n), { timeout: 8000 }, sel, n).then(() => true, () => false)
  check(`${tag}: a tap on ${n} checks it and saves`, ok, await checked(p, sel))
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/note-priority-phone-${width}.png` })
  await p.close()
}

async function desktop(browser, base, width) {
  const tag = `desktop ${width}`
  const p = await openPage(browser, base, width)
  await openTopic(p)
  const s = await p.evaluate(shape, CHOOSER)
  check(`${tag}: the bar keeps its old size (+-1 px)`, Math.abs(s.bar.w - OLD_DESKTOP.w) <= 1 && Math.abs(s.bar.h - OLD_DESKTOP.h) <= 1, { w: s.bar.w, h: s.bar.h, old: OLD_DESKTOP })
  check(`${tag}: the label reads "Prio"`, s.label === 'Prio', s.label)
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [360, 390]) await phoneTopic(browser, server.base, w)
  await phoneNote(browser, server.base, 390)
  await desktop(browser, server.base, 1440)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-priority-phone: ${results.length - failed.length}/${results.length} passed`)
if (failed.length || code) process.exit(1)
