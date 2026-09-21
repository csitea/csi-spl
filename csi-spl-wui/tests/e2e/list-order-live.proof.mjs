// CLE-3425 live audit + proof of "newest first everywhere" (013 US7 extended):
// every LIST the WUI renders must be newest-first by default, and a new item
// must appear at the TOP within LIMIT_MS with no reload.
//
// Two signed-in sessions A and B against a deployed WUI. Per list it checks
// (1) the rendered ORDER and (2) the LIVE behaviour (A acts, B sees it on top).
//
// The order check reads `data-ts` off each row — the clock the row is ordered
// by, which every list stamps since CLE-3425 — and asserts it never increases
// down the list. That is the owner's requirement stated literally, and it needs
// no second source of truth to disagree with. The thread list is additionally
// cross-checked against the hub's own answer (its rows carry task_id, so the two
// are comparable).
//
// Lists covered: the thread list `/`, the lobby feed, a channel feed, the
// sidebar channel list, the sidebar DM list, search results. The channel legs
// CLE-3412 already proved (a NEW root on top) stay in
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
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 30000 })
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

/** The (data-key, data-ts) of every row of a list, in rendered order. */
const rowsOf = (p, sel) => p.$$eval(sel, (els) => els.map((e) => ({
  key: e.getAttribute('data-key') || e.textContent.trim().slice(0, 40),
  ts: e.getAttribute('data-ts') || '',
})))

