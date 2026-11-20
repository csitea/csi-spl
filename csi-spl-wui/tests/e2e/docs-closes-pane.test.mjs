// SPL-6064 (owner HUM-10, t1 18140959 msg 96212906: "when I click on the
// docs from the channels section I get this view , which is wrong , I shoud
// see only the doc"): on desktop, the Docs link of the sidebar rail closes
// the right pane a channel had open, and /workspace/docs shows its tree and
// the doc only. Runs against the lde mock (no hub).
//
// Desktop 1440x900, a topic open on /channel/lobby, then a click on the
// rail's Docs link ([data-testid=qto-open]):
//   1  the right pane is gone (no [data-test=topic-section]) and no topic
//      store is armed
//   2  the docs layout reaches the right edge of the viewport: nothing is
//      drawn beside it
//   3  the live pane closes the same way
//   4  Back returns to /channel/lobby and the channel still renders
//
// The topic opens through the page's own pinia store, as its click handler
// does; a full load would reset the stores and prove nothing.
//
// Run:
//   BASE_URL=<generated bundle> pnpm test:e2e docs-closes-pane
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const TASK_A = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const DOCS = '[data-testid=sidebar-rail] [data-testid=qto-open]'
const W = 1440

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

/** Open a topic section through its store, as its click handler does. */
const openSection = (p, which) => p.evaluate(({ which, id }) => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  if (which === 'live') void pinia._s.get('live-pane').open(id)
  if (which === 'channel') pinia._s.get('topic').openTopic(id)
}, { which, id: TASK_A })

/** What the shell holds: the right pane, each store's flag, the docs layout's box. */
const state = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  const docs = document.querySelector('[data-test=ws-docs-layout]')?.getBoundingClientRect()
  return {
    pane: document.querySelectorAll('[data-test=topic-section]').length,
    live: Boolean(pinia._s.get('live-pane').taskId),
    channel: Boolean(pinia._s.get('topic').open),
    docsRight: docs ? Math.round(docs.right) : null,
    path: location.pathname,
  }
})

/** A forward SPA navigation, the call the rail's links make. */
async function push(p, to) {
  await p.evaluate((to) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to), to)
  await sleep(700)
}

/** Open `which` on /channel/lobby, then click the rail's Docs link. */
async function docsFromChannel(p, which) {
  await push(p, '/channel/lobby')
  await openSection(p, which)
  const opened = await until(p, () => document.querySelectorAll('[data-test=topic-section]').length === 1)
  ok(`${which}: a topic is open on /channel/lobby`, opened, await state(p))
  await p.waitForSelector(DOCS, { visible: true, timeout: NAV_TIMEOUT })
  await p.click(DOCS)
  await until(p, () => location.pathname.endsWith('/workspace/docs'))
  await p.waitForSelector('[data-test=ws-docs-layout]', { visible: true, timeout: NAV_TIMEOUT })
  await until(p, () => !document.querySelector('[data-test=topic-section]'))
  await sleep(300)
  return state(p)
}

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: W, height: 900 })
  await p.goto(`${srv.base}/channel/lobby`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(1200)

  /* ---- 1 + 2. the channel topic pane, then Docs from the rail ----------- */
  const s = await docsFromChannel(p, 'channel')
  await shot(p, '1-docs-after-channel-topic')
  ok('1 Docs from the rail: no right pane, no topic armed', s.path.endsWith('/workspace/docs') && s.pane === 0 && !s.live && !s.channel, s)
  ok('2 the docs layout fills the content area to the right edge', s.docsRight !== null && s.docsRight >= W - 2, s)

  /* ---- 3. the live pane closes the same way ------------------------------ */
  const l = await docsFromChannel(p, 'live')
  ok('3 Docs from the rail closes the live pane too', l.pane === 0 && !l.live && !l.channel, l)

  /* ---- 4. Back returns to the channel ------------------------------------ */
  await p.goBack()
  const back = await until(p, () => location.pathname.endsWith('/channel/lobby') && Boolean(document.querySelector('.spool-main')))
  ok('4 Back returns to /channel/lobby', back, await state(p))
  await shot(p, '4-back-to-channel')

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ndocs-closes-pane: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
