// SPL-5349 (owner HUM-10, t1 2fafde5c, option A of the mocks; was SPL-5288's
// 70%-smaller centred phone bar): "The prio should not be with a capital P
// but with a small p, and there should be a semicolon after it." "Show it,
// but for a quick, small, less-than-1-second on the right of the priority,
// and then it should fade." The bar sits on the topic header's second row,
// left, the same size as the card-size control (itself 30% lower, a little
// wider); the full title is row 1. Real browser, mock tenant:
//
//   phone 360, 390  the 1..5 bar is drawn 177 x 32 px (+-3%) - at least 1.5x
//                   the SPL-5288 height and 1.8x its width - as tall as the
//                   card-size control, left-aligned on row 2 under the title,
//                   the control at the row's right; the label "prio:" left
//                   of the bar; each value is tapped and saves, also 15 px
//                   above its drawn cell (the 44 px tall target the radio
//                   keeps); after a pick "✓ N" sits right of the bar, adds no
//                   height, and is gone by 1000 ms (also with reduced motion)
//   phone 390       the open note's bar has the same drawn size and saves
//   desktop 1440    bar 132 x 18 px, card-size control 80 x 18, both on row 2
//                   (bar left, control right), the full title on row 1
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
const CLIP = '[data-test=topic-section] [data-testid=card-clip-control]'
/* the SPL-5288 phone bar, measured on a39fd1e02 with this file's probe */
const SPL5288_PHONE = { w: 63.9, h: 13.8 }
/* option A as mocked: cells 35 x 30 (phone), 26 x 16 (desktop), 1 px border */
const PHONE = { w: 177, h: 32 }
const DESKTOP = { w: 132, h: 18 }
const DESKTOP_CLIP = { w: 80, h: 18 }
const TOL = 0.03

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
  const row = R(c.closest('.topic-head__row2') || c.parentElement)
  const label = c.querySelector('[id$=-label]')
  const clip = document.querySelector('[data-test=topic-section] [data-testid=card-clip-control]')
  const title = document.querySelector('[data-test=topic-section] [data-test=topic-heading]')
  return {
    bar: g,
    row,
    clip: clip ? R(clip) : null,
    title: title ? { ...R(title), cut: title.scrollWidth > title.clientWidth + 1 || title.scrollHeight > title.clientHeight + 1 } : null,
    head: (() => { const h = document.querySelector('[data-test=topic-section] > header'); return h ? R(h) : null })(),
    labelBox: label ? R(label) : null,
    label: label ? label.textContent.trim() : '',
    labelLeftOfBar: label ? R(label).r <= g.l + 1 : false,
    cells: [...c.querySelectorAll('label')].map((e) => R(e)),
    radios: [...c.querySelectorAll('input[type=radio]')].map((e) => R(e)),
    checkedValue: c.querySelector('input[type=radio]:checked')?.value || '',
  }
}

const near = (v, want) => Math.abs(v - want) <= want * TOL
const checked = (p, sel) => p.$eval(sel, (c) => c.querySelector('input[type=radio]:checked')?.value || '')

/* every point of the grid dx -4/0/+4, dy -21/-15/0/+15/+21 around each value's
   drawn centre that does NOT hit that value's radio: a round radio is
   hit-tested as an ellipse (R7 c-611, W1) */
function missedHits(sel) {
  const miss = []
  document.querySelectorAll(`${sel} label`).forEach((cell, i) => {
    const r = cell.getBoundingClientRect()
    for (const dx of [-4, 0, 4]) for (const dy of [-21, -15, 0, 15, 21]) {
      const hit = document.elementFromPoint(r.left + r.width / 2 + dx, r.top + r.height / 2 + dy)
      if (hit !== cell.querySelector('input[type=radio]')) miss.push(`${i + 1}@${dx},${dy}:${hit ? hit.tagName : 'none'}`)
    }
  })
  return miss
}

/* a finger on value n: the drawn cell's centre, moved dy px */
async function tapValue(p, sel, n, dy = 0) {
  const s = await p.evaluate(shape, sel)
  const c = s.cells[n - 1]
  await p.touchscreen.tap(c.l + c.w / 2, c.t + c.h / 2 + dy)
}

/* row 1 = the whole title; row 2 = the bar at the left, the card-size
   control at the right, both the same height */
function rowChecks(tag, s) {
  check(`${tag}: the title is shown whole (not cut)`, s.title && !s.title.cut, s.title)
  check(`${tag}: row 2 is under the title`, s.title && s.row.t >= s.title.b - 1, { row: s.row.t, titleBottom: s.title?.b })
  check(`${tag}: the bar starts row 2 (label at its left edge, +-12 px)`, s.labelBox && s.labelBox.l - s.row.l <= 12, { row: s.row.l, label: s.labelBox?.l })
  check(`${tag}: the card-size control ends row 2, right of the bar`, s.clip && s.clip.l > s.bar.r && s.row.r - s.clip.r <= 12, { clip: s.clip, row: s.row })
  check(`${tag}: the bar is as tall as the card-size control (+-1 px), on one line`,
    s.clip && Math.abs(s.clip.h - s.bar.h) <= 1 && Math.abs((s.clip.t + s.clip.b) / 2 - (s.bar.t + s.bar.b) / 2) <= 2, { bar: s.bar.h, clip: s.clip?.h })
}

