// SPL-2765 (prd msg 86530802, 2026-10-21, routing columns only): a note
// addressed to a person (HUM-10 -> HUM-154, kind note) was stored with
// channel=lobby on the lobby welcome discussion. The cause, read from the
// code: /lobby opens that discussion in the live pane, a channel -> DM route
// keeps the pane (topic-pane.mjs routeLeavesTopic), the DM page closed only
// the topic store (releaseStaleTopic), so the pane's task took the DM line,
// and the hub filed the line under that task's channel (channels.go
// tagChannel: the lobby task is #lobby; wuiChannel: a reply inherits its
// topic's channel). The hub never moves a task id, so the task id the page
// sends decides it. Real browser, mock tenant, 1440 px:
//
//   1 the lobby discussion open in the right pane, then an in-app route to
//     an OFFLINE person's DM (HUM-3): the line sent there carries no channel,
//     names HUM-3, and its task is not the lobby discussion (neither task_id
//     nor parent_task_id); the pane on that discussion is closed
//   2 a channel note stays on its channel: a line sent on #alerts is stored
//     with channel alerts
//   3 the third ask (owner, 2026-10-21): a click on a leftmost section closes
//     the reply panel and the previous list panel; only that section's own
//     panes stay. Direct messages from #alerts with a topic open, Channels
//     from a DM with the lobby pane open, Flow and Event log likewise.
//
// CONTROL: without the dm/[peer].vue change, case 1 reads task_id or
// parent_task_id = the lobby task; without the ChannelSidebar.vue change the
// pane stays open and the route stays on the old list in case 3.
//
//   BASE_URL=<generated bundle> node tests/e2e/dm-note-not-on-channel-topic.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
/* src/utils/mock-ids.ts MOCK_LOBBY_TASK_ID: the mock's lobby discussion */
const LOBBY_TASK = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
/* MOCK_ONLINE lists no HUM-3: an offline person */
const OFFLINE_PEER = 'HUM-3@box-wui'
const OMNI = 'form.composer.omnibox--global textarea'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 'mock' }

const results = []
const check = (name, pass, ev) => {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* in-app, not a reload: a cold /dm/<peer> in the mock lands on / first */
async function routeTo(p, path) {
  await p.evaluate((to) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(to), path)
  await p.waitForFunction((to) => decodeURIComponent(location.pathname).endsWith(to), { timeout: NAV }, path)
  await sleep(900)
}

/* the right pane: the live pane's task and the channel topic store */
const panes = (p) => p.evaluate(() => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value
  const visible = [...document.querySelectorAll('[data-test=topic-pane-close],[data-test=live-topic-close]')].some((el) => el.getClientRects().length > 0)
  return { live: (s['live-pane'] && s['live-pane'].taskId) || null, topic: Boolean(s.topic && s.topic.open), visible }
})
const paneClosed = (x) => !x.live && !x.topic && !x.visible

/** The channel store row whose body contains `needle`. */
const sentRow = (p, needle) => p.evaluate((n) => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value
  const m = [...((s.channel && s.channel.messages) || [])].reverse().find((x) => String(x.body || '').includes(n))
  return m ? { task_id: m.task_id || '', parent_task_id: m.parent_task_id || '', to: m.to || '', channel: m.channel || null } : null
}, needle)

async function send(p, text) {
  await p.waitForSelector(OMNI, { timeout: NAV })
  await p.focus(OMNI)
  await p.type(OMNI, text)
  await sleep(150)
  await p.click('form.composer.omnibox--global [data-testid=send]')
  await sleep(900)
}

/* mock-data.mjs: the lobby welcome card, the opening of the lobby task */
const WELCOME_MSG = '11111111-1111-4111-8111-111111111111'

/* a card in the middle feed (that one, else the first), clicked as a person
   does: its thread opens */
