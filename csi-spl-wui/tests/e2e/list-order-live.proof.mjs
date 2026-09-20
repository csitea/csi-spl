// CLE-3425 live audit + proof of "newest first everywhere" (013 US7 extended):
// every LIST the WUI renders must be newest-first by default, and a new item
// must appear at the TOP within LIMIT_MS with no reload.
//
// It runs two signed-in sessions A and B against a deployed WUI and checks, per
// list: (1) the rendered ORDER against the hub's own newest-first answer, and
// (2) the LIVE behaviour (A acts, B sees it on top).
//
// Lists covered: the thread list `/`, the lobby feed, a channel feed, the
// sidebar channel list, the sidebar DM list, and search results. The channel
// legs CLE-3412 already proved (a NEW root on top) stay in
// tests/e2e/newest-live.proof.mjs; this file adds the ones it did not cover: a
// REPLY into an existing thread, a channel bumped while another view is open,
// and a channel created in another session.
//
//   BASE=https://dev.<domain> EMAIL=<invited member> PW_FILE=<0600 file> \
//     OUT=<dir> [TENANT=t1] [CHANNEL=<slug>] [LIMIT_MS=1000] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/list-order-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every check PASS.
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
const LIMIT_MS = Number(process.env.LIMIT_MS || 1000)
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const res = { base: BASE, at: new Date().toISOString(), limit_ms: LIMIT_MS, steps: [], detail: {} }
let fails = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) fails++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const run = Date.now().toString(36)

async function signIn(ctx, label) {
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step(`${label}: native sign-in`, ok, { url: p.url() })
  if (!ok) throw new Error(`${label} not signed in`)
  return p
}

async function open(p, path) {
  await p.goto(BASE + path, { waitUntil: 'networkidle2' })
  await sleep(2500)
}

/** The hub base this tab reads (runtime config template + the tab's tenant). */
const apiOf = (p) => p.evaluate(() => {
  const cfg = (window.__NUXT__ && window.__NUXT__.config && window.__NUXT__.config.public) || {}
  let tenant = ''
  try { tenant = sessionStorage.getItem('spool.tenant') || '' } catch { /* memory only */ }
  return String(cfg.apiBase || '').replace('{tenant}', tenant || String(cfg.tenant || '')).replace(/\/+$/, '')
})

/** One credentialed hub GET from inside the tab (the session-door cookie). */
const hubGet = (p, api, path) => p.evaluate(async (root, q) => {
  const r = await fetch(root + q, { credentials: 'include' })
  return { status: r.status, body: await r.json().catch(() => null) }
}, api, path)

const keys = (p, sel) => p.$$eval(sel, (els) => els.map((e) => e.getAttribute('data-key') || e.textContent.trim()))
const sideChannels = (p) => p.$$eval('nav.sidebar a.nav-item', (els) => els
  .map((e) => (e.getAttribute('href') || '').split('/channel/')[1])
  .filter(Boolean))

/** Is `got` ordered the same as the prefix of `want` that it covers? */
function sameOrder(got, want) {
  const w = want.filter((x) => got.includes(x))
  const g = got.filter((x) => w.includes(x))
  return { ok: g.length > 0 && g.join('|') === w.join('|'), got: g, want: w }
}

/** Resolves with the browser clock when `fn` first holds in the page. */
function until(p, fn, arg, timeout = 15000) {
  return p.waitForFunction(fn, { polling: 'mutation', timeout }, arg).then((h) => h.jsonValue(), () => null)
}

