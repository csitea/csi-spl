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
//   3 the journey's other end: A (HUM-2) opened the DM, B answered in 1 with
//     no @mention; that row moves A's unread count for B and shows in A's
//     /dm/<B> (a second browser context, signed in as HUM-2)
//   4 FR-2: a NEW channel-less topic naming nobody (the 22f73584 shape) is
//     refused dm_needs_to and stores no row (the store's send: today's
//     composer never sends that shape, see the case)
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
  /* the whole stored row, for the other end in 3 (2 opens another topic) */
  const reply = await p.evaluate((n) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const m = [...(pinia.state.value.channel.messages || [])].reverse().find((x) => String(x.body || '').includes(n))
    return m ? JSON.parse(JSON.stringify(m)) : null
  }, 'fr4-reply-from-topic-page')

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

  /* 3 the journey's other end (lane B): A = HUM-2 opened this DM, B = the
     viewer HUM-1 answered on /t/<task> above with no @mention. The row B's
     page stored reaches A as the hub pushes it: A's unread count for B
     moves, and A sees the line in /dm/<B> */
  const ctx = await browser.createBrowserContext()
  const a = await ctx.newPage()
  const aErrors = []
  a.on('pageerror', (e) => aErrors.push(String(e).slice(0, 200)))
  await a.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
      localStorage.setItem('spool.mock.flow-keys', 'off')
    } catch { /* about:blank */ }
  }, [EXTRA[0], reply].filter(Boolean))
  await a.setViewport({ width: 1440, height: 900 })
  await a.goto(`${server.base}/lobby`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await a.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
  const notes = (fn, ...args) => a.evaluate((fn, args) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    if (fn === 'adopt') return void pinia._s.get('session').adopt(args[0])
    const n = pinia._s.get('notification')
    if (fn === 'unread') return { unread: n.unread[args[0]] || 0, total: n.dmTotal[args[0]] || 0 }
    const out = n[fn](...args)
    return out === undefined ? null : out
  }, fn, args)
  await notes('adopt', { hum: 'HUM-2', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  const B_KEY = 'dm:HUM-1@box-wui'
  await notes('applyDms', [{ task_id: DM_TASK, count: 1, participants: ['HUM-1@box-wui', 'HUM-2@box-wui'], inline: { messages: [{ ...EXTRA[0], to: 'HUM-1' }] } }], 'HUM-2', '')
  const before = await notes('unread', B_KEY)
  if (reply) {
    await notes('countDmLive', reply, 'HUM-2')
    await notes('ingest', [reply], { selfId: 'HUM-2', activeKey: '' }, { hydrate: false })
  }
  await sleep(300)
  const after = await notes('unread', B_KEY)
  ok('journey: B\'s reply is addressed to A (HUM-2), the DM\'s opener', Boolean(reply) && reply.from === 'HUM-1' && reply.to === 'HUM-2' && !reply.channel, reply && { from: reply.from, to: reply.to, channel: reply.channel })
  ok('journey: A\'s unread count for B moves by one (and the total)', after.unread === before.unread + 1 && after.total === before.total + 1, { before, after })
  await a.goto(`${server.base}/dm/HUM-1@box-wui`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  /* the DM lists the topic by its opening card; the reply is a line of it */
  const opener = `.spool-main article.msg[data-msg-id="${EXTRA[0].msg_id}"]`
  await a.waitForSelector(opener, { timeout: NAV_TIMEOUT })
  await a.click(opener)
  const seen = reply
    ? await a.waitForFunction((id) => [...document.querySelectorAll(`article.msg[data-msg-id="${CSS.escape(id)}"]`)].some((e) => e.getClientRects().length > 0), { timeout: 15000 }, reply.msg_id).then(() => true, () => false)
    : false
  const onDm = await a.evaluate(() => ({ path: location.pathname, cards: [...document.querySelectorAll('article.msg[data-msg-id]')].map((e) => e.getAttribute('data-msg-id').slice(0, 8)) }))
  ok('journey: A sees B\'s reply in /dm/<B>', seen, { ...onDm, want: reply && reply.msg_id })
  ok('journey: no page error on A\'s side', aErrors.length === 0, aErrors)
  await ctx.close()

  /* 4 FR-2 (lane B): a NEW channel-less topic naming nobody (the 22f73584
     shape: is_parent 1, no channel, no `to`) is refused by the hub (the mock
     answers 400 dm_needs_to) and stores no row; before, the mock stored it
     as sent. Today's composer never sends that shape from /t/<task> (n=4
     paths probed 2026-10-09: the thread's X, the flow, channels and phone
     lists all reply into a topic), so the page's own channel store sends
     it; the "Not sent" line for this token is case 2's */
  await openTopic(p, server.base, DM_TASK)
  const fr2 = await p.evaluate(async () => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const channel = pinia._s.get('channel')
    let err = null
    try { await channel.send('fr2-new-topic-for-nobody', undefined, [], undefined, 1) } catch (e) { err = { status: e.status, token: e.token } }
    return { err, active: channel.active || '', peer: channel.peer || '' }
  })
  ok('FR-2: a new channel-less topic naming nobody is refused dm_needs_to', Boolean(fr2.err) && fr2.err.status === 400 && fr2.err.token === 'dm_needs_to' && !fr2.active && !fr2.peer, fr2)
  const rootRow = await sentRow(p, 'fr2-new-topic-for-nobody')
  ok('FR-2: no row looks sent', rootRow === null, rootRow)

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
