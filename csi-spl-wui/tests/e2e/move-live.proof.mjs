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
// Proof channels must not wake the fallback responder (SPL-997), and that
// switch is a DB action, so a run is two invocations with the switch between:
//   PHASE=channels  sign in, create A and B, print their ids, exit
//   (shell)         for ch in A B: ENV=<env> TENANT_ID=<t> CHANNEL=$ch NO_FALLBACK=1
//                   DRY_RUN=0 ./run -a do_spl_channel_fallback   (csi-spl-orc)
//   PHASE=run CH_A=<A> CH_B=<B>   steps 2..7 in those channels
//   PHASE=restore MSG=<msg_id> TO=<channel>   move one topic card back (repair)
//   PHASE=clean IDS=<OUT of a KEEP=1 run>/ids.json   delete its topics and channels
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> EMAIL=<member>
//   PW_FILE=<0600 file> OUT=<dir> TENANT=<tenant> PHASE=channels|run|restore
//   [CH_A=... CH_B=...] [KEEP=1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//   node tests/e2e/move-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = need('TENANT')
const KEEP = process.env.KEEP === '1'
const PHASE = process.env.PHASE || 'run'
mkdirSync(OUT, { recursive: true })

const RUN = Date.now().toString(36)
const A = process.env.CH_A || `mv-a-${RUN}`
const B = process.env.CH_B || `mv-b-${RUN}`
if (PHASE === 'run' && (!process.env.CH_A || !process.env.CH_B)) {
  console.error('FATAL PHASE=run needs CH_A and CH_B from PHASE=channels (with the fallback switched off in between)')
  process.exit(2)
}

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, channels: [A, B], steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok: Boolean(ok), ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
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

/* SPL-1134: move-by-drag.test.mjs's drag - a REAL mouse drag. Press at
   `from` (the handle strip, or the card body for the control), walk through
   `via` (sampling what is lit at each point), release at the last point. */
