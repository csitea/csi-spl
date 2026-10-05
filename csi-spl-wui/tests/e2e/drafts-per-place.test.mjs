// 080 T003 (FR-001..FR-003, FR-008): one composer draft per place. Both
// desktop walks (c-245 T10, g-248 A4) found a draft typed in #feedback still
// in the box after a sidebar click to #alerts - one Enter posted it to the
// wrong channel - and a reload emptied the box.
//
//   mock tenant, signed in as HUM-1 (spool.mock.session), 1440x900:
//     AC1 type `abc` on #feedback, click #alerts -> the box is empty;
//         click #feedback -> the box is `abc` again
//     AC2 reload -> `abc`; open a topic (one in #alerts: the mock's #feedback
//         has none), type `xyz`, reload with ?topic= -> `xyz`
//     AC3 send from #feedback -> the box is empty, reload -> still empty, no
//         `ch:feedback` draft is kept
//     AC3 (T004, FR-005) the pencil: on #alerts the #feedback row shows it and
//         the #alerts row does not; the topic card with a reply draft shows
//         it; after the send the #feedback row has none
//     AC7 a draft on #feedback, sign out -> `spool.drafts` has no HUM-1 entry
//     CONTROL: before T003 the box kept `abc` on #alerts (AC1 fails) and a
//     reload emptied it (AC2 fails).
//
// Run:
//   pnpm run test:e2e drafts-per-place
//   BASE_URL=<generated bundle> pnpm run test:e2e drafts-per-place   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per step there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const HUM = 'HUM-1'
const BOX = 'form.composer.omnibox--global textarea'
/* the composer keeps a draft 300 ms after the last key */
const SAVE_WAIT = 700

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const boxText = (p) => p.$eval(BOX, (el) => el.value)
const drafts = (p) => p.evaluate(() => {
  try { return JSON.parse(localStorage.getItem('spool.drafts') || '{}') } catch { return null }
})

async function settle(p) {
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
}

async function reload(p) {
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await settle(p)
}

async function type(p, text) {
  await p.focus(BOX)
  await p.type(BOX, text)
  await sleep(SAVE_WAIT)
}

async function clickChannel(p, id) {
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await p.waitForSelector(`a.nav-item[data-key="${id}"]`, { visible: true, timeout: NAV_TIMEOUT })
  await p.evaluate((key) => document.querySelector(`a.nav-item[data-key="${key}"]`).click(), id)
  await p.waitForFunction((key) => location.pathname.endsWith(`/channel/${key}`), { timeout: NAV_TIMEOUT }, id)
  await settle(p)
}

const MARK_WAIT = 3000
/* the marks re-read `spool.drafts` once a second (composables/useDrafts.ts) */
const rowMark = (key) => `a.nav-item[data-key="${key}"] [data-testid=draft-mark]`
const cardMark = (taskId) => `.spool-main article.msg[data-task-id="${taskId}"] [data-testid=msg-draft]`
async function marked(p, sel) {
  return p.waitForSelector(sel, { timeout: MARK_WAIT }).then(() => true, () => false)
}
async function unmarked(p, sel) {
  await sleep(MARK_WAIT / 2)
  return !(await p.$(sel))
}
async function showChannels(p) {
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await p.waitForSelector('a.nav-item[data-key="feedback"]', { visible: true, timeout: NAV_TIMEOUT })
}

async function firstCard(p) {
  return p.evaluate(() => {
    const el = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')].find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const body = el.querySelector('.msg-body') || el
    const r = body.getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) }
  })
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + '/channel/feedback', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  /* a signed-in mock member: drafts are kept per human id (see act-as.test.mjs) */
  await p.evaluate((hum) => {
    localStorage.removeItem('spool.drafts')
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum, name: 'Admin', email: 'admin@example.com', t: 'mock' }))
  }, HUM)
  await reload(p)

  /* AC1 */
  await type(p, 'abc')
  await clickChannel(p, 'alerts')
  const onAlerts = await boxText(p)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'drafts-per-place-alerts.png') })
  ok('AC1 a draft typed on #feedback does not follow a click to #alerts', onAlerts === '', { onAlerts })
  await clickChannel(p, 'feedback')
  const back = await boxText(p)
  ok('AC1 back on #feedback the draft is in the box again', back === 'abc', { back })

  /* AC2 */
  await reload(p)
  const afterReload = await boxText(p)
  ok('AC2 a reload keeps the #feedback draft', afterReload === 'abc', { afterReload, drafts: await drafts(p) })
  /* the mock's #feedback has no topic yet: open one in #alerts */
  await clickChannel(p, 'alerts')
  const feedbackMark = await marked(p, rowMark('feedback'))
  const alertsClean = await unmarked(p, rowMark('alerts'))
  ok('AC3 on #alerts the #feedback row shows the draft pencil, the #alerts row none', feedbackMark && alertsClean, { feedbackMark, alertsClean })
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV_TIMEOUT })
  const card = await firstCard(p)
  await p.mouse.click(card.x, card.y)
  await sleep(800)
  const inTopic = await boxText(p)
  ok('AC2 opening a topic swaps the channel draft out of the box', inTopic === '', { inTopic })
  await type(p, 'xyz')
  const url = p.url()
  await reload(p)
  const topicAfter = await boxText(p)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'drafts-per-place-topic.png') })
  const taskId = new URL(url).searchParams.get('topic') || ''
  const topicMark = Boolean(taskId) && await marked(p, cardMark(taskId))
  ok('AC3 the topic card with a reply draft shows the pencil', topicMark, { taskId })
  ok('AC2 a reload with ?topic= keeps the reply draft', /[?&]topic=/.test(url) && topicAfter === 'xyz', { url, topicAfter, drafts: await drafts(p) })

  /* AC3 */
  await p.goto(server.base + '/channel/feedback', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await settle(p)
  const before = await boxText(p)
  await p.click('form.composer.omnibox--global [data-testid=send]')
  await sleep(SAVE_WAIT + 300)
  const sentBox = await boxText(p)
  await reload(p)
  const sentReload = await boxText(p)
  const kept = ((await drafts(p)) || {})[HUM] || {}
  ok('AC3 a send empties the box and drops the #feedback draft, also after a reload',
    before === 'abc' && sentBox === '' && sentReload === '' && !kept['ch:feedback'], { before, sentBox, sentReload, kept })
  await showChannels(p)
  const sentClean = await unmarked(p, rowMark('feedback'))
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'drafts-per-place-sent.png') })
  ok('AC3 after the send the #feedback row has no pencil', sentClean)

  /* AC7 */
  await type(p, 'zzz')
  const held = Boolean(((await drafts(p)) || {})[HUM])
  await p.click('[data-test=user-menu-trigger]')
  await p.waitForSelector('[data-test=user-menu-signout]', { visible: true, timeout: 5000 })
  await Promise.all([
    p.waitForNavigation({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT }).catch(() => null),
    p.click('[data-test=user-menu-signout]'),
  ])
  await p.waitForFunction(() => /\/login(\?|$)/.test(location.pathname + location.search), { timeout: NAV_TIMEOUT }).catch(() => null)
  await sleep(SAVE_WAIT)
  const left = await drafts(p)
  ok('AC7 sign-out deletes the member\'s drafts', held && Boolean(left) && !left[HUM], { held, left })
  ok('no page error', errors.length === 0, errors)
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
