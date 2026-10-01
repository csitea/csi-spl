// CLE-77921 — live proof, signed in, read-only: in Bulgarian, Issues read
// "Дела" (singular "Дело"), never "Проблеми" / "Задачи".
//
// Owner, csitea 7930dfbf: "мм превода е неправилен, трябва да е дела, от дело
// множествено число".
//
// Steps:
//   1. /bg/issues: the page shows "Дела" and the "Ново дело" button
//   2. no visible "Проблем…" or whole-word "Задача"/"Задачи" on the page
//      ("Подзадача" is a subtask and stays)
//   3. a screenshot of the view: <OUT>/issues-bg.png
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=t1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/issues-bg-dela-live.proof.mjs
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
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, steps: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

async function main() {
  const puppeteer = await loadPuppeteer()
  const browser = await puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  })
  try {
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    await nav(p, BASE + '/bg/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Fbg%2Fissues')
    await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
    await p.type('[data-test=native-auth-email]', email)
    await p.type('[data-test=native-auth-password]', pw)
    await p.click('[data-test=native-auth-submit]')
    const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
    step('native sign-in', ok, { url: p.url() })
    if (!ok) throw new Error('not signed in')
    res.build = await p.evaluate(async () => (await fetch('/build.json', { cache: 'no-store' })).json()).catch(() => ({}))
    console.log('build', JSON.stringify(res.build))
    await nav(p, BASE + '/bg/issues')
    await p.waitForSelector('[data-test=issues-filter-deadline-date]', { timeout: 30000 })
    await sleep(2500)
    const t = await p.evaluate(() => document.body.innerText)
    step('bg /issues shows "Дела" and "Ново дело"', /Дела/.test(t) && /Ново дело/.test(t), { lang: await p.evaluate(() => document.documentElement.lang) })
    const stale = [...new Set(t.match(/[Пп]роблем\S*|(?<![А-Яа-я])[Зз]адач[аи](?![А-Яа-я])/g) || [])]
    step('no "Проблем…" / "Задача" / "Задачи" left on the page', stale.length === 0, { stale })
    await p.screenshot({ path: `${OUT}/issues-bg.png` })
  } catch (e) {
    step('run', false, { error: String(e).slice(0, 300) })
  } finally {
    await browser.close()
  }
  writeFileSync(`${OUT}/issues-bg-dela-live.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed}` : 'ALL PASS', `${OUT}/issues-bg-dela-live.json`)
  process.exit(failed ? 1 : 0)
}

main()
