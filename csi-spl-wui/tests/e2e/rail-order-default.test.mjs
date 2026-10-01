// SPL-979 follow-up: the default left-rail order for new members.
//
// Owner, 2026-09-27 (topic 116646c8): "the default order for new members
// should be channels, direct messages, issues, topics, flow and archive". The
// Event log, which he did not name, goes last. A person with a stored order
// (humans.rail_order) keeps it exactly.
//
// In the mock tenant the session is adopted through the pinia store, once
// with no rail_order and once with the owner's stored order. Each time the
// rail and Settings -> Behaviour -> Left panel order must show the expected
// order. Runs at 1440 (desktop), 820 and 360 (touch).
//
// Run:
//   node tests/e2e/rail-order-default.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/rail-order-default.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
/* CLE-77794: the drawn order is parseRailOrder(claim) — a legacy stored order
   keeps its place and the tabs added since (people, agents) are appended, so the
   expected order tracks RAIL_IDS instead of a hardcoded list. */
import { parseRailOrder } from '../../src/utils/rail-order.mjs'

const results = []
function check(name, pass, ev) {
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
/* the owner's stored order on prd (humans.rail_order, measured 2026-09-27); a
   legacy seven-tab claim, drawn with people + agents appended (parseRailOrder). */
const STORED = ['channels', 'topics', 'issues', 'dm', 'events', 'flow', 'archive']
/* CLE-77916 (owner, t1 topic 5463df22): Archive is ALWAYS last and not
   draggable. A stored order with Archive first is drawn with it last. */
const ARCHIVE_FIRST = ['archive', 'channels', 'dm', 'issues', 'topics', 'flow', 'events', 'people', 'agents', 'boxes']

/** Sign in as a member; `order` undefined = never reordered (the claim is absent). */
const signIn = (p, order) => p.evaluate((order) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  const c = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
  if (order !== undefined) c.rail_order = order
  session.adopt(c)
  return true
}, order)

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const railOf = (p) => p.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))

/* CLE-77916: press a tab and move it one tab along the rail's own axis with the
   mouse (a desktop window at phone width is a row): the preview moves it ONE
   place - measured on the wrong axis it jumped to the first or last index.
   Pressing Archive and moving it previews nothing. Released with Escape-free
   pointercancel so nothing is saved. */
async function dragProbe(p, tag, rail) {
  const boxes = await p.$$eval('[data-testid=sidebar-rail] [data-reorder-id]', (els) => els.map((e) => {
    const r = e.getBoundingClientRect()
    return { id: e.getAttribute('data-reorder-id'), x: r.left + r.width / 2, y: r.top + r.height / 2, w: r.width, h: r.height }
  }))
  const row = Math.abs(boxes.at(-1).x - boxes[0].x) > Math.abs(boxes.at(-1).y - boxes[0].y)
  const a = boxes[1]
  const step = row ? { x: boxes[2].x - a.x + 4, y: 0 } : { x: 0, y: boxes[2].y - a.y + 4 }
  await p.mouse.move(a.x, a.y)
  await p.mouse.down()
  for (let i = 1; i <= 6; i++) await p.mouse.move(a.x + (step.x * i) / 6, a.y + (step.y * i) / 6)
  await sleep(100)
  const mid = await railOf(p)
  const expect = [rail[0], rail[2], rail[1], ...rail.slice(3)]
  check(`${tag}: a drag by one tab along the ${row ? 'row' : 'column'} moves it one place`, same(mid, expect), { mid })
  await p.evaluate(() => window.dispatchEvent(new PointerEvent('pointercancel', { pointerId: 1, isPrimary: true, pointerType: 'mouse' })))
  await p.mouse.up()
  await sleep(100)
  const arch = boxes.find((b) => b.id === 'archive')
  await p.mouse.move(arch.x, arch.y)
  await p.mouse.down()
  for (let i = 1; i <= 6; i++) await p.mouse.move(arch.x - (row ? arch.w * i / 3 : 0), arch.y - (row ? 0 : arch.h * i / 3))
  await sleep(100)
  const still = await railOf(p)
  check(`${tag}: pressing and moving Archive moves nothing`, same(still, rail), { still })
  await p.mouse.up()
  await sleep(100)
}

async function run(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: 800, isMobile: touch, hasTouch: touch })
  for (const [who, order] of [['fresh user (never reordered)', undefined], ['stored order', STORED], ['stored order with Archive first', ARCHIVE_FIRST]]) {
    const tag = `${width}px ${who}`
    /* the rail draws parseRailOrder(claim): the 9-tab default for a fresh user,
       the stored order with people + agents appended for a legacy claim. */
    const want = parseRailOrder(order)
    /* phones: / is the sidebar level (the rail); desktop draws it on every page */
    await p.goto(`${base}/`, { waitUntil: 'networkidle2', timeout: NAV })
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
    if (!(await signIn(p, order))) throw new Error('no session store')
    await p.waitForSelector('[data-testid=sidebar-rail] [data-reorder-id]', { timeout: NAV })
    await sleep(400)
    const rail = await railOf(p)
    check(`${tag}: the rail draws ${order ? 'the stored order, unchanged' : 'the new default'}`, same(rail, want), { rail })
    check(`${tag}: Archive is the last section`, rail.at(-1) === 'archive', { last: rail.at(-1) })
    const pinned = await p.$$eval('[data-testid=sidebar-rail] [data-pinned=last]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
    check(`${tag}: Archive, and only Archive, is not draggable`, same(pinned, ['archive']), { pinned })
    await dragProbe(p, tag, rail)
    await go(p, '/settings/behaviour')
    await p.waitForSelector('[data-test=rail-order-list] [data-reorder-id]', { timeout: NAV })
    await sleep(300)
    const list = await p.$$eval('[data-test=rail-order-list] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
    check(`${tag}: Settings -> Behaviour lists the same order`, same(list, want), { list })
    const archiveCtl = await p.$$('[data-test=rail-order-up-archive], [data-test=rail-order-down-archive]')
    check(`${tag}: Settings offers no Move up / down for Archive`, archiveCtl.length === 0, { n: archiveCtl.length })
  }
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, touch] of [[1440, false], [820, true], [360, true]]) await run(browser, server.base, w, touch)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nrail-order-default: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
