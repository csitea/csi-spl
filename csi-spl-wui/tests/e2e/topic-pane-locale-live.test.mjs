// SPL-5738 (F9 of topic 955ab0bd): TopicPane in a non-en locale with a live
// feed raises no Vue error.
//
// WHY: the prd error journal holds one dormant crash family (rows 1, 10, 14,
// 21, 25 of /var/spool-hub/dispatch/955ab0bd-event-types.md: 118 rows,
// 0 since 2026-10-27 08:03Z): "Failed to execute 'insertBefore' on 'Node'"
// first, then "Cannot read properties of null (reading 'emitsOptions')" and
// "Cannot destructure property 'bum' of 'h' as it is null". 66 of the 93
// emitsOptions rows came in one 2-minute burst from one reader in a non-en
// locale, on TopicPane / LiveFeed / TransitionGroup / MessageCard. Which
// commit ended it is not known, so this gate keeps the path exercised: the
// pane in Bulgarian, rows arriving in bursts while the reader switches topic,
// closes and reopens it.
//
// Every error is caught, three ways: `pageerror`, `console.error`, and the
// Vue app's own errorHandler (a render error Nuxt swallows still lands there).
// CONTROL, each run: a reply whose body throws, pushed into the same feed must be
// caught BY ITS OWN TEXT, so a collector that sees nothing (or only network
// noise) cannot read as green. A run whose page saw net::ERR_NETWORK_CHANGED
// (docker veth churn) is retried once, as lib/page-log.mjs does for every e2e.
//
// Run:
//   pnpm test:e2e topic-pane-locale-live
//   BASE_URL=<generated bundle> node tests/e2e/topic-pane-locale-live.test.mjs
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { watchPage, retryOnNetworkChanged } from './lib/page-log.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const LOCALE = 'bg'
const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const msgs = (code) => JSON.parse(readFileSync(join(WUI, `i18n/locales/${code}.json`), 'utf8'))
const LABEL = msgs(LOCALE).topic.replies_label
const LABEL_EN = msgs('en').topic.replies_label
/* The mock tenant's two fixture topics (src/utils/mock-data.mjs). */
const TASK_A = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TASK_B = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'

const fails = []
const ok = (name, pass, ev) => {
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
  if (!pass) fails.push(name)
}
/** One attempt's checks, kept until the attempt is final (see run()). */
const checks = () => {
  const list = []
  return { list, ok: (name, pass, ev) => list.push({ name, pass, ev }) }
}
/** A run, retried ONCE only when its page saw net::ERR_NETWORK_CHANGED (docker
    veth churn on the shared box and runners, lib/page-log.mjs); then reported. */
async function run(name, fn) {
  const list = await retryOnNetworkChanged(name, fn, { failed: (l) => l.filter((c) => !c.pass).map((c) => c.name).join('; ') })
  for (const c of list) ok(c.name, c.pass, c.ev)
}
const CONTROL_ERROR = 'SPL-5738 control row'
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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Open the shell in LOCALE with every error collected; returns { page, errors }. */
async function openShell(browser, base) {
  const page = watchPage(await browser.newPage())
  await page.setViewport({ width: 1280, height: 800 })
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  const errors = []
  page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`))
  page.on('console', (m) => { if (m.type() === 'error') errors.push(`console: ${m.text()}`) })
  await page.goto(`${base}/${LOCALE}/channel/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  const hooked = await page.waitForFunction(() => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const pinia = app?.config?.globalProperties?.$pinia
    if (!pinia?._s.get('topic')) return false
    if (!window.__vueErrors) {
      window.__vueErrors = []
      const prev = app.config.errorHandler
      app.config.errorHandler = (err, inst, info) => {
        window.__vueErrors.push(`${info}: ${err?.message || err}`)
        if (prev) return prev(err, inst, info)
      }
    }
    return true
  }, { timeout: NAV_TIMEOUT }).then(() => true, () => false)
  return { page, errors, hooked }
}

/** Call the topic store the way the feed's click handlers do. */
const topicDo = (page, fn, arg) => page.evaluate((fn, arg) => {
  const topic = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic')
  if (fn === 'open') topic.openTopic(arg)
  if (fn === 'close') topic.close()
}, fn, arg)

/** Rows the reader sees in the open topic pane, and the pane's feed label. */
const pane = (page) => page.evaluate(() => {
  const sec = document.querySelector('[data-test=topic-section]')
  const feed = sec?.querySelector('[data-test=topic-root] [aria-label]')
  return {
    open: !!sec,
    rows: sec ? sec.querySelectorAll('article.msg').length : 0,
    label: feed?.getAttribute('aria-label') || '',
  }
})

/** A live burst: n copies of the open topic's newest reply, one a frame
    apart, as frames off the socket arrive. Each row is delivered the way the
    mock hub holds a reply its socket just sent: added to the mock's
    `spool.mock.extra-messages` hook, which every mock listMessages reads, AND
    written to the channel store the pane reads (topic.messages is a view of
    channel.messages). The app's own refresh replaces channel.messages (mock
    catchUp = refresh, src/stores/channel.ts), so a row only in the store
    would be wiped by it; with the hook the refresh reads it back. */
