// live proof, signed in: a merge removes its source message.
//
// Owner, prd t1 topic 04130ea2: "the merge with previous and next works, but
// once the content is merged, the actual source of the merged content, the
// source card, should self-delete".
//
// Measured on prd before the fix (Cloud Run request log, 2026-09-27): the
// merge sent PATCH 845e637d (200) at 20:48:59Z and NO delete; the source was
// deleted by hand 9 s later. So this proof watches the WIRE as well as the
// screen:
//
//   1. sign in; refuse to write unless the session AND the page host are TENANT
//   2. create a topic in CHANNEL (default live-proof, fallback off): a card
//      and two replies, all ours
//   3. open /t/<task> in two tabs; in tab A, reply 2's menu -> Merge with previous
//   4. tab A: reply 2 leaves the thread, reply 1 shows both bodies
//   5. tab B (no reload): the same, from the live frame
//   6. the hub: reply 2 is gone from the topic, reply 1 holds both bodies;
//      the merge was ONE request (POST .../merge), not a PATCH and a DELETE
//   7. cleanup: the topic is deleted
//
//   BASE=https://<tenant>.<domain> API=https://api.<domain> TENANT=<tenant>
//   EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> [CHANNEL=live-proof] node tests/e2e/merge-delete-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = need('TENANT')
/* A proof channel with the fallback responder off (do_spl_channel_fallback
   NO_FALLBACK=1), so the proof posts do not wake an agent. */
const CHANNEL = process.env.CHANNEL || 'live-proof'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
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

/* A read the box's docker network churn killed is retried; an HTTP answer never is. */
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

/** Click the first VISIBLE match. */
const click = (p, sel) => p.evaluate((sel) => {
  const e = [...document.querySelectorAll(sel)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)

/** The rendered text of one row's body, '' when the row is not on screen. */
const bodyText = (p, id) => p.evaluate((id) => {
  const rows = [...document.querySelectorAll(`article.msg[data-msg-id="${id}"] .msg-body`)]
  return rows.map((r) => r.textContent || '').join(' | ')
}, id)

/* On screen only: the first control runs counted a copy of the row the
   screenshot showed gone (an off-screen panel). Where such copies sit is
   recorded in result.json (offscreen). */
const rowShown = (p, id) => p.evaluate((id) => [...document.querySelectorAll(`article.msg[data-msg-id="${id}"]`)]
  .some((r) => {
    const b = r.getBoundingClientRect()
    return b.height > 0 && b.bottom > 0 && b.right > 0 && b.top < innerHeight && b.left < innerWidth
  }), id)

const offscreen = (p, id) => p.evaluate((id) => [...document.querySelectorAll(`article.msg[data-msg-id="${id}"]`)].map((r) => {
  const b = r.getBoundingClientRect()
  const host = r.closest('[data-test], aside, section, main')
  return { top: Math.round(b.top), left: Math.round(b.left), h: Math.round(b.height), host: host ? (host.getAttribute('data-test') || host.tagName) : '' }
}), id)

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
const T = randomUUID()
const card = randomUUID()
const r1 = randomUUID()
const r2 = randomUUID()
let p0
try {
  p0 = await signIn(browser)
  const tag = `CLE-35064 merge proof ${Date.now().toString(36)}`
  const acks = await sendAll(p0, [
    { msg_id: card, task_id: T, channel: CHANNEL, body: `${tag}: the card`, is_parent: 1 },
    { msg_id: r1, task_id: T, channel: CHANNEL, body: `${tag}: reply one`, is_parent: 0 },
    { msg_id: r2, task_id: T, channel: CHANNEL, body: `${tag}: reply two`, is_parent: 0 },
  ])
  step('2 the card and two replies are stored (acked)', [card, r1, r2].every((id) => acks[id]), { acks: Object.keys(acks).length })
  writeFileSync(`${OUT}/ids.json`, JSON.stringify({ task: T, card, r1, r2 }, null, 2))

  const open = async () => {
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
    await nav(p, BASE + '/t/' + T)
    await p.waitForSelector(`article.msg[data-msg-id="${r2}"]`, { visible: true, timeout: 30000 }).catch(() => {})
    await sleep(1500)
    return p
  }
  const a = await open()
  const b = await open()
  const wire = []
  a.on('request', (rq) => {
    const u = rq.url()
    if (u.startsWith(API + '/v1/messages/') && !['OPTIONS', 'GET'].includes(rq.method())) wire.push(`${rq.method()} ${u.slice(API.length)}`)
  })
  step('3 both tabs show reply two', (await rowShown(a, r2)) && (await rowShown(b, r2)))
  /* The feed is a TransitionGroup: a leaving row waits for a paint, and a
     background tab never paints, so the row a merge removed stayed in tab A's
     DOM until its screenshot brought it forward. Each tab is read in front,
     as a person would see it. */
  await a.bringToFront()
  await click(a, `article.msg[data-msg-id="${r2}"] [data-testid=msg-menu-btn]`)
  await sleep(400)
  const offered = await click(a, '[data-testid=msg-menu-merge-prev]')
  step('3 reply two offers Merge with previous', offered)

  const t0 = Date.now()
  const goneA = await until(() => rowShown(a, r2).then((v) => !v), 30000)
  res.goneAfterMs = Date.now() - t0
  res.shownNow = await rowShown(a, r2)
  const textA = await until(async () => {
    const t = await bodyText(a, r1)
    return /reply two/.test(t) ? t : ''
  }, 10000)
  await shot(a, 'tab-a-after-merge')
  res.offscreen = await offscreen(a, r2)
  step('4 tab A: reply two is gone, reply one shows both bodies', goneA && /reply one/.test(textA || ''), { goneA, textA: String(textA || '').slice(0, 160) })

  await b.bringToFront()
  const goneB = await until(() => rowShown(b, r2).then((v) => !v), 10000)
  const textB = await until(async () => {
    const t = await bodyText(b, r1)
    return /reply two/.test(t) ? t : ''
  }, 10000)
  await shot(b, 'tab-b-after-merge')
  step('5 tab B (live frames, no reload): reply two is gone, reply one shows both', goneB && Boolean(textB), { goneB, textB: String(textB || '').slice(0, 160) })

  const topic = await hub(p0, 'GET', `/v1/view/topics/${T}?limit=50`)
  const rows = (topic.body && topic.body.messages) || []
  const idOf = (m) => String(m.msg_id || (m.env && m.env.msg && m.env.msg.msg_id) || '')
  const ids = rows.map(idOf)
  const keep = rows.find((m) => idOf(m) === r1)
  const keepBody = keep ? String(keep.body || (keep.env && keep.env.msg && keep.env.msg.body) || '') : ''
  step('6 the hub no longer holds reply two; reply one holds both bodies',
    topic.status === 200 && ids.includes(r1) && !ids.includes(r2) && /reply one[\s\S]*reply two/.test(keepBody),
    { status: topic.status, ids: ids.length, r2held: ids.includes(r2), revision: keep && keep.revision })
  step('6 the merge was one request, not a PATCH then a DELETE', wire.length === 1 && /\/merge$/.test(wire[0]), { wire })
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  if (p0) {
    const del = await hub(p0, 'DELETE', `/v1/messages/${card}/topic`).catch(() => ({ status: 0 }))
    step('7 cleanup: the proof topic is deleted', del.status === 200 || del.status === 204, { status: del.status })
  }
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(failed ? `FAIL ${failed} step(s)` : 'ALL PASS')
process.exit(failed ? 1 : 0)
