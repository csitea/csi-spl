// SPL-1018 (spec 044 FR-OS-017, owner t1 dee4081d msg e9ec66fa) - live proof,
// signed in, against a DEPLOYED WUI + hub: the per-agent sender allow-list.
//
//   1. sign in as the probe member (an admin: tenant.settings); refuse to
//      write unless the session AND the page host are TENANT
//   2. Workspace settings -> Agents lists the seated agents with "Who may
//      message each agent"; without AGENT the proof prints them and stops
//      (nothing written)
//   3. the agent's current list is kept, to be put back in step 7
//   4. LISTED: the list names the probe member -> "@AGENT ..." from the
//      composer is sent (no refusal line, the box empties)
//   5. UNLISTED: the list names another member (or nobody) -> the same send
//      is refused: the line under the composer names AGENT, the text stays
//   6. a channel post with no @mention is not checked (decision 3, CONTROL)
//   7. the agent's list is put back as it was (no list -> DELETE)
//
//   BASE=https://<wui host> API=https://<api host> TENANT=<test tenant>
//   EMAIL=<admin> PW_FILE=<0600 file> OUT=<dir> [AGENT=<id>] [CHANNEL=lobby]
//   [CHROME_PATH=...] [PUPPETEER_CORE=<path>] node tests/e2e/sender-allow-live.proof.mjs
//
// It WRITES (with AGENT): two short lines to AGENT and one to CHANNEL, so point
// it at a test tenant and a test agent. The password is read from PW_FILE and
// never printed. Exit 0 = every step PASS; OUT/results.json, OUT/*.png.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const TENANT = need('TENANT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const AGENT = (process.env.AGENT || '').trim()
const CHANNEL = process.env.CHANNEL || 'lobby'
const BOX = 'form.composer.omnibox--global textarea'
const REFUSAL = '[data-test=omnibox-send-error]'
mkdirSync(OUT, { recursive: true })
const RUN = Date.now().toString(36)

const res = { base: BASE, api: API, tenant: TENANT, agent: AGENT, at: new Date().toISOString(), steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok: Boolean(ok), ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

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

/* One hub call from the page (its cookies). */
const hub = (p, method, path, body) => p.evaluate(async (api, m, pth, b) => {
  const init = { method: m, credentials: 'include' }
  if (b !== undefined) { init.body = JSON.stringify(b); init.headers = { 'Content-Type': 'application/json' } }
  const r = await fetch(api + pth, init)
  let out = null
  try { out = await r.json() } catch { /* 204 */ }
  return { status: r.status, body: out }
}, API, method, path, body)

async function signIn(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('1 native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
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
    return { claim: String(s.claims.t || ''), hosts, page, me: String(s.claims.hum || s.claims.human_id || s.claims.sub || '') }
  }), 15000)
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  step('1 the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, claim: where && where.claim, page: where && where.page })
  if (!inTenant) throw new Error(`not in ${TENANT}: refusing to write`)
  return { p, me: where.me }
}

/* the page's own send settings, never saved: Enter sends from the top composer */
async function enterSends(p) {
  await p.waitForSelector(BOX, { timeout: 60000 })
  const ok = await until(() => p.evaluate(() => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const s = app && app.config.globalProperties.$pinia?._s.get('session')
    if (!s || !s.claims) return false
    s.claims = { ...s.claims, submit_key: 'enter' }
    return true
  }), 20000)
  if (!ok) throw new Error('the app did not boot on the channel page')
}

/* type text into the top composer and send it. The box empties at once (the
   send is optimistic), so the outcome is read after the hub answered:
   'refused' = the line under the composer shows; 'sent' = no line within
   SETTLE ms and the text is drawn in the feed */
