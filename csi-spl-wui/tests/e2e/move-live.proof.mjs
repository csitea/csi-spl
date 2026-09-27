// SPL-1024 (specs/045, SC-MV-3) — live proof, signed in, against a deployed
// WUI + hub. The prd `e2e` tenant and the dev test tenant only.
//
// Owner, 2026-09-27: "a starter of a topic should be able to just drag it to a
// different channel, provided he has access to this channel", and "thread
// level msgs / cards should be draggable to a different topic, from the
// right-most panel to the topic in the middle panel".
//
//   1. sign in; refuse to write unless the session AND the page host are TENANT
//   2. seed: two fresh channels A and B (created by this account), topics one
//      and two in A, a reply and a thread line under topic one
//   3. DRAG topic one onto rail channel B: the toast, the hub reads every row
//      of the topic in B with moved_from_channel = A; UNDO brings it home and
//      clears the stamp
//   4. DRAG the reply from the right pane onto topic two's card: the hub reads
//      the reply (and its thread line) under topic two, moved_from_task = one;
//      the reply shows "moved from ..."
//   5. MENU: Move to topic… takes the reply home (stamp cleared); Move to
//      channel… moves topic two to B, and B shows "moved from #A"
//   6. REFUSALS (controls for 3-5): another author's card is not draggable and
//      the hub answers 403 not_allowed; a channel that does not exist is 404
//      unknown_channel; the lobby is 409 lobby. Nothing moved (hub re-read).
//   7. CLEAN: delete both topics and both channels (KEEP=1 keeps them for the
//      screenshots / a DB count)
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> EMAIL=<member>
//   PW_FILE=<0600 file> OUT=<dir> TENANT=<tenant> [KEEP=1]
//   [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/move-live.proof.mjs
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
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = need('TENANT')
const KEEP = process.env.KEEP === '1'
mkdirSync(OUT, { recursive: true })

const RUN = Date.now().toString(36)
const A = `mv-a-${RUN}`
const B = `mv-b-${RUN}`
const MIME = 'application/x-spool-move'

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, channels: [A, B], steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok: Boolean(ok), ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

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
  /* topic-archive-live.proof.mjs's guard: nothing is written unless BOTH the
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
    return { claim: String(s.claims.t || ''), hosts, page, me: String(s.claims.sub || s.claims.hum || '') }
  }), 15000)
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  step('1 the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...where })
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  return p
}

/* One hub call from the page (its cookies). A network blip is retried; an HTTP answer never is. */
const hub = (p, method, path, body) => p.evaluate(async (api, m, pth, b) => {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      const init = { method: m, credentials: 'include' }
      if (b !== undefined) { init.body = JSON.stringify(b); init.headers = { 'Content-Type': 'application/json' } }
      const r = await fetch(api + pth, init)
      let out = null
      try { out = await r.json() } catch { /* 204 */ }
      return { status: r.status, body: out }
    } catch (e) {
      last = e
      await new Promise((res) => setTimeout(res, 2000))
    }
  }
  return { status: 0, body: { error: String(last) } }
}, API, method, path, body)

/** The topic's rows as the hub reads them now: msg_id -> { channel, task, moved fields }. */
async function rowsOf(p, task) {
  const r = await hub(p, 'GET', `/v1/view/topics/${task}?limit=100`)
  const out = {}
  for (const el of (r.body && r.body.messages) || []) {
    const env = el.env || {}
    const inner = env.msg || {}
    out[inner.id || inner.msg_id] = {
      channel: el.channel || env.channel || '', task: el.task_id || inner.task_id || '',
      moved_from_channel: el.moved_from_channel || '', moved_from_task: el.moved_from_task || '', moved_at: el.moved_at || '',
    }
  }
  return { status: r.status, rows: out }
}

const midCard = (id) => `.spool-main article.msg[data-msg-id="${id}"]`
const paneRow = (id) => `aside[data-pane="topic"] article.msg[data-msg-id="${id}"]`
const railRow = (ch) => `#sidebar-panel-channels .nav-row[data-order="${ch}"]`

/* move-by-drag.test.mjs's drag: arm with a press outside the text, then one
   DragEvent sequence (headless Chrome starts no native drag from synthetic
   mouse input). */
