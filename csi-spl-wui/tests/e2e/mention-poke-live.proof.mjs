// SPL-985 (spec 042) - live proof, signed in: the @ picker in three inputs and
// the poke DM each mention sends.
//
// Owner, 2026-09-26 (prd t1 topic 3aba968b): "typing the @ should invoke the
// drop box to select, which contains agents or people" + "those agents or
// people should get poked in their personal msgs".
//
// Steps (n = 1 per run), as the test member on the test tenant only:
//   1. top-bar omnibox on /lobby: `@<frag>` opens the list, the agent is in
//      it, Enter PICKS (the line is not sent), Ctrl+Enter then sends
//   2. a new issue: `@<frag>` + Tab picks in the description, Create
//   3. that issue's comment box: `@<frag>` + Enter picks, Ctrl+Enter sends
//   4. an edit of the description that keeps the same mention pokes nobody
//   5. the member's DM with AGENT holds exactly three poke DMs of this run:
//      "<member> needs you in <link>: ..." - one /t/<task>, two /issues?issue=KEY
//
//   BASE=https://<tenant host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     TENANT=<tenant> AGENT=<id@box> node tests/e2e/mention-poke-live.proof.mjs
//
// Refuses to write unless the session's tenant AND the page host's tenant are
// TENANT. The password is read from PW_FILE and never printed. Never point
// AGENT at a person: the poke is a real DM.
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
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const run = Date.now().toString(36)
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

/** goto / reload that retries what the box's docker network churn killed. */
async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      if (url) await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      else await p.reload({ waitUntil: 'domcontentloaded', timeout: 60000 })
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
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  /* Nothing is written unless BOTH the session's tenant (claim t) and the
     tenant the page writes to are TENANT. With tenant hosts on (SPL-959) the
     WUI writes to the page host's tenant (useSpoolApi hostTenant: the apex is
     t1) whatever the claim says: on 2026-09-26 this proof wrote SPL-967..970
     into prd t1 from the apex, one run with the claim reading e2e. On prd run
     it at https://<tenant>.<domain>. */
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
  step('the session AND the page host are in TENANT before anything is written', inTenant, { want: TENANT, ...where, url: p.url() })
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  return p
}


