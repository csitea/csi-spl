// SPL-962 / SPL-955 / SPL-16 / SPL-6 — live proof, signed in, against a
// deployed WUI + hub. Read-only: it types into the Issues filter and drags the
// dividers, and saves nothing.
//
// Owner, 2026-09-26: "the deadline format for the dates as well as all of the
// dates in the ui MUST be yyyy-mm-dd - USE ONLY this format".
//
// Steps, once per UI locale in LOCALES (default en,bg):
//   1. /issues: ONE Deadline filter, a text box with placeholder YYYY-MM-DD
//      (never a native date input), and no All issues row (SPL-955)
//   2. typing 2026-09-30 into it keeps 2026-09-30; every issue row deadline
//      and the open issue's deadline box read YYYY-MM-DD (SPL-962)
//   3. /lobby, /events, /settings/keys, /users: every absolute date on the
//      page is YYYY-MM-DD[ HH:MM]; no d/m/y, m/d/y or month-name date (SPL-962)
//   4. no visible member id (HUM-n) on those pages (SPL-6)
// Once (en): the left-most divider on /issues drags the side panel wider and
// narrower, by pointer and by keyboard (SPL-16).
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=t1] [LOCALES=en,bg] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/iso-dates-live.proof.mjs
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
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const LOCALES = (process.env.LOCALES || 'en,bg').split(',').map((s) => s.trim()).filter(Boolean)
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const shot = async (p, name) => { await p.screenshot({ path: `${OUT}/${name}.png` }).catch(() => {}) }

/** goto that retries what the box's docker network churn killed. */
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

/*
 * Every date-looking run of visible text on the page, split into ISO ones and
 * the rest. A non-ISO date is d/m/y, m/d/y, d.m.y, d-m-yyyy, or a day next to
 * a month name in en or bg. A version (0.8.6) is not a date.
 */
const SCAN = () => {
  const text = document.body.innerText
  const iso = text.match(/\b\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2})?\b/g) || []
  const bad = []
  const pats = [
    /\b\d{1,2}\/\d{1,2}\/\d{2,4}\b/g,
    /\b\d{1,2}\.\d{1,2}\.\d{4}\b/g,
    /\b\d{1,2}-\d{1,2}-\d{4}\b/g,
    /\b\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?(?:\s+\d{4})?\b/g,
    /\b(?:Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}(?:,?\s+\d{4})?\b/g,
    /\d{1,2}\s+(?:яну|фев|мар|апр|май|юни|юли|авг|сеп|окт|ное|дек)[а-я]*\.?(?:\s+\d{4}\s*г\.?)?/gi,
    /\d{4}\s*г\./g,
  ]
  for (const re of pats) for (const m of text.matchAll(re)) bad.push(m[0])
  const ids = [...new Set(text.match(/\bHUM-\d+\b/g) || [])]
  /* where each visible id sits: the element's class and the text around it */
  const where = []
  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
  for (let n = walk.nextNode(); n && where.length < 8; n = walk.nextNode()) {
    const el = n.parentElement
    if (!/\bHUM-\d+\b/.test(n.textContent) || !el || !el.offsetParent) continue
    where.push({ cls: String(el.className).slice(0, 50), text: n.textContent.trim().slice(0, 60), title: el.closest('[title]')?.getAttribute('title')?.slice(0, 60) || '' })
  }
  return { iso: iso.slice(0, 6), isoCount: iso.length, bad: bad.slice(0, 12), ids, where }
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
  return p
}

const pfx = (loc) => (loc === 'en' ? '' : '/' + loc)

async function issuesChecks(p, loc) {
  await nav(p, BASE + pfx(loc) + '/issues')
  await p.waitForSelector('[data-test=issues-filter-deadline-date]', { timeout: 30000 })
  await sleep(2500)
  const f = await p.evaluate(() => {
    const boxes = [...document.querySelectorAll('[data-test=issues-filter-deadline-date]')]
    const row = document.querySelector('[data-test=issues-filter-deadline]')
    return {
      n: boxes.length,
      type: boxes[0]?.type,
      placeholder: boxes[0]?.placeholder,
      label: row?.innerText.trim(),
      nativeDate: document.querySelectorAll('input[type=date], input[type=datetime-local]').length,
      allIssuesRow: !!document.querySelector('[data-testid=sidebar-issues-open]'),
      lang: document.documentElement.lang,
    }
  })
  step(`${loc} 1 issues: one Deadline filter, text YYYY-MM-DD, no native date input, no All issues row (SPL-955)`,
    f.n === 1 && f.type === 'text' && f.placeholder === 'YYYY-MM-DD' && f.nativeDate === 0 && !f.allIssuesRow, f)

  await p.click('[data-test=issues-filter-deadline-date]', { clickCount: 3 })
  await p.type('[data-test=issues-filter-deadline-date]', '2026-09-30')
  await p.keyboard.press('Tab')
  await sleep(800)
  const typed = await p.$eval('[data-test=issues-filter-deadline-date]', (e) => e.value)
  await p.click('[data-test=issues-filter-deadline-date]', { clickCount: 3 })
  await p.keyboard.press('Backspace')
  await p.keyboard.press('Tab')
  await sleep(800)

  const rows = await p.evaluate(() => [...document.querySelectorAll('.issues-when')].map((e) => e.textContent.trim()).slice(0, 10))
  /* open the first issue that has a deadline, else the first issue */
  const opened = await p.evaluate(() => {
    const all = [...document.querySelectorAll('[data-test=issues-row]')]
    const r = all.find((x) => x.querySelector('.issues-when')) || all[0]
    if (!r) return ''
    r.click()
    return r.getAttribute('data-key') || '?'
  })
  let detail = null
  if (opened) {
    await p.waitForSelector('[data-test=issues-deadline]', { timeout: 15000 }).catch(() => {})
    await sleep(1000)
    detail = await p.evaluate(() => {
      const d = document.querySelector('[data-test=issues-deadline]')
      return d ? { type: d.type, placeholder: d.placeholder, value: d.value } : null
    })
  }
  const isoRe = /^\d{4}-\d{2}-\d{2}( \d{2}:\d{2})?$/
  step(`${loc} 2 issues: the typed deadline stays ISO; rows and the open issue's deadline are YYYY-MM-DD (SPL-962)`,
    typed === '2026-09-30' && rows.every((s) => isoRe.test(s)) &&
      (!detail || (detail.type === 'text' && detail.placeholder === 'YYYY-MM-DD' && (detail.value === '' || isoRe.test(detail.value)))),
    { typed, rows, opened, detail })
  const scan = await p.evaluate(SCAN)
  step(`${loc} 3 /issues: no non-ISO date`, scan.bad.length === 0, scan)
  await shot(p, `${loc}-issues`)
  return scan
}

