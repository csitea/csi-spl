// SPL-992 live proof (epic SPL-988, owner topic c397d781): Issues on a phone
// on a deployed WUI, signed in. At 390 and 820 px: the list is cards, Filters
// opens a bottom sheet, a card opens the issue full screen (level 3), Status
// opens as a bottom sheet, Back returns to the cards, no sideways page
// scroll. At 1440 px the sheet (table) is still there. READ-ONLY: nothing is
// picked, typed or created. Screenshots and results.json to OUT.
//
//   BASE=https://<tenant>.<domain> TENANT=<tenant> EMAIL=<member>
//     PW_FILE=<0600 file> OUT=<dir> [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/issues-mobile-live.proof.mjs
//
// The password is read from PW_FILE and never printed. Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
const OUT = need('OUT')
const email = need('EMAIL')
const pw = readFileSync(need('PW_FILE'), 'utf8').trim()
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await browser.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Fissues', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  step('native sign-in', ok)
  if (!ok) throw new Error('not signed in')
  if (!new URL(p.url()).pathname.endsWith('/issues')) await p.goto(BASE + '/issues', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=issues-row]', { visible: true, timeout: 30000 })
  const desk = await p.evaluate(() => ({ table: !!document.querySelector('[data-test=issues-table]'), cards: !!document.querySelector('[data-test=issues-cards]'), fab: getComputedStyle(document.querySelector('[data-test=issues-new]')).position }))
  step('1440: the sheet (table) with the + in the header, no cards', desk.table && !desk.cards && desk.fab !== 'fixed', desk)
  await p.screenshot({ path: `${OUT}/issues-1440.png` })

  for (const vp of [{ width: 390, height: 844 }, { width: 820, height: 1180 }]) {
    const w = vp.width
    await p.setViewport({ ...vp, isMobile: true, hasTouch: true, deviceScaleFactor: 1 })
    await p.goto(BASE + '/issues', { waitUntil: 'networkidle2', timeout: 60000 })
    const seen = await p.waitForSelector('[data-test=issues-card]', { visible: true, timeout: 30000 }).then(() => true, () => false)
    await sleep(800)
    const list = await p.evaluate(() => {
      const fab = document.querySelector('[data-test=issues-new]').getBoundingClientRect()
      return {
        width: innerWidth,
        cards: document.querySelectorAll('[data-test=issues-card]').length,
        table: !!document.querySelector('[data-test=issues-table]'),
        fab: [Math.round(fab.width), Math.round(innerWidth - fab.right), Math.round(innerHeight - fab.bottom)],
        xs: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      }
    })
    step(`${w}: the list is cards, no table, the + floats bottom right, no sideways scroll`, seen && list.width === w && list.cards > 0 && !list.table && list.fab[0] >= 44 && list.fab[1] < 40 && list.fab[2] < 40 && list.xs <= 0, list)
    await p.screenshot({ path: `${OUT}/issues-${w}-list.png` })

    await p.tap('[data-test=issues-filters-open]')
    const sheet = await p.waitForSelector('[data-test=issues-filter-sheet]', { visible: true, timeout: 5000 }).then(() => true, () => false)
    await sleep(300)
    step(`${w}: Filters opens the bottom sheet`, sheet)
    await p.screenshot({ path: `${OUT}/issues-${w}-filters.png` })
    await p.tap('[data-test=issues-filter-sheet-close]')
    await sleep(300)

    const key = await p.$eval('[data-test=issues-card]', (e) => e.getAttribute('data-key'))
    await p.tap(`[data-test=issues-card][data-key="${key}"]`)
    await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 10000 })
    await sleep(800)
    const det = await p.evaluate(() => {
      const r = document.querySelector('[data-test=issues-detail]').getBoundingClientRect()
      return {
        full: Math.round(r.left) <= 0 && Math.round(r.right) >= innerWidth,
        level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level'),
        back: !!document.querySelector('[data-test=issues-detail-back]'),
        talk: !!document.querySelector('[data-test=issues-talk]'),
        xs: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      }
    })
    step(`${w}: a card opens the issue full screen at level 3 with Back and the discussion`, det.full && det.level === '3' && det.back && det.talk && det.xs <= 0, { key, ...det })
    await p.screenshot({ path: `${OUT}/issues-${w}-detail.png` })

    await p.tap('[data-test=issues-status]')
    const menu = await p.waitForSelector('[data-test=issues-menu][data-kind=status]', { visible: true, timeout: 5000 }).then(() => true, () => false)
    await sleep(300)
    const m = menu ? await p.$eval('[data-test=issues-menu]', (e) => { const r = e.getBoundingClientRect(); return { bottom: Math.round(innerHeight - r.bottom), width: Math.round(r.width) } }) : {}
    step(`${w}: Status opens as a bottom sheet`, menu && m.bottom <= 1 && m.width >= w - 1, m)
    await p.screenshot({ path: `${OUT}/issues-${w}-status-sheet.png` })
    await p.tap('[data-test=issues-sheet-scrim]')
    await sleep(300)

    await p.tap('[data-test=issues-detail-back]')
    const back = await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 }).then(() => true, () => false)
    step(`${w}: Back returns to the cards`, back && !!(await p.$('[data-test=issues-card]')))
  }
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
