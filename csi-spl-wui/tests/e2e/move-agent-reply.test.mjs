// Owner, t1 ffc3b83c: "the humans should be able to move the bots msgs to a
// desired topic". A plain member (role developer, not the owner, not an
// admin) opens a channel topic: an AGENT's reply offers Move to topic… in its
// menu and carries the drag handle; another PERSON's reply in the same topic
// offers neither (CONTROL: the author / owner / admin rule still holds there).
// Then the owner's own case (t1 ffc3b83c was a DM): in the viewer's DM with
// GRK-03, the agent's DM reply offers Move to topic… (never Make it a topic),
// the viewer's own DM message does not, and the pick moves it into a channel
// topic.
//
// Against the mock bundle: the two replies are added through the mock's test
// hook (localStorage spool.mock.extra-messages) under the #alerts card, and
// the mock member is a plain developer through spool.mock.archive_policy +
// spool.mock.role (the mock's me()). 1440x900.
//
// Run:
//   pnpm run test:e2e move-agent-reply
//   BASE_URL=<generated bundle> pnpm run test:e2e move-agent-reply     # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* the lde mock #alerts card (GRK-03) and its topic */
const CARD = '66666666-6666-4666-8666-666666666666'
const TOPIC = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
const AGENT_REPLY = 'e3730001-0000-4000-8000-000000000001'
const PERSON_REPLY = 'e3730001-0000-4000-8000-000000000002'
/* the mock DM of HUM-1 with GRK-03: its card (HUM-1's) and GRK-03's reply to HUM-1 */
const DM_PATH = '/dm/' + encodeURIComponent('GRK-03@box-a')
const DM_TOPIC = '99999999-9999-4999-8999-999999999999'
const DM_CARD = '77777777-7777-4777-8777-777777777777'
const DM_REPLY = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const EXTRA = [
  { v: 1, msg_id: AGENT_REPLY, task_id: 'e3730002-0000-4000-8000-000000000001', ts: '2026-09-18T10:05:30Z',
    from: 'c-004', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', kind: 'note', body: 'an agent reply',
    files: [], channel: 'alerts', parent_task_id: TOPIC, is_parent: 0 },
  { v: 1, msg_id: PERSON_REPLY, task_id: 'e3730002-0000-4000-8000-000000000002', ts: '2026-09-18T10:05:40Z',
    from: 'HUM-3', from_box: 'box-wui', to: 'ALL-0', to_box: 'box-wui', kind: 'note', body: 'a person reply',
    files: [], channel: 'alerts', parent_task_id: TOPIC, is_parent: 0 },
]

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

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const signIn = (p) => p.evaluate(() => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const paneRow = (id) => `aside[data-pane="topic"] article.msg[data-msg-id="${id}"]`

/** The menu's entries ('<testid>' or '<testid>:off'); the menu mounts lazily. */
async function openMenu(p, sel) {
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid') + (e.getAttribute('aria-disabled') === 'true' ? ':off' : '')))
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

async function closeMenu(p) {
  await p.keyboard.press('Escape')
  await sleep(200)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
      localStorage.setItem('spool.mock.archive_policy', 'everyone')
      localStorage.setItem('spool.mock.role', 'developer')
    } catch { /* about:blank */ }
  }, EXTRA)
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(`${server.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector(midCard(CARD), { timeout: NAV_TIMEOUT })
  if (!(await signIn(p))) throw new Error('no session store')
  await sleep(600)

  /* the mock me() is a developer (or null = no role at all): never owner or admin */
  const me = await p.evaluate(() => {
    const m = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('access')?.me
    return m ? { role: m.role, owner: m.tenantOwner } : null
  })
  ok('0 the viewer is not the owner nor an admin', !me || (me.owner !== true && !['admin', 'biz_owner'].includes(String(me.role))), me)

  let opened = false
  for (let i = 0; i < 3 && !opened; i++) {
    await p.evaluate((sel) => document.querySelector(sel)?.click(), `${midCard(CARD)} .msg-meta .msg-time`)
    opened = await p.waitForSelector(paneRow(AGENT_REPLY), { timeout: 4000 }).then(() => true, () => false)
  }
  ok('1 the topic pane shows the agent reply and the person reply', opened && Boolean(await p.$(paneRow(PERSON_REPLY))))

  const agentMenu = await openMenu(p, paneRow(AGENT_REPLY))
  ok('2 an agent reply offers Move to topic…', agentMenu.includes('msg-menu-move-topic'), agentMenu)
  await closeMenu(p)
  const agentHandle = Boolean(await p.$(`${paneRow(AGENT_REPLY)} [data-testid=move-handle]`))
  ok('3 an agent reply carries the drag handle', agentHandle)

  const personMenu = await openMenu(p, paneRow(PERSON_REPLY))
  ok('4 CONTROL another person\'s reply offers no Move to topic…', personMenu.length > 0 && !personMenu.some((x) => x.startsWith('msg-menu-move-topic')), personMenu)
  await closeMenu(p)
  const personHandle = Boolean(await p.$(`${paneRow(PERSON_REPLY)} [data-testid=move-handle]`))
  ok('5 CONTROL another person\'s reply has no drag handle', !personHandle)

  /* ---- the DM: an agent's DM reply to the viewer moves out to a channel topic */
  await go(p, `${DM_PATH}?topic=${DM_TOPIC}`)
  const dmRow = (id) => `aside.live-pane [data-msg-id="${id}"]`
  const inDm = await p.waitForSelector(dmRow(DM_REPLY), { visible: true, timeout: 10000 }).then(() => true, () => false)
  ok('6 the DM pane shows the agent\'s DM reply', inDm)
  const dmMenu = await openMenu(p, dmRow(DM_REPLY))
  ok('7 the agent\'s DM reply offers Move to topic… and not Make it a topic',
    dmMenu.includes('msg-menu-move-topic') && !dmMenu.some((x) => x.startsWith('msg-menu-promote-topic')), dmMenu)
  await closeMenu(p)
  const cardMenu = await openMenu(p, dmRow(DM_CARD))
  ok('8 CONTROL the viewer\'s own DM message offers no Move to topic…',
    cardMenu.length > 0 && !cardMenu.some((x) => x.startsWith('msg-menu-move-topic')), cardMenu)
  await closeMenu(p)

  await openMenu(p, dmRow(DM_REPLY))
  await p.click('[data-testid=msg-menu-move-topic]')
  await p.waitForSelector('[data-testid=move-picker-topic] [data-testid=move-picker-row]', { timeout: 8000 }).catch(() => {})
  const targets = await p.evaluate(() => [...document.querySelectorAll('[data-testid=move-picker-row]')].map((e) => e.getAttribute('data-target')))
  ok('9 the picker lists the #alerts topic', targets.includes(TOPIC), targets)
  await p.evaluate((t) => document.querySelector(`[data-testid=move-picker-row][data-target="${t}"]`)?.click(), TOPIC)
  let left = false
  for (let i = 0; i < 40 && !left; i++) {
    await sleep(150)
    left = await p.evaluate((sel) => !document.querySelector(sel), dmRow(DM_REPLY))
  }
  const toast = await p.evaluate(() => document.querySelector('[data-testid=move-toast-text]')?.textContent.trim() || '')
  ok('10 the pick moves the DM reply out of the DM', left, toast)
  ok('11 no page errors', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
