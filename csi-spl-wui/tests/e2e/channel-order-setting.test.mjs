// Owner DM 7fa9656f (2026-09-26): "the same option should apply to the order
// of the channels as well" - the option being "Left panel order" (SPL-979):
// drag in the panel AND define it in the person's settings. The panel drag
// (SPL-1034) exists; this proves Settings -> Behaviour -> "Channel order".
// Runs against the lde mock: the mock client keeps the order in localStorage
// the way the hub keeps it on the membership.
//
// Per width (1440x900 desktop, 390x844 phone with touch):
//   1  the list shows this workspace's channels in the left panel's order,
//      nothing stored yet, "Default order" disabled
//   2  Move down on the first row swaps the first two; the WHOLE list is stored
//   3  a pointer drag of the last row's grip onto the top makes it first, stored
//   4  (desktop) the left panel draws the same order at once, no reload
//   5  reload: Settings still lists the stored order
//   6  "Default order" clears it: the list is back to step 1, nothing stored
//
// Run:
//   node tests/e2e/channel-order-setting.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/channel-order-setting.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const OUT = process.env.OUT || ''
const KEY = 'spool.mock.channel-order'
const LIST = '[data-test=channel-order-list] [data-reorder-id]'
const PANEL = '#sidebar-panel-channels .nav-row'

if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

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

async function until(p, fn, arg, ms = 8000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(100)
  }
  return false
}

const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const listed = (p) => p.$$eval(LIST, (els) => els.map((e) => e.getAttribute('data-reorder-id')))
const stored = (p) => p.evaluate((k) => { try { return JSON.parse(localStorage.getItem(k) || 'null') } catch { return 'unreadable' } }, KEY)
const listIs = (p, want) => until(p, ({ sel, want }) => JSON.stringify([...document.querySelectorAll(sel)].map((e) => e.getAttribute('data-reorder-id'))) === JSON.stringify(want), { sel: LIST, want })
const storedIs = (p, want) => until(p, ({ k, want }) => { try { return JSON.stringify(JSON.parse(localStorage.getItem(k) || 'null')) === JSON.stringify(want) } catch { return false } }, { k: KEY, want })

async function openSettings(p, reload = false) {
  if (reload) await p.reload({ waitUntil: 'networkidle2', timeout: NAV })
  else await p.goto(`${p.base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p))) throw new Error('no session store')
  await go(p, '/settings/behaviour')
  await p.waitForSelector(LIST, { visible: true, timeout: NAV })
  await sleep(400)
}

/** A pointer drag of row `id`'s grip so it lands on top of the list. */
async function gripDragToTop(p, id) {
  const grip = await p.$eval(`[data-test=channel-order-row-${id}] .channel-order__grip`, (e) => {
    e.scrollIntoView({ block: 'center' })
    const r = e.getBoundingClientRect()
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) }
  })
  const top = await p.$eval(LIST, (e) => Math.round(e.getBoundingClientRect().top + 2))
  await p.mouse.move(grip.x, grip.y)
  await p.mouse.down()
  await p.mouse.move(grip.x, grip.y - 10, { steps: 3 })
  await p.mouse.move(grip.x, top, { steps: 10 })
  await sleep(80)
  await p.mouse.up()
}

async function run(browser, base, width, height, touch) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  p.base = base
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch })
  const tag = `${width}px`

  await openSettings(p)
  const initial = await listed(p)
  const resetOff = await p.$eval('[data-test=channel-order-reset]', (e) => e.disabled)
  ok(`${tag} 1 Settings lists the workspace's channels, nothing stored, Default order disabled`, initial.length >= 3 && (await stored(p)) === null && resetOff, initial)
  if (width >= 1024) {
    const panel = await p.$$eval(PANEL, (els) => els.map((e) => e.getAttribute('data-order')))
    ok(`${tag} 1 the list is the left panel's order`, !panel.length || same(panel, initial), { panel })
  }
  await shot(p, `${tag}-1-settings`)

  /* ---- 2. Move down on the first row ------------------------------------- */
  await p.click(`[data-test=channel-order-down-${initial[0]}]`)
  const want2 = [initial[1], initial[0], ...initial.slice(2)]
  ok(`${tag} 2 Move down swaps the first two rows`, await listIs(p, want2), await listed(p))
  ok(`${tag} 2 the WHOLE list is stored`, await storedIs(p, want2), await stored(p))
  await shot(p, `${tag}-2-move-down`)

  /* ---- 3. drag the last row's grip to the top ----------------------------- */
  const last = want2[want2.length - 1]
  await gripDragToTop(p, last)
  const want3 = [last, ...want2.slice(0, -1)]
  ok(`${tag} 3 the dragged channel is first`, await listIs(p, want3), await listed(p))
  ok(`${tag} 3 the dragged order is stored`, await storedIs(p, want3), await stored(p))
  await shot(p, `${tag}-3-dragged`)

  /* ---- 4. the left panel follows at once (desktop draws it beside) -------- */
  /* CLE-77934: a rail tab is built when first opened, and the open Settings
     dialog keeps the rail from switching, so the reader's way to see it:
     close Settings, open Channels - the new order, with no reload. (This
     step used to read the hidden Channels panel built on the first idle.) */
  if (width >= 1024) {
    await p.keyboard.press('Escape')
    await p.waitForFunction((sel) => !document.querySelector(sel), { timeout: NAV }, LIST)
    /* the close drops ?settings= from the route, and the route sets the rail
       tab: a click before that lands is undone by it */
    await p.waitForFunction(() => !new URLSearchParams(location.search).has('settings'), { timeout: NAV })
    await sleep(300)
    await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
    const follows = await until(p, ({ sel, want }) => JSON.stringify([...document.querySelectorAll(sel)].map((e) => e.getAttribute('data-order'))) === JSON.stringify(want), { sel: PANEL, want: want3 })
    ok(`${tag} 4 the left panel draws the new order without a reload`, follows, await p.$$eval(PANEL, (els) => els.map((e) => e.getAttribute('data-order'))))
    await shot(p, `${tag}-4-panel`)
  }

  /* ---- 5. reload keeps it ------------------------------------------------- */
  await openSettings(p, true)
  ok(`${tag} 5 after a reload Settings lists the stored order`, await listIs(p, want3), await listed(p))

  /* ---- 6. Default order --------------------------------------------------- */
  await p.click('[data-test=channel-order-reset]')
  ok(`${tag} 6 Default order puts the list back`, await listIs(p, initial), await listed(p))
  ok(`${tag} 6 nothing is stored any more`, await storedIs(p, null), await stored(p))
  await shot(p, `${tag}-6-reset`)

  const real = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok(`${tag} no page error`, real.length === 0, real)
  await ctx.close()
}

const srv = await startServer()
const browser = await launch()
let code = 0
try {
  for (const [w, h, touch] of [[1440, 900, false], [390, 844, true]]) await run(browser, srv.base, w, h, touch)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await srv.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nchannel-order-setting: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
