// Level 1 / level 2 — live proof, signed in, against a deployed WUI.
//
// Owner order 2026-09-25: a spool message is one of two levels.
//   level 1  the opening message of a topic. is_parent = 1. It is the card in
//            the middle pane, one card per topic, and the card's text stays
//            the opening message.
//   level 2  a message written while the right-hand topic pane is open (the
//            reader got there by clicking replies, and the left tab stayed
//            where it was). is_parent = 0. It is drawn only inside the open
//            topic on the right - never a middle card, never a new topic.
//
// Per surface (channel, DM, lobby, topics home, t), n = 1 each:
//   1. pane closed, send L1  -> one new middle card, hub is_parent 1, pane stays closed
//   2. open the card's topic (replies / row click), send L2 with the left tab
//      untouched -> hub is_parent 0 on the SAME task_id, L2 in the right pane
//      only, the middle still shows exactly one card for the task and it reads L1
//   3. reload -> L2 still absent from the middle, the card still reads L1, and
//      L2 is present once that topic is opened on the right
// Surface `t` (T014, FR-ML-011): L1 on the channel, then /t/<task> with the
// pane closed, send L2 -> it shows in the main column (the topic itself), not
// in the right pane, hub is_parent 0 on the same task, and back on the channel
// there is still one card for the task and it reads L1.
//
// The middle pane is `.feed-col` outside the right `aside.live-pane`; the
// right pane's own messages exclude the born-topics stack.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=lobby] [PEER=<agent>@<box>] [SURFACES=channel,dm,lobby,home,t] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/parent-level-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      return mod.default ?? mod
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || 'lobby'
const PEER = process.env.PEER || ''
const SURFACES = (process.env.SURFACES || 'channel,dm,lobby,home,t').split(',').map((s) => s.trim()).filter(Boolean)
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], surfaces: {}, console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const run = Date.now().toString(36)
/* Every line this proof posts starts with the probe marker: the desk shows it
   in an agent's notice strip and never types it into a prompt (specs/017
   FR-SEC-030). Unmarked, 'attach L1 lobby <id>' was obeyed as an order by an
   agent on prd 2026-09-25. */
const PROBE_MARK = '[spool-probe]'

/* ---- in-page reads ------------------------------------------------------ */

/** Everything the middle and right panes show, as plain data. */
const SNAPSHOT = () => {
  const pane = document.querySelector('aside.live-pane')
  const inPane = (el) => !!pane && pane.contains(el)
  const born = pane ? pane.querySelector('[data-test=born-topics]') : null
  const text = (el) => (el.innerText || '').replace(/\s+/g, ' ').trim()
  const middle = []
  for (const col of document.querySelectorAll('.feed-col')) {
    if (inPane(col)) continue
    for (const el of col.querySelectorAll('article.msg, a.topic-row')) {
      middle.push({ task: el.getAttribute('data-task-id') || el.getAttribute('data-key') || '', text: text(el) })
    }
  }
  const right = []
  if (pane) {
    for (const el of pane.querySelectorAll('article.msg')) {
      if (born && born.contains(el)) continue
      right.push({ task: el.getAttribute('data-task-id') || '', text: text(el) })
    }
  }
  const tab = document.querySelector('.sidebar-tab[aria-selected="true"]')
  return { paneOpen: !!pane, middle, right, tab: tab ? tab.id : '', url: location.pathname + location.search }
}

/* Two tabs share one headless browser: the one not in front is throttled
   and its evaluate() can hang, so every read and every keystroke first
   brings its own tab to the front. */
async function front(p) { await p.bringToFront().catch(() => {}) }

async function snap(p) { await front(p); return p.evaluate(SNAPSHOT) }

async function waitFor(p, pred, ms = 15000) {
  const end = Date.now() + ms
  let s
  while (Date.now() < end) {
    s = await snap(p)
    if (pred(s)) return s
    await sleep(300)
  }
  return s
}

