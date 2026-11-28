// Spec 186 4.9 (SPL-6741; owner HUM-10, t1 ec411af3, msg f0a3b378): with 2+
// topics ticked in a channel's topic list, open topic or not, the Omnibox's
// GO multicasts the typed text to exactly them, against the lde mock (no hub).
//   N  1280x800, no topic open: x1 and x2 ticked; GO reads "Send to 2
//      topics"; a click on GO puts the text into x1 and x2, not x3, and
//      starts no new topic; the dialog closes and the selection is empty
//   O  1280x800, x2 open in the right pane: x1 and x3 ticked; GO reads
//      "Send to 2 topics"; the send key (Ctrl+Enter) puts the text into x1
//      and x3, not into the open x2
//   S  1280x800, x2 open, only x1 ticked: GO keeps its own words; the send
//      is a reply in the open x2, not in x1, and the selection stays
// The ticks go through the select phase's store (multicast-prompt.test.mjs
// drives the card boxes); the Omnibox, its GO and its send key are driven
// as a person does.
//
// Red control (spec 186 4.9): on the base (TopBar without the multicast
// route) N and O fail: GO reads "Send to" nothing, and the text lands once,
// in a new topic (N) or in the open topic (O).
//
// Run:
//   BASE_URL=<generated bundle> node tests/e2e/multicast-omnibox.test.mjs   # what CI does
//   node tests/e2e/multicast-omnibox.test.mjs                                 # nuxi dev
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const CH = 's186-mc-omni'
const BOX = '[data-test=top-bar-omnibox]'
const GO = `${BOX} [data-testid=send]`

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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

/** fn(arg) in the page until it is truthy, or `ms` runs out. */
async function until(p, fn, arg, ms = 6000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg).catch(() => false)) return true
    await sleep(100)
  }
  return false
}

const card = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const mounted = (p) => until(p, () => Boolean(document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$pinia?._s.get('channel')), null, NAV_TIMEOUT)
const signIn = (p) => p.evaluateOnNewDocument(() => {
  try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'owner@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
})

/** A channel with one own topic per title, in order; their { msg_id, task_id, title }. */
const seed = (p, ch, titles) => p.evaluate(async ({ ch, titles }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const store = app.config.globalProperties.$pinia._s.get('channel')
  await store.createChannel(ch).catch(() => {})
  await app.config.globalProperties.$router.push('/channel/' + ch)
  await new Promise((r) => setTimeout(r, 500))
  const out = []
  for (const t of titles) {
    const row = await store.send(t, undefined, undefined, undefined, 1)
    out.push({ msg_id: row.msg_id, task_id: row.task_id, title: t })
  }
  store.refresh = async () => {}
  return out
}, { ch, titles })

