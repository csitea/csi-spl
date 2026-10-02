// SPL-964 - a send after selecting a thread message is not lost. Live proof,
// signed in, against a deployed WUI.
//
// Owner 2026-09-26, verbatim: "when being in the topics and a thread msg from
// the topic has been selected last, it does not result in adding a new msg
// when one clicks after that to the omnibox, types the msg and clicks on the
// send".
//
// Per surface (home = Topics, home-channel = a channel topic answered from
// Topics, lobby, channel, t = /t/<task>), n = 1 each:
//   1. pane closed, send L1 -> one new topic
//   2. open that topic on the right, send R1 -> R1 is a reply there
//   3. click R1 in the right pane (selects that message), click into the
//      Omnibox, type R2, click Send -> R2 is stored on the SAME task with
//      is_parent 0 and shows in the right pane; the Omnibox is empty
//   4. the same with the root L1 selected instead of a reply -> R3
//   DROP=1: in 3 and 4 the socket is closed the moment the frame goes out
//      (the frame is pending, as when a long-open tab loses its socket). The
//      send must still land (one automatic resend) - or, if it cannot, the
//      text stays in the Omnibox and an error shows. Never silent.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [TENANT=t1] [CHANNEL=lobby] [SURFACES=home,home-channel,lobby,channel,t] [DROP=1] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/select-reply-send-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || 'lobby'
const DROP = process.env.DROP === '1'
const SURFACES = (process.env.SURFACES || 'home,home-channel,lobby,channel,t').split(',').map((s) => s.trim()).filter(Boolean)
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], surfaces: {}, console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
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
  /* DROP=1: the socket goes away with the frame pending - the one frame whose
     body carries window.__spl964Drop is swallowed and its socket closed, the
     way a long-open tab loses its socket. Injected over CDP, so the deployed
     CSP does not apply. */
  await p.evaluateOnNewDocument(() => {
    const orig = WebSocket.prototype.send
    WebSocket.prototype.send = function (data) {
      const needle = window.__spl964Drop
      if (needle && typeof data === 'string' && data.includes(needle)) {
        window.__spl964Drop = null
        window.__spl964Dropped = (window.__spl964Dropped || 0) + 1
        this.close()
        return
      }
      return orig.call(this, data)
    }
  })
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

/** Open the topic of the middle card for TASK. A DOM click, not a mouse
    click at coordinates: a live list re-sorts on last activity, and a
    coordinate click then lands on whichever card slid under the pointer. */
async function openTopic(p, surface, task) {
  await front(p)
  return p.evaluate((sf, t) => {
    const sel = sf === 'home' ? `.feed-col a.topic-row[data-key="${t}"]` : `.feed-col article.msg[data-task-id="${t}"]`
    const card = document.querySelector(sel)
    if (!card) return false
    const replies = card.querySelector('[data-test=topic-replies]')
    ;(replies || card).click()
    return true
  }, surface, task)
}

function pathFor(surface) {
  switch (surface) {
    case 'channel': return '/channel/' + encodeURIComponent(CHANNEL)
    case 'lobby': return '/lobby'
    case 'home': return '/'
    case 't': return '/channel/' + encodeURIComponent(CHANNEL)
    case 'home-channel': return '/channel/' + encodeURIComponent(CHANNEL)
    default: throw new Error('unknown surface ' + surface)
  }
}

const has = (list, needle) => list.some((m) => m.text.includes(needle))

/** Which task the right pane reads, from the pinia stores (evidence only). */
const PANE_STATE = () => {
  const app = document.querySelector('#__nuxt') && document.querySelector('#__nuxt').__vue_app__
  const pinia = app && app.config.globalProperties.$pinia
  const get = (id) => (pinia && pinia._s.get(id)) || null
  const pane = get('live-pane')
  const topic = get('topic')
  const focus = get('pane-focus')
  return {
    url: location.pathname + location.search,
    paneTask: pane ? pane.taskId : null,
    topicOpen: topic ? topic.open : null,
    topicParent: topic ? topic.parentTaskId : null,
    target: topic ? topic.target : null,
    lastPane: focus ? focus.last : null,
    rightTasks: [...document.querySelectorAll('aside.live-pane article.msg')].map((el) => el.getAttribute('data-task-id')),
  }
}

/** The owner's sequence: click a message in the right pane (that selects the
    row), click into the Omnibox, type, click Send. */
async function selectThenSend(p, needle, text, where = 'aside.live-pane') {
  await front(p)
  const handle = await p.evaluateHandle((n, w) => {
    const pane = document.querySelector(w)
    const born = pane && pane.querySelector('[data-test=born-topics]')
    for (const el of pane ? pane.querySelectorAll('article.msg') : []) {
      if (born && born.contains(el)) continue
      if ((el.innerText || '').includes(n)) return el.querySelector('.msg-meta') || el
    }
    return null
  }, needle, where)
  const el = handle.asElement()
  if (!el) return { selected: false }
  await el.click()
  await sleep(300)
  const selected = await p.evaluate((w) => {
    const a = document.activeElement
    return !!(a && a.closest && a.closest(`${w} article.msg`))
  }, where)
  await p.click('form.composer textarea')
  await p.keyboard.type(text)
  if (DROP) await p.evaluate((t) => { window.__spl964Drop = t }, text)
  await p.click('form.composer [data-testid=send]')
  return { selected }
}