const burst = (page, n, tag) => page.evaluate(async (n, tag) => {
  const stores = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s
  const topic = stores.get('topic')
  const channel = stores.get('channel')
  const KEY = 'spool.mock.extra-messages'
  for (let i = 0; i < n; i++) {
    const like = topic.messages[topic.messages.length - 1]
    if (!like) return 'no-row'
    const ts = new Date(Date.now() + i).toISOString()
    const row = { ...JSON.parse(JSON.stringify(like)), msg_id: `live-${tag}-${i}-${Date.now()}`, ts, received_at: ts, body: `live ${tag} ${i}` }
    const held = JSON.parse(localStorage.getItem(KEY) || '[]')
    localStorage.setItem(KEY, JSON.stringify([...held, row]))
    channel.messages = [...channel.messages, row]
    await new Promise((r) => requestAnimationFrame(() => r()))
  }
  return 'ok'
}, n, tag)

const vueErrors = (page) => page.evaluate(() => window.__vueErrors || [])

/** The feed settled: no request in flight for 500 ms, then two frames painted.
    A "no error" claim cannot wait on an error event, so it waits on this. */
async function settled(page) {
  await page.waitForNetworkIdle({ idleTime: 500, timeout: 15000 }).catch(() => {})
  await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(() => r()))))
}

/** Wait until the planted error is collected (page, console or Vue handler), max 10 s. */
async function waitError(page, errors) {
  const end = Date.now() + 10000
  while (Date.now() < end) {
    if (errors.some((e) => e.includes(CONTROL_ERROR))) return
    const got = await page.waitForFunction((t) => (window.__vueErrors || []).some((e) => e.includes(t)), { timeout: 250 }, CONTROL_ERROR).then(() => true, () => false)
    if (got) return
  }
}

async function waitRows(page, want) {
  const end = Date.now() + 15000
  let s = await pane(page)
  while (Date.now() < end && !(s.open && s.rows >= want)) { await sleep(100); s = await pane(page) }
  return s
}

async function liveRun(browser, base) {
  const { list, ok } = checks()
  const { page, errors, hooked } = await openShell(browser, base)
  try {
    ok('the Vue error handler is hooked', hooked)
    await topicDo(page, 'open', TASK_A)
    const first = await waitRows(page, 1)
    ok(`TopicPane opens in ${LOCALE} (its feed label is the ${LOCALE} text)`, first.open && first.rows >= 1 && first.label === LABEL && LABEL !== LABEL_EN, first)
    ok('burst 1 (8 rows) lands', (await burst(page, 8, 'a1')) === 'ok')
    await topicDo(page, 'open', TASK_B)
    const pB = burst(page, 6, 'b1')
    await topicDo(page, 'open', TASK_A)
    await pB
    await topicDo(page, 'close')
    await sleep(50)
    await topicDo(page, 'open', TASK_A)
    ok('burst 2 (8 rows) after close / reopen lands', (await burst(page, 8, 'a2')) === 'ok')
    const end = await waitRows(page, first.rows + 8)
    ok('the pane shows the live rows', end.open && end.rows >= first.rows + 8, { before: first.rows, after: end.rows })
    await settled(page)
    const all = [...errors, ...(await vueErrors(page)).map((e) => `vue: ${e}`)]
    ok('no Vue, page or console error through the live bursts', all.length === 0, all.slice(0, 5))
  } finally { await page.close() }
  return list
}

/* The control must catch the error it planted, by its own text: any other
   console line (a churned request, say) is not that error and proves nothing. */
async function control(browser, base) {
  const { list, ok } = checks()
  const { page, errors, hooked } = await openShell(browser, base)
  try {
    ok('CONTROL: the Vue error handler is hooked', hooked)
    await topicDo(page, 'open', TASK_A)
    await waitRows(page, 1)
    await page.evaluate(() => {
      const stores = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s
      const like = stores.get('topic').messages.at(-1)
      /* a reply of the open topic whose body throws when the card reads it */
      const bad = { ...like, msg_id: `bad-${Date.now()}`, get body() { throw new Error('SPL-5738 control row') } }
      stores.get('channel').messages = [...stores.get('channel').messages, bad]
    })
    await waitError(page, errors)
    const all = [...errors, ...(await vueErrors(page))]
    ok('CONTROL: the planted throwing reply is caught as an error', all.some((e) => e.includes(CONTROL_ERROR)), all.slice(0, 3))
  } finally { await page.close() }
  return list
}

const srv = await startServer()
const browser = await launch()
try {
  await run('live bursts', () => liveRun(browser, srv.base))
  await run('control', () => control(browser, srv.base))
} finally {
  await browser.close()
  await srv.stop()
}
console.log(fails.length ? `\n${fails.length} failed` : '\nall topic-pane-locale-live checks passed')
process.exit(fails.length ? 1 : 0)
