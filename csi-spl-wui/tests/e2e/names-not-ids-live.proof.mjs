// SPL-1009 - live audit, signed in and read-only: is any HUMAN shown to a
// person by a technical id (HUM-n) where the tenant knows their display name?
//
// Owner, 2026-09-27 (prd t1 topic 3aba968b, after SPL-985): "but still the
// humans are presented with IDs". Rule: a human is shown by display name; the
// id is only a secondary detail (a tooltip, or a muted suffix in the @ list).
// Agents keep their ids. An unknown / nameless id falls back to the id.
//
// Per surface, at 1440 and 390 px, the scan collects every named member's
// HUM-n that is VISIBLE: text nodes, the value of an input / textarea, and a
// title that is the bare id (a tooltip that names nobody). "Name · HUM-n" in
// a title, and the @ list's muted id suffix, are the allowed secondary detail.
//
// Surfaces: the lobby, the @ list in the omnibox and the token a pick leaves
// in the field, a topic with a @HUM mention, a DM (pokes), reactions
// tooltips, /issues (assignee), an issue's detail, a channel's Properties,
// and /search results for "HUM".
//
//   BASE=https://<tenant host> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     TENANT=<tenant> node tests/e2e/names-not-ids-live.proof.mjs
//
// Writes nothing: the omnibox line is cleared, never sent. Exit 1 when any
// named member's id is visible.
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
const WIDTHS = (process.env.WIDTHS || '1440,390').split(',').map(Number)
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], findings: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

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

/**
 * Every visible HUM-n of a NAMED member. `names` is id -> name. The @ list's
 * muted suffix (data-id-suffix) is the allowed secondary detail.
 */
const SCAN = (names) => {
  const named = (s) => [...new Set(String(s || '').match(/\bHUM-\d+\b/g) || [])].filter((id) => names[id])
  const seen = (el) => {
    if (!el || !el.isConnected) return false
    const cs = getComputedStyle(el)
    if (cs.visibility === 'hidden' || cs.display === 'none') return false
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0
  }
  const out = []
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
  for (let n = walk.nextNode(); n; n = walk.nextNode()) {
    const el = n.parentElement
    if (!el || el.closest('[data-id-suffix], script, style')) continue
    const ids = named(n.textContent)
    if (ids.length && seen(el)) out.push({ how: 'text', ids, cls: String(el.className).slice(0, 60), text: n.textContent.trim().slice(0, 80) })
  }
  for (const el of document.querySelectorAll('input, textarea')) {
    const ids = named(el.value)
    if (ids.length && seen(el)) out.push({ how: 'value', ids, cls: String(el.className).slice(0, 60), text: el.value.slice(0, 80) })
  }
  for (const el of document.querySelectorAll('[title]')) {
    const t = el.getAttribute('title') || ''
    /* "Name · HUM-n", or the id as the tooltip of a shown name, is the secondary detail; a title of bare ids names nobody */
    const ids = named(t).filter((id) => !t.includes(names[id]) && !String(el.textContent || '').includes(names[id]))
    if (ids.length && seen(el)) out.push({ how: 'title', ids, cls: String(el.className).slice(0, 60), text: t.slice(0, 80) })
  }
  return out
}

