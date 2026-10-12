// Issues screen in a real browser. Mock mode starts with the one
// epic every tenant has (SPL-1 "random", SPL-18), so the rows it creates
// start at SPL-2 and land under that epic by default.
//
//   pnpm run test:e2e issues
//   BASE_URL=<generated bundle> pnpm run test:e2e issues
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

const sleepMs = (ms) => new Promise((r) => setTimeout(r, ms))
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

/* SPL-1027: a new issue is the sheet's top row (title, Enter); the
   description is written in the opened issue (the modal), saved on blur */
async function closeModal(p) {
  if (!(await p.$('[data-test=issues-detail]'))) return
  await p.click('[data-testid=ui-dialog-close]')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 })
}
async function create(p, title, body) {
  await closeModal(p)
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  const key = await p.waitForFunction((want) => {
    const row = [...document.querySelectorAll('[data-test=issues-row]')].find((r) => r.querySelector('.issues-title')?.textContent.trim() === want)
    return !document.querySelector('[data-test=issues-newrow]') && row ? row.getAttribute('data-key') : false
  }, { timeout: 5000 }, title).then((h) => h.jsonValue())
  if (body) {
    await p.click(`[data-test=issues-row][data-key="${key}"] .issues-c-key`)
    await p.waitForSelector('[data-test=issues-detail-rendered]', { visible: true, timeout: 5000 })
    await p.click('[data-test=issues-detail-rendered]')
    await p.waitForSelector('[data-test=issues-detail-body]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-detail-body]', body)
    await p.click('[data-test=issues-detail-title]')
    await p.waitForFunction((want) => document.querySelector('[data-test=issues-detail-rendered]')?.textContent.trim() === want, { timeout: 5000 }, body)
    await closeModal(p)
  }
  return key
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const rail = await p.$$eval('.sidebar-rail [role=tab]', (els) => els.map((e) => e.getAttribute('data-testid')))
  /* SPL-979 new-member order (owner 2026-09-27): Channels, DMs, Issues, ... */
  ok('1 Issues is the third rail tab, after Channels and DMs', rail[0] === 'sidebar-tab-channels' && rail[1] === 'sidebar-tab-dm' && rail[2] === 'sidebar-tab-issues' && rail.indexOf('sidebar-tab-events') > rail.indexOf('sidebar-tab-issues'), rail)
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
    JSON.stringify(sheet.nameTexts) === JSON.stringify(['Key', 'Title', 'Status', 'prio', 'Level', 'Assignee', 'Label', 'Deadline', 'Updated', '']) &&
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
  ok('3a each issue is one row in the same 10 columns (the last: delete); the title ellipsizes with the full text on hover',
    rowCols.cells === 10 && rowCols.under && rowCols.titleHover && rowCols.ellipsis === 'ellipsis', rowCols)
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
  const body = await p.$eval('[data-test=issues-detail-rendered]', (el) => el.textContent.trim())
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
  /* SPL-1147: no Done - the day and time applied at once; the x closes */
  await p.click('[data-test=deadline-picker-close]')
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
    const d = document.querySelector('[data-test=issues-detail]').closest('[data-testid=ui-dialog]')
    return { modal: Boolean(d && d.getAttribute('aria-modal') === 'true'), divider: Boolean(document.querySelector('[data-testid=pane-divider-issue]')) }
  })
  ok('4 the issue modal shows the description and a calendar with a 24-hour time (07:00-22:00); no right pane', body === 'Only in the detail' && deadlineType === 'text' && deadlineHint === 'YYYY-MM-DD HH:MM' &&
    times[0] === '07:00' && times[times.length - 1] === '22:00' && !times.some((x) => /am|pm/i.test(x)) && side.modal && !side.divider,
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
  /* the subtask dialog sits on the issue modal: gone = one dialog left */
  const dialogGone = () => p.waitForFunction(() => document.querySelectorAll('[data-testid=ui-dialog]').length === 1, { timeout: 5000 }).then(() => true, () => false)
  const focusOnOpener = () => p.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-test') === 'issues-subtask-open')
  await openSub()
  const modal = await p.evaluate(() => { const all = document.querySelectorAll('[data-testid=ui-dialog]'); const el = all[all.length - 1]; return { modal: el.getAttribute('aria-modal'), role: el.getAttribute('role'), n: all.length } })
  const trapped = []
  for (let n = 0; n < 9; n++) {
    await p.keyboard.press('Tab')
    trapped.push(await p.evaluate(() => { const all = document.querySelectorAll('[data-testid=ui-dialog]'); return Boolean(all[all.length - 1].contains(document.activeElement)) }))
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
  await closeModal(p)

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
  await closeModal(p)

  await create(p, 'A third row for J', '')
  /* the deadline box is as wide as "YYYY-MM-DD HH:MM" (topic 593a804a), plus
     the ~2 mm of SPL-1147: what it shows (the value, else the placeholder)
     and no more. Measured in the FIELD's font: an input does not
     inherit the page font, and Chrome answers the `font` shorthand of an
     input as '' (the probe then used the larger page font) */
  const dl = await p.$eval('[data-test=issues-filter-deadline-date]', (el) => {
    const probe = document.createElement('span')
    const cs = getComputedStyle(el)
    probe.style.cssText = `position:absolute;visibility:hidden;white-space:pre;font-family:${cs.fontFamily};font-size:${cs.fontSize};font-weight:${cs.fontWeight};font-variant-numeric:tabular-nums`
    probe.textContent = el.value || el.placeholder
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
  /* SPL-1027: J moves in the sheet, so the modal closes first (Esc) */
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 })
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
  await p.setViewport({ width: 390, height: 844, isMobile: true })
  await p.waitForSelector('[data-test=issues-page]', { timeout: 5000 })
  const narrow = await p.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }))
  await p.screenshot({ path: `${SHOTS}/mobile.png` })
  ok('8 no horizontal scroll at 390', narrow.sw <= narrow.cw + 1, narrow)

  /* t1 d5d00918 (owner msg c74e95d4): "It shouldn't list more than 30
     issues, and then it should have the "Load more" control at the end of
     the listing." The mock tenant starts with 64 more issues (SPL-1 is the epic, not a row). */
  const count = (sel) => p.$$eval(sel, (els) => els.length)
  const moreLast = (rowSel) => p.evaluate((rs) => {
    const more = document.querySelector('[data-test=issues-load-more]')
    const rows = document.querySelectorAll(rs)
    const last = rows[rows.length - 1]
    return Boolean(more && last && (last.compareDocumentPosition(more) & Node.DOCUMENT_POSITION_FOLLOWING))
  }, rowSel)
  const loadMore = async (rowSel, want) => {
    await p.click('[data-test=issues-load-more]')
    await p.waitForFunction((rs, n) => document.querySelectorAll(rs).length >= n, { timeout: 5000 }, rowSel, want).catch(() => null)
  }
  await p.setViewport({ width: 1440, height: 900 })
  await p.evaluate(() => localStorage.setItem('spool.mock.issues-seed', '64'))
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-row]', { visible: true, timeout: NAV_TIMEOUT })
  const pg1 = { rows: await count('[data-test=issues-row]'), more: await count('[data-test=issues-load-more]'), last: await moreLast('[data-test=issues-row]'),
    label: await p.$eval('[data-test=issues-load-more]', (el) => el.textContent.trim()).catch(() => '') }
  await p.$eval('[data-test=issues-load-more]', (el) => el.scrollIntoView({ block: 'center' })).catch(() => {})
  await p.screenshot({ path: `${SHOTS}/paged-1440.png` })
  ok('11 64 issues: the list shows 30 rows and Load more after the last one', pg1.rows === 30 && pg1.more === 1 && pg1.last && pg1.label === 'Load more', pg1)
  await loadMore('[data-test=issues-row]', 60)
  const keys60 = await p.$$eval('[data-test=issues-row]', (els) => els.map((e) => e.getAttribute('data-key')))
  ok('12 Load more reads the next 30: 60 rows, no key twice, Load more still there', keys60.length === 60 && new Set(keys60).size === 60 &&
    (await count('[data-test=issues-load-more]')) === 1, { rows: keys60.length })
  await loadMore('[data-test=issues-row]', 64)
  ok('13 the last page: 64 rows, no Load more', (await count('[data-test=issues-row]')) === 64 && (await count('[data-test=issues-load-more]')) === 0,
    { rows: await count('[data-test=issues-row]') })

  /* a sort starts the list again at one page */
  await p.click('[data-test=issues-sort-title]')
  await p.waitForFunction(() => document.querySelectorAll('[data-test=issues-row]').length === 30, { timeout: 5000 }).catch(() => null)
  ok('14 a sort reads the first page again (30 rows, Load more)', (await count('[data-test=issues-row]')) === 30 && (await count('[data-test=issues-load-more]')) === 1,
    { rows: await count('[data-test=issues-row]') })

  /* J walks on past the last row read: it reads the next page first */
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-row]', { visible: true, timeout: NAV_TIMEOUT })
  await p.evaluate(() => document.activeElement && document.activeElement.blur())
  for (let k = 0; k < 31; k++) {
    await p.keyboard.press('KeyJ')
    await sleepMs(40)
  }
  await p.waitForFunction(() => document.querySelectorAll('[data-test=issues-row]').length >= 60, { timeout: 5000 }).catch(() => null)
  const walked = await p.evaluate(() => {
    const rows = [...document.querySelectorAll('[data-test=issues-row]')]
    return { rows: rows.length, at: rows.findIndex((r) => r.getAttribute('data-selected') === 'true') }
  })
  ok('15 J from row 30 reads the next page and selects row 31', walked.rows === 60 && walked.at === 30, walked)

  /* the phone's cards: the same page and the same control */
  await p.setViewport({ width: 390, height: 844, isMobile: true })
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-card]', { visible: true, timeout: NAV_TIMEOUT })
  const ph1 = { cards: await count('[data-test=issues-card]'), last: await moreLast('[data-test=issues-card]') }
  await p.$eval('[data-test=issues-load-more]', (el) => el.scrollIntoView({ block: 'center' })).catch(() => {})
  await p.screenshot({ path: `${SHOTS}/paged-390.png` })
  await loadMore('[data-test=issues-card]', 60)
  const ph2 = { cards: await count('[data-test=issues-card]') }
  ok('16 phone: 30 cards, Load more at the end, then 60', ph1.cards === 30 && ph1.last && ph2.cards === 60, { ph1, ph2 })

  /* owner HUM-10 (t1 53ab04e7, msg 14b0e604): "the issues listing should
     have checkboxes to perform multiple actions the same way as in gmail".
     A box per row, a page box, shift-click runs, x the focused row, Esc
     clears; with a row checked the bulk bar replaces the header. */
  const bulkState = () => p.evaluate(() => {
    const rows = [...document.querySelectorAll('[data-test=issues-row], [data-test=issues-card]')]
    const checked = [...document.querySelectorAll('[data-test=issues-row-check], [data-test=issues-card-check]')].map((b, i) => (b.checked ? i : -1)).filter((i) => i >= 0)
    const bar = document.querySelector('[data-test=issues-bulk-bar]')
    return {
      rows: rows.length,
      checked,
      tinted: rows.map((r, i) => ((r.getAttribute('data-checked') || r.closest('li')?.getAttribute('data-checked')) === 'true' ? i : -1)).filter((i) => i >= 0),
      bar: Boolean(bar && bar.getBoundingClientRect().height > 0),
      head: Boolean(document.querySelector('[data-test=issues-heading]')),
      count: document.querySelector('[data-test=issues-bulk-count]')?.textContent.trim() || '',
      note: document.querySelector('[data-test=issues-bulk-note]')?.textContent.replace(/\s+/g, ' ').trim() || '',
      result: document.querySelector('[data-test=issues-bulk-result]')?.textContent.replace(/\s+/g, ' ').trim() || '',
    }
  })
  const rowKeys = (sel) => p.$$eval(sel, (els) => els.map((e) => e.getAttribute('data-key')))
  const statusOf = (sel, keys) => p.evaluate((s, ks) => ks.map((k) => document.querySelector(`[data-key="${k}"] ${s}`)?.getAttribute('data-status')), sel, keys)
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-row]', { visible: true, timeout: NAV_TIMEOUT })
  const bk = await rowKeys('[data-test=issues-row]')
  const box = (k) => `[data-test=issues-row][data-key="${k}"] [data-test=issues-row-check]`
  const s0 = await bulkState()
  ok('17a 1440: every row has a box, none checked, the header shows (no bulk bar)',
    (await count('[data-test=issues-row-check]')) === s0.rows && s0.rows === 30 && s0.checked.length === 0 && !s0.bar && s0.head && (await count('[data-test=issues-select-page]')) === 1, s0)
  await p.click(box(bk[0]))
  await p.click(box(bk[1]))
  await p.waitForSelector('[data-test=issues-bulk-bar]', { visible: true, timeout: 10000 }).catch(() => null)
  const s1 = await bulkState()
  ok('17b checking 2 rows: the bulk bar replaces the header and counts 2, both rows tinted',
    s1.bar && !s1.head && s1.count === 'Selected: 2' && JSON.stringify(s1.checked) === '[0,1]' && JSON.stringify(s1.tinted) === '[0,1]', s1)
  const ctl0 = (await statusOf('[data-test=issues-row-status]', [bk[2]]))[0]
  await p.click('[data-test=issues-bulk-status]')
  await p.waitForSelector('[data-test=issues-menu][data-kind=status] [data-value=onhold]', { visible: true, timeout: 5000 }).catch(() => null)
  await p.click('[data-test=issues-menu][data-kind=status] [data-value=onhold]').catch(() => null)
  await p.waitForFunction((a, b) => [a, b].every((k) => document.querySelector(`[data-test=issues-row][data-key="${k}"] [data-test=issues-row-status]`)?.getAttribute('data-status') === 'onhold'), { timeout: 10000 }, bk[0], bk[1]).catch(() => null)
  const st = { two: await statusOf('[data-test=issues-row-status]', [bk[0], bk[1]]), control: (await statusOf('[data-test=issues-row-status]', [bk[2]]))[0], ctl0, bulk: await bulkState() }
  await p.screenshot({ path: `${SHOTS}/bulk-1440.png` })
  ok('17c Status on the bar sets both checked rows to 06-onhold; the unchecked row (control) keeps its status; one summary',
    st.two.every((s) => s === 'onhold') && st.control === ctl0 && ctl0 !== 'onhold' && st.bulk.result === 'Done: 2 of 2.' && st.bulk.count === 'Selected: 2', st)
  await p.click(box(bk[4]))
  await p.keyboard.down('Shift')
  await p.click(box(bk[7]))
  await p.keyboard.up('Shift')
  const s2 = await bulkState()
  ok('17d shift-click checks the run from the last box clicked (rows 5..8)', JSON.stringify(s2.checked) === '[0,1,4,5,6,7]' && s2.count === 'Selected: 6', s2)
  await p.focus(`[data-test=issues-row][data-key="${bk[10]}"]`)
  await p.keyboard.press('KeyX')
  const s3 = await bulkState()
  await p.keyboard.press('KeyX')
  const s4 = await bulkState()
  ok('17e x checks, then unchecks, the focused row', s3.checked.includes(10) && s3.count === 'Selected: 7' && !s4.checked.includes(10) && s4.count === 'Selected: 6', { s3: s3.checked, s4: s4.checked })
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-bulk-bar]'), { timeout: 5000 }).catch(() => null)
  const s5 = await bulkState()
  ok('17f Esc clears the selection: no box checked, the header is back', s5.checked.length === 0 && !s5.bar && s5.head, s5)
  await p.click('[data-test=issues-select-page]')
  await p.waitForSelector('[data-test=issues-bulk-note]', { visible: true, timeout: 5000 }).catch(() => null)
  const s6 = await bulkState()
  ok('17g the page box checks the 30 rows shown and offers all 64 matching (Gmail)',
    s6.checked.length === 30 && s6.count === 'Selected: 30' && s6.note === 'All 30 on this page are selected. Select all 64 matching', s6)
  await p.click('[data-test=issues-bulk-all-matching]')
  await p.waitForFunction(() => document.querySelector('[data-test=issues-bulk-count]')?.textContent.trim() === 'Selected: 64', { timeout: 10000 }).catch(() => null)
  const s7 = await bulkState()
  ok('17h Select all matching reads every page: 64 rows, 64 checked', s7.rows === 64 && s7.checked.length === 64 && s7.count === 'Selected: 64' && s7.note === 'All 64 matching are selected.', { rows: s7.rows, n: s7.checked.length, count: s7.count, note: s7.note })
  await p.click('[data-test=issues-bulk-clear]')
  await p.click(box(bk[2]))
  await p.click(box(bk[3]))
  await p.click('[data-test=issues-bulk-delete]')
  await p.waitForSelector('[data-testid=issues-bulk-confirm-body]', { visible: true, timeout: 5000 }).catch(() => null)
  const dlg = await p.evaluate(() => ({ count: document.querySelector('[data-testid=issues-bulk-confirm-body]')?.getAttribute('data-count'), title: document.querySelector('[role=dialog] h2, [role=alertdialog] h2')?.textContent.trim() || '', btn: document.querySelector('[data-testid=issues-bulk-confirm-confirm]')?.textContent.trim() }))
  await p.click('[data-testid=issues-bulk-confirm-confirm]').catch(() => null)
  await p.waitForFunction((a, b) => !document.querySelector(`[data-test=issues-row][data-key="${a}"]`) && !document.querySelector(`[data-test=issues-row][data-key="${b}"]`), { timeout: 10000 }, bk[2], bk[3]).catch(() => null)
  const s8 = await bulkState()
  ok('17i Delete asks once, naming the count, then both rows go and the summary says so',
    dlg.count === '2' && dlg.btn === 'Delete 2' && s8.rows === 62 && !s8.bar && s8.result === 'Done: 2 of 2.', { dlg, rows: s8.rows, result: s8.result })

  /* the phone: a box per card, the bar fits 390 with 44 px targets */
  await p.setViewport({ width: 390, height: 844, isMobile: true })
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-card]', { visible: true, timeout: NAV_TIMEOUT })
  const ck = await rowKeys('[data-test=issues-card]')
  await p.click(`[data-test=issues-card-check][data-key="${ck[0]}"]`)
  await p.click(`[data-test=issues-card-check][data-key="${ck[1]}"]`)
  await p.waitForSelector('[data-test=issues-bulk-bar]', { visible: true, timeout: 10000 }).catch(() => null)
  const m1 = await p.evaluate(() => {
    const vw = document.documentElement.clientWidth
    const btns = [...document.querySelectorAll('[data-test=issues-bulk-bar] button')].map((b) => b.getBoundingClientRect())
    return { sw: document.documentElement.scrollWidth, vw, inside: btns.every((r) => r.left >= 0 && r.right <= vw + 1), tap: btns.every((r) => r.width >= 43 && r.height >= 43), n: btns.length, opened: Boolean(document.querySelector('[data-test=issues-detail]')) }
  })
  const m1s = await bulkState()
  ok('18a 390: checking 2 cards opens no issue; the bar counts 2, fits the width, every button a 44 px target',
    m1s.bar && m1s.count === 'Selected: 2' && JSON.stringify(m1s.checked) === '[0,1]' && !m1.opened && m1.sw <= m1.vw + 1 && m1.inside && m1.tap && m1.n === 6, { m1, m1s })
  await p.click('[data-test=issues-bulk-assign]')
  await p.waitForSelector('[data-test=issues-menu][data-kind=assign] [data-test=issues-menu-option]', { visible: true, timeout: 5000 }).catch(() => null)
  const assignee = await p.$$eval('[data-test=issues-menu][data-kind=assign] [data-test=issues-menu-option]', (els) => els.map((e) => e.getAttribute('data-value')).find((v) => v))
  await p.click(`[data-test=issues-menu][data-kind=assign] [data-value="${assignee}"]`).catch(() => null)
  await p.waitForFunction((a, b, w) => [a, b].every((k) => document.querySelector(`[data-test=issues-card][data-key="${k}"] [data-test=issues-card-assignee]`)?.getAttribute('data-assignee') === w), { timeout: 10000 }, ck[0], ck[1], assignee).catch(() => null)
  const asg = await p.evaluate((ks) => ks.map((k) => document.querySelector(`[data-test=issues-card][data-key="${k}"] [data-test=issues-card-assignee]`)?.getAttribute('data-assignee')), [ck[0], ck[1], ck[2]])
  await p.screenshot({ path: `${SHOTS}/bulk-390.png` })
  ok('18b 390: Assignee on the bar assigns both checked cards; the unchecked card (control) is not assigned', Boolean(assignee) && asg[0] === assignee && asg[1] === assignee && asg[2] !== assignee, { assignee, asg })
  await p.click('[data-test=issues-bulk-clear]')
  const m2 = await bulkState()
  ok('18c 390: Clear unchecks every card and brings the header back', m2.checked.length === 0 && !m2.bar && m2.head, m2)
  await p.evaluate(() => localStorage.removeItem('spool.mock.issues-seed'))
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
