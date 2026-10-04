// Owner (t1 topic 5108d85d): "when a topic is archived - if it has the right
// pane opened on desktop it should close". Runs against the lde mock (no hub).
//
// Desktop 1440x900, a channel with two own topic cards A and B, A open in the
// right pane:
//   1  archive B from its card menu -> A's pane stays (control: another
//      topic's archive leaves the pane alone)
//   2  archive A from its card menu -> the right pane closes
//   3  Undo -> A's card is back, the pane stays closed
//   4  the live pane (LiveTopicPane) open on a topic closes on its archive too
//
// Run:
//   node tests/e2e/archive-close-pane.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/archive-close-pane.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const CH = 'archive-close-pane'

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

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
/** What the reader sees: the right pane, whichever store holds it. */
const paneTask = (p) => p.evaluate(() => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const pinia = app.config.globalProperties.$pinia
  const on = Boolean(document.querySelector('[data-test=topic-section]'))
  const topic = pinia._s.get('topic')
  const live = pinia._s.get('live-pane')
  return on ? String((topic.open && topic.parentTaskId) || live.taskId || '?') : ''
})

/** Open the right pane on a task through the stores, as the feed's click does. */
const openPane = (p, which, taskId) => p.evaluate(({ which, taskId }) => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  if (which === 'live') void pinia._s.get('live-pane').open(taskId)
  else pinia._s.get('topic').openTopic(taskId)
}, { which, taskId })

/** Open a middle card's ⋯ menu and return its item testids. */
async function openMenu(p, sel) {
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  for (let i = 0; i < 2; i++) {
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), sel)
    for (let t = 0; t < 20; t++) {
      await sleep(150)
      const got = await items()
      if (got.length) return got
    }
  }
  return []
}

async function archiveFromMenu(p, msgId) {
  const menu = await openMenu(p, midCard(msgId))
  if (!menu.includes('msg-menu-archive')) return false
  await p.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())
  return until(p, (sel) => !document.querySelector(sel), midCard(msgId))
}

/** Seed a channel and own topic cards, return their ids. */
const seed = (p, texts) => p.evaluate(async ({ CH, texts }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(CH).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + CH)
  await new Promise((r) => setTimeout(r, 500))
  const out = []
  for (const text of texts) {
    const m = await ch.send(text, undefined, undefined, undefined, 1)
    out.push({ msg_id: m.msg_id, task_id: m.task_id })
  }
  return out
}, { CH, texts })

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  /* warm a throwaway page: a cold nuxi dev drops the first dynamic import */
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  const [a, b, c] = await seed(p, ['5108d85d topic A', '5108d85d topic B', '5108d85d topic C'])
  await p.waitForSelector(midCard(c.msg_id), { timeout: 10000 })
  await sleep(400)

  await openPane(p, 'channel', a.task_id)
  const opened = await until(p, () => Boolean(document.querySelector('[data-test=topic-section]')))
  ok('0 topic A is open in the right pane', opened && await paneTask(p) === a.task_id, await paneTask(p))
  await shot(p, '0-pane-open')

  /* ---- 1. another topic's archive leaves the pane alone ------------------- */
  ok('1 topic B is archived from its card menu', await archiveFromMenu(p, b.msg_id))
  await sleep(400)
  ok('1 ... and topic A\'s pane stays open', await paneTask(p) === a.task_id, await paneTask(p))
  await shot(p, '1-other-archived')

  /* ---- 2. archiving the topic in the pane closes the pane ----------------- */
  ok('2 topic A is archived from its card menu', await archiveFromMenu(p, a.msg_id))
  const closed = await until(p, () => !document.querySelector('[data-test=topic-section]'))
  ok('2 ... and the right pane closes', closed, await paneTask(p))
  await shot(p, '2-pane-closed')

  /* ---- 3. Undo brings the card back, not the pane ------------------------- */
  await p.waitForSelector('[data-testid=archive-toast-undo]', { timeout: 5000 }).catch(() => {})
  await p.evaluate(() => document.querySelector('[data-testid=archive-toast-undo]')?.click())
  const back = await until(p, (sel) => Boolean(document.querySelector(sel)), midCard(a.msg_id))
  ok('3 Undo brings topic A\'s card back', back)
  await sleep(400)
  ok('3 ... and the right pane stays closed', await paneTask(p) === '', await paneTask(p))
  await shot(p, '3-undo')

  /* ---- 4. the live pane closes the same way -------------------------------- */
  await openPane(p, 'live', c.task_id)
  const liveOpen = await until(p, () => Boolean(document.querySelector('[data-test=topic-section]')))
  ok('4 topic C is open in the live right pane', liveOpen && await paneTask(p) === c.task_id, await paneTask(p))
  ok('4 topic C is archived from its card menu', await archiveFromMenu(p, c.msg_id))
  const liveClosed = await until(p, () => !document.querySelector('[data-test=topic-section]'))
  ok('4 ... and the live right pane closes', liveClosed, await paneTask(p))
  await shot(p, '4-live-closed')

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\narchive-close-pane: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
