// SPL-983 (specs/041) — live proof, signed in, against a deployed WUI + hub.
//
// Owner, 2026-09-26: "archive and delete a topic or msg in direct msgs (aka
// card with is_parent=1), which if archived will add a soft delete = 1 and
// if delete will actually delete not only the parent msg or topic but also
// all of its children".
//
// PHASE=a (n = 1 per run):
//   1. sign in; refuse to write unless the session AND the page host are TENANT
//   2. create a #lobby-channel topic over the browser socket: the card, three
//      replies (is_parent 0) and a thread opened on reply 1 - four children
//   3. the card's menu (right click) shows Archive then Delete, the archive
//      glyph left of the label
//   4. Archive -> the card leaves /channel/lobby; the hub list leaves it out;
//      GET /v1/view/archived has it, with 4 replies
//   5. /archive lists it; Unarchive -> gone from /archive, back in the list
//   ids -> $OUT/ids.json (the DB count is taken between the phases)
// PHASE=b:
//   6. the card's Delete opens the dialog, which names 4 replies; confirm ->
//      the card leaves the feed and the hub answers 404 for the topic
// PHASE=clean IDS=<ids.json>: delete an interrupted run's topic (archived or not)
//
// SPL-986 (spec 041 §3.5): the same menu on a ROW of the left-rail Topics
// section. The same topic shape as PHASE=a, created the same way.
// PHASE=rail-a:
//   R2. create the topic (card + 3 replies + a thread on reply 1)
//   R3. the Topics section: a right-click on the topic's row opens its menu,
//       which (after the hub's answer) ends with Archive then Delete, icon left
//   R4. Archive -> the row leaves the Topics section and the Topics home; the
//       hub list leaves it out; GET /v1/view/archived has it with 4 replies
//   R5. /archive: Unarchive -> the row is back in the Topics section
// PHASE=rail-b:
//   R6. the row's ⋯ button -> Delete -> the dialog names 4 replies; confirm ->
//       the row leaves the Topics section and the hub answers 404 for the topic
//
//   BASE=https://dev.<domain> (prd: https://<tenant>.<domain>) API=https://dev.api.<domain>
//   EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> TENANT=<tenant> PHASE=a|b|clean
//   [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/topic-archive-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { randomUUID } from 'node:crypto'

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
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = need('TENANT')
const PHASE = need('PHASE')
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, phase: PHASE, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${PHASE}-${name}.png` }).catch(() => {}) }

async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

async function until(fn, ms = 15000) {
  const end = Date.now() + ms
  let v
  while (Date.now() < end) {
    v = await fn()
    if (v) return v
    await sleep(300)
  }
  return v
}

async function signIn(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('1 native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  /* issues-live.proof.mjs's guard: nothing is written unless BOTH the
     session's tenant (claim t) and the tenant the page writes to are TENANT. */
  const where = await until(() => p.evaluate(() => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const g = app && app.config.globalProperties
    const s = g && g.$pinia && g.$pinia.state.value.session
    const pub = (g && g.$config && g.$config.public) || null
    if (!pub || !s || !s.claims) return null
    const hosts = String(pub.tenantHosts || '0') === '1'
    let page = ''
    if (hosts) {
      const site = new URL(String(pub.siteUrl || location.origin)).hostname.toLowerCase()
      const h = location.hostname.toLowerCase()
      page = h === site ? String(pub.tenant || '') : h.endsWith('.' + site) ? h.slice(0, -site.length - 1) : '?'
    }
    return { claim: String(s.claims.t || ''), hosts, page }
  }), 15000)
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  step('1 the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...where })
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  return p
}

/* A read the box's docker network churn killed (TypeError: Failed to fetch,
   measured on the first dev run) is retried; an HTTP answer never is. */
const hub = (p, method, path) => p.evaluate(async (api, m, pth) => {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      const r = await fetch(api + pth, { method: m, credentials: 'include' })
      let body = null
      try { body = await r.json() } catch { /* 204 */ }
      return { status: r.status, body }
    } catch (e) {
      last = e
      await new Promise((res) => setTimeout(res, 2000))
    }
  }
  return { status: 0, body: { error: String(last) } }
}, API, method, path)

/** Sends frames over a fresh browser socket (the page's cookies): the WUI's own wire. */
const sendAll = (p, frames) => p.evaluate(async (api, fs) => {
  const ws = new WebSocket(api.replace(/^http/, 'ws') + '/v1/wui/ws')
  const acks = {}
  await new Promise((ok, bad) => {
    const t = setTimeout(() => bad(new Error('no welcome')), 15000)
    ws.onopen = () => ws.send(JSON.stringify({ type: 'hello' }))
    ws.onmessage = (ev) => {
      const f = JSON.parse(ev.data)
      if (f.type === 'welcome') { clearTimeout(t); ok() }
      if (f.type === 'ack') acks[f.msg_id] = true
      if (f.type === 'error') acks['error:' + (f.msg_id || '')] = f
    }
  })
  for (const f of fs) {
    ws.send(JSON.stringify({ type: 'send', kind: 'note', files: [], ...f }))
    const end = Date.now() + 15000
    while (!acks[f.msg_id] && Date.now() < end) await new Promise((r) => setTimeout(r, 100))
  }
  ws.close()
  return acks
}, API, frames)

const cardSel = (id) => `[data-key="${id}"]`

async function openMenu(p, id) {
  await p.waitForSelector(cardSel(id), { visible: true, timeout: 20000 })
  const el = await p.$(cardSel(id))
  const box = await el.boundingBox()
  await p.mouse.click(box.x + 40, box.y + 12, { button: 'right' })
  await p.waitForSelector('[data-testid=msg-menu]', { visible: true, timeout: 5000 })
}

/* SPL-986: the rail's Topics section and one row of it */
const railRow = (task) => `#sidebar-panel-topics .nav-row[data-order="${task}"]`
async function openTopicsSection(p, task) {
  await nav(p, BASE + '/')
  await p.waitForSelector('[data-testid=sidebar-tab-topics]', { visible: true, timeout: 30000 })
  await p.click('[data-testid=sidebar-tab-topics]')
  return p.waitForSelector(railRow(task), { visible: true, timeout: 30000 }).then(() => true, () => false)
}
async function railMenuItems(p, task) {
  const panel = `[data-testid=sidebar-row-menu-panel][id="sidebar-row-menu-th-${task}"]`
  await p.waitForSelector(`${panel}[data-topic-state="ready"], ${panel}[data-topic-state="none"]`, { visible: true, timeout: 20000 })
  return p.$$eval(`${panel} [role=menuitem]`, (els) => els.map((e) => ({
    id: e.getAttribute('data-testid'), icon: !!e.querySelector('svg'), first: e.firstElementChild && e.firstElementChild.tagName.toLowerCase(),
  })))
}
async function makeTopic(p, label) {
  const T = randomUUID()
  const card = randomUUID()
  const replies = [randomUUID(), randomUUID(), randomUUID()]
  const thread = randomUUID()
  const tag = `${label} proof ${Date.now().toString(36)}`
  const acks = await sendAll(p, [
    { msg_id: card, task_id: T, channel: 'lobby', body: `${tag}: the card`, is_parent: 1 },
    ...replies.map((id, i) => ({ msg_id: id, task_id: T, channel: 'lobby', body: `${tag}: reply ${i + 1}`, is_parent: 0 })),
    { msg_id: thread, task_id: replies[0], parent_task_id: T, channel: 'lobby', body: `${tag}: a thread on reply 1`, is_parent: 0 },
  ])
  const all = [card, ...replies, thread]
  return { T, card, replies, thread, all, acked: all.every((id) => acks[id]), n: Object.keys(acks).length }
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
try {
  const p = await signIn(browser)
  if (PHASE === 'a') {
    // 2. the topic: card + 3 replies + a thread on reply 1
    const T = randomUUID()
    const card = randomUUID()
    const replies = [randomUUID(), randomUUID(), randomUUID()]
    const thread = randomUUID()
    const tag = `SPL-983 proof ${Date.now().toString(36)}`
    const acks = await sendAll(p, [
      { msg_id: card, task_id: T, channel: 'lobby', body: `${tag}: the card`, is_parent: 1 },
      ...replies.map((id, i) => ({ msg_id: id, task_id: T, channel: 'lobby', body: `${tag}: reply ${i + 1}`, is_parent: 0 })),
      { msg_id: thread, task_id: replies[0], parent_task_id: T, channel: 'lobby', body: `${tag}: a thread on reply 1`, is_parent: 0 },
    ])
    const all = [card, ...replies, thread]
    step('2 the card, three replies and a thread on reply 1 are stored (acked)', all.every((id) => acks[id]), { acks: Object.keys(acks).length })
    writeFileSync(`${OUT}/ids.json`, JSON.stringify({ task: T, card, children: [...replies, thread], all }, null, 2))

    // 3. the menu
    await nav(p, BASE + '/channel/lobby')
    await openMenu(p, card)
    const items = await p.$$eval('[data-testid=msg-menu] [role=menuitem]', (els) => els.map((e) => ({
      id: e.getAttribute('data-testid'), icon: !!e.querySelector('svg'), first: e.firstElementChild && e.firstElementChild.tagName.toLowerCase(),
    })))
    const ids = items.map((i) => i.id)
    const tail = ids.slice(-2)
    step('3 the card menu ends with Archive then Delete, the icon left of each label', JSON.stringify(tail) === JSON.stringify(['msg-menu-archive', 'msg-menu-delete-topic']) &&
      items.slice(-2).every((i) => i.icon && i.first === 'svg'), { ids })
    await shot(p, '03-menu')

    // 4. archive
    await p.click('[data-testid=msg-menu-archive]')
    const gone = await until(() => p.$(cardSel(card)).then((h) => !h), 10000)
    const list = await hub(p, 'GET', '/v1/view/topics?channel=lobby&limit=100')
    const listed = (list.body?.topics || []).some((t) => t.task_id === T)
    const arch = await hub(p, 'GET', '/v1/view/archived')
    const row = (arch.body?.cards || []).find((c) => c.msg_id === card)
    step('4 Archive: the card leaves the feed, the hub list leaves the topic out, the Archive read has it with 4 replies',
      gone && !listed && !!row && row.replies === 4, { gone, listed, archived: !!row, replies: row && row.replies, archived_by: row && row.archived_by })
    const size = await hub(p, 'GET', `/v1/view/messages/${card}/topic`)
    step('4 the archived topic is still readable by its id', size.status === 200 && size.body?.archived === true, { status: size.status, archived: size.body?.archived })
    await shot(p, '04-archived')

    // 5. the Archive page + Unarchive
    await nav(p, BASE + '/archive')
    const onPage = await p.waitForSelector(`[data-test=archive-row][data-msg-id="${card}"]`, { visible: true, timeout: 20000 }).then(() => true, () => false)
    step('5 /archive lists the card', onPage)
    await shot(p, '05-archive-page')
    await p.click(`[data-test=archive-row][data-msg-id="${card}"] [data-test=archive-unarchive]`)
    const left = await until(() => p.$(`[data-test=archive-row][data-msg-id="${card}"]`).then((h) => !h), 10000)
    const back = await hub(p, 'GET', '/v1/view/topics?channel=lobby&limit=100')
    step('5 Unarchive: the row leaves /archive and the topic is back in the list', left && (back.body?.topics || []).some((t) => t.task_id === T), { left })
  } else if (PHASE === 'b') {
    const ids = JSON.parse(readFileSync(`${OUT}/ids.json`, 'utf8'))
    await nav(p, BASE + '/channel/lobby')
    await openMenu(p, ids.card)
    await p.click('[data-testid=msg-menu-delete-topic]')
    await p.waitForSelector('[data-testid=topic-delete-count][data-replies="4"]', { visible: true, timeout: 15000 }).then(() => true, () => false)
    const count = await p.$eval('[data-testid=topic-delete-count]', (e) => ({ n: e.getAttribute('data-replies'), text: e.textContent.trim() })).catch(() => null)
    step('6 Delete opens the dialog, which names the 4 replies first', !!count && count.n === '4', count || {})
    await shot(p, '06-dialog')
    await p.click('[data-testid=topic-delete-confirm]')
    const gone = await until(() => p.$(cardSel(ids.card)).then((h) => !h), 15000)
    const after = await hub(p, 'GET', `/v1/view/messages/${ids.card}/topic`)
    const topic = await hub(p, 'GET', `/v1/view/topics/${ids.task}`)
    step('6 confirm: the card leaves the feed; the hub has neither the card nor its topic', gone && after.status === 404 && topic.status === 404,
      { gone, card: after.status, topic: topic.status })
    await shot(p, '06-deleted')
  } else if (PHASE === 'rail-a') {
    const tp = await makeTopic(p, 'SPL-986')
    step('R2 the card, three replies and a thread on reply 1 are stored (acked)', tp.acked, { acks: tp.n })
    writeFileSync(`${OUT}/ids.json`, JSON.stringify({ task: tp.T, card: tp.card, children: [...tp.replies, tp.thread], all: tp.all }, null, 2))

    const shown = await openTopicsSection(p, tp.T)
    step('R3 the topic is a row of the left-rail Topics section', shown)
    const row = await p.$(railRow(tp.T))
    const box = await row.boundingBox()
    await p.mouse.click(box.x + 30, box.y + box.height / 2, { button: 'right' })
    const items = await railMenuItems(p, tp.T)
    const ids = items.map((i) => i.id)
    step('R3 right-click on the row: its menu ends with Archive then Delete, the icon left of each label',
      JSON.stringify(ids.slice(-2)) === JSON.stringify(['sidebar-row-menu-archive', 'sidebar-row-menu-delete-topic']) &&
      items.slice(-2).every((i) => i.icon && i.first === 'svg'), { ids })
    await shot(p, 'R03-rail-menu')

    await p.click(`#sidebar-row-menu-th-${tp.T} [data-testid=sidebar-row-menu-archive]`)
    const gone = await until(() => p.$(railRow(tp.T)).then((h) => !h), 10000)
    const home = await p.$(`.feed-col a.topic-row[data-key="${tp.T}"]`).then((h) => !h)
    const list = await hub(p, 'GET', '/v1/view/topics?limit=100')
    const listed = (list.body?.topics || []).some((t) => t.task_id === tp.T)
    const arch = await hub(p, 'GET', '/v1/view/archived')
    const card = (arch.body?.cards || []).find((c) => c.msg_id === tp.card)
    step('R4 Archive: the row leaves the Topics section and the Topics home, the hub list leaves it out, the Archive read has it with 4 replies',
      gone && home && !listed && !!card && card.replies === 4, { gone, home_gone: home, listed, archived: !!card, replies: card && card.replies })
    await shot(p, 'R04-archived')

    await nav(p, BASE + '/archive')
    const onPage = await p.waitForSelector(`[data-test=archive-row][data-msg-id="${tp.card}"]`, { visible: true, timeout: 20000 }).then(() => true, () => false)
    if (onPage) await p.click(`[data-test=archive-row][data-msg-id="${tp.card}"] [data-test=archive-unarchive]`)
    const left = onPage && await until(() => p.$(`[data-test=archive-row][data-msg-id="${tp.card}"]`).then((h) => !h), 10000)
    const back = await openTopicsSection(p, tp.T)
    step('R5 /archive Unarchive: the row is back in the Topics section', !!left && back, { on_page: onPage, left, back })
  } else if (PHASE === 'rail-b') {
    const ids = JSON.parse(readFileSync(`${OUT}/ids.json`, 'utf8'))
    const shown = await openTopicsSection(p, ids.task)
    await p.click(`#sidebar-panel-topics [data-testid=sidebar-row-menu][data-menu-id="th:${ids.task}"]`)
    const items = await railMenuItems(p, ids.task)
    step('R6 the row\'s button opens the same menu, Delete last', shown && items.at(-1)?.id === 'sidebar-row-menu-delete-topic', { ids: items.map((i) => i.id) })
    await p.click(`#sidebar-row-menu-th-${ids.task} [data-testid=sidebar-row-menu-delete-topic]`)
    await p.waitForSelector('[data-testid=topic-delete-count][data-replies="4"]', { visible: true, timeout: 15000 }).catch(() => {})
    const count = await p.$eval('[data-testid=topic-delete-count]', (e) => ({ n: e.getAttribute('data-replies'), text: e.textContent.trim() })).catch(() => null)
    step('R6 Delete opens the dialog, which names the 4 replies first', !!count && count.n === '4', count || {})
    await shot(p, 'R06-dialog')
    await p.click('[data-testid=topic-delete-confirm]')
    const gone = await until(() => p.$(railRow(ids.task)).then((h) => !h), 15000)
    const after = await hub(p, 'GET', `/v1/view/messages/${ids.card}/topic`)
    const topic = await hub(p, 'GET', `/v1/view/topics/${ids.task}`)
    step('R6 confirm: the row leaves the Topics section; the hub has neither the card nor its topic', gone && after.status === 404 && topic.status === 404,
      { gone, card: after.status, topic: topic.status })
    await shot(p, 'R06-deleted')
  } else if (PHASE === 'clean') {
    // an interrupted run's topic (IDS=<its ids.json>): delete it through the hub
    const ids = JSON.parse(readFileSync(process.env.IDS || `${OUT}/ids.json`, 'utf8'))
    const del = await hub(p, 'DELETE', `/v1/messages/${ids.card}/topic`)
    step('clean: the proof topic is deleted', del.status === 200 || del.status === 404, { status: del.status, deleted: del.body?.deleted })
  }
} catch (e) {
  step('run', false, { error: String(e).slice(0, 400) })
} finally {
  res.failed = failed
  writeFileSync(`${OUT}/result-${PHASE}.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
process.exit(failed ? 1 : 0)
