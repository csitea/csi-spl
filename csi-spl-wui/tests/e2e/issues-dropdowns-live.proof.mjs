// SPL-972 / SPL-973 - live proof, signed in, against a deployed WUI + hub.
//
// Owner, topic e0f6f074: every dropdown on the Issues page closes on a click
// outside it and on Esc; prio (sheet cells + side panel) and level (sheet
// cells) are select boxes ("not dropdowns but dropboxes"). Owner, topic
// 593a804a: no Comment button; the deadline box is as wide as its text.
//
// Steps:
//   1. a sheet row's Status list opens, and closes on an outside click, then on Esc
//   2. the Status filter list closes on an outside click and on Esc
//   3. the deadline calendar closes on Esc and on an outside click
//   4. every Prio and Level cell is a select box (1..5 / 1..3); so is the side panel's prio
//   5. no Comment button; the comment box says Enter sends
//   6. the deadline box fits "YYYY-MM-DD HH:MM"
//   7. WRITE=1 only: a row's prio changed in its select box is still there
//      after a reload, then set back (never on a tenant that is not a test one)
//
//   BASE=https://dev.<domain> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir>
//     [TENANT=t1] [WRITE=1] [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/issues-dropdowns-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
const TENANT = process.env.TENANT || ''
const WRITE = process.env.WRITE === '1'
mkdirSync(OUT, { recursive: true })

const res = { base: BASE, at: new Date().toISOString(), tenant: TENANT, write: WRITE, steps: [], console: [] }
let failed = 0
const step = (name, ok, ev = {}) => {
  res.steps.push({ name, ok, ...ev })
  if (!ok) failed++
  console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev))
}
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

async function signIn(browser) {
  const p = await browser.newPage()
  await p.setViewport({ width: 1920, height: 1080 })
  p.on('pageerror', (e) => res.console.push('pageerror: ' + String(e).slice(0, 300)))
  const q = TENANT ? `?tenant=${encodeURIComponent(TENANT)}&` : '?'
  await nav(p, `${BASE}/login${q}redirect=%2Fissues`)
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok, { url: p.url() })
  if (!ok) throw new Error('not signed in')
  return p
}

const up = (p, sel) => p.$(sel).then(Boolean)
const visible = (p, sel) => p.$eval(sel, (el) => getComputedStyle(el).display !== 'none' && el.offsetParent !== null).catch(() => false)