function dnd(p, source, target, { peek = '' } = {}) {
  return p.evaluate(async ({ source, target, peek }) => {
    const src = document.querySelector(source)
    const dst = document.querySelector(target)
    if (!src || !dst) return { error: 'missing', src: Boolean(src), dst: Boolean(dst) }
    const meta = src.querySelector('.msg-meta') || src
    const r = meta.getBoundingClientRect()
    meta.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, pointerType: 'mouse', button: 0, isPrimary: true, clientX: r.left + 4, clientY: r.top + 4 }))
    meta.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, cancelable: true, pointerType: 'mouse', button: 0, isPrimary: true }))
    await new Promise((res) => setTimeout(res, 50))
    const draggable = src.getAttribute('draggable')
    const dt = new DataTransfer()
    src.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: dt }))
    await new Promise((res) => setTimeout(res, 50))
    const lit = peek ? [...document.querySelectorAll(peek)].map((e) => e.getAttribute('data-order') || e.getAttribute('data-msg-id')) : []
    dst.dispatchEvent(new DragEvent('dragenter', { bubbles: true, cancelable: true, dataTransfer: dt }))
    const over = new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt })
    dst.dispatchEvent(over)
    await new Promise((res) => setTimeout(res, 30))
    const ev = new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt })
    dst.dispatchEvent(ev)
    if (src.isConnected) src.dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true, dataTransfer: dt }))
    return { draggable, accepted: over.defaultPrevented, dropped: ev.defaultPrevented, lit, types: [...dt.types] }
  }, { source, target, peek })
}