/** The hub's own rows for one topic: [{ body, is_parent }] oldest first. */
async function hubRows(p, apiRoot, task) {
  return p.evaluate(async (root, id) => {
    const r = await fetch(`${root}/v1/view/topics/${encodeURIComponent(id)}?order=asc&limit=50`, { credentials: 'include', headers: { accept: 'application/json' } })
    if (!r.ok) return { status: r.status }
    const j = await r.json()
    return {
      status: r.status,
      rows: (j.messages || []).map((m) => ({ body: String((m.env && m.env.msg && m.env.msg.body) || m.body || ''), is_parent: m.is_parent, msg_id: m.msg_id })),
    }
  }, apiRoot, task)
}

/* ---- browser steps ------------------------------------------------------ */

async function signIn(ctx) {
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  p.on('request', (req) => {
    const u = req.url()
    const i = u.indexOf('/v1/view/')
    if (i > 0 && !res.apiRoot) res.apiRoot = u.slice(0, i)
  })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  return p
}

async function send(p, text) {
  await front(p)
  const ta = await p.waitForSelector('form.composer textarea')
  await ta.click({ count: 3 })
  await p.keyboard.press('Backspace')
  await p.keyboard.type(text)
  await p.keyboard.down('Control')
  await p.keyboard.press('Enter')
  await p.keyboard.up('Control')
}

async function closePane(p) {
  await front(p)
  for (let i = 0; i < 3; i++) {
    const btn = await p.$('aside.live-pane [data-test=topic-pane-close], aside.live-pane [data-test=live-topic-close]')
    if (!btn) return
    await btn.click().catch(() => {})
    await sleep(600)
  }
}

/** Open the topic of the middle card for TASK the way a reader does. */
async function openTopic(p, surface, task) {
  await front(p)
  if (surface === 'home') {
    const row = await p.$(`.feed-col a.topic-row[data-key="${task}"]`)
    if (!row) return false
    await row.click()
    return true
  }
  const card = await p.$(`.feed-col article.msg[data-task-id="${task}"]`)
  if (!card) return false
  const replies = await card.$('[data-test=topic-replies]')
  if (replies) await replies.click()
  else await card.click()
  return true
}

function pathFor(surface) {
  switch (surface) {
    case 'channel': return '/channel/' + encodeURIComponent(CHANNEL)
    case 'dm': return '/dm/' + encodeURIComponent(PEER)
    case 'lobby': return '/lobby'
    case 'home': return '/'
    default: throw new Error('unknown surface ' + surface)
  }
}

const cardsFor = (s, task) => s.middle.filter((m) => m.task === task)
const has = (list, needle) => list.some((m) => m.text.includes(needle))

/* A second tab on the same surface, never typing: it sees every line only
   through the hub's live frame, which is the path the sender's own
   optimistic row hides. */
let watcher = null