/** The selection becomes exactly `topics` (the select phase's store). */
const tick = (p, topics) => p.evaluate((topics) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topicSelect')
  s.clear()
  for (const t of topics) s.toggle({ task_id: t.task_id, channel: t.ch, title: t.title }, true)
  return s.count
}, topics)
const selCount = (p) => p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topicSelect').count)
const openTopic = (p, id) => p.evaluate((id) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic').openTopic(id), id)
const closeTopic = (p) => p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topic').close?.())
const goLabel = (p) => p.evaluate((sel) => document.querySelector(sel)?.getAttribute('aria-label') || '', GO)

/** Type `text` into the Omnibox. */
async function typeInBox(p, text) {
  const field = `${BOX} textarea`
  await p.waitForSelector(field, { visible: true, timeout: 5000 })
  await p.focus(field)
  await p.keyboard.type(text)
  await until(p, ({ f, t }) => document.querySelector(f)?.value === t, { f: field, t: text }, 3000)
}

/** For each topic: does its open pane hold a card with `text`? */
async function inTopics(p, topics, text) {
  const seen = []
  for (const t of topics) {
    await openTopic(p, t.task_id)
    seen.push(await until(p, (text) => [...document.querySelectorAll('.topic article.msg')].some((e) => e.getClientRects().length && e.textContent.includes(text)), text, t.expect === false ? 2500 : 8000))
    await closeTopic(p)
    await sleep(200)
  }
  return seen
}
/** The channel's topic openers whose body is `text`: a send that started a new topic. */
const newTopicsWith = (p, text) => p.evaluate((text) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel').messages
  .filter((m) => m.is_parent !== 0 && String(m.body || '').includes(text)).length, text)

async function run(browser, base) {
  const d = await browser.newPage()
  const errors = []
  d.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  d.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await signIn(d)
  await d.setViewport({ width: 1280, height: 800 })
  await d.goto(`${base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await d.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await mounted(d)
  const [x1, x2, x3] = (await seed(d, CH, ['omni one', 'omni two', 'omni three'])).map((t) => ({ ...t, ch: CH }))
  await d.waitForSelector(card(x1.msg_id), { visible: true, timeout: 10000 })
  const plain = await goLabel(d)

  /* N: no topic open, x1 and x2 ticked, GO clicked */
  ok('N: x1 and x2 ticked: "2 selected"', (await tick(d, [x1, x2])) === 2 && await until(d, () => document.querySelector('[data-test=topic-select-bar]')?.getAttribute('data-count') === '2', null, 4000))
  const textN = `omni-n ${Date.now().toString(36)}`
  await typeInBox(d, textN)
  ok('N: GO reads "Send to 2 topics"', await until(d, (sel) => document.querySelector(sel)?.getAttribute('aria-label') === 'Send to 2 topics', GO, 3000), await goLabel(d))
  ok('N: ... and so does its tooltip', await d.evaluate((sel) => document.querySelector(sel)?.querySelector('[data-test=go-tip]')?.textContent?.trim() === 'Send to 2 topics', GO))
  await d.click(GO)
  ok('N: every copy acked: the selection is empty', await until(d, () => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topicSelect').count === 0 && !document.querySelector('[data-test=multicast-dialog]'), null, 8000), { sel: await selCount(d) })
  ok('N: no new topic holds the text', (await newTopicsWith(d, textN)) === 0, await newTopicsWith(d, textN))
  const seenN = await inTopics(d, [x1, x2, { ...x3, expect: false }], textN)
  ok('N: the text is in x1 and x2, not in x3', seenN[0] && seenN[1] && !seenN[2], seenN)

  /* O: x2 open, x1 and x3 ticked, the send key */
  await openTopic(d, x2.task_id)
  await until(d, () => Boolean(document.querySelector('.topic article.msg')), null, 5000)
  ok('O: x2 open, x1 and x3 ticked', (await tick(d, [x1, x3])) === 2)
  const textO = `omni-o ${Date.now().toString(36)}`
  await typeInBox(d, textO)
  ok('O: GO reads "Send to 2 topics" with a topic open', await until(d, (sel) => document.querySelector(sel)?.getAttribute('aria-label') === 'Send to 2 topics', GO, 3000), await goLabel(d))
  await d.keyboard.down('Control')
  await d.keyboard.press('Enter')
  await d.keyboard.up('Control')
  ok('O: every copy acked: the selection is empty', await until(d, () => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('topicSelect').count === 0 && !document.querySelector('[data-test=multicast-dialog]'), null, 8000), { sel: await selCount(d) })
  await closeTopic(d)
  const seenO = await inTopics(d, [x1, x3, { ...x2, expect: false }], textO)
  ok('O: the text is in x1 and x3, not in the open x2', seenO[0] && seenO[1] && !seenO[2], seenO)

  /* S: x2 open, only x1 ticked: the normal send */
  await openTopic(d, x2.task_id)
  await until(d, () => Boolean(document.querySelector('.topic article.msg')), null, 5000)
  ok('S: x2 open, only x1 ticked', (await tick(d, [x1])) === 1)
  const textS = `omni-s ${Date.now().toString(36)}`
  await typeInBox(d, textS)
  const labelS = await goLabel(d)
  ok('S: GO keeps its own words (no "Send to")', !/Send to/.test(labelS) && labelS !== '', { labelS, plain })
  await d.click(GO)
  ok('S: the reply lands in the open x2', await until(d, (text) => [...document.querySelectorAll('.topic article.msg')].some((e) => e.getClientRects().length && e.textContent.includes(text)), textS, 8000))
  ok('S: ... and the selection stays: 1', (await selCount(d)) === 1, await selCount(d))
  await closeTopic(d)
  const seenS = await inTopics(d, [{ ...x1, expect: false }], textS)
  ok('S: the text is not in x1', !seenS[0], seenS)
  ok('N+O+S: no page errors', errors.length === 0, errors)
  await d.close()
}

const srv = await startServer()
const browser = await launch()
try {
  await run(browser, srv.base)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmulticast-omnibox: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