async function openTopic(p, cardId, row) {
  for (let i = 0; i < 4; i++) {
    await sleep(500)
    await p.evaluate((sel) => document.querySelector(sel)?.click(), `${midCard(cardId)} .msg-meta .msg-time`)
    if (await p.waitForSelector(row, { timeout: 6000 }).then(() => true, () => false)) return true
  }
  return false
}
async function openMenu(p, sel) {
  await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), sel)
  await sleep(400)
  return p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
}
const toastText = (p) => p.evaluate(() => document.querySelector('[data-testid=move-toast-text]')?.textContent.trim() || '')
const goto = (p, path) => p.evaluate(async (path) => {
  await document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path)
}, path)

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
let p
let seeded = null
try {
  p = await signIn(browser)

  /* ---- 2. seed -------------------------------------------------------------- */
  seeded = await p.evaluate(async ({ A, B, RUN }) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    const ch = app.config.globalProperties.$pinia._s.get('channel')
    await ch.createChannel(B)
    await ch.createChannel(A)
    await app.config.globalProperties.$router.push('/channel/' + A)
    await new Promise((r) => setTimeout(r, 1500))
    const one = await ch.send(`SPL-1024 proof ${RUN}: topic one`, undefined, undefined, undefined, 1)
    await new Promise((r) => setTimeout(r, 300))
    const two = await ch.send(`SPL-1024 proof ${RUN}: topic two`, undefined, undefined, undefined, 1)
    const reply = await ch.send(`SPL-1024 proof ${RUN}: a reply on one`, one.task_id, undefined, undefined, 0)
    return {
      one: { msg_id: one.msg_id, task_id: one.task_id }, two: { msg_id: two.msg_id, task_id: two.task_id },
      reply: { msg_id: reply.msg_id },
    }
  }, { A, B, RUN })
  writeFileSync(`${OUT}/ids.json`, JSON.stringify({ A, B, ...seeded }, null, 2))
  const s0 = await rowsOf(p, seeded.one.task_id)
  step('2 seeded: channels A and B, topics one and two in A, a reply under one', s0.status === 200 &&
    s0.rows[seeded.one.msg_id]?.channel === A && s0.rows[seeded.reply.msg_id]?.channel === A, { A, B, ...seeded })
  await p.waitForSelector(midCard(seeded.one.msg_id), { timeout: 20000 }).catch(() => {})
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await sleep(800)
  await shot(p, '2-seeded')

  /* ---- 3. topic drag onto rail channel B, then Undo ------------------------- */
  const drag = await dnd(p, midCard(seeded.one.msg_id), railRow(B), { peek: '#sidebar-panel-channels .nav-row[data-move-target="true"]' })
  step('3 the card is armed, carries the move type, and B takes the drop', drag.draggable === 'true' && drag.types.includes(MIME) && drag.accepted && drag.dropped, drag)
  step('3 A (its own channel) and #lobby do not light up, B does', drag.lit.includes(B) && !drag.lit.includes(A) && !drag.lit.includes('lobby'), { lit: drag.lit })
  await p.waitForSelector('[data-testid=move-toast]', { timeout: 10000 }).catch(() => {})
  const t3 = await toastText(p)
  step('3 the toast says "Moved to #B" and offers Undo', t3 === `Moved to #${B}` && Boolean(await p.$('[data-testid=move-toast-undo]')), { toast: t3 })
  const s3 = await until(async () => { const r = await rowsOf(p, seeded.one.task_id); return Object.values(r.rows).every((x) => x.channel === B) && r }, 15000)
  step('3 the hub reads every row of topic one in B, home A recorded', !!s3 && Object.values(s3.rows).length >= 2 &&
    Object.values(s3.rows).every((x) => x.channel === B && x.moved_from_channel === A && x.moved_at), s3 && s3.rows)
  await shot(p, '3-topic-dragged-to-B')
  await p.click('[data-testid=move-toast-undo]').catch(() => {})
  const s3u = await until(async () => { const r = await rowsOf(p, seeded.one.task_id); return Object.values(r.rows).every((x) => x.channel === A && !x.moved_at) && r }, 15000)
  step('3 Undo: topic one is home in A, the stamp cleared on every row', !!s3u, s3u && s3u.rows)
  const back = await until(() => p.$(midCard(seeded.one.msg_id)), 15000)
  step('3 ... and its card is back in the A feed', Boolean(back))

  /* ---- 4. reply drag from the right pane onto topic two's card -------------- */
  const opened = await openTopic(p, seeded.one.msg_id, paneRow(seeded.reply.msg_id))
  step('4 topic one opens on the right with the reply', opened)
  const rdrag = await dnd(p, paneRow(seeded.reply.msg_id), midCard(seeded.two.msg_id), { peek: '.spool-main article.msg[data-move-target="true"]' })
  step('4 the reply is armed and topic two\'s card takes the drop; topic one\'s card is no target',
    rdrag.draggable === 'true' && rdrag.accepted && rdrag.dropped && rdrag.lit.includes(seeded.two.msg_id) && !rdrag.lit.includes(seeded.one.msg_id), rdrag)
  const s4 = await until(async () => { const r = await rowsOf(p, seeded.two.task_id); return r.rows[seeded.reply.msg_id] && r }, 15000)
  step('4 the hub reads the reply under topic two, home topic one recorded',
    !!s4 && s4.rows[seeded.reply.msg_id].moved_from_task === seeded.one.task_id && s4.rows[seeded.reply.msg_id].task === seeded.two.task_id, s4 && s4.rows[seeded.reply.msg_id])
  const s4o = await rowsOf(p, seeded.one.task_id)
  step('4 ... and topic one no longer holds it', !s4o.rows[seeded.reply.msg_id], { rows: Object.keys(s4o.rows).length })
  await openTopic(p, seeded.two.msg_id, paneRow(seeded.reply.msg_id))
  const note = await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-moved]`)?.textContent.trim() || '', paneRow(seeded.reply.msg_id))
  step('4 in topic two the reply says "moved from ..."', /moved from/.test(note), { note })
  await shot(p, '4-reply-dragged-to-topic-two')

  /* ---- 5. the menu path (keyboard + touch) ---------------------------------- */
  const rmenu = await openMenu(p, paneRow(seeded.reply.msg_id))
  step('5 the reply\'s menu offers Move to topic…', rmenu.includes('msg-menu-move-topic'), { rmenu })
  await p.click('[data-testid=msg-menu-move-topic]')
  await p.waitForSelector('[data-testid=move-picker-topic] [data-testid=move-picker-row]', { timeout: 10000 }).catch(() => {})
  await shot(p, '5-topic-picker')
  await p.keyboard.type('topic one')
  await p.keyboard.press('Enter')
  const s5 = await until(async () => { const r = await rowsOf(p, seeded.one.task_id); return r.rows[seeded.reply.msg_id] && !r.rows[seeded.reply.msg_id].moved_at && r }, 15000)
  step('5 Move to topic… takes the reply home to topic one, the stamp cleared', !!s5, s5 && s5.rows[seeded.reply.msg_id])
  await goto(p, '/channel/' + A)
  await p.waitForSelector(midCard(seeded.two.msg_id), { timeout: 15000 }).catch(() => {})
  const cmenu = await openMenu(p, midCard(seeded.two.msg_id))
  step('5 an own card\'s menu offers Move to channel…', cmenu.includes('msg-menu-move-channel'), { cmenu })
  await p.click('[data-testid=msg-menu-move-channel]')
  await p.waitForSelector('[data-testid=move-picker-channel] [data-testid=move-picker-row]', { timeout: 10000 }).catch(() => {})
  const choices = await p.evaluate(() => [...document.querySelectorAll('[data-testid=move-picker-row]')].map((e) => e.getAttribute('data-target')))
  step('5 the channel picker lists B, not A, not #lobby', choices.includes(B) && !choices.includes(A) && !choices.includes('lobby'), { choices })
  await shot(p, '5-channel-picker')
  await p.keyboard.type(B)
  await p.keyboard.press('Enter')
  const s5c = await until(async () => { const r = await rowsOf(p, seeded.two.task_id); return r.rows[seeded.two.msg_id]?.channel === B && r }, 15000)
  step('5 Move to channel… moves topic two to B', !!s5c, s5c && s5c.rows[seeded.two.msg_id])
  await goto(p, '/channel/' + B)
  await p.waitForSelector(midCard(seeded.two.msg_id), { timeout: 15000 }).catch(() => {})
  await sleep(800)
  const cardNote = await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-moved]`)?.textContent.trim() || '', midCard(seeded.two.msg_id))
  step('5 B shows topic two with "moved from #A"', cardNote === `moved from #${A}`, { cardNote })
  await shot(p, '5-topic-two-in-B-moved-from-A')

  /* ---- 6. refusals (controls) ----------------------------------------------- */
  const me = await p.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia.state.value.viewer
    return s && s.me ? String(s.me.id || '') : ''
  })
  const chans = await hub(p, 'GET', '/v1/view/channels')
  let other = null
  for (const c of ((chans.body && chans.body.channels) || []).map((x) => x.channel_id || x.channel).filter((c) => c && !['lobby', 'general', 'issues', A, B].includes(c))) {
    const t = await hub(p, 'GET', `/v1/view/topics?channel=${encodeURIComponent(c)}&per_topic=1&limit=20`)
    for (const row of (t.body && t.body.topics) || []) {
      const el = (row.messages || [])[0]
      const inner = (el && el.env && el.env.msg) || {}
      if (el && el.is_parent === 1 && inner.from && inner.from !== me) { other = { msg_id: inner.id || inner.msg_id, channel: c, from: inner.from }; break }
    }
    if (other) break
  }
  if (other) {
    const r = await hub(p, 'POST', `/v1/messages/${other.msg_id}/move`, { to_channel: B })
    step('6 another author\'s card: the hub refuses the move, 403 not_allowed', r.status === 403 && r.body?.error === 'not_allowed', { other, status: r.status, error: r.body?.error })
  } else {
    step('6 another author\'s card: none readable in this tenant (skipped, not a pass)', false, { me })
  }
  const nope = await hub(p, 'POST', `/v1/messages/${seeded.one.msg_id}/move`, { to_channel: `no-such-${RUN}` })
  step('6 a channel that does not exist: 404 unknown_channel', nope.status === 404 && nope.body?.error === 'unknown_channel', { status: nope.status, error: nope.body?.error })
  const lob = await hub(p, 'POST', `/v1/messages/${seeded.one.msg_id}/move`, { to_channel: 'lobby' })
  step('6 the lobby: 409 lobby', lob.status === 409 && lob.body?.error === 'lobby', { status: lob.status, error: lob.body?.error })
  const s6 = await rowsOf(p, seeded.one.task_id)
  step('6 the refusals moved nothing (topic one still home in A)', Object.values(s6.rows).every((x) => x.channel === A && !x.moved_at), s6.rows)
  step('no page errors', !res.console.some((c) => c.startsWith('pageerror')), { n: res.console.length })
} catch (e) {
  step('the run completed', false, { error: String(e).slice(0, 300) })
} finally {
  /* ---- 7. clean -------------------------------------------------------------- */
  if (p && seeded && !KEEP) {
    for (const card of [seeded.one.msg_id, seeded.two.msg_id]) {
      const r = await hub(p, 'DELETE', `/v1/messages/${card}/topic`).catch(() => ({ status: 0 }))
      console.log('clean topic', card, r.status)
    }
    for (const ch of [A, B]) {
      const r = await hub(p, 'DELETE', `/v1/channels/${ch}`).catch(() => ({ status: 0 }))
      console.log('clean channel', ch, r.status)
    }
  }
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(`\nmove-live: ${res.steps.length - failed}/${res.steps.length} passed`)
process.exit(failed ? 1 : 0)
