// SPL-2503, owner HUM-10 (t1 7ff1521d, phone, a thread open, the omnibox
// dragged taller): "The position of the search button seems a bit off and
// funny when the omnibox is resized" (msg c9bc359f) and "there is this
// strange vertical line there" (msg a980ea90). Same lane, t1 8de4c254 (msg
// a80f71d8): "it should be possible to resize the Omnibox up to the top
// button section".
//
//   phone (393x851, touch, the mock), a thread open (level 3):
//     1 CONTROL one line: Search, Back, Attach and Send share one bottom line
//     2 the size handle dragged to the top of the screen: the field grows
//       until the grip meets the topic header (back, title, the three view
//       buttons), never over it - was half the room under the top bar
//     3 resized: Search still sits on the bottom line with Back, Attach and
//       Send - was pinned to the field's top
//     4 resized with a long draft (the field scrolls): no scrollbar is drawn
//       down the text's edge (the "vertical line") - checked with classic
//       scrollbars, 393 px wide without touch emulation
//   desktop (1440x900):
//     5 CONTROL the top bar box: "?" stays in the field's top corner, level
//       with Attach and Send
//     6 the bottom dock (Settings: Omnibox at the bottom): the grip dragged
//       up grows the box to just under the middle pane's header - was 60%
//       of the room under the top bar
//
// Run:
//   pnpm run test:e2e omnibox-resize-align
//   BASE_URL=<generated bundle> pnpm run test:e2e omnibox-resize-align   # what CI does
//   SHOTS=<dir> ... also writes the phone and desktop views there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const PATH = '/channel/alerts'
const TA = 'form.composer.omnibox--global textarea'
const PHONE = { width: 393, height: 851, isMobile: true, hasTouch: true, deviceScaleFactor: 2 }

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const near = (a, b, d = 2) => typeof a === 'number' && typeof b === 'number' && Math.abs(a - b) <= d

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
        /* step 4 needs the scrollbars a real browser draws */
        ignoreDefaultArgs: ['--hide-scrollbars'],
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Where the box, its controls and the header row over it are. */
const facts = (p) => p.evaluate(() => {
  const R = (e) => {
    if (!e || !e.getClientRects().length) return null
    const r = e.getBoundingClientRect()
    return { l: Math.round(r.left), t: Math.round(r.top), r: Math.round(r.right), b: Math.round(r.bottom) }
  }
  const f = document.querySelector('form.composer.omnibox--global')
  if (!f) return null
  const ta = f.querySelector('textarea')
  const bar = document.querySelector('[data-test=top-bar]')
  const barBottom = bar ? bar.getBoundingClientRect().bottom : 0
  /* the header row right under the top bar over the box (its middle); on a
     phone past level 1 the section strip sits between them (SPL-3785) */
  const strip = document.querySelector('.spool-shell[data-mobile-section] > .sidebar')
  const ceil = Math.max(barBottom, strip ? strip.getBoundingClientRect().bottom : 0)
  const fr = f.getBoundingClientRect()
  const x = fr.left + fr.width / 2
  const rows = [...document.querySelectorAll('.spool-shell header, .spool-shell .feed-header')]
    .map((e) => e.getBoundingClientRect())
    .filter((r) => r.height > 0 && r.top <= ceil + 1 && r.bottom > ceil + 1 && r.left <= x && r.right >= x)
  let stored = null
  try { stored = JSON.parse(localStorage.getItem('spool.omnibox-phone-size') || 'null') } catch { /* denied */ }
  return {
    vw: innerWidth,
    vh: innerHeight,
    barBottom: Math.round(barBottom),
    header: rows.length ? Math.round(Math.max(...rows.map((r) => r.bottom))) : null,
    form: R(f),
    field: R(f.querySelector('.omnibox-field')),
    ta: R(ta),
    scrollbar: ta ? ta.offsetWidth - ta.clientWidth : null,
    scrolls: ta ? ta.scrollHeight > ta.clientHeight : null,
    search: R(f.querySelector('.search-syntax-btn')),
    back: R(f.querySelector('[data-testid=dock-back]')),
    attach: R(f.querySelector('[data-testid=attach]')),
    send: R(f.querySelector('[data-testid=send]')),
    size: R(document.querySelector('[data-testid=omnibox-size]')),
    grip: R(document.querySelector('[data-testid=omnibox-grip]')),
    resize: R(f.querySelector('[data-test=omnibox-resize]')),
    stored,
  }
})

/* two reads 100 ms apart agree: a resize has landed */
async function settled(p) {
  let prev = JSON.stringify(await facts(p))
  for (let i = 0; i < 50; i++) {
    await sleep(100)
    const v = await facts(p)
    const now = JSON.stringify(v)
    if (now === prev) return v
    prev = now
  }
  return facts(p)
}

async function open(browser, vp, size) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport(vp)
  await p.goto(server.base + PATH, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((s) => {
    try {
      if (s) localStorage.setItem('spool.omnibox-phone-size', JSON.stringify(s))
      else localStorage.removeItem('spool.omnibox-phone-size')
      localStorage.removeItem('spool.omnibox-phone-pos')
    } catch { /* denied */ }
  }, size || null)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  await p.waitForFunction(() => Boolean(document.querySelector('#__nuxt')?.__vue_app__), { timeout: NAV_TIMEOUT })
  await sleep(400)
  return { p, errors }
}

