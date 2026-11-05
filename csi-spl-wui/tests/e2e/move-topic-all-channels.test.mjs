// SPL-4892 (specs/045 §3.2, owner t1 5eee1925 msg 91dc8b84): Move to topic…
// suggests the topics of EVERY channel of the workspace the viewer may read,
// not only the channel on screen, and never a topic of a channel the viewer
// is not in.
//
// The mock feed gets, through its test hook (localStorage
// spool.mock.extra-messages):
//   - an own topic + an own reply in #alerts (the reply is what is moved);
//   - 60 newer topics in #alerts, so the newest 50 topics of the workspace
//     are all #alerts (the busy-channel case: one tenant-wide page of 50 left
//     every other channel out);
//   - an OLDER topic in #feedback (a channel the viewer reads): it must be
//     offered, with its #feedback hint, and the filter must find it;
//   - the NEWEST topic, in #spl-4892-private, a channel the viewer is not in
//     (the mock lists no such channel): it must never be offered.
// Red before the fix: the #feedback topic is missing (n=1).
//
// Run:
//   pnpm run test:e2e move-topic-all-channels
//   BASE_URL=<generated bundle> pnpm run test:e2e move-topic-all-channels   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OWN_TOPIC = '48920000-0000-4000-8000-000000000001'
const OWN_REPLY = '48920000-0000-4000-8000-000000000002'
const OTHER_TOPIC = '48920000-0000-4000-8000-000000000003'
const PRIVATE_TOPIC = '48920000-0000-4000-8000-000000000004'
const FLOOD = 60

const row = (p) => ({ v: 1, files: [], parent_task_id: null, is_parent: 1, from: 'GRK-03', from_box: 'box-a', to: '@channel', to_box: 'box-wui', kind: 'note', ...p })
const EXTRA = [
  row({ msg_id: OTHER_TOPIC, task_id: OTHER_TOPIC, ts: '2026-10-01T09:00:00Z', channel: 'feedback', body: 'SPL-4892 a topic in feedback' }),
  ...Array.from({ length: FLOOD }, (_, i) => {
    const id = `48920001-0000-4000-8000-${String(i).padStart(12, '0')}`
    return row({ msg_id: id, task_id: id, ts: `2026-11-01T${String(Math.floor(i / 60)).padStart(2, '0')}:${String(i % 60).padStart(2, '0')}:00Z`, channel: 'alerts', body: `SPL-4892 alerts flood ${i}` })
  }),
  row({ msg_id: OWN_TOPIC, task_id: OWN_TOPIC, ts: '2026-11-02T10:00:00Z', channel: 'alerts', from: 'HUM-1', from_box: 'box-wui', body: 'SPL-4892 own topic' }),
  row({ msg_id: OWN_REPLY, task_id: OWN_TOPIC, parent_task_id: OWN_TOPIC, is_parent: 0, ts: '2026-11-02T10:01:00Z', channel: 'alerts', from: 'HUM-1', from_box: 'box-wui', body: 'SPL-4892 own reply' }),
  row({ msg_id: PRIVATE_TOPIC, task_id: PRIVATE_TOPIC, ts: '2026-11-03T09:00:00Z', channel: 'spl-4892-private', body: 'SPL-4892 a topic in a channel the viewer is not in' }),
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

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const paneRow = (id) => `aside[data-pane="topic"] article.msg[data-msg-id="${id}"]`

/** Open a middle card's topic on the right and wait for `sel` there (retried once or twice). */
async function openTopic(p, cardId, sel) {
  for (let i = 0; i < 3; i++) {
    await sleep(300)
    await p.evaluate((s) => document.querySelector(s)?.click(), `${midCard(cardId)} .msg-meta .msg-time`)
    if (await p.waitForSelector(sel, { timeout: 4000 }).then(() => true, () => false)) return true
  }
  return false
}

async function openMenu(p, sel) {
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
  for (let i = 0; i < 2; i++) {
    await p.evaluate((s) => document.querySelector(`${s} [data-testid=msg-menu-btn]`)?.click(), sel)
    for (let t = 0; t < 20; t++) {
      await sleep(150)
      const got = await items()
      if (got.length) return got
    }
  }
  return []
}

const pickerRows = (p) => p.evaluate(() => [...document.querySelectorAll('[data-testid=move-picker-topic] [data-testid=move-picker-row]')]
  .map((e) => ({ id: e.getAttribute('data-target'), hint: e.querySelector('.move-picker__hint')?.textContent.trim() || '' })))

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1440, height: 900 })
  await p.evaluateOnNewDocument((extra) => {
    try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra)) } catch { /* about:blank */ }
  }, EXTRA)
  await p.goto(`${srv.base}/channel/alerts`, { waitUntil: 'networkidle2' })
  await p.waitForSelector(midCard(OWN_TOPIC), { timeout: NAV_TIMEOUT })
  ok('seed: the reply opens in the topic pane', await openTopic(p, OWN_TOPIC, paneRow(OWN_REPLY)))

  const menu = await openMenu(p, paneRow(OWN_REPLY))
  ok('the reply\'s menu offers Move to topic…', menu.includes('msg-menu-move-topic'), menu)
  await p.click('[data-testid=msg-menu-move-topic]')
  await p.waitForSelector('[data-testid=move-picker-topic] [data-testid=move-picker-row]', { timeout: 8000 }).catch(() => {})
  await sleep(800)
  const rows = await pickerRows(p)
  const other = rows.find((r) => r.id === OTHER_TOPIC)
  ok('a topic of another channel the viewer reads (#feedback) is offered', Boolean(other), { rows: rows.length })
  ok('... its row names its channel', other?.hint === '#feedback', other)
  ok('a topic of the channel on screen (#alerts) is still offered', rows.some((r) => r.id.startsWith('48920001-')), { rows: rows.length })
  ok('CONTROL: a topic of a channel the viewer is not in is never offered', !rows.some((r) => r.id === PRIVATE_TOPIC))
  ok('CONTROL: the reply\'s own topic is not offered', !rows.some((r) => r.id === OWN_TOPIC))

  await p.keyboard.type('feedback')
  await sleep(300)
  const filtered = await pickerRows(p)
  ok('the filter finds the other channel\'s topic', filtered.some((r) => r.id === OTHER_TOPIC) && filtered.every((r) => r.hint === '#feedback'), filtered)
  ok('no page errors', errors.length === 0, errors)
  await p.keyboard.press('Escape')
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmove-topic-all-channels: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
