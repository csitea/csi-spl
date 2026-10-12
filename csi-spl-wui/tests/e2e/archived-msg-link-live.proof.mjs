// HUM-10 (t1 89b0200d) — live proof, signed in, against a deployed WUI + hub.
//
// Owner: "we should be able to open even archived msg from their link,
// regardless of the fact that they are in the archive".
//
//   1. sign in; refuse to write unless the session AND the page host are TENANT
//   2. create a #lobby topic over the browser socket: the card and one reply
//   3. archive it through the hub (PUT /v1/messages/<card>/archive)
//   4. /m/<reply> and /m/<card>, at 1440x900 and 390x844: the channel opens
//      with the topic on the right, the message marked, the Archived badge in
//      the pane, no failure notice; still so 2.5 s later
//   5. the topic is still archived (the link did not unarchive it)
//   6. the proof topic is deleted again unless KEEP=1
// Screenshots: $OUT/<desktop|phone>-<reply|card>.png; result: $OUT/result.json.
//
//   BASE=https://<tenant>.<domain> API=https://api.<domain> EMAIL=<member> \
//   PW_FILE=<0600 file> OUT=<dir> TENANT=<tenant> [KEEP=1] [CHROME_PATH=...] \
//   [PUPPETEER_CORE=<path>] node tests/e2e/archived-msg-link-live.proof.mjs
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
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}

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
    return { claim: String(s.claims.t || ''), hosts, page }
  }), 15000)
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  step('1 the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...where })
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  return p
}

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

/* msg-deep-links.test.mjs's openedArchived, against the live pane */
async function opened(p, id, task) {
  await nav(p, `${BASE}/m/${id}`)
  const state = () => p.evaluate((markId, task) => {
    const pane = document.querySelector('aside.live-pane')
    const el = pane && pane.querySelector(`article.msg[data-msg-id="${markId}"]`)
    const notice = document.querySelector('[data-testid="open-msg-notice"]')
    return {
      path: location.pathname + location.search + location.hash,
      place: location.pathname.endsWith('/channel/lobby') && new URLSearchParams(location.search).get('topic') === task,
      shown: Boolean(el && el.getBoundingClientRect().height > 0),
      lit: Boolean(el && (el.classList.contains('open-focus') || el.classList.contains('search-focus'))),
      badge: Boolean(pane && pane.querySelector('[data-test="archived-badge"]')),
      notice: notice ? notice.getAttribute('data-reason') : '',
    }
  }, id, task)
  const start = Date.now()
  let lit = false
  let last = null
  while (Date.now() - start < 30000) {
    last = await state()
    lit = lit || last.lit
    if (last.notice || (lit && last.place && last.shown && last.badge)) break
    await sleep(100)
  }
  await sleep(2500)
  const later = await state()
  return { ok: lit && last.place && last.shown && last.badge && !last.notice && later.place && later.badge, lit, last, later }
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
let p = null
let card = ''
try {
  p = await signIn(browser)
  const T = randomUUID()
  card = randomUUID()
  const reply = randomUUID()
  const tag = `HUM-10 archived-link proof ${Date.now().toString(36)}`
  const acks = await sendAll(p, [
    { msg_id: card, task_id: T, channel: 'lobby', body: `${tag}: the card`, is_parent: 1 },
    { msg_id: reply, task_id: T, channel: 'lobby', body: `${tag}: a reply`, is_parent: 0 },
  ])
  step('2 the card and a reply are stored (acked)', Boolean(acks[card] && acks[reply]), { card, reply, task: T })
  writeFileSync(`${OUT}/ids.json`, JSON.stringify({ task: T, card, reply }, null, 2))

  const arch = await hub(p, 'PUT', `/v1/messages/${card}/archive`)
  const read = await hub(p, 'GET', `/v1/view/messages/${card}/topic`)
  step('3 the topic is archived', arch.status === 200 && read.body?.archived === true, { put: arch.status, archived: read.body?.archived })

  for (const vp of [{ name: 'desktop', width: 1440, height: 900 }, { name: 'phone', width: 390, height: 844, isMobile: true, hasTouch: true }]) {
    await p.setViewport(vp)
    for (const [label, id] of [['reply', reply], ['card', card]]) {
      const got = await opened(p, id, T)
      await p.screenshot({ path: `${OUT}/${vp.name}-${label}.png` }).catch(() => {})
      step(`4 ${vp.name} /m/<${label}>: opens in #lobby with the topic, marked, Archived badge, no failure`, got.ok, got)
    }
  }

  const still = await hub(p, 'GET', `/v1/view/messages/${card}/topic`)
  step('5 the topic is still archived after the links', still.body?.archived === true, { archived: still.body?.archived })
} catch (e) {
  step('run', false, { error: String(e).slice(0, 400) })
} finally {
  if (p && card && !process.env.KEEP) {
    const del = await hub(p, 'DELETE', `/v1/messages/${card}/topic`).catch((e) => ({ status: 0, body: String(e) }))
    step('6 the proof topic is deleted', del.status === 200 || del.status === 404, { status: del.status })
  }
  res.failed = failed
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
process.exit(failed ? 1 : 0)
