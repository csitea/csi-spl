// CLE-77851: a muted channel row is marked by a muted bell, NOT faded.
// csitea #csi-fina: a member saw her own channel pale (the row's opacity 0.55
// was the only "muted" cue) and read it as "inactive / not a member"; the
// fade also made the open row menu see-through. Runs against the lde mock.
//
// Desktop 1440x900, Channels tab, `alerts` muted in this browser:
//   1  an unmuted (member's own) channel row: no bell, not faded
//   2  the muted row: a visible muted bell named for the channel, the row and
//      its name drawn exactly like the unmuted one (opacity 1, same colour and
//      weight), the bell clear of the name and of the row menu button
//   3  the muted row's open menu is opaque (no faded ancestor) and offers Unmute
//   4  a click on the bell unmutes: bell gone, the browser list emptied, the
//      menu offers Mute again, and the click did not navigate
//   5  Mute from the menu brings the bell back
//
// Run:
//   node tests/e2e/row-muted-mark.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/row-muted-mark.test.mjs
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const KEY = 'spool.muted-channels'
const MUTED = 'alerts'

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

async function shot(p, name) {
  if (OUT) await p.screenshot({ path: `${OUT}/${name}.png` })
}

async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

const ROWS = '#sidebar-panel-channels .nav-row'
const railRow = (ch) => `#sidebar-panel-channels .nav-row[data-order="${ch}"]`
const bell = (ch) => `${railRow(ch)} [data-testid=row-muted]`
const menuBtn = (ch) => `${railRow(ch)} [data-testid=sidebar-row-menu]`
const PANEL = '[data-testid=sidebar-row-menu-panel]'