async function openFirstCard(p, msgId = '') {
  await p.waitForSelector('.spool-main article.msg[data-msg-id]', { timeout: NAV })
  const at = await p.evaluate((id) => {
    const all = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')]
    const want = id && all.find((e) => e.getAttribute('data-msg-id') === id)
    if (want) want.scrollIntoView({ block: 'center' })
    const el = want || all.find((e) => e.getBoundingClientRect().height > 30)
    if (!el) return null
    const r = (el.querySelector('.msg-body') || el).getBoundingClientRect()
    return { x: Math.round(r.left + Math.min(40, r.width / 2)), y: Math.round(r.top + Math.min(10, r.height / 2)) }
  }, msgId)
  if (at) await p.mouse.click(at.x, at.y)
  await sleep(900)
}

async function railClick(p, id) {
  await p.click(`#sidebar-tab-${id}`)
  await sleep(1200)
}

const path = (p) => p.evaluate(() => decodeURIComponent(location.pathname + location.search))

const browser = await launch()
const server = await startServer()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((c) => {
    try { localStorage.setItem('spool.mock.session', JSON.stringify(c)) } catch { /* about:blank */ }
  }, CLAIMS)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV })

  /* 1 the measured shape: the lobby discussion open, then a person's DM */
  await openFirstCard(p, WELCOME_MSG)
  const before = await panes(p)
  check('1 setup: the lobby discussion is open in the right pane', before.live === LOBBY_TASK, before)
  await routeTo(p, '/dm/' + OFFLINE_PEER)
  const onDm = await panes(p)
  check('1 the DM closed the pane on the lobby discussion', paneClosed(onDm), onDm)
  await send(p, 'spl2765-note-to-offline-person')
  const dm = await sentRow(p, 'spl2765-note-to-offline-person')
  check('1 a note to an offline person: no channel, to HUM-3, not on the lobby discussion',
    Boolean(dm) && !dm.channel && dm.to === 'HUM-3' && dm.task_id !== LOBBY_TASK && dm.parent_task_id !== LOBBY_TASK, dm)

  /* 2 a channel note stays on its channel */
  await routeTo(p, '/channel/alerts')
  await send(p, 'spl2765-channel-note')
  const ch = await sentRow(p, 'spl2765-channel-note')
  check('2 a note on #alerts is stored on alerts', Boolean(ch) && ch.channel === 'alerts', ch)

  /* 3 a leftmost section closes the reply panel and the previous list */
  await openFirstCard(p)
  const a0 = await panes(p)
  check('3 setup: a topic is open on #alerts', !paneClosed(a0), a0)
  await railClick(p, 'dm')
  const a1 = await panes(p)
  const a1path = await path(p)
  check('3 Direct messages from #alerts: the reply panel closes', paneClosed(a1), a1)
  check('3 Direct messages from #alerts: the #alerts list closes, a DM place shows', a1path.includes('/dm') && !a1path.includes('alerts'), a1path)

  await routeTo(p, '/dm/' + OFFLINE_PEER)
  await routeTo(p, '/lobby')
  await openFirstCard(p, WELCOME_MSG)
  const b0 = await panes(p)
  check('3 setup: the lobby discussion is open again', b0.live === LOBBY_TASK, b0)
  await railClick(p, 'dm')
  const b1 = await panes(p)
  const b1path = await path(p)
  check('3 Direct messages from #lobby: the pane closes, the last DM shows with no topic', paneClosed(b1) && b1path.endsWith('/dm/' + OFFLINE_PEER), { b1, b1path })
  await railClick(p, 'channels')
  const c1 = await panes(p)
  const c1path = await path(p)
  check('3 Channels from a DM: the DM list closes, the last channel shows with no topic open', paneClosed(c1) && !c1path.includes('/dm') && !c1path.includes('topic='), { c1, c1path })

  await openFirstCard(p)
  await railClick(p, 'flow')
  const f1 = await panes(p)
  check('3 Flow: the reply panel closes', paneClosed(f1), f1)

  await railClick(p, 'channels')
  await openFirstCard(p)
  /* SPL-3250: the Event log is Monitoring's tab now; Monitoring is the section page */
  await railClick(p, 'monitoring')
  const e1 = await panes(p)
  const e1path = await path(p)
  check('3 Monitoring: the reply panel closes, Monitoring shows', paneClosed(e1) && e1path.includes('/monitoring'), { e1, e1path })

  check('no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
