// SPL-994 — live proof, signed in, against a deployed WUI + hub: on a phone
// Back closes the top overlay first. READ-ONLY: it opens the new-channel
// dialog (nothing saved), the avatar sheet and the search sheet, presses
// browser Back, and screenshots each step. Per width it prints
//   SCORE <w> <overlay> ok|BROKEN <before -> after>
// ok = the overlay closed, the URL and data-mobile-level did not move, and a
// second Back popped the level (where there is one below).
//
//   BASE=https://e2e.<domain> TENANT=e2e EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [WIDTHS=390x844,820x1180] node tests/e2e/mobile-overlay-live.proof.mjs
//
// On prd run it only at the e2e tenant's host, never the apex (t1). The
// password is read from PW_FILE and never printed.
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || 't1'
const WIDTHS = (process.env.WIDTHS || '390x844,820x1180').split(',').map((s) => s.split('x').map(Number))
if (new URL(BASE).hostname.split('.').length === 2 && TENANT !== 't1') { console.error('FATAL the apex is the t1 host: use https://<tenant>.<domain>'); process.exit(2) }
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, score: [] }
const score = (w, area, ok, detail) => {
  const line = `SCORE ${w} ${area} ${ok ? 'ok' : 'BROKEN'} ${detail}`
  res.score.push(line)
  console.log(line)
}

/** goto that retries what the box's docker network churn killed. */
async function nav(p, url) {
  let last
  for (let i = 0; i < 4; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 })
      await p.waitForSelector('.sidebar', { timeout: 45000 })
      await sleep(3000)
      return
    } catch (e) {
      last = e
      if (!/ERR_NETWORK_CHANGED|Timeout|ERR_INTERNET_DISCONNECTED/.test(String(e))) throw e
      await sleep(3000)
    }
  }
  throw last
}

const look = (p) => p.evaluate(() => {
  const vis = (s) => [...document.querySelectorAll(s)].some((e) => {
    const r = e.getBoundingClientRect()
    const cs = getComputedStyle(e)
    return cs.display !== 'none' && cs.visibility !== 'hidden' && r.width > 0 && r.height > 0
  })
  return {
    level: document.querySelector('.spool-shell')?.dataset.mobileLevel || null,
    url: location.pathname + location.search,
    dialog: vis('[data-testid=ui-dialog]'),
    menu: vis('[data-test=user-menu-panel]'),
    search: document.querySelector('[data-test=top-bar]')?.classList.contains('top-bar--open') || false,
  }
})

async function tap(p, sel) {
  const h = await p.$(sel)
  if (!h || !(await h.boundingBox())) return false
  await h.tap().catch(() => h.click())
  await sleep(1500)
  return true
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
})
try {
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2F', { waitUntil: 'domcontentloaded', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  await p.waitForFunction(() => !location.pathname.includes('/login') && document.querySelector('.sidebar'), { timeout: 60000 })
  await sleep(2000)
  res.build = await p.evaluate(() => fetch('/build.json').then((r) => r.json()).catch(() => null))
  console.log('build', JSON.stringify(res.build))

  for (const [w, h] of WIDTHS) {
    const key = `${w}x${h}`
    await p.setViewport({ width: w, height: h, isMobile: true, hasTouch: true })
    const shot = (name) => p.screenshot({ path: join(OUT, `${key}_${name}.png`) })
    const flow = async (name, open, is) => {
      const before = await look(p)
      const opened = await open()
      const up = await look(p)
      await shot(`${name}-open`)
      await p.goBack().catch(() => {})
      await sleep(2000)
      const after = await look(p)
      await shot(`${name}-after-back`)
      score(key, name, opened && is(up) && !is(after) && after.url === before.url && after.level === before.level,
        `opened=${opened} ${name} ${is(up)}->${is(after)} url ${before.url}->${after.url} level ${before.level}->${after.level}`)
      return after
    }

    /* level 1: the new-channel dialog (nothing is saved) */
    await nav(p, BASE + '/')
    await tap(p, '[data-testid=sidebar-tab-channels]')
    await flow('dialog', () => tap(p, '[data-testid=create-channel]'), (s) => s.dialog)

    /* level 2 (a channel): the avatar sheet, then a second Back pops 2 -> 1 */
    await tap(p, '[data-testid=sidebar-tab-channels]')
    await p.evaluate(() => document.querySelector('#sidebar-panel-channels .nav-item')?.click())
    await sleep(2500)
    const l2 = await look(p)
    await flow('avatar-sheet', () => tap(p, '[data-test=user-menu-trigger]'), (s) => s.menu)
    await flow('search-sheet', () => tap(p, '[data-test=top-bar-search-toggle]'), (s) => s.search)
    await p.goBack().catch(() => {})
    await sleep(2000)
    const down = await look(p)
    score(key, 'second-back', l2.level === '2' && down.level === '1', `level ${l2.level}->${down.level}`)
  }
} finally {
  writeFileSync(join(OUT, 'results.json'), JSON.stringify(res, null, 2))
  await browser.close()
}