const AGENT = need('AGENT')
const [agentId] = AGENT.split('@')
const frag = agentId.slice(0, -1)
const OMNI = '[data-test=top-bar-omnibox] textarea'
const listHas = (p) => until(() => p.evaluate((id) => {
  const l = document.querySelector('[data-test=mention-list]')
  return l ? [...l.querySelectorAll('[data-test=mention-option]')].map((b) => b.getAttribute('data-id')).includes(id) : false
}, agentId), 10000)
const ctrlEnter = async (p) => { await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control') }
const val = (p, sel) => p.$eval(sel, (el) => el.value)
/* a refused (K4) or failed (K6) poke is a snackbar line: none may show here */
const snack = (p) => p.evaluate(() => [...document.querySelectorAll('[data-test=error-snackbar-item]')].map((e) => e.textContent.trim().slice(0, 160)))

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
  protocolTimeout: 60000,
})
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await signIn(browser)
  // 1 the omnibox
  await p.waitForSelector(OMNI, { visible: true, timeout: 30000 })
  await p.click(OMNI)
  await p.keyboard.type(`SPL-985 proof ${run} omnibox, please look @${frag}`)
  const omniList = await listHas(p)
  await shot(p, '01-omnibox-list')
  await p.keyboard.press('Enter')
  await sleep(400)
  const omniText = await val(p, OMNI)
  step('1a omnibox: @ opens the list with the agent; Enter picks and does not send', omniList && omniText.endsWith(`@${AGENT} `), { omniList, omniText })
  await ctrlEnter(p)
  const sent1 = await until(() => val(p, OMNI).then((v) => v === ''), 10000)
  await sleep(3000)
  const snack1 = await snack(p)
  step('1b Ctrl+Enter sends the line; no poke warning', sent1 && snack1.length === 0, { snack1 })

  // 2 a new issue, the mention in its description
  await nav(p, BASE + '/issues')
  await p.waitForSelector('[data-test=issues-new]', { visible: true, timeout: 30000 })
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  const title = `SPL-985 proof ${run} issue`
  await p.type('[data-test=issues-detail-title]', title)
  await p.click('[data-test=issues-detail-body]')
  await p.keyboard.type(`description asks @${frag}`)
  const descList = await listHas(p)
  await shot(p, '02-description-list')
  await p.keyboard.press('Tab')
  await sleep(300)
  const descText = await val(p, '[data-test=issues-detail-body]')
  step('2a new-issue description: @ opens the list; Tab picks', descList && descText.endsWith(`@${AGENT} `), { descList, descText })
  /* a level-2 issue needs an epic; a feature is top-level and needs none */
  for (let i = 0; i < 3; i++) {
    if (await p.$eval('[data-test=issues-kind]', (b) => b.getAttribute('data-kind')) === 'feature') break
    await p.click('[data-test=issues-kind]')
    await sleep(200)
  }
  await p.click('[data-test=issues-create]')
  const key = await until(() => p.evaluate((want) => {
    const t = document.querySelector('[data-test=issues-detail-title]')
    const k = document.querySelector('[data-test=issues-detail-key]')
    return !document.querySelector('[data-test=issues-create]') && t && t.value === want && k ? k.textContent.trim() : ''
  }, title), 30000)
  step('2b the issue is created', Boolean(key), { key })
  if (!key) throw new Error('no key')

  // 3 its comment box
  await p.waitForSelector('[data-test=issues-comment-input]', { visible: true, timeout: 15000 })
  await p.click('[data-test=issues-comment-input]')
  await p.keyboard.type(`SPL-985 proof ${run} comment for @${frag}`)
  const comList = await listHas(p)
  await shot(p, '03-comment-list')
  await p.keyboard.press('Enter')
  await sleep(300)
  const comText = await val(p, '[data-test=issues-comment-input]')
  step('3a comment: @ opens the list; Enter picks and does not send', comList && comText.endsWith(`@${AGENT} `), { comList, comText })
  await ctrlEnter(p)
  const sent3 = await until(() => val(p, '[data-test=issues-comment-input]').then((v) => v === ''), 10000)
  await sleep(3000)
  const snack3 = await snack(p)
  step('3b Ctrl+Enter sends the comment; no poke warning', sent3 && snack3.length === 0, { snack3 })

  // 4 an edit that keeps the mention: no new poke
  await p.click('[data-test=issues-detail-rendered]')
  await p.waitForSelector('[data-test=issues-detail-body]', { visible: true, timeout: 5000 })
  await p.focus('[data-test=issues-detail-body]')
  await p.keyboard.press('End')
  await p.keyboard.type(' (edited)')
  await p.click('[data-test=issues-detail-key]')
  await sleep(4000)

  // 5 the DMs, as the member reads them
  const want = { t: 1, issue: 2 }
  let got = null
  const pokes = await until(async () => {
    await nav(p, `${BASE}/dm/${encodeURIComponent(AGENT)}`)
    await sleep(5000)
    got = await p.evaluate((r) => {
      const g = document.querySelector('#__nuxt')?.__vue_app__?.config.globalProperties
      const ms = (g && g.$pinia && g.$pinia.state.value.channel && g.$pinia.state.value.channel.messages) || []
      /* the author is named by bare id: the member's own HUM id, and the row is from them */
      return ms.filter((m) => /^HUM-\d+ needs you in /.test(String(m.body || '')) && String(m.body || '').includes(r))
        .map((m) => ({ from: m.from, to: m.to, kind: m.kind, body: m.body, author: String(m.body).split(' ')[0] }))
    }, run)
    return got && got.length >= 3 ? got : null
  }, 60000)
  const rows = pokes || got || []
  const tLinks = rows.filter((m) => m.body.includes(`${BASE}/t/`)).length
  const iLinks = rows.filter((m) => m.body.includes(`/issues?issue=${key}`)).length
  await shot(p, '05-dm')
  step('5 exactly three poke DMs to the agent: one card link, two issue links, none for the edit', rows.length === 3 && tLinks === want.t && iLinks === want.issue && rows.every((m) => m.to === agentId && m.author === m.from),
    { n: rows.length, tLinks, iLinks, rows })
  res.key = key
} catch (e) {
  step('run', false, { error: String(e).slice(0, 300) })
} finally {
  await browser.close()
}
res.run = run
res.failed = failed
writeFileSync(`${OUT}/result.json`, JSON.stringify(res, null, 2))
console.log(failed ? `FAILED ${failed}` : 'ALL PASS', `n=1 run=${run}`)
process.exit(failed ? 1 : 0)