async function openChannels(p, path = '/channel/lobby') {
  await p.goto(`${p.base}${path}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await p.waitForSelector(ROWS, { visible: true, timeout: NAV_TIMEOUT })
  await sleep(400)
}

/** How a row is drawn: its effective opacity (row up to the panel), the name's colour and weight. */
const look = (p, ch) => p.$eval(railRow(ch), (row) => {
  let op = 1
  for (let e = row; e && e !== document.body; e = e.parentElement) op *= Number(getComputedStyle(e).opacity)
  const link = row.querySelector('.nav-item')
  const label = row.querySelector('.nav-item .label')
  const cs = getComputedStyle(label)
  return { op, linkOp: Number(getComputedStyle(link).opacity), color: cs.color, weight: cs.fontWeight, filter: getComputedStyle(row).filter }
})

/** The panel's effective opacity: its own times every ancestor's. */
const panelOpacity = (p) => p.$eval(PANEL, (el) => {
  let op = 1
  for (let e = el; e; e = e.parentElement) op *= Number(getComputedStyle(e).opacity)
  return op
})

async function menuItems(p, ch) {
  await p.click(menuBtn(ch))
  await p.waitForSelector(PANEL, { visible: true, timeout: 4000 })
  await sleep(150)
  return p.$$eval(`${PANEL} [role=menuitem]`, (els) => els.map((e) => e.getAttribute('data-testid').replace('sidebar-row-menu-', '')))
}
async function closeMenu(p) {
  await p.keyboard.press('Escape')
  await sleep(200)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  p.base = srv.base
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await openChannels(p)
  await p.evaluate(({ k, ch }) => localStorage.setItem(k, JSON.stringify([ch])), { k: KEY, ch: MUTED })
  await openChannels(p)

  const ids = await p.$$eval(ROWS, (els) => els.map((e) => e.getAttribute('data-order')))
  const plain = ids.find((id) => id !== MUTED && id !== 'lobby') || ids.find((id) => id !== MUTED)
  ok('seed: the muted channel and another channel are drawn', ids.includes(MUTED) && Boolean(plain), ids)

  /* ---- 1. an unmuted row: no bell, not faded ------------------------------------ */
  const plainLook = await look(p, plain)
  ok('1 an unmuted channel has no muted bell', (await p.$(bell(plain))) === null)
  ok('1 ... and is not faded', plainLook.op === 1 && plainLook.linkOp === 1, plainLook)

  /* ---- 2. the muted row: a bell, drawn like the others ---------------------------- */
  const b = await p.$(bell(MUTED))
  ok('2 the muted channel shows the muted bell', b !== null && (await b.isIntersectingViewport()))
  const name = await p.$eval(`${railRow(MUTED)} .nav-item .label`, (e) => e.textContent.trim())
  const aria = b ? await b.evaluate((e) => ({ label: e.getAttribute('aria-label') || '', title: e.getAttribute('title') || '', tag: e.tagName })) : {}
  ok('2 the bell is a button named for the channel, saying how to unmute', aria.tag === 'BUTTON' && aria.label.includes(name) && /unmute/i.test(aria.label) && aria.title === aria.label, aria)
  const mutedLook = await look(p, MUTED)
  ok('2 the muted row is NOT faded (opacity 1, no filter)', mutedLook.op === 1 && mutedLook.linkOp === 1 && mutedLook.filter === 'none', mutedLook)
  ok('2 its name has the same colour and weight as an unmuted channel', mutedLook.color === plainLook.color && mutedLook.weight === plainLook.weight, { muted: mutedLook, plain: plainLook })
  const boxes = await p.$eval(railRow(MUTED), (row) => {
    const r = (sel) => { const x = row.querySelector(sel).getBoundingClientRect(); return { l: x.left, r: x.right, t: x.top, b: x.bottom } }
    return { bell: r('[data-testid=row-muted]'), menu: r('[data-testid=sidebar-row-menu]'), label: r('.nav-item .label') }
  })
  const apart = (a, c) => a.r <= c.l || c.r <= a.l || a.b <= c.t || c.b <= a.t
  ok('2 the bell sits clear of the row menu button and of the name', apart(boxes.bell, boxes.menu) && apart(boxes.bell, boxes.label), boxes)
  await shot(p, '2-muted-row')

  /* ---- 3. the muted row's menu is opaque and offers Unmute ------------------------- */
  const items3 = await menuItems(p, MUTED)
  ok('3 the muted row\'s menu offers Unmute', items3.includes('mute'), items3)
  const unmuteText = await p.$eval(`${PANEL} [data-testid=sidebar-row-menu-mute]`, (e) => e.textContent.trim())
  ok('3 ... labelled Unmute', /unmute/i.test(unmuteText), unmuteText)
  const op3 = await panelOpacity(p)
  ok('3 the open menu is opaque (no faded ancestor)', op3 === 1, op3)
  await shot(p, '3-muted-menu')
  await closeMenu(p)

  /* ---- 4. a click on the bell unmutes ---------------------------------------------- */
  const path4 = await p.evaluate(() => location.pathname)
  await p.click(bell(MUTED))
  const gone = await until(p, (sel) => !document.querySelector(sel), bell(MUTED))
  ok('4 a click on the bell unmutes: the bell is gone', gone)
  const stored = await p.evaluate((k) => localStorage.getItem(k), KEY)
  ok('4 ... and the browser\'s muted list no longer holds it', !String(stored).includes(MUTED), stored)
  ok('4 ... and the click did not navigate', (await p.evaluate(() => location.pathname)) === path4)
  const text4 = (await menuItems(p, MUTED)) && await p.$eval(`${PANEL} [data-testid=sidebar-row-menu-mute]`, (e) => e.textContent.trim())
  ok('4 the menu offers Mute again', /^mute$/i.test(text4), text4)

  /* ---- 5. Mute from the menu brings the bell back ----------------------------------- */
  await p.click(`${PANEL} [data-testid=sidebar-row-menu-mute]`)
  const back = await until(p, (sel) => Boolean(document.querySelector(sel)), bell(MUTED))
  ok('5 Mute from the menu shows the bell again', back)
  ok('5 ... and the row is still not faded', (await look(p, MUTED)).op === 1)
  await shot(p, '5-muted-again')

  ok('no page errors', errors.length === 0, errors)
  await p.close()
} catch (e) {
  console.error(e)
  results.push({ name: 'threw', ok: false })
} finally {
  await browser.close()
  await srv.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nrow-muted-mark: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
