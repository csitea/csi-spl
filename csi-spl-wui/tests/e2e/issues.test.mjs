// Issues screen in a real browser (GRK-3519). Mock mode starts with the one
// epic every tenant has (SPL-1 "random", SPL-18), so the rows it creates
// start at SPL-2 and land under that epic by default.
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
  ok('2a the side panel has no All issues row', !(await p.$('[data-testid=sidebar-issues-open]')), '')
  await p.waitForSelector('[data-testid=sidebar-epics-h]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
  const panelHeads = await p.$$eval('#sidebar-panel-issues h2', (els) => els.map((e) => e.getAttribute('data-testid') || e.textContent.trim()))
  ok('2b the side panel has one section, Epics and features, first (no ISSUES heading)', panelHeads.length === 1 && panelHeads[0] === 'sidebar-epics-h', panelHeads)

  await p.select('[data-test=issues-sort]', 'level')
  const rowLabels = await p.evaluate(() => {
    const root = document.querySelector('[data-test=issues-filters]')
    const textOf = (sel) => {
      const el = root.querySelector(sel)
      if (!el) return ''
      if (el.tagName === 'SELECT') return el.options[el.selectedIndex].text.trim()
      return (el.textContent || '').trim()
    }
    const span = (sel) => {
      const el = root.querySelector(sel)
      const label = el && el.closest('label, [role=group]')
      const s = label && label.querySelector('span')
      return s ? s.textContent.trim() : ''
    }
    return [
      textOf('[data-test=issues-sort]'),
      textOf('[data-test=issues-filter-status-btn]'),
      textOf('[data-test=issues-filter-priority]'),
      textOf('[data-test=issues-filter-level]'),
      textOf('[data-test=issues-filter-assignee]'),
      textOf('[data-test=issues-filter-label]'),
      span('[data-test=issues-filter-deadline-date]'),
    ]
  })
  ok('2c filter controls do not share a label', new Set(rowLabels).size === rowLabels.length && rowLabels[0] === 'Sort: Level' && rowLabels[3] === 'Level: All' && rowLabels[6] === 'Deadline:' && !rowLabels.includes('Deadline from') && !rowLabels.includes('Deadline until'), rowLabels)
  await p.select('[data-test=issues-sort]', 'priority')

  await p.click('[data-test=issues-filter-status-btn]')
  await p.waitForSelector('[data-test=issues-filter-status-opt][data-value="wip"]', { visible: true, timeout: 5000 })
  const codes = await p.$$eval('[data-test=issues-filter-status-opt] .issues-status-code', (els) => els.map((e) => e.textContent.trim()))
  await p.hover('[data-test=issues-filter-status-opt][data-value="wip"]')
  const tip = await p.$eval('[data-test=issues-filter-status-opt][data-value="wip"] .issues-status-tip', (el) => {
    const st = getComputedStyle(el)
    const box = el.getBoundingClientRect()
    return { text: el.textContent.trim(), display: st.display, w: box.width, h: box.height }
  })
  await p.mouse.move(0, 0)
  await p.click('[data-test=issues-filter-status-all]')
  ok('2b hovering 03-wip pops up work in progress', JSON.stringify(codes) === JSON.stringify(['01-eval', '02-todo', '03-wip', '03-diss', '07-qas', '09-done']) && tip.text === 'work in progress' && tip.display === 'block' && tip.w > 8 && tip.h > 4, { codes, tip })

  await create(p, 'The first read drops', 'Only in the detail')
  await create(p, 'Show the display name', '')
  const listText = await p.$eval('[data-test=issues-list]', (el) => el.innerText)
  ok('3 the list shows the key and not the description', listText.includes('SPL-2') && listText.includes('The first read drops') && !listText.includes('Only in the detail'), listText.slice(0, 280))

  await p.click('[data-test=issues-row][data-key="SPL-2"]')
  await p.waitForSelector('[data-test=issues-detail]', { visible: true, timeout: 5000 })
  const body = await p.$eval('[data-test=issues-detail-body]', (el) => el.value)
  const deadlineType = await p.$eval('[data-test=issues-deadline]', (el) => el.getAttribute('type'))
  const deadlineHint = await p.$eval('[data-test=issues-deadline]', (el) => el.getAttribute('placeholder'))
  /* owner, topic 778ad161: a click opens a calendar (month grid) with a 24-hour time, 07:00-22:00, no AM/PM */
  await p.click('[data-test=issues-deadline-open]')
  await p.waitForSelector('[data-test=deadline-picker]', { visible: true, timeout: 5000 })
  const times = await p.$$eval('[data-test=issues-deadline-time] option', (els) => els.map((e) => e.textContent.trim()))
  const grid = await p.evaluate(() => ({
    month: document.querySelector('[data-test=deadline-picker-month]').textContent.trim(),
    days: document.querySelectorAll('[data-test=deadline-picker-day]').length,
    head: [...document.querySelectorAll('.dlp__wd')].map((e) => e.textContent.trim()).join(' '),
    native: document.querySelectorAll('input[type=date], input[type=datetime-local]').length,
  }))
  ok('4a the calendar is a YYYY-MM month grid, Monday first, never a native date input',
    /^\d{4}-\d{2}$/.test(grid.month) && grid.days === 42 && grid.head === 'Mo Tu We Th Fr Sa Su' && grid.native === 0, grid)
  const day15 = `${grid.month}-15`
  await p.click(`[data-test=deadline-picker-day][data-date="${day15}"]`)
  await p.select('[data-test=issues-deadline-time]', '15:30')
  await p.click('[data-test=deadline-picker-done]')
  await p.waitForFunction((want) => document.querySelector('[data-test=issues-deadline]').value === want, { timeout: 5000 }, `${day15} 15:30`).catch(() => {})
  const picked = await p.$eval('[data-test=issues-deadline]', (el) => el.value)
  const popGone = !(await p.$('[data-test=deadline-picker]'))
  ok('4c a day and a time picked in the calendar read back as YYYY-MM-DD HH:MM', picked === `${day15} 15:30` && popGone, { picked, popGone })
  /* typing stays possible: the shown form, and a refusal for a locale form */
  const selectAll = (sel) => p.$eval(sel, (el) => { el.focus(); el.select() })
  await selectAll('[data-test=issues-deadline]')
  await p.type('[data-test=issues-deadline]', '10/02/2026')
  await p.keyboard.press('Enter')
  const refused = await p.$eval('[data-test=issues-deadline]', (el) => el.getAttribute('aria-invalid'))
  await selectAll('[data-test=issues-deadline]')
  await p.type('[data-test=issues-deadline]', '2026-10-02 07:45')
  await p.keyboard.press('Enter')
  await p.waitForFunction(() => document.querySelector('[data-test=issues-deadline]').getAttribute('aria-invalid') === null, { timeout: 5000 }).catch(() => {})
  const typed = await p.$eval('[data-test=issues-deadline]', (el) => ({ v: el.value, inv: el.getAttribute('aria-invalid') }))
  ok('4d typing YYYY-MM-DD HH:MM is kept, mm/dd/yyyy is refused', refused === 'true' && typed.v === '2026-10-02 07:45' && typed.inv === null, { refused, typed })
  const side = await p.evaluate(() => {
    const list = document.querySelector('[data-test=issues-list]').getBoundingClientRect()
    const pane = document.querySelector('[data-test=issues-detail]').getBoundingClientRect()
    return { paneRight: pane.left >= list.right - 2 }
  })
  ok('4 the right pane shows the description and a calendar with a 24-hour time (07:00-22:00)', body === 'Only in the detail' && deadlineType === 'text' && deadlineHint === 'YYYY-MM-DD HH:MM' &&
    times[0] === '07:00' && times[times.length - 1] === '22:00' && !times.some((x) => /am|pm/i.test(x)) && side.paneRight,
    { body, deadlineType, deadlineHint, first: times[0], last: times[times.length - 1], n: times.length, side })

  /* SPL-949: level is the tree's (1 epic / feature, 2 issue, 3 subtask), shown and never picked */
  const lvl = await p.$eval('[data-test=issues-level]', (el) => ({ tag: el.tagName, level: el.getAttribute('data-level') }))
  const opts = await p.$$eval('[data-test=issues-filter-level] option', (els) => els.map((e) => e.value).filter(Boolean))
  ok('4b level is read-only, 2 for an issue; the filter offers 1, 2, 3', lvl.tag !== 'BUTTON' && lvl.level === '2' && opts.join() === '1,2,3', { lvl, opts })

  await p.click('[data-test=issues-status]')
  await p.waitForSelector('[data-test=issues-menu-option][data-value="wip"]', { visible: true, timeout: 5000 })
  await p.hover('[data-test=issues-menu-option][data-value="diss"]')
  const menuTip = await p.$eval('[data-test=issues-menu-option][data-value="diss"] .issues-status-tip', (el) => {
    const st = getComputedStyle(el)
    const box = el.getBoundingClientRect()
    const code = el.parentElement.querySelector('.issues-status-code').textContent.trim()
    return { code, text: el.textContent.trim(), display: st.display, w: box.width, h: box.height }
  })
  ok('5b hovering 03-diss pops up discard', menuTip.code === '03-diss' && menuTip.text === 'discard' && menuTip.display === 'block' && menuTip.w > 8 && menuTip.h > 4, menuTip)
  await p.click('[data-test=issues-menu-option][data-value="wip"]')
  await p.waitForFunction(() => {
    const group = document.querySelector('[data-status="wip"]')
    return Boolean(group && group.querySelector('[data-key="SPL-2"]'))
  }, { timeout: 5000 }).catch(() => null)
  ok('5 changing status moves the row into that group', Boolean(await p.$('[data-status="wip"] [data-key="SPL-2"]')))

  await p.click('[data-test=issues-row][data-key="SPL-3"]')
  await p.waitForFunction(() => {
    const el = document.querySelector('[data-test=issues-row][data-selected="true"]')
    return el && el.getAttribute('data-key') === 'SPL-3' && new URL(location.href).searchParams.get('issue') === 'SPL-3'
  }, { timeout: 5000 })
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

  async function dragHandle(selector, dx) {
    const box = await p.$eval(selector, (el) => {
      const b = el.getBoundingClientRect()
      return { x: b.x + b.width / 2, y: b.y + Math.min(220, b.height / 2) }
    })
    await p.mouse.move(box.x, box.y)
    await p.mouse.down()
    await p.mouse.move(box.x + dx, box.y, { steps: 10 })
    await p.mouse.up()
  }
  const side0 = await p.evaluate(() => getComputedStyle(document.querySelector('.spool-shell')).getPropertyValue('--sidebar-w'))
  await dragHandle('[data-testid=pane-divider-sidebar]', 64)
  const side1 = await p.evaluate(() => getComputedStyle(document.querySelector('.spool-shell')).getPropertyValue('--sidebar-w'))
  ok('10 the sidebar divider resizes beside the issue list', parseFloat(side1) >= parseFloat(side0) + 40, { side0, side1 })
  await p.waitForSelector('[data-testid=pane-divider-issue]', { timeout: 5000 })
  const d0 = await p.$eval('[data-test=issues-detail]', (el) => el.getBoundingClientRect().width)
  await dragHandle('[data-testid=pane-divider-issue]', -72)
  const d1 = await p.$eval('[data-test=issues-detail]', (el) => el.getBoundingClientRect().width)
  ok('11 the issue detail divider widens the detail', d1 >= d0 + 40, { d0, d1 })
  await p.click('[data-testid=pane-divider-issue]')
  await p.keyboard.press('ArrowRight')
  const d2 = await p.$eval('[data-test=issues-detail]', (el) => el.getBoundingClientRect().width)
  ok('12 the issue detail divider answers the keyboard', d2 <= d1 - 8, { d1, d2 })
  const stored = await p.evaluate(() => localStorage.getItem('spool.pane-widths'))
  ok('13 the issue detail width is stored with the other pane widths', Boolean(stored && stored.includes('"issues"')), stored)
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