const SETTLE = 8000
async function send(p, text) {
  await p.waitForSelector(BOX, { timeout: 30000 })
  await p.evaluate((sel) => { const el = document.querySelector(sel); el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) }, BOX)
  await p.focus(BOX)
  await p.type(BOX, text)
  await p.keyboard.press('Enter')
  const read = () => p.evaluate((box, ref, t) => {
    const line = document.querySelector(ref)
    const left = document.querySelector(box)?.value || ''
    const fed = [...document.querySelectorAll('article.msg')].some((e) => e.textContent.includes(t.slice(t.indexOf(' ') + 1)))
    return { outcome: line ? 'refused' : 'pending', line: line ? line.textContent.replace(/\s+/g, ' ').trim() : '', left, fed }
  }, BOX, REFUSAL, text)
  const refused = await until(async () => { const r = await read(); return r.outcome === 'refused' && r }, SETTLE)
  if (refused) {
    await sleep(500)
    return read()
  }
  const r = await read()
  return { ...r, outcome: r.left === '' && r.fed ? 'sent' : 'unclear' }
}
const dismiss = (p) => p.evaluate((ref) => document.querySelector(`${ref} button`)?.click(), REFUSAL)

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'], protocolTimeout: 60000 })
let p
let me = ''
let before
try {
  ;({ p, me } = await signIn(browser))
  res.me = me
  const vme = await hub(p, 'GET', '/v1/view/me')
  res.me_role = vme.body?.role || null
  console.log('INFO probe member', me, 'role', res.me_role)
  res.version = await fetch(API + '/version').then((r) => r.json(), () => null)
  res.wui_build = await fetch(BASE + '/build.json', { cache: 'no-store' }).then((r) => r.json(), () => null)

  /* 2. the Agents page and its "who may message" rows */
  await p.goto(BASE + '/tenant-settings/agents', { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=tenant-agent-senders] [data-test=tenant-sender-row]', { timeout: 30000 }).catch(() => null)
  const rows = await p.$$eval('[data-test=tenant-sender-row]', (xs) => xs.map((x) => ({
    agent: x.getAttribute('data-agent'),
    state: (x.querySelector('[data-test=tenant-sender-state]')?.textContent || '').trim(),
  })))
  const admin = await hub(p, 'GET', '/v1/tenant/agent-senders')
  step('2 the probe member is a workspace admin (tenant.settings)', admin.status === 200, { me, status: admin.status })
  step('2 the Agents page lists who may message each seated agent', rows.length > 0, { rows })
  await shot(p, '2-agents-page')
  if (!AGENT) {
    console.log('INFO no AGENT: nothing written. Pick a test agent from the rows above and re-run with AGENT=<id>.')
  } else {
    /* 3. keep the current list */
    const all = await hub(p, 'GET', '/v1/tenant/agent-senders')
    step('3 the admin reads every list', all.status === 200, { status: all.status })
    before = (all.body?.lists || []).find((l) => l.agent === AGENT.toLowerCase()) || null
    res.before = before
    const dir = await hub(p, 'GET', '/v1/members')
    const others = (dir.body?.members || []).map((m) => m.human_id || m.humanId || m.id).filter((id) => /^HUM-\d+$/.test(String(id)) && id !== me)
    const other = others[0] ? [others[0]] : []
    await p.goto(BASE + '/' + CHANNEL, { waitUntil: 'domcontentloaded', timeout: 60000 })
    await enterSends(p)

    /* 4. listed: the probe member is on the list */
    let put = await hub(p, 'PUT', '/v1/tenant/agent-senders/' + encodeURIComponent(AGENT), { members: [me] })
    step('4 the list names the probe member', put.status === 200 && (put.body?.members || []).includes(me), { status: put.status, members: put.body?.members })
    const ok4 = await send(p, `@${AGENT} SPL-1018 live probe ${RUN}: listed sender, no action needed`)
    step('4 LISTED: the @mention is sent, no refusal line', ok4?.outcome === 'sent', ok4 || {})
    await shot(p, '4-listed-sent')

    /* 5. unlisted: the list names someone else (or nobody) */
    put = await hub(p, 'PUT', '/v1/tenant/agent-senders/' + encodeURIComponent(AGENT), { members: other })
    step('5 the list no longer names the probe member', put.status === 200 && !(put.body?.members || []).includes(me), { status: put.status, members: put.body?.members })
    const text5 = `@${AGENT} SPL-1018 live probe ${RUN}: unlisted sender, must be refused`
    const r5 = await send(p, text5)
    step('5 UNLISTED: refused, the line under the composer names the agent, nothing drawn in the feed', r5?.outcome === 'refused' && r5.line.toLowerCase().includes(AGENT.toLowerCase()) && !r5.fed, r5 || {})
    step('5 the refused text stays in the composer', !!r5 && r5.left === text5, { left: r5 && r5.left })
    await shot(p, '5-unlisted-refused')
    await dismiss(p)

    /* 6. decision 3: a channel post without an @mention is not checked (CONTROL) */
    const r6 = await send(p, `SPL-1018 live probe ${RUN}: a channel post with no mention goes through`)
    step('6 CONTROL: a channel post with no @mention is sent while unlisted', r6?.outcome === 'sent', r6 || {})
  }
} catch (e) {
  step('the proof ran to the end', false, { error: String(e).slice(0, 300) })
  if (p) await shot(p, 'error')
} finally {
  /* 7. put the list back as it was */
  if (p && AGENT && before !== undefined) {
    const back = before
      ? await hub(p, 'PUT', '/v1/tenant/agent-senders/' + encodeURIComponent(AGENT), { members: before.members || [] })
      : await hub(p, 'DELETE', '/v1/tenant/agent-senders/' + encodeURIComponent(AGENT))
    step('7 the agent\'s list is put back as it was', back.status === (before ? 200 : 204), { status: back.status, had_list: Boolean(before) })
  }
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 2))
  await browser.close()
}
console.log(failed ? `sender-allow-live: ${failed} FAILED` : `sender-allow-live: all ${res.steps.length} passed`)
process.exit(failed ? 1 : 0)
