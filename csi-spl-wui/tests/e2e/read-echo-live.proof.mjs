// ap-05 (the hub speed round of 2026-10-06, its plan doc row 1):
// how many GET /v1/view/channels follow the tab's own read-mark PUT. Signs in
// through the WUI form, opens one channel and sits on it, logging every
// PUT /v1/me/reads and GET /v1/view/channels from the browser's network
// events. A PUT "is followed by a GET" when a channels GET starts within
// FOLLOW_MS after the PUT's answer and before the next PUT.
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
//     [CHANNEL=general] [MINUTES=4] [MIN_PUTS=20] [FOLLOW_MS=3000] [TENANT=t1] \
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/read-echo-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Prints and writes
// results.json: puts, gets, followed, ratio. Exit 0 = the measurement ran.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const CHANNEL = process.env.CHANNEL || 'general'
const MINUTES = Number(process.env.MINUTES || 4)
const MIN_PUTS = Number(process.env.MIN_PUTS || 20)
const FOLLOW_MS = Number(process.env.FOLLOW_MS || 3000)
mkdirSync(OUT, { recursive: true })
const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
const res = { base: BASE, at: new Date().toISOString(), channel: CHANNEL, events: [] }
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await browser.newPage()
  await p.setViewport({ width: 1280, height: 800 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2' })
  await p.waitForSelector('[data-test=native-auth-email]')
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  if (!(await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).catch(() => null))) throw new Error('sign-in failed')
  const t0 = Date.now()
  p.on('response', (r) => {
    if (r.request().method() !== 'PUT' || !r.url().includes('/v1/me/reads')) return
    const t = Date.now() - t0
    const sent = Object.keys((() => { try { return JSON.parse(r.request().postData() || '{}').marks || {} } catch { return {} } })())
    res.events.push({ t, kind: 'PUT', status: r.status(), sent })
  })
  p.on('request', (q) => {
    if (q.method() === 'GET' && q.url().includes('/v1/view/channels')) res.events.push({ t: Date.now() - t0, kind: 'GET' })
  })
  await p.goto(BASE + '/channel/' + encodeURIComponent(CHANNEL), { waitUntil: 'networkidle2' })
  const end = t0 + MINUTES * 60000
  while (Date.now() < end && res.events.filter((e) => e.kind === 'PUT').length < MIN_PUTS) await sleep(1000)
  await sleep(FOLLOW_MS)
  const ev = res.events.sort((a, b) => a.t - b.t)
  const puts = ev.filter((e) => e.kind === 'PUT')
  let followed = 0
  for (let i = 0; i < puts.length; i++) {
    const until = Math.min(puts[i].t + FOLLOW_MS, i + 1 < puts.length ? puts[i + 1].t : Infinity)
    if (ev.some((e) => e.kind === 'GET' && e.t >= puts[i].t && e.t <= until)) followed++
  }
  Object.assign(res, { puts: puts.length, gets: ev.filter((e) => e.kind === 'GET').length, followed, ratio: puts.length ? followed / puts.length : null, seconds: Math.round((Date.now() - t0) / 1000) })
  console.log(JSON.stringify({ build: res.build.commit, channel: CHANNEL, seconds: res.seconds, puts: res.puts, gets: res.gets, followed, ratio: res.ratio }))
} finally {
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
