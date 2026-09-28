// SPL-1034 (specs/045 §3.8) — live proof, signed in: a person's own Channels
// order. The dev test tenant (and prd e2e) only.
//
// Owner, 2026-09-28 (topic 49a2588c): "one should be able to drag and drop
// the channels to define their order".
//
//   1. sign in as A; refuse to write unless the session AND the page host are TENANT
//   2. B's stored order is read first (the control, needs B_EMAIL / B_PW_FILE)
//   3. A: Move down on the FIRST channel row (the row menu, keyboard/touch path)
//      -> the hub stores the whole list with that channel second
//   4. A: a real mouse drag of the LAST row to the top -> stored first
//   5. reload -> the Channels list shows exactly the stored order
//   6. A creates a channel -> it is drawn LAST and is not written into the list
//   7. B's stored order is unchanged (CONTROL)
//   8. clean: A deletes the channel and puts the order back as it was
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> TENANT=<tenant>
//   EMAIL=<A> PW_FILE=<0600> B_EMAIL=<B> B_PW_FILE=<0600> OUT=<dir>
//   [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/channel-order-live.proof.mjs
//
// Passwords are read from the files and never printed. Exit 0 = every step PASS.
import { createRequire } from 'node:module'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const need = (k) => { if (!process.env[k]) { console.error(`FATAL ${k} must be set`); process.exit(2) } return process.env[k] }
const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = need('TENANT')
const A = { email: need('EMAIL'), pw: readFileSync(need('PW_FILE'), 'utf8').trim() }
const B = { email: need('B_EMAIL'), pw: readFileSync(need('B_PW_FILE'), 'utf8').trim() }
mkdirSync(OUT, { recursive: true })
const RUN = Date.now().toString(36)

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok: Boolean(ok), ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

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

async function signIn(browser, who) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', who.email)
  await p.type('[data-test=native-auth-password]', who.pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step(`1 native sign-in (${who.tag})`, ok, { url: p.url() })
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
  step(`1 (${who.tag}) the session AND the page host are in TENANT before anything is written`, inTenant, { want: TENANT, claim: where && where.claim, page: where && where.page })
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


const rows = (p) => p.evaluate(() => [...document.querySelectorAll('#sidebar-panel-channels .nav-row[data-order]')].map((e) => e.getAttribute('data-order')))
const stored = async (p) => (await hub(p, 'GET', '/v1/view/me')).body?.channel_order ?? null
/* the rail builds its hidden panels after the first idle, so the
   tab is waited for and the click retried until the Channels rows show */
async function channelsTab(p) {
  await p.waitForSelector('[data-testid=sidebar-tab-channels]', { timeout: 60000 })
  for (let i = 0; i < 10; i++) {
    await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.click())
    if (await p.waitForSelector('#sidebar-panel-channels .nav-row[data-order]', { visible: true, timeout: 3000 }).then(() => true, () => false)) break
  }
  await p.waitForSelector('#sidebar-panel-channels .nav-row[data-order]', { visible: true, timeout: 10000 })
  await sleep(800)
}