async function main() {
  const puppeteer = await loadPuppeteer()
  const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
  try {
    const p = await signIn(browser)
    await nav(p, BASE + '/issues')
    await p.waitForSelector('[data-test=issues-row]', { timeout: 30000 })
    await sleep(2000)
    res.build = await p.evaluate(async () => (await fetch('/build.json', { cache: 'no-store' })).json()).catch(() => ({}))
    console.log('build', JSON.stringify(res.build))

    /* 1. a row's Status list */
    await p.click('[data-test=issues-row] [data-test=issues-row-status]')
    const a1 = await up(p, '[data-test=issues-menu]')
    await shot(p, 'row-status-open')
    await p.click('[data-test=issues-heading]')
    const a2 = await up(p, '[data-test=issues-menu]')
    await p.click('[data-test=issues-row] [data-test=issues-row-status]')
    const a3 = await up(p, '[data-test=issues-menu]')
    await p.keyboard.press('Escape')
    const a4 = await up(p, '[data-test=issues-menu]')
    step("1 a row's Status list closes on an outside click and on Esc", a1 && !a2 && a3 && !a4, { openedA: a1, afterOutside: a2, openedB: a3, afterEsc: a4 })

    /* 2. the Status filter list */
    await p.click('[data-test=issues-filter-status-btn]')
    const b1 = await visible(p, '.issues-status-dd__list')
    await p.click('[data-test=issues-heading]')
    const b2 = await visible(p, '.issues-status-dd__list')
    await p.click('[data-test=issues-filter-status-btn]')
    const b3 = await visible(p, '.issues-status-dd__list')
    await p.keyboard.press('Escape')
    const b4 = await visible(p, '.issues-status-dd__list')
    step('2 the Status filter list closes on an outside click and on Esc', b1 && !b2 && b3 && !b4, { openedA: b1, afterOutside: b2, openedB: b3, afterEsc: b4 })

    /* 3. the deadline calendar (the filter's) */
    await p.click('[data-test=issues-filter-deadline-date-open]')
    const c1 = await up(p, '[data-test=deadline-picker]')
    await p.keyboard.press('Escape')
    const c2 = await up(p, '[data-test=deadline-picker]')
    await p.click('[data-test=issues-filter-deadline-date-open]')
    const c3 = await up(p, '[data-test=deadline-picker]')
    await p.click('[data-test=issues-heading]')
    const c4 = await up(p, '[data-test=deadline-picker]')
    step('3 the deadline calendar closes on Esc and on an outside click', c1 && !c2 && c3 && !c4, { openedA: c1, afterEsc: c2, openedB: c3, afterOutside: c4 })

    /* 4. select boxes */
    const cells = await p.evaluate(() => {
      const rows = [...document.querySelectorAll('[data-test=issues-row]')]
      const opt = (el) => (el ? [...el.options].map((o) => o.value).join() : '')
      return {
        rows: rows.length,
        prioSelects: rows.filter((r) => r.querySelector('[data-test=issues-row-priority]')?.tagName === 'SELECT').length,
        levelSelects: rows.filter((r) => r.querySelector('[data-test=issues-row-level]')?.tagName === 'SELECT').length,
        prioOpts: opt(rows[0]?.querySelector('[data-test=issues-row-priority]')),
        levelOpts: opt(rows[0]?.querySelector('[data-test=issues-row-level]')),
        prioMatches: rows.every((r) => r.querySelector('[data-test=issues-row-priority]').value === r.getAttribute('data-priority')),
      }
    })
    await p.click('[data-test=issues-row] .issues-c-key')
    await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 15000 })
    await sleep(800)
    const side = await p.$eval('[data-test=issues-priority]', (el) => ({ tag: el.tagName, opts: [...el.options].map((o) => o.value).join() })).catch(() => ({}))
    step('4 every Prio and Level cell is a select box, and so is the side panel prio',
      cells.rows > 0 && cells.prioSelects === cells.rows && cells.levelSelects === cells.rows && cells.prioOpts === '1,2,3,4,5' && cells.levelOpts === '1,2,3' && cells.prioMatches &&
        side.tag === 'SELECT' && side.opts === '1,2,3,4,5', { ...cells, side })
    await shot(p, 'sheet-and-detail')

    /* 5. no Comment button */
    const talk = await p.evaluate(() => ({
      sendButton: !!document.querySelector('[data-test=issues-comment-send]'),
      buttonNamedComment: [...document.querySelectorAll('[data-test=issues-detail] button')].some((b) => /^comment$/i.test(b.textContent.trim())),
      hint: document.querySelector('[data-test=issues-comment-input]')?.getAttribute('placeholder') || '',
    }))
    step('5 no Comment button; the comment box says Enter sends', !talk.sendButton && !talk.buttonNamedComment && /enter/i.test(talk.hint), talk)

    /* 6. deadline width */
    const dl = await p.$eval('[data-test=issues-deadline]', (el) => {
      const probe = document.createElement('span')
      const cs = getComputedStyle(el)
      probe.style.cssText = `position:absolute;visibility:hidden;white-space:pre;font:${cs.font};font-variant-numeric:tabular-nums`
      probe.textContent = '2026-09-26 17:45'
      document.body.appendChild(probe)
      const text = probe.getBoundingClientRect().width
      probe.remove()
      return { box: Math.round(el.getBoundingClientRect().width), text: Math.round(text) }
    })
    step('6 the deadline box fits YYYY-MM-DD HH:MM and no more', dl.box >= dl.text && dl.box <= dl.text + 40, dl)

    /* 7. a prio change is stored (dev / test tenants only) */
    if (WRITE) {
      const row = await p.$eval('[data-test=issues-row]', (el) => ({ key: el.getAttribute('data-key'), prio: el.getAttribute('data-priority') }))
      const want = row.prio === '5' ? '4' : '5'
      const sel = `[data-test=issues-row][data-key="${row.key}"] [data-test=issues-row-priority]`
      await p.select(sel, want)
      await sleep(2500)
      await nav(p, BASE + '/issues')
      await p.waitForSelector(`[data-test=issues-row][data-key="${row.key}"]`, { timeout: 30000 })
      await sleep(1500)
      const after = await p.$eval(`[data-test=issues-row][data-key="${row.key}"]`, (el) => el.getAttribute('data-priority'))
      await p.select(sel, row.prio)
      await sleep(2500)
      step("7 a row's prio set in its select box is still there after a reload (then set back)", after === want, { key: row.key, was: row.prio, want, afterReload: after })
    }
  } catch (e) {
    step('run', false, { error: String(e).slice(0, 300) })
  } finally {
    await browser.close()
  }
  writeFileSync(`${OUT}/issues-dropdowns-live.json`, JSON.stringify(res, null, 2))
  console.log(failed ? `FAIL ${failed}` : 'ALL PASS', `${OUT}/issues-dropdowns-live.json`)
  process.exit(failed ? 1 : 0)
}

main()
