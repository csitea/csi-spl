// SPL-6175 (spec 155 2.6, B6 + D8): on a phone a press held on a note row
// lifts it and the finger drags it up or down; the release lands it as the
// desktop drop does, so a drop onto a run of another priority takes that
// priority. Owner HUM-10, t1 cc9d7c26, msg 82670a2e: "just keeping the thumb
// down would activate the dragging mode, and then one would be able to drag a
// note up or down based on its priority. The priority, of course, will change."
// Runs against the lde mock (no hub).
//
// Phone 390x844, REAL touch input (CDP touch events):
//   1  a press held on a P5 row lifts it (the row is marked lifted); the
//      finger drags it above the P2 row and lets go: it is drawn first and is
//      now a P2, still after the list is read again; no note opened. Then
//      the P2 mock-note-2 dragged down past the first P5 row becomes a P5
//   2  a tap on a row opens the note
//   3  CONTROL: a quick swipe on a row scrolls the list, lifts and moves
//      nothing and opens no note
//   4  a hold released in place moves nothing, opens no note and no row menu
//   5  a touch contextmenu (synthetic: headless CDP touch fires none) opens no
//      row menu at 390 px; at 1280 px the same event still opens it
// CONTROL: on the parent (no touch drag on a phone, notes.vue draggable off),
// case 1 FAILS and 2..4 stay OK.
//
// Run:
//   node tests/e2e/notes-phone-long-press-drag.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/notes-phone-long-press-drag.test.mjs   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const FILLER = 14

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const rows = (p) => p.$$eval('[data-test=notes-group-rest] [data-test=notes-row]', (els) => els.map((e) => e.getAttribute('data-note-id')))
const noteQuery = (p) => p.evaluate(() => new URL(location.href).searchParams.get('note') || '')
const priority = (p, id) => p.evaluate((id) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes').notes.find((n) => n.id === id)?.priority, id)
const lifted = (p) => p.$$eval('.notes-row--lifted', (els) => els.map((e) => e.getAttribute('data-note-id')))
const menuOpen = (p) => p.evaluate(() => Boolean(document.querySelector('[data-testid=note-actions-menu]')))
const refetch = async (p) => { await p.evaluate(() => window.dispatchEvent(new Event('focus'))); await sleep(500) }

/* the middle of a row's open link, scrolled into view */
const centre = (p, id) => p.evaluate((id) => {
  const e = document.querySelector(`[data-note-id="${id}"] [data-test=notes-open]`)
  if (!e) return null
  e.scrollIntoView({ block: 'center' })
  const r = e.getBoundingClientRect()
  return { x: r.left + r.width * 0.4, y: r.top + r.height / 2, top: r.top }
}, id)
/* the scroll offset of the box the rows scroll in */
const listTop = (p) => p.evaluate(() => {
  for (let e = document.querySelector('[data-test=notes-row]')?.parentElement; e; e = e.parentElement) {
    const oy = getComputedStyle(e).overflowY
    if ((oy === 'auto' || oy === 'scroll') && e.scrollHeight > e.clientHeight) return { top: e.scrollTop, room: e.scrollHeight - e.clientHeight }
  }
  const d = document.scrollingElement
  return { top: d.scrollTop, room: d.scrollHeight - d.clientHeight }
})
async function walk(p, a, b, n, ms) {
  for (let i = 1; i <= n; i++) {
    await p.touchscreen.touchMove(a.x + ((b.x - a.x) * i) / n, a.y + ((b.y - a.y) * i) / n)
    await sleep(ms)
  }
}

/* mock-note-2 a P2, then FILLER P5 notes after mock-note-3, so the list scrolls */
const seed = (p, filler) => p.evaluate(async (filler) => {
  const store = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notes')
  await store.patch('mock-note-2', { priority: 2 })
  for (let i = 0; i < filler; i++) {
    const id = await store.create()
    await store.patch(id, { title: `Filler ${i}`, position: 100 + i })
  }
  await store.load()
}, filler)

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(`${srv.base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await go(p, '/notes')
  await p.waitForSelector('[data-test=notes-row]', { visible: true, timeout: NAV })
  await seed(p, FILLER)
  await sleep(500)
  const start = await rows(p)
  ok('0 seed: the P2 note is drawn above the P5 note', start[0] === 'mock-note-2' && start[1] === 'mock-note-3' && start.length === FILLER + 2, start)

  /* ---- 1. hold mock-note-3, drag it above mock-note-2, let go ------------ */
  const from = await centre(p, 'mock-note-3')
  const above = await centre(p, 'mock-note-2')
  await p.touchscreen.touchStart(from.x, from.y)
  await sleep(700)
  const up = await lifted(p)
  ok('1 a press held on a row lifts it', up.length === 1 && up[0] === 'mock-note-3', up)
  await walk(p, from, { x: from.x, y: above.top + 2 }, 8, 30)
  await sleep(150)
  const mid = await rows(p)
  ok('1 while dragged the row is drawn where the finger is', mid[0] === 'mock-note-3', mid.slice(0, 3))
  await p.touchscreen.touchEnd()
  await sleep(600)
  const after = await rows(p)
  ok('1 the release places it first', after[0] === 'mock-note-3' && after[1] === 'mock-note-2', after.slice(0, 3))
  ok('1 ... and it takes the P2 of where it landed (D8)', (await priority(p, 'mock-note-3')) === 2, await priority(p, 'mock-note-3'))
  ok('1 ... and the release opens no note, the row is no longer lifted', (await noteQuery(p)) === '' && (await lifted(p)).length === 0)
  await refetch(p)
  const again = await rows(p)
  ok('1 ... still so after the list is read again', again[0] === 'mock-note-3' && (await priority(p, 'mock-note-3')) === 2, again.slice(0, 3))

  /* ---- 1b. drag mock-note-2 down past the first P5 row ------------------ */
  const filler0 = again[2]
  const d0 = await centre(p, 'mock-note-2')
  const below = await p.evaluate((id) => document.querySelector(`[data-note-id="${id}"]`).getBoundingClientRect().bottom, filler0)
  await p.touchscreen.touchStart(d0.x, d0.y)
  await sleep(700)
  await walk(p, d0, { x: d0.x, y: below - 2 }, 8, 30)
  await sleep(150)
  await p.touchscreen.touchEnd()
  await sleep(600)
  const down = await rows(p)
  ok('1b dragged down past the first P5 row, it lands after it', down[1] === filler0 && down[2] === 'mock-note-2', down.slice(0, 4))
  ok('1b ... and becomes a P5 (D8)', (await priority(p, 'mock-note-2')) === 5, await priority(p, 'mock-note-2'))

  /* ---- 2. a tap opens --------------------------------------------------- */
  await p.tap('[data-note-id="mock-note-2"] [data-test=notes-open]')
  const opened = await p.waitForSelector('[data-test=note-detail][data-note-id="mock-note-2"][data-state=ready]', { visible: true, timeout: 15000 }).then(() => true, () => false)
  ok('2 a tap on a row opens the note', opened && (await noteQuery(p)) === 'mock-note-2', await noteQuery(p))
  await p.click('[data-test=note-detail] [data-testid=mobile-back]')
  await p.waitForFunction(() => !document.querySelector('[data-test=note-detail]'), { timeout: 15000 }).catch(() => {})
  await sleep(400)

  /* ---- 3. CONTROL: a quick swipe scrolls, moves nothing ------------------ */
  const order3 = await rows(p)
  const f = await centre(p, 'mock-note-3')
  const t0 = await listTop(p)
  await p.touchscreen.touchStart(f.x, f.y)
  const seen = []
  for (let i = 1; i <= 6; i++) {
    await p.touchscreen.touchMove(f.x, f.y - i * 30)
    await sleep(16)
    seen.push(...(await lifted(p)))
  }
  await p.touchscreen.touchEnd()
  await sleep(600)
  const t1 = await listTop(p)
  ok('3 control: a quick swipe lifts nothing', seen.length === 0 && (await lifted(p)).length === 0, seen)
  ok('3 control: ... moves no row and opens no note', JSON.stringify(await rows(p)) === JSON.stringify(order3) && (await noteQuery(p)) === '')
  ok('3 control: ... and the list scrolled', t0.room === 0 || t1.top !== t0.top, { t0, t1 })

  /* ---- 4. a hold let go in place --------------------------------------- */
  const order4 = await rows(p)
  const h = await centre(p, 'mock-note-2')
  await p.touchscreen.touchStart(h.x, h.y)
  await sleep(1200)
  await p.touchscreen.touchEnd()
  await sleep(600)
  ok('4 a hold let go in place moves nothing', JSON.stringify(await rows(p)) === JSON.stringify(order4))
  ok('4 ... opens no note and no row menu', (await noteQuery(p)) === '' && !(await menuOpen(p)), { note: await noteQuery(p), menu: await menuOpen(p) })

  /* ---- 5. a touch contextmenu: no menu on a phone, the menu when wider -- */
  const touchMenu = (p) => p.evaluate(() => {
    const e = document.querySelector('[data-note-id="mock-note-2"] [data-test=notes-open]')
    const r = e.getBoundingClientRect()
    e.dispatchEvent(new PointerEvent('contextmenu', { pointerType: 'touch', bubbles: true, cancelable: true, clientX: r.left + 10, clientY: r.top + 5 }))
  })
  await touchMenu(p)
  await sleep(300)
  ok('5 a touch contextmenu on a phone opens no row menu', !(await menuOpen(p)))
  await p.setViewport({ width: 1280, height: 844, isMobile: false, hasTouch: true })
  await sleep(600)
  await touchMenu(p)
  await sleep(300)
  ok('5 ... at 1280 px the same touch contextmenu opens the row menu', await menuOpen(p))

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nnotes-phone-long-press-drag: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