async function surfaceRun(p, surface) {
  const L1 = `${PROBE_MARK} L1 ${surface} ${run}`
  const L2 = `${PROBE_MARK} L2 ${surface} ${run}`
  const ev = { L1, L2 }
  res.surfaces[surface] = ev
  const tag = (n) => `${surface}: ${n}`

  await p.goto(BASE + pathFor(surface), { waitUntil: 'networkidle2' })
  await sleep(1500)
  await closePane(p)
  if (watcher) {
    await watcher.goto(BASE + pathFor(surface), { waitUntil: 'networkidle2' })
    await sleep(1500)
    await closePane(watcher)
  }

  /* 1. pane closed -> a new level-1 card */
  await send(p, L1)
  let s = await waitFor(p, (x) => has(x.middle, L1))
  const l1 = s.middle.filter((m) => m.text.includes(L1))
  const task = l1.length ? l1[0].task : ''
  ev.task = task
  step(tag('1 L1 is one middle card'), l1.length === 1 && !!task, { cards: l1.length, task })
  step(tag('1 right pane stays closed'), !s.paneOpen, { paneOpen: s.paneOpen })
  if (!task) return
  await sleep(1200)
  let hub = res.apiRoot ? await hubRows(p, res.apiRoot, task) : { status: 0 }
  const h1 = (hub.rows || []).find((r) => r.body.includes(L1))
  step(tag('1 hub stores L1 with is_parent 1'), !!h1 && h1.is_parent === 1, { status: hub.status, is_parent: h1 && h1.is_parent })

  /* 2. replies click -> right pane open, left tab untouched, send L2 */
  const tabBefore = s.tab
  const opened = await openTopic(p, surface, task)
  s = await waitFor(p, (x) => x.paneOpen, 10000)
  step(tag('2 replies opens the right pane'), opened && s.paneOpen, { opened, paneOpen: s.paneOpen })
  step(tag('2 left tab unchanged'), s.tab === tabBefore, { before: tabBefore, after: s.tab })
  /* owner, 2026-09-25: the pane's Open button is obsolete and removed */
  const openBtn = await p.$('aside.live-pane [data-test=live-topic-open]')
  step(tag('2 the right pane has no Open button'), !openBtn, {})
  await sleep(800)
  await send(p, L2)
  s = await waitFor(p, (x) => has(x.right, L2))
  await sleep(2500) /* let the echo and any re-read land before judging the middle */
  s = await snap(p)
  step(tag('2 L2 is in the right pane'), has(s.right, L2), { right: s.right.length })
  step(tag('2 L2 is not in the middle'), !has(s.middle, L2), { middle: s.middle.filter((m) => m.text.includes(L2)) })
  const cards2 = cardsFor(s, task)
  step(tag('2 middle has one card for the topic and it reads L1'),
    cards2.length === 1 && cards2[0].text.includes(L1) && !cards2[0].text.includes(L2),
    { cards: cards2.map((c) => c.text.slice(0, 120)) })
  hub = await hubRows(p, res.apiRoot, task)
  const h2 = (hub.rows || []).find((r) => r.body.includes(L2))
  step(tag('2 hub stores L2 on the same task with is_parent 0'), !!h2 && h2.is_parent === 0,
    { status: hub.status, is_parent: h2 && h2.is_parent, rows: (hub.rows || []).length })
  await p.screenshot({ path: `${OUT}/${surface}-2-after-L2.png` })
  if (watcher) {
    const w = await waitFor(watcher, (x) => has(x.middle, L1), 8000)
    const wc = cardsFor(w, task)
    step(tag('2 watcher: L2 is not in its middle'), !has(w.middle, L2), { middle: w.middle.filter((m) => m.text.includes(L2)).map((m) => m.text.slice(0, 120)) })
    step(tag('2 watcher: one card for the topic and it reads L1'),
      wc.length === 1 && wc[0].text.includes(L1) && !wc[0].text.includes(L2), { cards: wc.map((c) => c.text.slice(0, 120)) })
    await watcher.screenshot({ path: `${OUT}/${surface}-2-watcher.png` })
  }

  /* 2b. test-02: the pane stays open but the reader clicks back in the
     middle. The next line is a NEW level-1 topic, not a line of the open one. */
  const L3 = `${PROBE_MARK} L3 ${surface} ${run}`
  const L4 = `${PROBE_MARK} L4 ${surface} ${run}`
  ev.L3 = L3
  ev.L4 = L4
  await front(p)
  await p.click('.spool-main .feed-header').catch(async () => { await p.click('.spool-main') })
  await sleep(400)
  await send(p, L3)
  s = await waitFor(p, (x) => has(x.middle, L3))
  const l3 = s.middle.filter((m) => m.text.includes(L3))
  const task3 = l3.length ? l3[0].task : ''
  step(tag('2b middle selected last: L3 is a new middle card'), l3.length === 1 && !!task3 && task3 !== task, { cards: l3.length, task3 })
  step(tag('2b L3 is not a line of the open topic'), !s.right.some((m) => m.text.includes(L3) && m.task === task), {})
  if (task3) {
    const h3 = ((await hubRows(p, res.apiRoot, task3)).rows || []).find((r) => r.body.includes(L3))
    step(tag('2b hub stores L3 with is_parent 1'), !!h3 && h3.is_parent === 1, { is_parent: h3 && h3.is_parent })
  }

  /* 2c. test-03: the reader clicks in the right pane again. The next line is
     level 2 of the topic that pane shows. */
  s = await snap(p)
  if (s.paneOpen) {
    await front(p)
    await p.click('aside.live-pane header')
    await sleep(400)
    await send(p, L4)
    s = await waitFor(p, (x) => has(x.right, L4))
    await sleep(1500)
    s = await snap(p)
    step(tag('2c right selected last: L4 is in the right pane, not the middle'), has(s.right, L4) && !has(s.middle, L4), {})
    /* the pane still shows L1's topic; L3 sits above it as a born card, which
       is a different stack. L4 belongs to L1's topic. */
    const h4 = ((await hubRows(p, res.apiRoot, task)).rows || []).find((r) => r.body.includes(L4))
    step(tag('2c hub stores L4 with is_parent 0 in the open (L1) topic'), !!h4 && h4.is_parent === 0, { is_parent: h4 && h4.is_parent })
  } else {
    step(tag('2c the right pane is still open after the middle send'), false, {})
  }

  /* 2d. double click on the reader's own level-1 card opens the editor */
  if (surface !== 'home') {
    await front(p)
    const card = await p.$(`.spool-main article.msg[data-task-id="${task}"] .msg-body, .spool-main article.msg[data-task-id="${task}"]`)
    if (card) await card.click({ count: 2 })
    const editing = await p.waitForSelector(`.spool-main article.msg[data-task-id="${task}"] [data-test=msg-edit-box]`, { timeout: 5000 }).then(() => true, () => false)
    step(tag('2d double click on the L1 card opens its editor'), editing, {})
    if (editing) { await p.keyboard.press('Escape'); await sleep(400) }
  }

  /* 2e. the Open button: on middle cards only, and it opens the topic on the right */
  if (surface !== 'home') {
    await closePane(p)
    await front(p)
    const btn = await p.$(`.spool-main article.msg[data-task-id="${task}"] [data-test=open-topic]`)
    step(tag('2e the L1 card carries the Open button'), !!btn, {})
    if (btn) await btn.click()
    s = await waitFor(p, (x) => x.paneOpen && has(x.right, L2), 10000)
    step(tag('2e Open opens that topic in the right pane'), s.paneOpen && has(s.right, L2), { paneOpen: s.paneOpen })
    const inPane = await p.$$('aside.live-pane [data-test=open-topic], aside.live-pane [data-test=live-topic-open]')
    step(tag('2e the right pane has no Open button'), inPane.length === 0, { n: inPane.length })
  }

  /* 3. reload */
  await front(p)
  await p.reload({ waitUntil: 'networkidle2' })
  await sleep(2500)
  await closePane(p)
  s = await waitFor(p, (x) => cardsFor(x, task).length > 0, 10000)
  const cards3 = cardsFor(s, task)
  step(tag('3 after reload L2 is not in the middle'), !has(s.middle, L2), {})
  step(tag('3 after reload one card reads L1'),
    cards3.length === 1 && cards3[0].text.includes(L1) && !cards3[0].text.includes(L2),
    { cards: cards3.map((c) => c.text.slice(0, 120)) })
  await openTopic(p, surface, task)
  s = await waitFor(p, (x) => x.paneOpen && has(x.right, L2), 10000)
  step(tag('3 after reload the opened topic shows L2 on the right'), s.paneOpen && has(s.right, L2), { right: s.right.length })
  await p.screenshot({ path: `${OUT}/${surface}-3-reloaded.png` })
  await closePane(p)
}