async function signIn(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  p.on('console', (m) => { if (m.type() === 'error') res.console.push(m.text().slice(0, 300)) })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  /* the tenant's display names: the same view-v1 roster read useHumanNames makes */
  p.on('response', async (r) => {
    if (!/\/v1\/view\/roster(\?|$)/.test(r.url()) || r.request().method() !== 'GET' || !r.ok()) return
    const body = await r.json().catch(() => null)
    for (const h of (body && Array.isArray(body.humans) ? body.humans : [])) {
      if (h && /^HUM-\d+$/.test(String(h.human_id || '')) && typeof h.display_name === 'string' && h.display_name.trim()) names[h.human_id] = h.display_name.trim()
    }
  })
  await nav(p, BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby')
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  return p
}

let names = {}
async function audit(p, w, surface, prep) {
  const tag = `${String(w).padStart(4, '0')}-${surface}`
  let note = ''
  try {
    note = (await prep()) || ''
  } catch (e) {
    note = 'prep failed: ' + String(e).slice(0, 120)
  }
  await sleep(1500)
  const hits = await p.evaluate(SCAN, names)
  await shot(p, tag)
  res.findings.push({ width: w, surface, note, hits })
  console.log(hits.length ? 'IDS ' : 'ok  ', tag, note, JSON.stringify(hits.slice(0, 4)))
  return hits
}

const OMNI = '[data-test=top-bar-omnibox] textarea'
const clickFirst = (p, sel) => p.evaluate((s) => { const e = document.querySelector(s); if (!e) return false; e.click(); return true }, sel)

async function main() {
  const puppeteer = await loadPuppeteer()
  const browser = await puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
    protocolTimeout: 60000,
  })
  try {
    res.build = await (await fetch(BASE + '/build.json')).json().catch(() => ({}))
    const p = await signIn(browser)
    await until(() => Object.keys(names).length > 0, 20000)
    res.names = Object.keys(names).length
    res.namedIds = Object.keys(names)
    step('the roster names are loaded', res.names > 0, { n: res.names })

    /* a topic whose rows mention a named member */
    const mentionTask = await p.evaluate(() => {
      const app = document.querySelector('#__nuxt')?.__vue_app__
      const st = app.config.globalProperties.$pinia.state.value
      const rows = []
      const walk = (v, d) => {
        if (!v || typeof v !== 'object' || d > 4) return
        if (Array.isArray(v)) { for (const x of v) if (x && x.msg_id) rows.push(x); else walk(x, d + 1); return }
        for (const x of Object.values(v)) walk(x, d + 1)
      }
      walk(st, 0)
      const m = rows.find((r) => /@HUM-\d+/.test(String(r.body || '')))
      return m ? m.task_id : ''
    }).catch(() => '')
    res.mentionTask = mentionTask

    for (const w of WIDTHS) {
      await p.setViewport({ width: w, height: w < 800 ? 844 : 900, isMobile: w < 800, hasTouch: w < 800 })
      await audit(p, w, '01-lobby', async () => { await nav(p, BASE + '/lobby'); await p.waitForSelector('.msg', { timeout: 30000 }).catch(() => {}); await sleep(2500) })
      await audit(p, w, '02-omnibox-at-list', async () => {
        await p.waitForSelector(OMNI, { visible: true, timeout: 20000 })
        await p.click(OMNI)
        await p.keyboard.type('@HUM')
        await p.waitForSelector('[data-test=mention-list]', { visible: true, timeout: 8000 }).catch(() => {})
      })
      await audit(p, w, '03-omnibox-picked-token', async () => {
        const human = await p.evaluate(() => [...document.querySelectorAll('[data-test=mention-option]')].findIndex((b) => /^HUM-/.test(b.getAttribute('data-id') || '')))
        for (let i = 0; i < human; i++) await p.keyboard.press('ArrowDown')
        await p.keyboard.press('Tab')
        return `picked row ${human}`
      })
      /* clear the line: this proof never sends */
      await p.$eval(OMNI, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) }).catch(() => {})
      if (mentionTask) {
        await audit(p, w, '04-topic-with-mention', async () => { await nav(p, BASE + '/t/' + mentionTask); await p.waitForSelector('.msg', { timeout: 30000 }).catch(() => {}); await sleep(2500) })
      }
      await audit(p, w, '05-dm', async () => {
        await nav(p, BASE + '/lobby')
        await p.waitForSelector('.msg', { timeout: 30000 }).catch(() => {})
        const peer = await p.evaluate(() => [...document.querySelectorAll('a[href*="/dm/"]')].map((x) => x.getAttribute('href'))[0] || '')
        if (peer) await nav(p, BASE + peer)
        await sleep(3000)
        return peer
      })
      await audit(p, w, '06-issues', async () => { await nav(p, BASE + '/issues'); await p.waitForSelector('[data-test=issues-row], [data-test=issues-card-assignee]', { timeout: 30000 }).catch(() => {}) })
      await audit(p, w, '07-issue-detail', async () => {
        const k = await p.evaluate(() => {
          const r = [...document.querySelectorAll('[data-test=issues-row], .issues-card')].find((x) => x.querySelector('[data-assignee^="HUM-"]'))
          if (!r) return ''
          r.click()
          return r.getAttribute('data-key') || '?'
        })
        await sleep(2000)
        return k
      })
      await audit(p, w, '08-channel-properties', async () => {
        await nav(p, BASE + '/lobby')
        await sleep(2500)
        const ch = await p.evaluate(() => [...document.querySelectorAll('a[href*="/channel/"]')].map((x) => x.getAttribute('href'))[0] || '')
        if (ch) await nav(p, BASE + ch)
        await sleep(2500)
        const opened = await clickFirst(p, '[data-testid=channel-properties-open], [data-testid=feed-header-properties], [data-testid=channel-props]')
        return `${ch} opened=${opened}`
      })
      await audit(p, w, '09-search', async () => { await nav(p, BASE + '/search?q=' + encodeURIComponent('HUM')); await p.waitForSelector('[data-test=search-results], [data-test=search-empty]', { timeout: 30000 }).catch(() => {}) })
    }
    const bad = res.findings.filter((f) => f.hits.length)
    step('SPL-1009: no named member is shown by HUM-n on any audited surface', bad.length === 0,
      { surfaces: bad.map((f) => `${f.width} ${f.surface}: ${[...new Set(f.hits.map((h) => h.how + ' ' + h.cls.split(' ')[0]))].join(' | ')}`) })
  } catch (e) {
    step('run', false, { error: String(e).slice(0, 300) })
  } finally {
    await browser.close()
  }
  writeFileSync(`${OUT}/names-not-ids-live.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed}` : 'ALL PASS', `${OUT}/names-not-ids-live.json`)
  process.exit(failed ? 1 : 0)
}

main()