async function sendInto(p, text) {
  const ta = await p.waitForSelector('form.composer textarea', { timeout: 20000 })
  await ta.focus()
  await p.keyboard.type(text)
  const t0 = Date.now()
  await p.keyboard.press('Enter')
  return t0
}

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const a = await signIn(await browser.createBrowserContext(), 'A')
  const b = await signIn(await browser.createBrowserContext(), 'B')
  const api = await apiOf(a)
  res.detail.api = api
  res.hub = await (await fetch(api + '/version')).json().catch(() => null)

  /* ---- 1. ORDER of every list, against the hub's own newest-first answer ---- */

  // 1.1 thread list `/`
  await open(a, '/')
  const th = await hubGet(a, api, '/v1/view/threads?limit=50')
  const wantThreads = ((th.body && th.body.threads) || []).map((t) => t.task_id)
  const gotThreads = await keys(a, '.thread-row')
  const o1 = sameOrder(gotThreads, wantThreads)
  step('order: thread list / is newest activity first', o1.ok, { n: o1.got.length, got: o1.got.slice(0, 6), want: o1.want.slice(0, 6) })
  await a.screenshot({ path: `${OUT}/order-thread-list.png` })

  // 1.2 lobby message feed (newest message on top)
  await open(a, '/lobby')
  const lobbyId = await a.evaluate(() => {
    const cfg = (window.__NUXT__ && window.__NUXT__.config && window.__NUXT__.config.public) || {}
    return String(cfg.lobbyTaskId || '')
  })
  const lobbyRows = await keys(a, '.live-rows > article.msg')
  let o2 = { ok: false, got: [], want: [] }
  if (lobbyId) {
    const lt = await hubGet(a, api, `/v1/view/threads/${lobbyId}?order=desc&limit=50`)
    const want = ((lt.body && lt.body.messages) || []).map((m) => (m.env && m.env.msg && m.env.msg.msg_id) || m.msg_id)
    o2 = sameOrder(lobbyRows, want)
  }
  step('order: lobby feed is newest message first', o2.ok, { n: o2.got.length, got: o2.got.slice(0, 4), want: o2.want.slice(0, 4), lobby: lobbyId })
  await a.screenshot({ path: `${OUT}/order-lobby.png` })

  // 1.3 channel feed: thread cards by LAST activity, newest first
  await open(a, '/channel/' + CHANNEL)
  const cth = await hubGet(a, api, `/v1/view/threads?limit=20&channel=${encodeURIComponent(CHANNEL)}`)
  const wantCh = ((cth.body && cth.body.threads) || []).map((t) => t.task_id)
  const gotCh = await keys(a, '.live-rows > article.msg')
  const o3 = sameOrder(gotCh, wantCh)
  step(`order: #${CHANNEL} thread cards are newest ACTIVITY first`, o3.ok, { n: o3.got.length, got: o3.got.slice(0, 6), want: o3.want.slice(0, 6) })
  res.detail.channel_threads = ((cth.body && cth.body.threads) || []).slice(0, 8).map((t) => ({ task_id: t.task_id, first_ts: t.first_ts, last_ts: t.last_ts }))
  await a.screenshot({ path: `${OUT}/order-channel.png` })

  // 1.4 sidebar channel list, newest activity first
  const chs = await hubGet(a, api, '/v1/view/channels')
  const rows = (chs.body && chs.body.channels) || []
  const wantSide = rows.slice().sort((x, y) => String(y.last_ts || '').localeCompare(String(x.last_ts || ''))).map((c) => c.channel)
  const gotSide = await sideChannels(a)
  const o4 = sameOrder(gotSide, wantSide)
  step('order: sidebar channel list is newest activity first', o4.ok, { got: o4.got, want: o4.want })
  res.detail.channels = rows.map((c) => ({ channel: c.channel, last_ts: c.last_ts, unread: c.unread }))

  // 1.5 sidebar DM list, newest DM activity first
  const dm = await hubGet(a, api, '/v1/view/threads?limit=50&dm=true')
  const lastByPeer = new Map()
  for (const t of (dm.body && dm.body.threads) || []) {
    for (const p of t.participants || []) {
      const at = String(t.last_ts || '')
      if (at > String(lastByPeer.get(p) || '')) lastByPeer.set(p, at)
    }
  }
  const wantDm = [...lastByPeer.entries()].sort((x, y) => String(y[1]).localeCompare(String(x[1]))).map((e) => e[0])
  const gotDm = await a.$$eval('nav.sidebar a.nav-item', (els) => els.map((e) => {
    const h = e.getAttribute('href') || ''
    const i = h.indexOf('/dm/')
    return i < 0 ? '' : decodeURIComponent(h.slice(i + 4))
  }).filter(Boolean))
  const o5 = sameOrder(gotDm, wantDm)
  step('order: sidebar DM list is newest DM activity first', o5.ok, { got: o5.got, want: o5.want, peers: gotDm.length })

  // 1.6 search results, newest first per group
  const term = 'live'
  await open(a, '/search?q=' + encodeURIComponent(term))
  const sr = await hubGet(a, api, '/v1/view/search?q=' + encodeURIComponent(term))
  const wantSearch = ((((sr.body && sr.body.groups) || []).find((g) => g.type === 'messages') || {}).items || []).map((m) => m.msg_id)
  const gotSearch = await keys(a, '[data-key]')
  const o6 = sameOrder(gotSearch, wantSearch)
  step('order: search message results are newest first', o6.ok, { n: o6.got.length, got: o6.got.slice(0, 4), want: o6.want.slice(0, 4) })
  await a.screenshot({ path: `${OUT}/order-search.png` })

  /* ---- 2. LIVE: a new item arrives on top with no reload ---- */

  // 2.1 a REPLY into an existing thread bumps its card to the top of the channel feed
  await open(a, '/channel/' + CHANNEL)
  await open(b, '/channel/' + CHANNEL)
  const cards = await keys(b, '.live-rows > article.msg')
  const oldest = cards[cards.length - 1]
  if (oldest && cards.length > 1) {
    const nonce = `reply-bump ${run}`
    const seen = until(b, (want) => {
      const first = document.querySelector('.live-rows > article.msg')
      return first && first.getAttribute('data-key') === want ? Date.now() : false
    }, oldest)
    /* reply INTO that thread: the hub takes task_id, so drive the store directly
       through the same send path the thread pane uses */
    const t0 = await a.evaluate(async (arg) => {
      const el = [...document.querySelectorAll('.live-rows > article.msg')].find((x) => x.getAttribute('data-key') === arg.id)
      const btn = el && (el.querySelector('[data-testid=open-thread]') || el.querySelector('button.thread-link') || el.querySelector('button'))
      if (btn) btn.click()
      await new Promise((r) => setTimeout(r, 1200))
      const ta = document.querySelector('.thread-pane form.composer textarea') || document.querySelector('form.composer textarea')
      if (!ta) return 0
      ta.focus()
      const set = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set
      set.call(ta, arg.text)
      ta.dispatchEvent(new Event('input', { bubbles: true }))
      const t = Date.now()
      ta.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
      return t
    }, { id: oldest, text: nonce })
    const t = await seen
    step('live: a reply into an OLD thread moves its card to B\'s top', t !== null && t0 > 0 && t - t0 <= LIMIT_MS, { ms: t && t0 ? t - t0 : null, task: oldest })
    await b.screenshot({ path: `${OUT}/live-reply-bump-B.png` })
  } else {
    step('live: a reply into an OLD thread moves its card to B\'s top', false, { skipped: 'fewer than two thread cards in the channel', cards: cards.length })
  }

  // 2.2 a message in ANOTHER channel bumps that channel to the top of B's sidebar
  await open(b, '/')
  const target = rows.map((c) => c.channel).find((c) => c !== CHANNEL && c !== 'lobby') || 'tasks'
  await open(a, '/channel/' + target)
  const sideSeen = until(b, (want) => {
    const first = [...document.querySelectorAll('nav.sidebar a.nav-item')]
      .map((e) => (e.getAttribute('href') || '').split('/channel/')[1]).filter(Boolean)[0]
    return first === want ? Date.now() : false
  }, target)
  const t1 = await sendInto(a, `sidebar-bump ${run}`)
  const ts1 = await sideSeen
  step(`live: a message in #${target} moves it to the top of B's sidebar`, ts1 !== null && ts1 - t1 <= LIMIT_MS, { ms: ts1 ? ts1 - t1 : null, sidebar: await sideChannels(b) })
  await b.screenshot({ path: `${OUT}/live-sidebar-bump-B.png` })

  // 2.3 a channel created in A appears at the top of B's sidebar
  const fresh = `cle3425-${run}`
  const chSeen = until(b, (want) => {
    const list = [...document.querySelectorAll('nav.sidebar a.nav-item')]
      .map((e) => (e.getAttribute('href') || '').split('/channel/')[1]).filter(Boolean)
    return list[0] === want ? Date.now() : false
  }, fresh)
  await open(a, '/lobby')
  const t2 = await a.evaluate(async (name) => {
    const form = document.querySelector('[data-testid=create-channel]')
    const input = form && form.querySelector('input')
    if (!input) return 0
    input.focus()
    const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set
    set.call(input, name)
    input.dispatchEvent(new Event('input', { bubbles: true }))
    const t = Date.now()
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    return t
  }, fresh)
  const ts2 = await chSeen
  step('live: a channel created by A appears on top of B\'s sidebar', ts2 !== null && t2 > 0 && ts2 - t2 <= LIMIT_MS, { ms: ts2 && t2 ? ts2 - t2 : null, channel: fresh, sidebar: await sideChannels(b) })
  await b.screenshot({ path: `${OUT}/live-new-channel-B.png` })
} catch (e) {
  step('harness', false, { error: String((e && e.message) || e) })
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(fails ? `FAIL ${fails} check(s)` : 'ALL PASS')
process.exit(fails ? 1 : 0)
