// CLE-77930 live proof (owner, t1 bf737f3f: unread is "for me and me only ...
// not the new messages which I have seen"): a channel read on one device is
// read on every other. Two browser contexts are two devices of ONE member:
//
//   A  signs in, opens /channel/<X> (the channel with the most unread for
//      this member), and leaves it; the WUI pushes the read mark
//      (PUT /v1/me/reads) - checked with GET /v1/me/reads
//   B  a fresh device (empty localStorage, so no read= at all) signs in:
//      #<X> must show NO unread badge, while a channel A never opened keeps
//      its count (the control: a hub that zeroed every badge would pass A alone)
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> [TENANT=t1] \
//     node tests/e2e/read-marks-live.proof.mjs
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }

async function signIn(ctx) {
  const p = await ctx.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(`${BASE}/login?tenant=${encodeURIComponent(TENANT)}&redirect=${encodeURIComponent('/lobby')}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  return { p, ok }
}

/** The hub's channel rows as this tab's channel store holds them, freshly loaded. */
const channelRows = (p) => p.evaluate(async () => {
  const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
  await s.loadChannels()
  return s.channels.map((c) => ({ id: c.channel_id, unread: c.unread, count: c.count }))
})
/** The rail badge of a channel ('' = none). */
const badge = (p, id) => p.evaluate((id) => {
  const n = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('notification')
  return Number(n.unread['ch:' + id] || 0)
}, id)
/** GET /v1/me/reads through the page's own API host and session. */
const hubMarks = (p, base) => p.evaluate(async (base) => {
  const r = await fetch(`${base}/v1/me/reads`, { credentials: 'include', headers: { accept: 'application/json' } })
  return { status: r.status, body: r.ok ? await r.json() : null }
}, base)

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
let code = 0
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  /* device A */
  const ctxA = await browser.createBrowserContext()
  const a = await signIn(ctxA)
  step('device A signs in', a.ok)
  if (!a.ok) throw new Error('sign-in failed (rate limit? see the memory note)')
  await sleep(2500)
  const before = await channelRows(a.p)
  const ranked = before.filter((c) => c.unread > 0).sort((x, y) => y.unread - x.unread)
  step('device A: at least two channels have unread lines for this member', ranked.length >= 2, { unread: ranked })
  if (ranked.length < 2) throw new Error('no unread to prove against')
  const [X, Y] = ranked
  await a.p.goto(`${BASE}/channel/${X.id}`, { waitUntil: 'networkidle2' })
  await sleep(1500)
  await a.p.goto(`${BASE}/lobby`, { waitUntil: 'networkidle2' })
  await sleep(7000) /* one push tick (5 s) */
  const base = String(process.env.API_BASE || '')
  const marks = base ? await hubMarks(a.p, base) : { status: 0, body: null }
  if (base) step(`hub holds A's read mark for #${X.id}`, marks.status === 200 && Boolean(marks.body && marks.body.marks && marks.body.marks['ch:' + X.id]), { status: marks.status, mark: marks.body && marks.body.marks && marks.body.marks['ch:' + X.id] })
  await a.p.screenshot({ path: `${OUT}/device-a.png` })

  /* device B: a fresh profile, nothing in localStorage */
  const ctxB = await browser.createBrowserContext()
  const b = await signIn(ctxB)
  step('device B (empty storage) signs in', b.ok)
  if (!b.ok) throw new Error('sign-in B failed')
  const storage = await b.p.evaluate(() => Object.keys(JSON.parse(localStorage.getItem('spool.read-cursors') || '{}')).length)
  await sleep(3000)
  const rowsB = await channelRows(b.p)
  const xb = rowsB.find((c) => c.id === X.id) || {}
  const yb = rowsB.find((c) => c.id === Y.id) || {}
  step(`device B: #${X.id}, read on A, has nothing unread (was ${X.unread})`, xb.unread === 0, { before: X.unread, after: xb.unread })
  step(`CONTROL device B: #${Y.id}, never opened, keeps its unread (${Y.unread})`, yb.unread > 0, { before: Y.unread, after: yb.unread })
  await sleep(1000)
  step(`device B rail: no badge on #${X.id}`, (await badge(b.p, X.id)) === 0, { badge: await badge(b.p, X.id), storageKeysAtLoad: storage })
  await b.p.screenshot({ path: `${OUT}/device-b.png` })
} catch (e) {
  console.error(String(e && e.message || e))
  code = 1
} finally {
  await browser.close()
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
}
const failed = res.steps.filter((s) => !s.ok)
console.log(`\nread-marks-live: ${res.steps.length - failed.length}/${res.steps.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