/* tap (touch) or click the first card: its thread opens (level 3 on a phone) */
async function openThread(p, touch) {
  const c = await p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    const r = (el.querySelector('.msg-body') || el).getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) }
  })
  if (touch) await p.touchscreen.tap(c.x, c.y)
  else await p.mouse.click(c.x, c.y)
  await sleep(700)
}

async function touchDrag(p, from, to) {
  await p.touchscreen.touchStart(from.x, from.y)
  const n = 12
  for (let i = 1; i <= n; i++) {
    await p.touchscreen.touchMove(from.x + ((to.x - from.x) * i) / n, from.y + ((to.y - from.y) * i) / n)
    await sleep(16)
  }
  await p.touchscreen.touchEnd()
  return settled(p)
}

const bottomLine = (f) => Boolean(f.search && f.back && f.attach && f.send
  && near(f.search.b, f.send.b) && near(f.search.b, f.attach.b) && near(f.search.b, f.back.b))

async function phone(browser) {
  const { p, errors } = await open(browser, PHONE)
  await openThread(p, true)
  await p.focus(TA)
  const f1 = await settled(p)
  ok('393px 1 CONTROL one line: Search, Back, Attach and Send share the bottom line', bottomLine(f1),
    { search: f1.search, back: f1.back, attach: f1.attach, send: f1.send })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-resize-393-default.png') })

  const s = f1.size
  const f2 = await touchDrag(p, { x: (s.l + s.r) / 2, y: (s.t + s.b) / 2 }, { x: (s.l + s.r) / 2, y: 1 })
  const gripTop = Math.min(f2.size?.t ?? 1e9, f2.grip?.t ?? 1e9)
  ok('393px 2 LIMIT: dragged to the top, the field grows until the grip meets the topic header, never over it',
    Boolean(f2.header != null && f2.header > f2.barBottom && gripTop >= f2.header - 1 && gripTop <= f2.header + 6 && f2.stored && f2.stored.bottom > 0.5),
    { header: f2.header, barBottom: f2.barBottom, gripTop, form: f2.form, stored: f2.stored })
  ok('393px 3 resized: Search sits on the bottom line with Back, Attach and Send', bottomLine(f2) && f2.field.t < f2.search.t - 100,
    { field: f2.field, search: f2.search, back: f2.back, attach: f2.attach, send: f2.send })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-resize-393-resized.png') })
  ok('393px no page error', errors.length === 0, errors)
  await p.close()

  /* 4: classic scrollbars (no touch emulation) at the phone width */
  const q = await open(browser, { width: 393, height: 851 }, { bottom: 0.5 })
  await openThread(q.p, false)
  await q.p.focus(TA)
  await q.p.evaluate((sel) => {
    const ta = document.querySelector(sel)
    ta.value = Array.from({ length: 60 }, (_, i) => `line ${i}`).join('\n')
    ta.dispatchEvent(new Event('input', { bubbles: true }))
  }, TA)
  const f4 = await settled(q.p)
  ok('393px 4 resized, a long draft scrolls the field: no scrollbar drawn down its edge', Boolean(f4.scrolls && f4.scrollbar === 0),
    { scrolls: f4.scrolls, scrollbar: f4.scrollbar, ta: f4.ta })
  if (SHOTS) await q.p.screenshot({ path: join(SHOTS, 'omnibox-resize-393-long-draft.png') })
  await q.p.close()
}

/** Adopt a member session; `pos` = the composer_position claim. */
const setPosition = (p, pos) => p.evaluate((pos) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ ...(session.claims || {}), hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', composer_position: pos })
  return true
}, pos)

async function desktop(browser) {
  const { p, errors } = await open(browser, { width: 1440, height: 900 })
  await openThread(p, false)
  await p.focus(TA)
  const f5 = await settled(p)
  ok('1440px 5 CONTROL top bar: "?" in the field\'s top corner, Attach and Send level with the field\'s top',
    Boolean(f5.search && f5.attach && f5.send && f5.search.t - f5.field.t <= 10 && near(f5.attach.t, f5.field.t, 3)),
    { field: f5.field, search: f5.search, attach: f5.attach, send: f5.send })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-resize-1440-default.png') })

  await setPosition(p, 'bottom')
  await sleep(500)
  await p.focus(TA)
  const f6a = await settled(p)
  const r = f6a.resize
  if (r) {
    await p.mouse.move((r.l + r.r) / 2, (r.t + r.b) / 2)
    await p.mouse.down()
    await p.mouse.move((r.l + r.r) / 2, 2, { steps: 12 })
    await p.mouse.up()
  }
  const f6 = await settled(p)
  ok('1440px 6 bottom dock: the grip dragged up grows the box to just under the middle pane\'s header',
    Boolean(r && f6.header != null && f6.field.t >= f6.header && f6.field.t <= f6.header + 24),
    { header: f6.header, field: f6.field, before: f6a.field })
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'omnibox-resize-1440-bottom-resized.png') })
  ok('1440px no page error', errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
let browser
try {
  browser = await launch()
  await phone(browser)
  await desktop(browser)
} catch (e) {
  ok('the run finished', false, String(e && e.stack || e).slice(0, 400))
} finally {
  await browser?.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`omnibox-resize-align: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
