// SPL-1028 live proof (owner, prd t1 topic 89485c7a): on a deployed WUI +
// hub, 1440 px, the Issues views. The List is the control; By status shows
// one group per status in the workflow order with counts and the hub keeps
// issues_view=status (a reload opens in it); a group's + files a row into
// that status; a drag onto another group changes the status at the hub. Its
// row is deleted and the person's view is put back as found.
//
//   BASE=https://dev.<domain> API=https://dev.api.<domain> EMAIL=<member>
//     (prd: BASE=https://<tenant>.<domain>; writes only when the session's
//     tenant AND the page host are TENANT)
//     PW_FILE=<0600 file> OUT=<dir> [TENANT=t1] [CHROME_PATH=...]
//     [PUPPETEER_CORE=<path>] node tests/e2e/issues-views-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
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
const API = need('API').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, api: API, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const nav = (p, url) => p.goto(url, { waitUntil: 'networkidle2', timeout: 60000 })
const until = async (fn, ms) => { const t0 = Date.now(); for (;;) { const v = await fn().catch(() => null); if (v || Date.now() - t0 > ms) return v; await sleep(300) } }
const row = (key) => `[data-test=issues-row][data-key="${key}"]`
const hubIssue = (p, key) => p.evaluate(async (api, k) => {
  const r = await fetch(`${api}/v1/view/issues/${k}`, { credentials: 'include' })
  return r.ok ? (await r.json()).issue : { status_code: r.status }
}, API, key)

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
  /* the tenant-host guard of issues-live.proof.mjs (6c080b57): nothing is
     written unless the claim AND the page host's tenant are TENANT */
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


/* the person's view as the hub keeps it (the session claim) */
const hubView = (p) => p.evaluate(async (api) => {
  const r = await fetch(`${api}/api/v1/auth/session`, { credentials: 'include' })
  return r.ok ? ((await r.json()).issues_view ?? null) : { status_code: r.status }
}, API)
const layout = (p) => p.evaluate(() => [...document.querySelectorAll('[data-test=issues-group]')].map((g) => ({
  status: g.getAttribute('data-status'), head: Boolean(g.querySelector('[data-test=issues-group-h]')),
  count: Number(g.querySelector('[data-test=issues-group-count]')?.textContent || -1),
  keys: [...g.querySelectorAll('[data-test=issues-row]')].map((r) => r.getAttribute('data-key')),
})))
const ORDER = ['eval', 'todo', 'wip', 'diss', 'blocked', 'onhold', 'qas', 'done']

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
const made = []
let page = null
let original
try {
  res.build = await (await fetch(BASE + '/build.json')).json().catch(() => null)
  res.hub = await (await fetch(API + '/version')).json().catch(() => null)
  const p = await signIn(browser)
  page = p
  await nav(p, BASE + '/issues')
  await p.waitForSelector('[data-test=issues-views]', { visible: true, timeout: 30000 })
  original = await hubView(p)
  res.original_view = original
  /* start from the list whatever the account had (restored at the end) */
  if (original === 'status') { await p.click('[data-test=issues-view][data-value="list"]'); await sleep(800) }
  const l0 = await layout(p)
  step('control: the List view is one flat group with no headers', l0.length === 1 && !l0[0].head, { groups: l0.length })

  await p.click('[data-test=issues-view][data-value="status"]')
  await p.waitForSelector('[data-test=issues-group-h]', { visible: true, timeout: 8000 })
  const s1 = await layout(p)
  const stored = await until(async () => ((await hubView(p)) === 'status' ? 'status' : null), 8000)
  step('By status: one group per status in the workflow order with its count; the hub keeps issues_view=status',
    JSON.stringify(s1.map((g) => g.status)) === JSON.stringify(ORDER) && s1.every((g) => g.head && g.count >= g.keys.length) && stored === 'status',
    { order: s1.map((g) => `${g.status}:${g.count}`), stored })
  await p.screenshot({ path: `${OUT}/views-status.png` })

  await nav(p, BASE + '/issues')
  await p.waitForSelector('[data-test=issues-views]', { visible: true, timeout: 30000 })
  const kept = await until(() => p.$$eval('[data-test=issues-group-h]', (els) => els.length || null), 10000)
  step('a reload opens the page in the person\'s view (By status)', kept === 8, { heads: kept })

  /* a group's + files the row into that status */
  await p.click('[data-test=issues-group][data-status="onhold"] [data-test=issues-group-add]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 8000 })
  const stamp = `spl1028 ${Date.now().toString(36)}`
  await p.type('[data-test=issues-newrow-title]', stamp)
  await p.keyboard.press('Enter')
  const key = await until(() => p.evaluate((want) => {
    const r = [...document.querySelectorAll('[data-test=issues-group][data-status="onhold"] [data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === want)
    return r ? r.getAttribute('data-key') : null
  }, stamp), 10000)
  if (key) made.push(key)
  const hubNew = key ? await hubIssue(p, key) : null
  step('a group\'s + stores the new row in that status (06-onhold) and it shows in that group', Boolean(key) && hubNew?.status === 'onhold', { key, status: hubNew?.status })

  if (key) {
    /* drag it onto 05-blocked (the page's drag handlers, a real DataTransfer) */
    await p.evaluate((k) => {
      const src = document.querySelector(`[data-test=issues-row][data-key="${k}"]`)
      const dst = document.querySelector('[data-test=issues-group][data-status="blocked"]')
      const dt = new DataTransfer()
      src.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: dt }))
      dst.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt }))
      dst.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt }))
      src.dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true, dataTransfer: dt }))
    }, key)
    const moved = await until(async () => ((await hubIssue(p, key))?.status === 'blocked' ? true : null), 10000)
    const inGroup = await p.$(`[data-test=issues-group][data-status="blocked"] [data-test=issues-row][data-key="${key}"]`).then(Boolean)
    step('dragged onto 05-blocked: the hub holds status blocked and the row sits in that group', Boolean(moved) && inGroup, { moved, inGroup })

    /* clean up: delete the row (the SPL-1027 confirm) */
    await p.click(`[data-test=issues-row][data-key="${key}"] [data-test=issues-row-delete]`)
    await p.waitForSelector('[data-testid=issues-delete-confirm]', { visible: true, timeout: 8000 })
    await p.click('[data-testid=issues-delete-confirm]')
    const gone = await until(async () => ((await hubIssue(p, key))?.status_code === 404 ? true : null), 10000)
    if (gone) made.splice(made.indexOf(key), 1)
    step('its row is deleted again (hub 404)', Boolean(gone))
  }
  const noise = res.console.filter((c) => !/favicon|ResizeObserver loop|Failed to load resource/.test(c))
  step('no page errors', noise.length === 0, { noise: noise.slice(0, 5) })
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  /* put the person's view back as found (null = never picked) */
  if (page && original !== undefined && (original === null || typeof original === 'string')) {
    res.restored = await page.evaluate(async (api, v) => {
      const r = await fetch(`${api}/api/v1/auth/preferences`, { method: 'PUT', credentials: 'include', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ issues_view: v }) })
      return r.status
    }, API, original).catch((e) => String(e))
  }
  res.left_behind = made
  if (made.length) console.log('LEFT BEHIND (delete by hand):', made.join(' '))
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
console.log(`${res.steps.length - failed}/${res.steps.length} PASS; build ${res.build && res.build.commit}; hub ${res.hub && res.hub.commit}; view restored ${res.restored}`)
process.exit(failed ? 1 : 0)