/** Newest first = data-ts never increases as you go down. */
function descending(rows) {
  const stamped = rows.filter((r) => r.ts)
  for (let i = 1; i < stamped.length; i++) {
    if (stamped[i].ts > stamped[i - 1].ts) {
      return { ok: false, at: i, prev: stamped[i - 1], row: stamped[i], n: stamped.length }
    }
  }
  return { ok: stamped.length > 0, n: stamped.length, first: stamped[0], last: stamped[stamped.length - 1] }
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

const FEED = '.live-rows > article.msg'
const SIDE_CH = 'nav.sidebar a.nav-item[href*="/channel/"]'
const SIDE_DM = 'nav.sidebar a.nav-item[href*="/dm/"]'

const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const a = await signIn(await browser.createBrowserContext(), 'A')
  const b = await signIn(await browser.createBrowserContext(), 'B')
  const api = await apiOf(a)
  res.detail.api = api
  res.hub = await (await fetch(api + '/version')).json().catch(() => null)

  /* ---- 1. ORDER: every list newest first ---- */

  // 1.1 thread list `/` — DOM order, and the hub's own answer for the same rows
  await open(a, '/')
  const threads = await rowsOf(a, '.thread-row')
  const d1 = descending(threads)
  step('order: thread list / is newest activity first', d1.ok, d1)
  const th = await hubGet(a, api, '/v1/view/threads?limit=50')
  const wantThreads = ((th.body && th.body.threads) || []).map((t) => t.task_id)
  const gotThreads = threads.map((r) => r.key).filter((k) => wantThreads.includes(k))
  const sameAsHub = gotThreads.join('|') === wantThreads.filter((k) => gotThreads.includes(k)).join('|')
  step('order: thread list / matches the hub\'s own newest-first answer', sameAsHub && gotThreads.length > 0,
    { n: gotThreads.length, got: gotThreads.slice(0, 5) })
  await a.screenshot({ path: `${OUT}/order-thread-list.png` })

  // 1.2 lobby message feed
  await open(a, '/lobby')
  const d2 = descending(await rowsOf(a, FEED))
  step('order: lobby feed is newest message first', d2.ok, d2)
  await a.screenshot({ path: `${OUT}/order-lobby.png` })

  // 1.3 channel feed: thread cards by LAST activity
  await open(a, '/channel/' + CHANNEL)
  const d3 = descending(await rowsOf(a, FEED))
  step(`order: #${CHANNEL} thread cards are newest ACTIVITY first`, d3.ok, d3)
  const cth = await hubGet(a, api, `/v1/view/threads?limit=20&channel=${encodeURIComponent(CHANNEL)}`)
  res.detail.channel_threads = ((cth.body && cth.body.threads) || []).slice(0, 8)
    .map((t) => ({ task_id: t.task_id, first_ts: t.first_ts, last_ts: t.last_ts }))
  await a.screenshot({ path: `${OUT}/order-channel.png` })

  // 1.4 sidebar channel list
  const sideCh = await rowsOf(a, SIDE_CH)
  const d4 = descending(sideCh)
  step('order: sidebar channel list is newest activity first', d4.ok, { ...d4, rendered: sideCh })
  const chs = await hubGet(a, api, '/v1/view/channels')
  res.detail.channels = ((chs.body && chs.body.channels) || [])
    .map((c) => ({ channel: c.channel, last_ts: c.last_ts, created_at: c.created_at, unread: c.unread }))

  // 1.5 sidebar DM list
  const sideDm = await rowsOf(a, SIDE_DM)
  const d5 = descending(sideDm)
  step('order: sidebar DM list is newest DM activity first', d5.ok, { ...d5, peers: sideDm.length })
  res.detail.dm_sidebar = sideDm

  // 1.6 search results — per group: the hub answers each group newest first
  // (search-v1 §4), and the groups themselves are ordered by kind, not by time.
  await open(a, '/search?q=' + encodeURIComponent('live'))
  const perGroup = await a.$$eval('section.search-group', (secs) => secs.map((sec) => ({
    group: sec.getAttribute('data-group') || '',
    rows: [...sec.querySelectorAll('.search-row')].map((e) => ({
      key: e.getAttribute('data-key') || '', ts: e.getAttribute('data-ts') || '',
    })),
  })))
  /* A group whose rows carry NO clock cannot be time-ordered and is reported,
     never silently passed: `robots` and `users` are identities (the hub orders
     them by id), so only the stamped groups are checked here. */
  const judged = perGroup.map((g) => ({
    group: g.group,
    stamped: g.rows.filter((r) => r.ts).length,
    ...descending(g.rows),
  }))
  const timed = judged.filter((g) => g.stamped > 1)
  const bad = timed.filter((g) => !g.ok)
  step('order: every timed search group is newest first', timed.length > 0 && bad.length === 0, {
    checked: timed.map((g) => `${g.group}:${g.stamped}`),
    not_time_ordered: judged.filter((g) => g.stamped <= 1).map((g) => `${g.group}:${g.stamped}`),
    bad,
  })
  const sr = await hubGet(a, api, '/v1/view/search?q=live')
  const groups = (sr.body && sr.body.groups) || {}
  res.detail.search_groups = Object.fromEntries(Object.entries(groups)
    .map(([k, g]) => [k, ((g && g.results) || []).slice(0, 3).map((r) => r.received_at || r.last_at || r.last_hello_at || r.last_ts || '')]))
  await a.screenshot({ path: `${OUT}/order-search.png` })

  /* ---- 2. LIVE: a new item arrives on top with no reload ---- */

  // 2.1 a REPLY into an existing thread bumps its card to the top of the feed.
  // The reply is sent through the app's OWN send path (the channel store, which
  // is what the thread-pane composer calls), so the hub and the push are real.
  await open(a, '/channel/' + CHANNEL)
  await open(b, '/channel/' + CHANNEL)
  const cards = await rowsOf(b, FEED)
  const oldest = cards.filter((c) => c.ts).slice(-1)[0]
  if (oldest && cards.length > 1) {
    const seen = until(b, (want) => {
      const first = document.querySelector('.live-rows > article.msg')
      return first && first.getAttribute('data-key') === want ? Date.now() : false
    }, oldest.key)
    const t0 = await a.evaluate(async (arg) => {
      const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
      const el = [...document.querySelectorAll('.live-rows > article.msg')].find((x) => x.getAttribute('data-key') === arg.key)
      if (!el) return { t: 0, why: 'row gone' }
      /* the task the card stands for: the store holds it under this msg_id */
      const ch = pinia._s.get('channel')
      const row = ch.messages.find((m) => m.msg_id === arg.key)
      if (!row) return { t: 0, why: 'no store row' }
      const t = Date.now()
      await ch.send(arg.text, String(row.task_id))
      return { t, task: String(row.task_id) }
    }, { key: oldest.key, text: `reply-bump ${run}` })
    const t = await seen
    step('live: a reply into an OLD thread moves its card to B\'s top',
      t !== null && t0.t > 0 && t - t0.t <= LIMIT_MS,
      { ms: t && t0.t ? t - t0.t : null, card: oldest.key, task: t0.task, why: t0.why })
    await b.screenshot({ path: `${OUT}/live-reply-bump-B.png` })
  } else {
    step('live: a reply into an OLD thread moves its card to B\'s top', false,
      { skipped: 'fewer than two stamped thread cards in the channel', cards: cards.length })
  }

  // 2.2 a message in ANOTHER channel bumps that channel to the top of B's sidebar
  await open(b, '/')
  const target = sideCh.map((c) => c.key).find((c) => c && c !== CHANNEL) || 'tasks'
  await open(a, '/channel/' + target)
  const sideSeen = until(b, (want) => {
    const first = document.querySelector('nav.sidebar a.nav-item[href*="/channel/"]')
    return first && first.getAttribute('data-key') === want ? Date.now() : false
  }, target)
  const t1 = await sendInto(a, `sidebar-bump ${run}`)
  const ts1 = await sideSeen
  step(`live: a message in #${target} moves it to the top of B's sidebar`, ts1 !== null && ts1 - t1 <= LIMIT_MS,
    { ms: ts1 ? ts1 - t1 : null, target, sidebar: (await rowsOf(b, SIDE_CH)).map((r) => r.key) })
  /* the same frame has to raise the unread badge of a channel B is NOT viewing
     (013 FR-014): before the tab-wide follow this moved only on a reload */
  const badge = await b.evaluate((want) => {
    const row = [...document.querySelectorAll('nav.sidebar a.nav-item[href*="/channel/"]')]
      .find((e) => e.getAttribute('data-key') === want)
    const el = row && row.querySelector('.badge-unread')
    return el ? el.textContent.trim() : ''
  }, target)
  step(`live: #${target} shows an unread badge on B without a reload`, Boolean(badge), { badge, target })
  await b.screenshot({ path: `${OUT}/live-sidebar-bump-B.png` })

  // 2.3 a channel created in A appears at the top of B's sidebar (needs the hub
  // `channel` frame, wui-live-ws 0.6)
  const fresh = `cle3425-${run}`
  const chSeen = until(b, (want) => {
    const first = document.querySelector('nav.sidebar a.nav-item[href*="/channel/"]')
    return first && first.getAttribute('data-key') === want ? Date.now() : false
  }, fresh)
  await open(a, '/lobby')
  const t2 = await a.evaluate(async (name) => {
    const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
    const ch = pinia._s.get('channel')
    const t = Date.now()
    try {
      await ch.createChannel(name)
    } catch (e) {
      return { t, err: String((e && e.message) || e) }
    }
    return { t }
  }, fresh)
  const ts2 = await chSeen
  step('live: a channel created by A appears on top of B\'s sidebar',
    ts2 !== null && t2.t > 0 && ts2 - t2.t <= LIMIT_MS,
    { ms: ts2 && t2.t ? ts2 - t2.t : null, channel: fresh, err: t2.err, sidebar: (await rowsOf(b, SIDE_CH)).map((r) => r.key) })
  await b.screenshot({ path: `${OUT}/live-new-channel-B.png` })
} catch (e) {
  step('harness', false, { error: String((e && e.message) || e) })
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(fails ? `FAIL ${fails} check(s)` : 'ALL PASS')
process.exit(fails ? 1 : 0)
