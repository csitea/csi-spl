// Spec 117 FR-4 + FR-5 (t1 f87e6c9d): a member's DM replies never reached the
// owner. They were written on the topic page /t/<dm task>, where the channel
// store holds no DM peer, so the frame went out with no `to` and the hub
// stored it as ALL-0 that only its sender could read. Proved in a REAL
// browser on the mock bundle, driving the omnibox and GO as a person does:
//
//   1 FR-4: a reply on /t/<a DM topic with HUM-2> is sent to HUM-2@box-wui,
//     the same `to` the /dm/HUM-2@box-wui page sends
//   2 FR-5: a reply on /t/<a topic with no other end> is refused by the hub
//     (the mock answers 400 dm_needs_to, as the hub does): the existing
//     "Not sent" line shows, the text stays in the box, and no row looks sent.
//     No new string: the en core catalogue is in the home set, which has no
//     headroom (027 ci_home_gzip_kb)
//
// Before the fix case 1 stored `to` = @channel (no addressee), and the mock
// stored case 2 as sent.
//
// Run:
//   pnpm run test:e2e dm-reply-topic-to
//   BASE_URL=<generated bundle> pnpm run test:e2e dm-reply-topic-to   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const DM_TASK = 'e1170000-0000-4000-8000-000000000001'
const NOBODY_TASK = 'e1170000-0000-4000-8000-000000000002'
const EXTRA = [
  /* HUM-2 opened a DM with the viewer HUM-1: two people, no channel */
  { v: 1, msg_id: 'e1170001-0000-4000-8000-000000000001', task_id: DM_TASK, ts: '2026-09-18T10:10:00Z',
    from: 'HUM-2', from_box: 'box-wui', to: 'HUM-1', to_box: 'box-wui', kind: 'note', body: 'a question for you',
    files: [], channel: null, parent_task_id: null },
  /* the viewer's own channel-less root with no addressee (the 22f73584 shape) */
  { v: 1, msg_id: 'e1170001-0000-4000-8000-000000000002', task_id: NOBODY_TASK, ts: '2026-09-18T10:11:00Z',
    from: 'HUM-1', from_box: 'box-wui', to: 'ALL-0', to_box: 'box-wui', kind: 'note', body: 'a line for nobody',
    files: [], channel: null, parent_task_id: null },
]

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

/** The channel store row whose body contains `needle` (the mock send appends it). */
function sentRow(p, needle) {
  return p.evaluate((n) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const msgs = (pinia.state.value.channel && pinia.state.value.channel.messages) || []
    const m = [...msgs].reverse().find((x) => String(x.body || '').includes(n))
    return m ? { to: String(m.to || ''), to_box: String(m.to_box || ''), channel: m.channel || null } : null
  }, needle)
}

async function send(p, text) {
  const ta = 'form.composer.omnibox--global textarea'
  await p.waitForSelector(ta, { timeout: NAV_TIMEOUT })
  await p.focus(ta)
  await p.type(ta, text)
  await sleep(150)
  await p.click('form.composer.omnibox--global [data-testid=send]')
  await sleep(900)
}

async function openTopic(p, base, id) {
  await p.goto(`${base}/t/${id}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(`article.msg[data-msg-id="${EXTRA.find((m) => m.task_id === id).msg_id}"]`, { timeout: NAV_TIMEOUT })
  await sleep(400)
}

const browser = await launch()
const server = await startServer()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((extra) => {
    try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra)) } catch { /* about:blank */ }
  }, EXTRA)
  await p.setViewport({ width: 1440, height: 900 })

  /* 1 FR-4: the reply goes to the other person, as /dm does */
  await openTopic(p, server.base, DM_TASK)
  await send(p, 'fr4-reply-from-topic-page')
  const row = await sentRow(p, 'fr4-reply-from-topic-page')
  ok('FR-4: a reply on /t/<DM topic> is sent to HUM-2@box-wui, no channel', Boolean(row) && row.to === 'HUM-2' && row.to_box === 'box-wui' && !row.channel, row)

  /* 2 FR-5: the hub cannot tell who it is for, and the reader is told */
  await openTopic(p, server.base, NOBODY_TASK)
  await send(p, 'fr5-reply-for-nobody')
  const shown = await p.evaluate(() => {
    const el = document.querySelector('[data-test=omnibox-send-error]')
    const ta = document.querySelector('form.composer.omnibox--global textarea')
    return {
      error: el ? el.querySelector('[data-test=omnibox-send-error-message]')?.textContent.trim() || '' : '',
      visible: Boolean(el && el.getClientRects().length > 0),
      box: ta ? ta.value : '',
    }
  })
  ok('FR-5: a dm_needs_to refusal shows the "Not sent" line', shown.visible && shown.error.startsWith('Not sent'), shown)
  ok('FR-5: the text stays in the box', shown.box === 'fr5-reply-for-nobody', shown.box)
  ok('FR-5: no row looks sent', (await sentRow(p, 'fr5-reply-for-nobody')) === null)

  ok('no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
if (failed.length) {
  console.error('FAILED:', failed.map((r) => r.name).join(' | '))
  process.exit(1)
}
