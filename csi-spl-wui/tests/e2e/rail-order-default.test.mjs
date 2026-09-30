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

async function run(browser, base, width, touch) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: 800, isMobile: touch, hasTouch: touch })
  for (const [who, order] of [['fresh user (never reordered)', undefined], ['stored order', STORED]]) {
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
    await go(p, '/settings/behaviour')
    await p.waitForSelector('[data-test=rail-order-list] [data-reorder-id]', { timeout: NAV })
    await sleep(300)
    const list = await p.$$eval('[data-test=rail-order-list] [data-reorder-id]', (els) => els.map((e) => e.getAttribute('data-reorder-id')))
    check(`${tag}: Settings -> Behaviour lists the same order`, same(list, want), { list })
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