async function pageScan(p, loc, path, ready) {
  await nav(p, BASE + pfx(loc) + path)
  if (ready) await p.waitForSelector(ready, { timeout: 30000 }).catch(() => {})
  await sleep(4000)
  const scan = await p.evaluate(SCAN)
  step(`${loc} 3 ${path}: every absolute date is YYYY-MM-DD, none other (SPL-962)`, scan.bad.length === 0, scan)
  await shot(p, `${loc}-${path.replace(/\W+/g, '_')}`)
  return scan
}

async function dividerChecks(p) {
  await nav(p, BASE + '/issues')
  await p.waitForSelector('[data-test=issues-filter-deadline-date]', { timeout: 30000 })
  await sleep(2000)
  const sel = '[data-testid=pane-divider-sidebar]'
  const width = () => p.evaluate(() => Math.round(document.querySelector('nav.sidebar')?.getBoundingClientRect().width || 0))
  const div = await p.$(sel)
  if (!div) { step('SPL-16 the left-most divider on /issues exists', false, {}); return }
  const rail = await p.evaluate(() => !!document.querySelector('nav.sidebar--rail'))
  const w0 = await width()
  const box = await div.boundingBox()
  const x = box.x + box.width / 2
  const y = box.y + box.height / 2
  await p.mouse.move(x, y)
  await p.mouse.down()
  for (let i = 1; i <= 8; i++) await p.mouse.move(x + i * 10, y)
  await p.mouse.up()
  await sleep(500)
  const w1 = await width()
  await div.focus()
  for (let i = 0; i < 4; i++) await p.keyboard.press('ArrowLeft')
  await sleep(500)
  const w2 = await width()
  step('SPL-16 /issues: the left-most divider drags the side panel (pointer +80 px, then 4x ArrowLeft)',
    w1 > w0 && w2 < w1, { rail, w0, afterDrag: w1, afterKeys: w2 })
  await shot(p, 'issues-divider')
  /* put the width back */
  await p.evaluate((s) => document.querySelector(s)?.dispatchEvent(new MouseEvent('dblclick', { bubbles: true })), sel)
}

async function main() {
  const puppeteer = await loadPuppeteer()
  const browser = await puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  })
  try {
    const p = await signIn(browser)
    res.build = await p.evaluate(async () => (await fetch('/build.json', { cache: 'no-store' })).json()).catch(() => ({}))
    console.log('build', JSON.stringify(res.build))
    const idsSeen = {}
    for (const loc of LOCALES) {
      idsSeen[`${loc} /issues`] = (await issuesChecks(p, loc)).ids
      for (const [path, ready] of [['/lobby', '.msg-time'], ['/events', '[data-test=events-page]'], ['/settings/keys', '[data-test=keys]'], ['/users', null]]) {
        idsSeen[`${loc} ${path}`] = (await pageScan(p, loc, path, ready)).ids
      }
    }
    const hover = await p.evaluate(() => [...document.querySelectorAll('[title*="HUM-"]')].slice(0, 6)
      .map((e) => ({ text: e.textContent.trim().slice(0, 40), title: e.getAttribute('title').slice(0, 60) })))
    const shown = Object.entries(idsSeen).filter(([, v]) => v.length)
    step('SPL-6 no visible HUM-n member id on issues, lobby, events, keys, users', shown.length === 0, { shown, hoverOnUsers: hover })
    await dividerChecks(p)
  } catch (e) {
    step('run', false, { error: String(e).slice(0, 300) })
  } finally {
    await browser.close()
  }
  writeFileSync(`${OUT}/iso-dates-live.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed}` : 'ALL PASS', `${OUT}/iso-dates-live.json`)
  process.exit(failed ? 1 : 0)
}

main()