const centreOf = (p, sel) => p.evaluate((sel) => {
  const e = document.querySelector(sel)
  if (!e) return null
  const r = e.getBoundingClientRect()
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 }
}, sel)
const litNow = (p) => p.evaluate(() => ({
  lit: [...document.querySelectorAll('.nav-row--move-over, article.msg.msg--move-over')].map((e) => e.getAttribute('data-order') || e.getAttribute('data-msg-id')),
  denied: [...document.querySelectorAll('.nav-row--move-denied')].map((e) => e.getAttribute('data-order')),
  ghost: document.querySelector('[data-testid=move-ghost]')?.textContent || null,
}))
async function mouseDrag(p, from, via, name = '') {
  await p.mouse.move(from.x, from.y)
  await p.mouse.down()
  const seen = []
  for (const pt of via.filter(Boolean)) {
    await p.mouse.move(pt.x, pt.y, { steps: 10 })
    await sleep(120)
    seen.push(await litNow(p))
  }
  if (name) await shot(p, name)
  await p.mouse.up()
  await sleep(300)
  return seen
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
  /* the menu mounts lazily: wait for its items (a fixed sleep read [] now and then), click again once */
  const items = () => p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => e.getAttribute('data-testid')))
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
  const meBody = (await hub(p, 'GET', '/v1/view/me')).body || {}
  const me = String(meBody.human_id || '')
  /* spec 045 §3.4: an owner or admin MAY move anyone's card, so the
     "another author's card is refused" control only means something for a
     plain member (the dev test member; the prd e2e account owns its tenant) */
  const mayAll = meBody.tenant_owner === true || meBody.role === 'admin' || meBody.role === 'biz_owner'
  step('1 the hub names the signed-in member', /^HUM-[0-9]+$/.test(me), { me, role: meBody.role, tenant_owner: meBody.tenant_owner })
  if (!me) throw new Error('no member id: refusing to judge authorship')

  if (PHASE === 'channels') {
    await p.evaluate(async ({ A, B }) => {
      const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
      await ch.createChannel(A)
      await ch.createChannel(B)
    }, { A, B })
    const list = await hub(p, 'GET', '/v1/view/channels')
    const ids = ((list.body && list.body.channels) || []).map((c) => c.channel_id || c.channel)
    step('channels: A and B exist', ids.includes(A) && ids.includes(B), { A, B })
    writeFileSync(`${OUT}/channels.json`, JSON.stringify({ A, B }))
    console.log(`CH_A=${A} CH_B=${B}`)
    throw new Error('__phase_done__')
  }
  if (PHASE === 'clean') { /* a KEEP=1 run's topics and channels, from its ids.json */
    const ids = JSON.parse(readFileSync(need('IDS'), 'utf8'))
    for (const card of [ids.one && ids.one.msg_id, ids.two && ids.two.msg_id].filter(Boolean)) {
      const r = await hub(p, 'DELETE', `/v1/messages/${card}/topic`)
      step(`clean: topic ${card.slice(0, 8)} deleted`, r.status === 200 || r.status === 404, { status: r.status })
    }
    for (const ch of [ids.A, ids.B].filter(Boolean)) {
      const r = await hub(p, 'DELETE', `/v1/channels/${ch}`)
      step(`clean: channel ${ch} deleted`, r.status === 204 || r.status === 200 || r.status === 404, { status: r.status })
    }
    throw new Error('__phase_done__')
  }
  if (PHASE === 'restore') {
    const r = await hub(p, 'POST', `/v1/messages/${need('MSG')}/move`, { to_channel: need('TO') })
    step('restore: the card is back', r.status === 200, { status: r.status, body: r.body })
    throw new Error('__phase_done__')
  }

  /* ---- 2. seed -------------------------------------------------------------- */
  seeded = await p.evaluate(async ({ A, RUN }) => {
    const app = document.querySelector('#__nuxt').__vue_app__
    const ch = app.config.globalProperties.$pinia._s.get('channel')
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
  }, { A, RUN })
  writeFileSync(`${OUT}/ids.json`, JSON.stringify({ A, B, ...seeded }, null, 2))
  const s0 = await rowsOf(p, seeded.one.task_id)
  step('2 seeded: channels A and B, topics one and two in A, a reply under one', s0.status === 200 &&
    s0.rows[seeded.one.msg_id]?.channel === A && s0.rows[seeded.reply.msg_id]?.channel === A, { A, B, ...seeded })
  await p.waitForSelector(midCard(seeded.one.msg_id), { timeout: 20000 }).catch(() => {})
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
  await sleep(800)
  await shot(p, '2-seeded')

  /* ---- 3. topic drag onto rail channel B, then Undo ------------------------- */
  /* SPL-1134 control: a drag from the card BODY moves nothing */
  const bodyPt = await centreOf(p, `${midCard(seeded.one.msg_id)} .msg-body`)
  const bodyDrag = await mouseDrag(p, bodyPt, [await centreOf(p, railRow(B))])
  await p.evaluate(() => window.getSelection()?.removeAllRanges())
  const s3b = await rowsOf(p, seeded.one.task_id)
  step('3 a drag from the card body lights nothing and moves nothing (control)', bodyDrag.every((x) => x.lit.length === 0 && !x.ghost) &&
    Object.values(s3b.rows).every((x) => x.channel === A), { bodyDrag })
  /* the handle drag: A (its own), the lobby, then B - one row lit at most, B the drop */
  const handlePt = await centreOf(p, `${midCard(seeded.one.msg_id)} [data-testid=move-handle]`)
  const walk = await mouseDrag(p, handlePt, [await centreOf(p, railRow(A)), await centreOf(p, railRow('lobby')), await centreOf(p, railRow(B))], '3-dragging-one-channel-lit')
  const atB = walk[walk.length - 1]
  step('3 from the handle: at most ONE row lit at every step; A and #lobby never lit (say not allowed); B lit under the pointer',
    Boolean(handlePt) && walk.every((x) => x.lit.length <= 1) && walk.slice(0, -1).every((x) => x.lit.length === 0 && x.denied.length === 1) &&
    atB.lit.length === 1 && atB.lit[0] === B && /./.test(atB.ghost || ''), { walk })
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
  const rFrom = await centreOf(p, `${paneRow(seeded.reply.msg_id)} [data-testid=move-handle]`)
  const rdrag = await mouseDrag(p, rFrom, [await centreOf(p, midCard(seeded.one.msg_id)), await centreOf(p, midCard(seeded.two.msg_id))], '4-dragging-one-card-lit')
  step('4 from the reply\'s handle: topic one\'s card is never lit, topic two\'s is the one lit card and takes the drop',
    Boolean(rFrom) && rdrag[0].lit.length === 0 && rdrag[1].lit.length === 1 && rdrag[1].lit[0] === seeded.two.msg_id, rdrag)
  const s4 = await until(async () => { const r = await rowsOf(p, seeded.two.task_id); return r.rows[seeded.reply.msg_id] && r }, 15000)
  step('4 the hub reads the reply under topic two, home topic one recorded',
    !!s4 && s4.rows[seeded.reply.msg_id].moved_from_task === seeded.one.task_id && s4.rows[seeded.reply.msg_id].task === seeded.two.task_id, s4 && s4.rows[seeded.reply.msg_id])
  const s4o = await rowsOf(p, seeded.one.task_id)
  step('4 ... and topic one no longer holds it', !s4o.rows[seeded.reply.msg_id], { rows: Object.keys(s4o.rows).length })
  await openTopic(p, seeded.two.msg_id, paneRow(seeded.reply.msg_id))
  const note = await p.evaluate((sel) => {
    const el = document.querySelector(`${sel} [data-testid=msg-moved]`)
    return { text: el?.textContent.trim() || '', width: Math.round(el?.getBoundingClientRect().width || 0) }
  }, paneRow(seeded.reply.msg_id))
  step('4 in topic two the reply says "moved from ..." and the note is visible (>= 60 px)', /moved from/.test(note.text) && note.width >= 60, note)
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
  if (mayAll) {
    console.log('SKIP 6 another author\'s card: this account is the tenant owner / an admin, who may move any card (§3.4) - the control runs on the dev test member')
  } else if (other) {
    const r = await hub(p, 'POST', `/v1/messages/${other.msg_id}/move`, { to_channel: B })
    step('6 another author\'s card: the hub refuses the move, 403 not_allowed', r.status === 403 && r.body?.error === 'not_allowed', { other, me, status: r.status, error: r.body?.error })
    if (r.status === 200 && r.body?.undo) { /* a control must never leave a real card moved */
      const u = await hub(p, 'POST', `/v1/messages/${other.msg_id}/move`, r.body.undo)
      step('6 (repair) the wrongly moved card was moved back at once', u.status === 200, { status: u.status })
    }
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
  if (String(e).includes('__phase_done__')) seeded = null
  else step('the run completed', false, { error: String(e).slice(0, 300) })
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