/* T014: /t/<task> is the topic in the main column; a line sent there is
   level 2 of that topic and adds no card on the channel feed. */
async function topicPageRun(p) {
  const L1 = `L1 t ${run}`
  const L2 = `L2 t ${run}`
  const ev = { L1, L2 }
  res.surfaces.t = ev
  const tag = (n) => `t: ${n}`

  await p.goto(BASE + pathFor('channel'), { waitUntil: 'networkidle2' })
  await sleep(1500)
  await closePane(p)
  await send(p, L1)
  let s = await waitFor(p, (x) => has(x.middle, L1))
  const l1 = s.middle.filter((m) => m.text.includes(L1))
  const task = l1.length ? l1[0].task : ''
  ev.task = task
  step(tag('1 L1 is one channel card'), l1.length === 1 && !!task, { cards: l1.length, task })
  if (!task) return

  await p.goto(BASE + '/t/' + encodeURIComponent(task), { waitUntil: 'networkidle2' })
  await sleep(1500)
  await closePane(p)
  await send(p, L2)
  s = await waitFor(p, (x) => has(x.middle, L2))
  await sleep(2500) /* let the echo and any re-read land before judging */
  s = await snap(p)
  step(tag('2 L2 is in the main column'), has(s.middle, L2), { middle: s.middle.length })
  step(tag('2 L2 is not in the right pane'), !has(s.right, L2), { paneOpen: s.paneOpen })
  const hub = res.apiRoot ? await hubRows(p, res.apiRoot, task) : { status: 0 }
  const h2 = (hub.rows || []).find((r) => r.body.includes(L2))
  step(tag('2 hub stores L2 on the same task with is_parent 0'), !!h2 && h2.is_parent === 0,
    { status: hub.status, is_parent: h2 && h2.is_parent, rows: (hub.rows || []).length })
  await p.screenshot({ path: `${OUT}/t-2-after-L2.png` })

  await p.goto(BASE + pathFor('channel'), { waitUntil: 'networkidle2' })
  await sleep(2500)
  await closePane(p)
  s = await waitFor(p, (x) => cardsFor(x, task).length > 0, 10000)
  const cards3 = cardsFor(s, task)
  step(tag('3 channel: L2 is not in the middle'), !has(s.middle, L2), {})
  step(tag('3 channel: one card for the topic and it reads L1'),
    cards3.length === 1 && cards3[0].text.includes(L1) && !cards3[0].text.includes(L2),
    { cards: cards3.map((c) => c.text.slice(0, 120)) })
  await p.screenshot({ path: `${OUT}/t-3-channel.png` })
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  protocolTimeout: 60000,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--lang=en-GB',
    '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows'],
})
try {
  res.build = await fetch(BASE + '/build.json').then((r) => (r.ok ? r.json() : null)).catch(() => null)
  console.log('build', JSON.stringify(res.build))
  const ctx = await browser.createBrowserContext()
  const p = await signIn(ctx)
  if (process.env.WATCHER !== '0') {
    watcher = await ctx.newPage()
    await watcher.setViewport({ width: 1440, height: 900 })
  }
  for (const surface of SURFACES) {
    if (surface === 'dm' && !PEER) { step('dm: PEER is set', false, { hint: 'PEER=<agent>@<box>' }); continue }
    try {
      if (surface === 't') await topicPageRun(p)
      else await surfaceRun(p, surface)
    } catch (e) {
      step(`${surface}: ran to the end`, false, { error: String(e).slice(0, 300) })
      await p.screenshot({ path: `${OUT}/${surface}-error.png` }).catch(() => {})
    }
  }
} catch (e) {
  step('proof ran', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAIL ${failed} step(s)` : 'PASS all steps', '->', OUT + '/results.json')
process.exit(failed ? 1 : 0)