/* "✓ N" right of the bar after a pick: no added height, gone by 1000 ms */
async function okChecks(p, tag, pick) {
  const OK = `${CHOOSER} [data-testid=topic-priority-ok]`
  for (const motion of ['no-preference', 'reduce']) {
    const t2 = `${tag} (${motion} motion)`
    await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: motion }])
    const before = await p.evaluate(shape, CHOOSER)
    const target = before.cells.findIndex((c, i) => i + 1 !== Number(before.checkedValue)) + 1
    const t0 = Date.now()
    await pick(target)
    const seen = await p.waitForSelector(OK, { timeout: 900 }).then(() => true, () => false)
    const ok = seen ? await p.evaluate((sel, chooser) => {
      const o = document.querySelector(sel).getBoundingClientRect()
      const g = document.querySelector(`${chooser} [role=radiogroup]`).getBoundingClientRect()
      const h = document.querySelector('[data-test=topic-section] > header').getBoundingClientRect().height
      return { okL: o.left, barR: g.right, okMid: (o.top + o.bottom) / 2, barT: g.top, barB: g.bottom, headH: h, text: document.querySelector(sel).textContent }
    }, OK, CHOOSER) : null
    const at = Date.now() - t0
    check(`${t2}: after a pick a check shows right of the bar (seen at ${at} ms)`, ok && ok.okL >= ok.barR && ok.okMid >= ok.barT && ok.okMid <= ok.barB, ok)
    check(`${t2}: the check adds no height to the header`, ok && Math.abs(ok.headH - before.head.h) <= 0.5, { before: before.head.h, after: ok?.headH })
    const wait = 1000 - (Date.now() - t0)
    if (wait > 0) await sleep(wait)
    const gone = await p.evaluate((sel) => {
      const o = document.querySelector(sel)
      return !o || Number(getComputedStyle(o).opacity) === 0 || o.getBoundingClientRect().width === 0
    }, OK)
    check(`${t2}: the check is gone by 1000 ms after the pick`, gone, { elapsed: Date.now() - t0 })
    const sr = await p.$eval(`${CHOOSER} [role=status]`, (e) => e.textContent.trim())
    check(`${t2}: screen readers still hear the whole sentence`, /^Priority set to \d\.$/.test(sr), sr)
  }
  await p.emulateMediaFeatures([{ name: 'prefers-reduced-motion', value: 'no-preference' }])
}

async function phoneTopic(browser, base, width) {
  const tag = `phone ${width}`
  const p = await openPage(browser, base, width)
  await openTopic(p)
  const s = await p.evaluate(shape, CHOOSER)
  const ev = { w: s.bar.w, h: s.bar.h, want: PHONE }
  check(`${tag}: the bar is drawn ${PHONE.w} x ${PHONE.h} px (+-3%)`, near(s.bar.w, PHONE.w) && near(s.bar.h, PHONE.h), ev)
  check(`${tag}: the bar is >= 1.5x the SPL-5288 height and >= 1.8x its width`, s.bar.h >= 1.5 * SPL5288_PHONE.h && s.bar.w >= 1.8 * SPL5288_PHONE.w, ev)
  rowChecks(tag, s)
  check(`${tag}: the label reads "prio:", left of the bar`, s.label === 'prio:' && s.labelLeftOfBar, { label: s.label, left: s.labelLeftOfBar })
  check(`${tag}: each value's radio is a 44 px tall target`, s.radios.every((r) => r.h >= 44), s.radios.map((r) => r.h))
  const missT = await p.evaluate(missedHits, CHOOSER)
  check(`${tag}: each value is hit at dx +-4, dy +-21 around its centre`, missT.length === 0, missT)
  if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/topic-priority-phone-${width}-before.png`, clip: { x: 0, y: 0, width, height: 360 } })
  await okChecks(p, tag, (n) => tapValue(p, CHOOSER, n))
  for (const n of [1, 4, 5, 3]) {
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
  const ev = { w: s.bar.w, h: s.bar.h, want: PHONE }
  check(`${tag}: the bar is drawn ${PHONE.w} x ${PHONE.h} px (+-3%), as the topic's`, near(s.bar.w, PHONE.w) && near(s.bar.h, PHONE.h), ev)
  check(`${tag}: each value's radio is a 44 px tall target`, s.radios.every((r) => r.h >= 44), s.radios.map((r) => r.h))
  const missN = await p.evaluate(missedHits, sel)
  check(`${tag}: each value is hit at dx +-4, dy +-21 around its centre`, missN.length === 0, missN)
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
  check(`${tag}: the bar is drawn ${DESKTOP.w} x ${DESKTOP.h} px (+-3%)`, near(s.bar.w, DESKTOP.w) && near(s.bar.h, DESKTOP.h), { w: s.bar.w, h: s.bar.h })
  check(`${tag}: the card-size control is ${DESKTOP_CLIP.w} x ${DESKTOP_CLIP.h} px (+-3%)`, s.clip && near(s.clip.w, DESKTOP_CLIP.w) && near(s.clip.h, DESKTOP_CLIP.h), s.clip)
  rowChecks(tag, s)
  check(`${tag}: the label reads "prio:"`, s.label === 'prio:', s.label)
  await okChecks(p, tag, (n) => p.click(`${CHOOSER} [data-testid=topic-priority-${n}]`))
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
