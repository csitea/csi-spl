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

  /* owner, topic e65c0f60: the default is ONE flat list, newest update first */
  const view = await p.evaluate(() => ({
    sortControls: document.querySelectorAll('[data-test=issues-sort], [data-test=issues-group-by]').length,
    ariaSort: [...document.querySelectorAll('[data-test=issues-table] thead th[aria-sort]')].map((th) => th.getAttribute('aria-sort')),
    marks: [...document.querySelectorAll('.issues-sort-mark')].map((m) => m.textContent).join(''),
    headers: document.querySelectorAll('.issues-group__h').length,
    rowStatus: document.querySelectorAll('[data-test=issues-row-status]').length,
    rows: document.querySelectorAll('[data-test=issues-row]').length,
  }))
  ok('2f the default view is one flat list: no Sort / Group controls, no triangle, no status sections',
    view.sortControls === 0 && view.ariaSort.length === 9 && view.ariaSort.every((a) => a === 'none') && view.marks === '' && view.headers === 0 && view.rowStatus === view.rows, view)

  /* owner, topic e00da93b: a sheet - names row, a filter row under each column, one issue per row */
  const sheet = await p.evaluate(() => {
    const table = document.querySelector('[data-test=issues-table]')
    const [names, filters] = table.tHead.rows
    const nameTexts = [...names.cells].map((c) => c.textContent.trim())
    const cols = [...names.cells].map((c) => { const r = c.getBoundingClientRect(); return [Math.round(r.left), Math.round(r.right)] })
    const underName = [...filters.cells].every((c, i) => { const r = c.getBoundingClientRect(); return Math.abs(r.left - cols[i][0]) <= 1 && Math.abs(r.right - cols[i][1]) <= 1 })
    const ctrlValues = [...filters.querySelectorAll('select, .issues-status-dd__btn')].map((el) => el.tagName === 'SELECT' ? el.options[el.selectedIndex].text.trim() : el.textContent.trim())
    const row = table.querySelector('[data-test=issues-row]')
    const rowCells = row ? row.cells.length : 0
    const rowUnder = row ? [...row.cells].every((c, i) => Math.abs(Math.round(c.getBoundingClientRect().left) - cols[i][0]) <= 1) : false
    const sticky = getComputedStyle(names.cells[0]).position
    const grid = getComputedStyle(names.cells[0]).borderBottomStyle
    return { nameTexts, underName, ctrlValues, rowCells, rowUnder, sticky, grid, deadline: !!filters.querySelector('[data-test=issues-filter-deadline-date]') }
  })
  ok('2c the list is a sheet: names row, each filter under its column, rows in the same columns, sticky, gridlines',
    JSON.stringify(sheet.nameTexts) === JSON.stringify(['Key', 'Title', 'Status', 'prio', 'Level', 'Assignee', 'Label', 'Deadline', 'Updated']) &&
      sheet.underName && sheet.sticky === 'sticky' && sheet.grid === 'solid' && sheet.deadline &&
      !sheet.ctrlValues.some((v) => v.includes(':')), sheet)
  /* owner, topic e00da93b: the closed Assignee control is sized to its value like the others, capped at 13em */
  const widths = await p.evaluate(() => {
    const w = (sel) => Math.round(document.querySelector(sel).getBoundingClientRect().width)
    const a = document.querySelector('[data-test=issues-filter-assignee]')
    const em = parseFloat(getComputedStyle(a).fontSize)
    const opts = [...a.options].map((o) => o.text.length)
    const out = { assignee: w('[data-test=issues-filter-assignee]'), prio: w('[data-test=issues-filter-priority]'), level: w('[data-test=issues-filter-level]'), capPx: Math.round(13 * em), title: a.title, longestOption: Math.max(...opts) }
    /* CONTROL: the same select sized the old way (to its widest option) */
    a.style.fieldSizing = 'fixed'; a.style.maxWidth = 'none'
    out.controlOldWay = w('[data-test=issues-filter-assignee]')
    a.style.fieldSizing = ''; a.style.maxWidth = ''
    return out
  })
  const who = await p.evaluate(() => {
    const a = document.querySelector('[data-test=issues-filter-assignee]')
    return { text: a.options[a.selectedIndex].text.trim(), aria: a.getAttribute('aria-label') }
  })
  ok('2e the Assignee control shows the value alone; Assignee is its name (topic e00da93b)', who.text === 'All' && who.aria === 'Assignee', who)
  ok('2d the closed Assignee control is no wider than 13em, near prio / level, the full text on hover',
    widths.assignee <= widths.capPx + 1 && widths.assignee < widths.controlOldWay && widths.assignee <= Math.max(widths.prio, widths.level) * 1.5 && widths.title === 'Assignee: All', widths)

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
  ok('2b hovering 03-wip pops up work in progress', JSON.stringify(codes) === JSON.stringify(['01-eval', '02-todo', '03-wip', '03-diss', '05-blocked', '06-onhold', '07-qas', '09-done']) && tip.text === 'work in progress' && tip.display === 'block' && tip.w > 8 && tip.h > 4, { codes, tip })

  await create(p, 'The first read drops', 'Only in the detail')
  await create(p, 'Show the display name', '')
  const listText = await p.$eval('[data-test=issues-list]', (el) => el.innerText)
  const rowCols = await p.evaluate(() => {
    const table = document.querySelector('[data-test=issues-table]')
    const cols = [...table.tHead.rows[0].cells].map((c) => Math.round(c.getBoundingClientRect().left))
    const row = table.querySelector('[data-test=issues-row]')
    const title = row.querySelector('.issues-title')
    return { cells: row.cells.length, under: [...row.cells].every((c, i) => Math.abs(Math.round(c.getBoundingClientRect().left) - cols[i]) <= 1), titleHover: title.getAttribute('title') === title.textContent.trim(), ellipsis: getComputedStyle(title).textOverflow }
  })
  ok('3a each issue is one row in the same 9 columns; the title ellipsizes with the full text on hover',
    rowCols.cells === 9 && rowCols.under && rowCols.titleHover && rowCols.ellipsis === 'ellipsis', rowCols)
  /* owner, topic e00da93b: a header click sorts ▲, then ▼, then back to the default */
  const sortState = () => p.evaluate(() => {
    const th = document.querySelector('[data-test=issues-sort-title]').closest('th')
    const titles = [...document.querySelectorAll('[data-test=issues-row] .issues-title')].map((e) => e.textContent.trim())
    const u = new URL(location.href)
    return { aria: th.getAttribute('aria-sort'), mark: th.querySelector('.issues-sort-mark').textContent, sort: u.searchParams.get('sort'), dir: u.searchParams.get('dir'), titles, others: [...document.querySelectorAll('.issues-sort-mark')].filter((m) => m.textContent).length }
  })
  await p.click('[data-test=issues-sort-title]')
  const up = await sortState()
  await p.click('[data-test=issues-sort-title]')
  const down = await sortState()
  await p.click('[data-test=issues-sort-title]')
  const back = await sortState()
  const byTitle = (l) => [...l].sort((a, b) => a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' }))
  ok('3b a header click sorts ▲ then ▼ then back; only that column shows a triangle; the URL keeps it',
    up.aria === 'ascending' && up.mark === '▲' && up.sort === 'title' && up.dir === 'asc' && up.others === 1 && JSON.stringify(up.titles) === JSON.stringify(byTitle(up.titles)) &&
      down.aria === 'descending' && down.mark === '▼' && down.dir === 'desc' && JSON.stringify(down.titles) === JSON.stringify(byTitle(down.titles).reverse()) &&
      back.aria === 'none' && back.mark === '' && back.sort === null && back.others === 0, { up, down, back })
  ok('3 the list shows the key and not the description', listText.includes('SPL-2') && listText.includes('The first read drops') && !listText.includes('Only in the detail'), listText.slice(0, 280))

  await p.click('[data-test=issues-row][data-key="SPL-2"] .issues-c-key')
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

  /* SPL-974: one plus+hierarchy icon (no inline title box, no Add subtask
     button) opens a modal with the subtask UI: Enter creates, Esc and the
     backdrop close, focus is trapped and handed back */
  const subUi = await p.evaluate(() => {
    const b = document.querySelector('[data-test=issues-subtask-open]')
    return { inline: document.querySelectorAll('[data-test=issues-subtasks] input, [data-test=issues-subtasks] form').length,
      label: b && b.getAttribute('aria-label'), title: b && b.getAttribute('title'), icon: Boolean(b && b.querySelector('svg[data-icon=subtask-add]')), text: b ? b.textContent.trim() : null }
  })
  ok('4e the subtask section has one icon button labelled Add subtask and no inline form',
    subUi.inline === 0 && subUi.label === 'Add subtask' && subUi.title === 'Add subtask' && subUi.icon && subUi.text === '', subUi)
  const openSub = async () => {
    await p.click('[data-test=issues-subtask-open]')
    await p.waitForFunction(() => document.activeElement && document.activeElement.getAttribute('data-test') === 'issues-subtask-input', { timeout: 5000 })
  }
  const dialogGone = () => p.waitForFunction(() => !document.querySelector('[data-testid=ui-dialog]'), { timeout: 5000 }).then(() => true, () => false)
  const focusOnOpener = () => p.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-test') === 'issues-subtask-open')
  await openSub()
  const modal = await p.$eval('[data-testid=ui-dialog]', (el) => ({ modal: el.getAttribute('aria-modal'), role: el.getAttribute('role') }))
  const trapped = []
  for (let n = 0; n < 9; n++) {
    await p.keyboard.press('Tab')
    trapped.push(await p.evaluate(() => Boolean(document.querySelector('[data-testid=ui-dialog]').contains(document.activeElement))))
  }
  await p.keyboard.press('Escape')
  const escClosed = await dialogGone()
  const escBack = await focusOnOpener()
  const stillOpen = await p.$('[data-test=issues-detail]')
  ok('4f the dialog is modal, Tab stays inside it, Esc closes it and focus returns to the icon (the issue stays open)',
    modal.modal === 'true' && modal.role === 'dialog' && trapped.every(Boolean) && escClosed && escBack && Boolean(stillOpen), { modal, trapped, escClosed, escBack })
  await openSub()
  await p.mouse.click(4, 4)
  const backdropClosed = await dialogGone()
  ok('4g a click on the backdrop closes the dialog', backdropClosed, { backdropClosed })
  await openSub()
  await p.type('[data-test=issues-subtask-input]', 'Mock subtask')
  await p.keyboard.press('Enter')
  const enterClosed = await dialogGone()
  const subRow = await p.waitForFunction(() => {
    const el = [...document.querySelectorAll('[data-test=issues-subtask]')].find((x) => x.textContent.includes('Mock subtask'))
    return el ? el.getAttribute('data-key') : false
  }, { timeout: 5000 }).then((h) => h.jsonValue(), () => '')
  ok('4h Enter in the dialog creates the subtask and it shows in the pane right away', enterClosed && Boolean(subRow), { enterClosed, subRow })

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
  await p.waitForSelector('[data-test=issues-row][data-key="SPL-2"] [data-test=issues-row-status]', { timeout: 5000 }).catch(() => {})
  const flatStatus = await p.$eval('[data-test=issues-row][data-key="SPL-2"] [data-test=issues-row-status]', (el) => ({ status: el.getAttribute('data-status'), text: el.textContent.trim() })).catch(() => null)
  ok('5c back in the flat list the row shows its new status', flatStatus && flatStatus.status === 'wip' && flatStatus.text === '03-wip', flatStatus)

  /* owner, topic e0f6f074 (SPL-972): every pop-up list closes on a click outside it and on Esc */
  const menuUp = () => p.$('[data-test=issues-menu]').then(Boolean)
  await p.click('[data-test=issues-row][data-key="SPL-3"] [data-test=issues-row-status]')
  const openedA = await menuUp()
  await p.click('[data-test=issues-heading]')
  const afterOutside = await menuUp()
  await p.click('[data-test=issues-row][data-key="SPL-3"] [data-test=issues-row-status]')
  const openedB = await menuUp()
  await p.keyboard.press('Escape')
  const afterEsc = await menuUp()
  ok('5d an open row menu closes on a click outside it and on Esc', openedA && !afterOutside && openedB && !afterEsc, { openedA, afterOutside, openedB, afterEsc })

  /* prio is a select box in the sheet */
  await p.select('[data-test=issues-row][data-key="SPL-3"] [data-test=issues-row-priority]', '1')
  await p.waitForFunction(() => document.querySelector('[data-test=issues-row][data-key="SPL-3"]')?.getAttribute('data-priority') === '1', { timeout: 5000 }).catch(() => {})
  const prio = await p.$eval('[data-test=issues-row][data-key="SPL-3"]', (el) => ({ row: el.getAttribute('data-priority'), box: el.querySelector('[data-test=issues-row-priority]').tagName }))
  ok('5e the Prio cell is a select box and saves the new prio', prio.row === '1' && prio.box === 'SELECT', prio)

  /* level is a select box that moves the issue in the tree: 2 -> 3 under a picked
     issue (a subtask is listed under its parent, not as a row of the sheet) */
  await p.select('[data-test=issues-row][data-key="SPL-3"] [data-test=issues-row-level]', '3')
  await p.waitForSelector('[data-test=issues-menu-option][data-value="SPL-2"]', { visible: true, timeout: 5000 }).catch(() => {})
  const parentOpts = await p.$$eval('[data-test=issues-menu-option]', (els) => els.map((e) => e.getAttribute('data-value')))
  await p.click('[data-test=issues-menu-option][data-value="SPL-2"]').catch(() => {})
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-row][data-key="SPL-3"]'), { timeout: 5000 }).catch(() => {})
  const rowGone = !(await p.$('[data-test=issues-row][data-key="SPL-3"]'))
  await p.click('[data-test=issues-row][data-key="SPL-2"] .issues-c-key')
  await p.waitForSelector('[data-test=issues-subtask]', { visible: true, timeout: 5000 }).catch(() => {})
  const subs = await p.$$eval('[data-test=issues-subtask]', (els) => els.map((e) => e.textContent.replace(/\s+/g, ' ').trim()))
  ok('5f the Level cell is a select box: 3 moves the issue under a picked issue, listed as its subtask',
    parentOpts.includes('SPL-2') && !parentOpts.includes('SPL-3') && rowGone && subs.some((x) => x.includes('SPL-3')), { parentOpts, rowGone, subs })

  await create(p, 'A third row for J', '')
  /* the deadline box is as wide as "YYYY-MM-DD HH:MM" (topic 593a804a) */
  const dl = await p.$eval('[data-test=issues-filter-deadline-date]', (el) => {
    const probe = document.createElement('span')
    const cs = getComputedStyle(el)
    probe.style.cssText = `position:absolute;visibility:hidden;white-space:pre;font:${cs.font};font-variant-numeric:tabular-nums`
    probe.textContent = '2026-09-26 17:45'
    document.body.appendChild(probe)
    const text = probe.getBoundingClientRect().width
    probe.remove()
    return { box: Math.round(el.getBoundingClientRect().width), text: Math.round(text) }
  })
  ok('5g the deadline box fits YYYY-MM-DD HH:MM and no more', dl.box >= dl.text && dl.box <= dl.text + 32, dl)

  /* start on the first row of the sheet, so J has a row below it */
  const firstKey = await p.$eval('[data-test=issues-row]', (el) => el.getAttribute('data-key'))
  await p.click(`[data-test=issues-row][data-key="${firstKey}"] .issues-c-key`)
  await p.waitForFunction((k) => {
    const el = document.querySelector('[data-test=issues-row][data-selected="true"]')
    return el && el.getAttribute('data-key') === k && new URL(location.href).searchParams.get('issue') === k
  }, { timeout: 5000 }, firstKey)
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
