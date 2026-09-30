// 8f588edd (SC-PROMOTE): drag a reply out of its thread into the channel's
// topics-list BACKGROUND (not onto a card) to PROMOTE it into a NEW topic of
// its own - by the reply's drag HANDLE, and from the reply menu ("Make it a
// topic"), with the Undo toast.
// Runs against the lde mock (no hub): mockPromoteTopic mirrors the hub's
// refusals and mints the new task id (utils/move-mock.mjs).
//
// Desktop 1440x900, REAL mouse input (the drag is a pointer stream):
//   1  seed #a with one topic and a reply; open the topic on the right - the
//      reply has a handle, the opening card has none
//   2  drag the reply into the topics-list background (below the card): the
//      ghost reads "ok" over the zone; the drop promotes - the reply leaves
//      the thread and appears as a NEW topic card in #a; the toast offers Undo
//   3  Undo puts the reply back in its old topic
//   4  the menu path: the reply's menu offers "Make it a topic"; it promotes
//
// Run:
//   node tests/e2e/promote-by-drag.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/promote-by-drag.test.mjs   # what CI does
//   OUT=<dir> ... also writes a screenshot per step
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const OTHER_CARD = '66666666-6666-4666-8666-666666666666'
const A = 'promote-a'

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
const paneRow = (id) => `aside[data-pane="topic"] article.msg[data-msg-id="${id}"]`
const handleOf = (sel) => `${sel} [data-testid=move-handle]`
const centre = (p, sel) => p.evaluate((sel) => {
  const e = document.querySelector(sel)
  if (!e) return null
  const r = e.getBoundingClientRect()
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
}, sel)
const toastText = (p) => p.evaluate(() => document.querySelector('[data-testid=move-toast-text]')?.textContent.trim() || '')
const ghostState = (p) => p.evaluate(() => document.querySelector('[data-testid=move-ghost]')?.dataset.state || '')

/** A point inside the channel feed-body that is the promote drop ZONE (topics),
    not any topic card - the empty scroller area below the cards. */
const dropPoint = (p) => p.evaluate(() => {
  const body = document.querySelector('.spool-main .feed-body')
  if (!body) return null
  const r = body.getBoundingClientRect()
  const x = Math.round(r.left + r.width / 2)
  for (const y of [r.bottom - 24, r.bottom - 60, r.top + r.height * 0.75, r.top + r.height * 0.6]) {
    const el = document.elementFromPoint(x, Math.round(y))
    const drop = el && el.closest && el.closest('[data-move-drop]')
    if (drop && drop.dataset.moveDrop === 'topics') return { x, y: Math.round(y) }
  }
  return null
})

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

/** Open a middle card's topic on the right and wait for `row` there. */
async function openTopic(p, cardId, row) {
  for (let i = 0; i < 4; i++) {
    await sleep(300)
    await p.evaluate((sel) => document.querySelector(sel)?.click(), `${midCard(cardId)} .msg-meta .msg-time`)
    if (await p.waitForSelector(row, { timeout: 4000 }).then(() => true, () => false)) return true
  }
  return false
}

const seed = (p) => p.evaluate(async ({ A }) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  await ch.createChannel(A)
  await app.config.globalProperties.$router.push('/channel/' + A)
  await new Promise((r) => setTimeout(r, 500))
  const one = await ch.send('8f588edd topic one', undefined, undefined, undefined, 1)
  const reply = await ch.send('8f588edd a reply to promote', one.task_id, undefined, undefined, 0)
  return { one: { msg_id: one.msg_id, task_id: one.task_id }, reply: { msg_id: reply.msg_id } }
}, { A })