const puppeteer = await loadPuppeteer()
const launch = () => puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
const bA = await launch()
const bB = await launch()
let p
let before = null
let created = ''
try {
  /* 2. B first: the control's "before" */
  const pb = await signIn(bB, { ...B, tag: 'B' })
  const bBefore = await stored(pb)
  step('2 B\'s stored order read (the control)', true, { b_order: bBefore })

  p = await signIn(bA, { ...A, tag: 'A' })
  before = await stored(p)
  await nav(p, BASE + '/lobby')
  await channelsTab(p)
  const shown0 = await rows(p)
  step('2 A\'s Channels list is drawn', shown0.length >= 3, { shown: shown0, stored: before })

  /* 3. the row menu: Move down on the first row */
  const first = shown0[0]
  await p.evaluate((id) => {
    const row = document.querySelector(`#sidebar-panel-channels .nav-row[data-order="${id}"]`)
    row?.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true }))
  }, first)
  await sleep(500)
  const items = await p.evaluate(() => [...document.querySelectorAll('[data-testid=sidebar-row-menu-panel] [role=menuitem]')].map((e) => e.getAttribute('data-testid') || e.textContent.trim()))
  const down = items.find((x) => /move[-_]?down/i.test(String(x)))
  step('3 the first row\'s menu offers Move down (and not Move up)', Boolean(down) && !items.some((x) => /move[-_]?up/i.test(String(x))), { items })
  await p.evaluate(() => {
    const el = [...document.querySelectorAll('[data-testid=sidebar-row-menu-panel] [role=menuitem]')].find((e) => /move[-_]?down/i.test(e.getAttribute('data-testid') || e.textContent))
    el?.click()
  })
  const s3 = await until(async () => { const o = await stored(p); return Array.isArray(o) && o[1] === first && o }, 10000)
  step('3 Move down: the hub stores the whole list with that channel second', !!s3 && s3.length >= shown0.length, { stored: s3 })
  await shot(p, '3-after-move-down')

  /* 4. a real mouse drag: the last row to the top */
  const shown1 = await rows(p)
  const last = shown1[shown1.length - 1]
  const box = async (id) => (await p.$(`#sidebar-panel-channels .nav-row[data-order="${id}"]`)).boundingBox()
  const from = await box(last)
  const to = await box(shown1[0])
  await p.mouse.move(from.x + from.width - 60, from.y + from.height / 2)
  await p.mouse.down()
  for (let i = 1; i <= 12; i++) await p.mouse.move(from.x + from.width - 60, from.y + from.height / 2 + (to.y - 4 - from.y - from.height / 2) * i / 12)
  await p.mouse.up()
  const s4 = await until(async () => { const o = await stored(p); return Array.isArray(o) && o[0] === last && o }, 10000)
  step('4 a mouse drag of the last row to the top: stored first', !!s4, { last, stored: s4 })
  await shot(p, '4-after-drag')

  /* 5. reload: the list shows exactly the stored order */
  await nav(p, BASE + '/lobby')
  await channelsTab(p)
  const shown2 = await rows(p)
  const want = (s4 || []).filter((id) => shown2.includes(id))
  step('5 after a reload the Channels list is the stored order', JSON.stringify(shown2.slice(0, want.length)) === JSON.stringify(want), { shown: shown2, stored: s4 })
  await shot(p, '5-after-reload')

  /* 6. a new channel is drawn last and not written into the list */
  created = `co-proof-${RUN}`
  await p.evaluate(async (id) => {
    const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
    await ch.createChannel(id)
  }, created)
  await nav(p, BASE + '/lobby')
  await channelsTab(p)
  const shown3 = await until(async () => { const r = await rows(p); return r.includes(created) && r }, 15000)
  const s6 = await stored(p)
  step('6 a new channel is drawn LAST', !!shown3 && shown3[shown3.length - 1] === created, { shown: shown3 })
  step('6 ... and is not written into the stored list', Array.isArray(s6) && !s6.includes(created), { stored: s6 })
  await shot(p, '6-new-channel-last')

  /* 7. CONTROL: B's order is untouched */
  const bAfter = await stored(pb)
  step('7 CONTROL: B\'s stored order is unchanged', JSON.stringify(bAfter) === JSON.stringify(bBefore), { before: bBefore, after: bAfter })
  step('no page errors', !res.console.some((c) => c.startsWith('pageerror')), { n: res.console.length })
} catch (e) {
  step('the run completed', false, { error: String(e).slice(0, 300) })
} finally {
  /* 8. clean */
  if (p) {
    if (created) console.log('clean channel', created, (await hub(p, 'DELETE', `/v1/channels/${created}`).catch(() => ({ status: 0 }))).status)
    const r = await hub(p, 'PUT', '/v1/me/channel-order', { channel_order: before || [] }).catch(() => ({ status: 0 }))
    console.log('clean order back to', JSON.stringify(before), r.status)
  }
  writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
  await bA.close()
  await bB.close()
}
console.log(`\nchannel-order-live: ${res.steps.length - failed}/${res.steps.length} passed`)
process.exit(failed ? 1 : 0)
