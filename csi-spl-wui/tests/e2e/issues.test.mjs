// Issues screen in a real browser (GRK-3519). Mock mode starts with an empty
// catalogue (the shared issues mock), so the test creates the rows it reads.
//
//   pnpm run test:e2e:issues
//   BASE_URL=<generated bundle> pnpm run test:e2e:issues
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
// A fresh dir per run: a fixed /tmp path is owned by whoever ran first, and
// the CI runner user then gets EACCES (gate runs 36227035545 ff.).
const SHOTS = process.env.ISSUES_SHOTS || mkdtempSync(join(tmpdir(), 'spool-issues-'))

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function create(p, title, body) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-detail-title]', { clickCount: 3 })
  await p.type('[data-test=issues-detail-title]', title)
  if (body) {
    await p.click('[data-test=issues-detail-body]')
    await p.type('[data-test=issues-detail-body]', body)
  }
  await p.click('[data-test=issues-create]')
  await p.waitForFunction((want) => {
    const el = document.querySelector('[data-test=issues-detail-title]')
    return el && el.value === want
  }, { timeout: 5000 }, title)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const rail = await p.$$eval('.sidebar-rail [role=tab]', (els) => els.map((e) => e.getAttribute('data-testid')))
  ok('1 Issues is the third rail tab, after Channels', rail[0] === 'sidebar-tab-dm' && rail[1] === 'sidebar-tab-channels' && rail[2] === 'sidebar-tab-issues' && rail.indexOf('sidebar-tab-events') > rail.indexOf('sidebar-tab-issues'), rail)
  await p.click('[data-testid=sidebar-tab-issues]')
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  ok('2 the tab opens /issues', new URL(p.url()).pathname.endsWith('/issues'), p.url())

  await create(p, 'The first read drops', 'Only in the detail')
  await create(p, 'Show the display name', '')
  const listText = await p.$eval('[data-test=issues-list]', (el) => el.innerText)
  ok('3 the list shows the key and not the description', listText.includes('SPL-1') && listText.includes('The first read drops') && !listText.includes('Only in the detail'), listText.slice(0, 280))

  await p.click('[data-test=issues-row][data-key="SPL-1"]')
  await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 5000 })
  const body = await p.$eval('[data-test=issues-detail-body]', (el) => el.value)
  const deadlineType = await p.$eval('[data-test=issues-deadline]', (el) => el.type)
  const side = await p.evaluate(() => {
    const list = document.querySelector('[data-test=issues-list]').getBoundingClientRect()
    const pane = document.querySelector('[data-test=issues-detail]').getBoundingClientRect()
    return { paneRight: pane.left >= list.right - 2 }
  })
  ok('4 the right pane shows the description and a calendar with time', body === 'Only in the detail' && deadlineType === 'datetime-local' && side.paneRight, { body, deadlineType, side })

  await p.click('[data-test=issues-status]')
  await p.waitForSelector('[data-test=issues-menu-option][data-value="in_progress"]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-menu-option][data-value="in_progress"]')
  await p.waitForFunction(() => {
    const group = document.querySelector('[data-status="in_progress"]')
    return Boolean(group && group.querySelector('[data-key="SPL-1"]'))
  }, { timeout: 5000 }).catch(() => null)
  ok('5 changing status moves the row into that group', Boolean(await p.$('[data-status="in_progress"] [data-key="SPL-1"]')))

  await p.click('[data-test=issues-row][data-key="SPL-2"]')
  const before = await p.$eval('[data-test=issues-row][data-selected="true"]', (el) => el.getAttribute('data-key'))
  await p.keyboard.press('KeyJ')
  await p.waitForFunction((prev) => {
    const el = document.querySelector('[data-test=issues-row][data-selected="true"]')
    return Boolean(el && el.getAttribute('data-key') && el.getAttribute('data-key') !== prev)
  }, { timeout: 3000 }, before).catch(() => null)
  const after = await p.$eval('[data-test=issues-row][data-selected="true"]', (el) => el.getAttribute('data-key')).catch(() => '')
  ok('6 J moves the selection', Boolean(after) && after !== before, { before, after })

  mkdirSync(SHOTS, { recursive: true })
  await p.screenshot({ path: `${SHOTS}/desktop.png` })
  const wide = await p.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }))
  ok('7 no horizontal scroll at 1400', wide.sw <= wide.cw + 1, wide)
  await p.setViewport({ width: 390, height: 844, isMobile: true })
  await p.waitForSelector('[data-test=issues-page]', { timeout: 5000 })
  const narrow = await p.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }))
  await p.screenshot({ path: `${SHOTS}/mobile.png` })
  ok('8 no horizontal scroll at 390', narrow.sw <= narrow.cw + 1, narrow)
  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('9 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log(failed.map((r) => r.name).join('\n'))
  process.exit(1)
}