const replyTask = (p, id) => p.evaluate((id) => {
  const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  const row = ch.messages.find((m) => m.msg_id === id)
  return row ? { task_id: row.task_id, is_parent: row.is_parent, parent: row.parent_task_id || null } : null
}, id)

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector(midCard(OTHER_CARD), { timeout: NAV_TIMEOUT })
  await sleep(600)

  /* ---- 1. seed and open the topic --------------------------------------- */
  const s = await seed(p)
  await p.waitForSelector(midCard(s.one.msg_id), { timeout: 10000 })
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await sleep(400)
  const opened = await openTopic(p, s.one.msg_id, paneRow(s.reply.msg_id))
  ok('1 the topic opens with the reply in the right pane', opened)
  const paneState = await p.evaluate(({ r, c }) => ({
    reply: Boolean(document.querySelector(`aside[data-pane="topic"] article.msg[data-msg-id="${r}"] [data-testid=move-handle]`)),
    opener: Boolean(document.querySelector(`aside[data-pane="topic"] article.msg[data-msg-id="${c}"] [data-testid=move-handle]`)),
  }), { r: s.reply.msg_id, c: s.one.msg_id })
  ok('1 the reply has a drag handle, the opening card has none', paneState.reply && !paneState.opener, paneState)

  /* ---- 2. drag the reply into the topics-list background ----------------- */
  const from = await centre(p, handleOf(paneRow(s.reply.msg_id)))
  const zone = await dropPoint(p)
  ok('2 the channel feed exposes a topics drop zone below the cards', Boolean(zone), zone)
  await p.mouse.move(from.x, from.y)
  await p.mouse.down()
  await p.mouse.move((from.x + zone.x) / 2, (from.y + zone.y) / 2, { steps: 6 })
  await sleep(70)
  await p.mouse.move(zone.x, zone.y, { steps: 8 })
  await sleep(90)
  const gs = await ghostState(p)
  ok('2 the ghost reads "ok" over the topics zone', gs === 'ok', gs)
  await shot(p, '2-over-zone')
  await p.mouse.up()
  await sleep(300)
  const leftThread = await until(p, (sel) => !document.querySelector(sel), paneRow(s.reply.msg_id))
  ok('2 the promoted reply left its old thread', leftThread)
  const becameCard = await until(p, (sel) => Boolean(document.querySelector(sel)), midCard(s.reply.msg_id))
  ok('2 the reply is now a topic card of its own in the channel', becameCard)
  const promoted = await replyTask(p, s.reply.msg_id)
  ok('2 ... a new task, is_parent 1, no parent', promoted && promoted.is_parent === 1 && promoted.task_id !== s.one.task_id && !promoted.parent, promoted)
  await p.waitForSelector('[data-testid=move-toast]', { timeout: 5000 }).catch(() => {})
  const t2 = await toastText(p)
  ok('2 the toast reports a new topic and offers Undo', /topic/i.test(t2) && Boolean(await p.$('[data-testid=move-toast-undo]')), t2)
  await shot(p, '2-promoted')

  /* ---- 3. Undo -------------------------------------------------------------- */
  await p.click('[data-testid=move-toast-undo]')
  const notCard = await until(p, (sel) => !document.querySelector(sel), midCard(s.reply.msg_id))
  ok('3 Undo: the promoted reply is no longer a top-level card in the channel', notCard)
  const backInThread = await openTopic(p, s.one.msg_id, paneRow(s.reply.msg_id))
  ok('3 Undo re-seats the reply back in its old topic (a reply again)', backInThread)

  /* ---- 4. the menu path ("Make it a topic") ----------------------------- */
  await openTopic(p, s.one.msg_id, paneRow(s.reply.msg_id))
  const menu = await openMenu(p, paneRow(s.reply.msg_id))
  ok('4 the reply menu offers "Make it a topic"', menu.includes('msg-menu-promote-topic'), menu)
  await p.click('[data-testid=msg-menu-promote-topic]')
  const promotedAgain = await until(p, (sel) => Boolean(document.querySelector(sel)), midCard(s.reply.msg_id))
  ok('4 the menu entry promotes the reply into a new topic', promotedAgain, await toastText(p))
  await shot(p, '4-menu-promoted')

  ok('no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\npromote-by-drag: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
