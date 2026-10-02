// SPL-1008 — live proof, signed in, against a deployed WUI + hub, in a TEST
// tenant's channel seeded by `./run -a do_spl_reply_count_probe` (csi-spl-orc):
// an OLD topic with agent replies (note to the member, blocker, result), the
// member's own reply and one sent while no tab was open, behind newer topics
// that push its middle lines out of the first page window.
//
// Owner, 2026-09-27 (prd t1 #spool-hub-mobile): the middle list showed "2 >>"
// on a topic with 6 replies stored, "0 >>" on one with a blocker reply.
//
// Steps:
//   1. sign in; the session AND the page host are in TENANT (the live step writes)
//   2. at 1440, 820 and 390 px: /channel/<CHANNEL>, the OLD card reads
//      "<EXPECT> >>" = the hub's /v1/view/topics count - 1; screenshot each
//   3. CONTROL: the page holds fewer of the OLD topic's lines than EXPECT + 1,
//      so counting the held lines (the pre-fix rule) would show a lower number
//   4. live: with the page open at 1440, the member replies in the OLD topic
//      from another socket; the card reads EXPECT + 1 without a reload
//   5. a newer topic's card also equals its hub count - 1 (no change there)
//
//   BASE=https://<tenant>.<domain> API=https://api.<domain> TENANT=e2e
//   CHANNEL=rc-probe-<utc> TASK=<old task id> EXPECT=<replies> EMAIL=<member>
//   PW_FILE=<0600 file> OUT=<dir> [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/reply-counts-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = need('TENANT')
const CHANNEL = need('CHANNEL')
const TASK = need('TASK')
const EXPECT = Number(need('EXPECT'))
const email = need('EMAIL')
const PW_FILE = need('PW_FILE')
const pw = readFileSync(PW_FILE, 'utf8').trim()
if (TENANT === 't1') { console.error('FATAL TENANT=t1 is a real tenant: run in a test tenant'); process.exit(2) }
mkdirSync(OUT, { recursive: true })
const POSTER = join(dirname(fileURLToPath(import.meta.url)), '../../../csi-spl-orc/src/bash/scripts/reply-count-probe-post.py')

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, channel: CHANNEL, task: TASK, expect: EXPECT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }
async function until(fn, ms = 20000) {
  const t0 = Date.now()
  for (;;) {
    const v = await fn().catch(() => null)
    if (v || Date.now() - t0 > ms) return v
    await sleep(400)
  }
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
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  /* the same guard as issues-live.proof.mjs: step 4 writes, so both the claim and the page host must be TENANT */
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
  step('the session AND the page host are in TENANT', inTenant, { want: TENANT, ...where })
  if (!inTenant) throw new Error(`not in ${TENANT}: refusing to go on`)
  return p
}

/** The hub's topic rows for the channel, read with the page's own session. */
async function hubCounts(p) {
  return p.evaluate(async (api, ch) => {
    const r = await fetch(`${api}/v1/view/topics?channel=${encodeURIComponent(ch)}&limit=50`, { credentials: 'include' })
    const j = await r.json()
    return Object.fromEntries((j.topics || []).map((t) => [t.task_id, t.count]))
  }, API, CHANNEL)
}

/** The card's "N >>" and how many of the topic's lines the page holds. */
async function card(p, task) {
  return p.evaluate((t) => {
    const els = [...document.querySelectorAll(`article.msg[data-task-id="${t}"]`)].filter((e) => e.offsetParent)
    const el = els[0]
    const btn = el && el.querySelector('[data-test=topic-replies]')
    const shown = btn ? Number(String(btn.textContent || '').replace(/[^0-9]/g, '')) : (el ? 0 : null)
    const st = document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties.$pinia._s.get('channel')
    const held = st ? st.messages.filter((m) => m.task_id === t && !m.topic_row).length : null
    return { shown, held }
  }, task)
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
  const hub = await hubCounts(p)
  step('the hub counts the seeded replies', hub[TASK] - 1 === EXPECT, { hub_count: hub[TASK], expect: EXPECT, topics: Object.keys(hub).length })
  let first = null
  for (const [w, h] of [[1440, 900], [820, 1180], [390, 844]]) {
    await p.setViewport({ width: w, height: h })
    await nav(p, BASE + '/channel/' + encodeURIComponent(CHANNEL))
    const c = await until(async () => { const v = await card(p, TASK); return v && v.shown !== null && v.shown === EXPECT ? v : null }, 20000) || await card(p, TASK)
    if (!first) first = c
    step(`${w}px: the OLD card reads "${EXPECT} >>"`, c.shown === EXPECT, { w, ...c })
    await p.evaluate((t) => document.querySelector(`article.msg[data-task-id="${t}"]`)?.scrollIntoView({ block: 'center' }), TASK)
    await sleep(500)
    await shot(p, `reply-counts-${w}`)
  }
  step('CONTROL: the page holds fewer OLD lines than replies + 1 (the held-line count would be lower)',
    first && first.held !== null && first.held - 1 < EXPECT, { held: first && first.held, held_count: first && first.held - 1, expect: EXPECT })

  await p.setViewport({ width: 1440, height: 900 })
  await nav(p, BASE + '/channel/' + encodeURIComponent(CHANNEL))
  await until(async () => (await card(p, TASK)).shown === EXPECT)
  const out = execFileSync('python3', [POSTER], {
    env: { ...process.env, PROBE_API: API, PROBE_TENANT: TENANT, PROBE_EMAIL: email, PROBE_PW_FILE: PW_FILE, PROBE_CHANNEL: CHANNEL,
      PROBE_PLAN: JSON.stringify([{ task: TASK, body: 'SPL-1008: a live reply while the tab is open' }]) },
    encoding: 'utf8',
  })
  const live = await until(async () => { const v = await card(p, TASK); return v.shown === EXPECT + 1 ? v : null }, 20000) || await card(p, TASK)
  step(`live: the OLD card reads "${EXPECT + 1} >>" without a reload`, live.shown === EXPECT + 1, { ...live, sent: JSON.parse(out) })
  await p.evaluate((t) => document.querySelector(`article.msg[data-task-id="${t}"]`)?.scrollIntoView({ block: 'center' }), TASK)
  await shot(p, 'reply-counts-live-1440')

  const hub2 = await hubCounts(p)
  const other = Object.keys(hub2).find((t) => t !== TASK)
  const oc = other ? await card(p, other) : null
  step('a newer card equals its hub count - 1', !!oc && oc.shown === hub2[other] - 1, { task: other, hub_count: other && hub2[other], ...oc })
} catch (e) {
  step('run', false, { error: String(e).slice(0, 400) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/reply-counts-live.json`, JSON.stringify(res, null, 2))
}
console.log(failed ? `FAIL ${failed} step(s)` : 'PASS all steps')
process.exit(failed ? 1 : 0)