async function surfaceRun(p, surface) {
  const L1 = `${PROBE_MARK} SPL-964 L1 ${surface} ${run}`
  const R1 = `${PROBE_MARK} SPL-964 R1 ${surface} ${run}`
  const R2 = `${PROBE_MARK} SPL-964 R2 ${surface} ${run}`
  const R3 = `${PROBE_MARK} SPL-964 R3 ${surface} ${run}`
  const ev = { L1, R1, R2, R3 }
  res.surfaces[surface] = ev
  const tag = (n) => `${surface}: ${n}`

  await p.goto(BASE + pathFor(surface), { waitUntil: 'networkidle2' })
  await sleep(1500)
  await closePane(p)

  await send(p, L1)
  let s = await waitFor(p, (x) => has(x.middle, L1))
  const l1 = s.middle.filter((m) => m.text.includes(L1))
  const task = l1.length ? l1[0].task : ''
  ev.task = task
  step(tag('1 L1 is a new topic'), !!task, { task })
  if (!task) return

  /* /t/<task>: the topic is the main column, not the right pane */
  const onT = surface === 't'
  /* home-channel: a CHANNEL topic, answered from the Topics page */
  if (surface === 'home-channel') {
    await p.goto(BASE + '/', { waitUntil: 'networkidle2' })
    await sleep(1500)
    await closePane(p)
    surface = 'home'
  }
  const where = onT ? '.feed-col [data-test=topic-root]' : 'aside.live-pane'
  const shown = (x) => (onT ? x.middle : x.right)
  if (onT) {
    await p.goto(BASE + '/t/' + encodeURIComponent(task), { waitUntil: 'networkidle2' })
    await sleep(1500)
    await closePane(p)
    ev.afterOpen = await p.evaluate(PANE_STATE)
  } else {
    const opened = await openTopic(p, surface, task)
    s = await waitFor(p, (x) => x.paneOpen, 10000)
    ev.afterOpen = await p.evaluate(PANE_STATE)
    step(tag('2 the topic opens on the right'), opened && s.paneOpen, ev.afterOpen)
    step(tag('2 it is the topic of L1'), [ev.afterOpen.paneTask, ev.afterOpen.topicParent].includes(task) || (ev.afterOpen.url || '').includes(task), { url: ev.afterOpen.url })
  }
  await sleep(800)
  await send(p, R1)
  s = await waitFor(p, (x) => has(shown(x), R1))
  step(tag('2 R1 is in the topic'), has(shown(s), R1), {})

  for (const [picked, text, n] of [[R1, R2, '3 reply'], [L1, R3, '4 root']]) {
    await sleep(800)
    const r = await selectThenSend(p, picked, text, where)
    step(tag(`${n} selected in the topic`), r.selected, r)
    s = await waitFor(p, (x) => has(shown(x), text), 10000)
    await sleep(1500)
    s = await snap(p)
    step(tag(`${n} selected: the new line shows in the topic`), has(shown(s), text), { shown: shown(s).length })
    if (!onT) step(tag(`${n} selected: the new line is not a middle card`), !has(s.middle, text), {})
    const state = await p.evaluate(PANE_STATE)
    ev[`state ${n}`] = state
    /* the topic the pane shows: the task, or (a message-rooted topic) the L1 msg id */
    const topicTask = onT ? task : ((state.target && state.target.taskId) || state.paneTask || task)
    /* poll: after a dropped socket the resend waits for the reconnect, so the
       row can reach the hub a few seconds after the optimistic card shows */
    let hub = { status: 0 }
    let h
    for (let i = 0; i < 15 && !h; i++) {
      if (i) await sleep(1000)
      hub = res.apiRoot ? await hubRows(p, res.apiRoot, topicTask) : { status: 0 }
      h = (hub.rows || []).find((x) => x.body.includes(text))
    }
    step(tag(`${n} selected: hub stores it on the SAME task with is_parent 0`), !!h && h.is_parent === 0,
      { status: hub.status, is_parent: h && h.is_parent, rows: (hub.rows || []).length })
    const left = await p.evaluate(() => (document.querySelector('form.composer textarea') || {}).value || '')
    const shownError = await p.evaluate(() => !!document.querySelector('[data-test=omnibox-send-error], [data-test=live-pane-error]'))
    /* a stored send empties the box; a failed one keeps the text AND shows an error */
    step(tag(`${n} selected: never silent`), h ? left === '' : (left.includes(text) && shownError), { left: left.slice(0, 80), shownError })
    await p.screenshot({ path: `${OUT}/${surface}-${n.replace(/ /g, '-')}.png` })
  }
  await closePane(p)
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
  for (const surface of SURFACES) {
    try {
      await surfaceRun(p, surface)
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
