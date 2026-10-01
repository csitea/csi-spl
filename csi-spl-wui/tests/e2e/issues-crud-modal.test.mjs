// SPL-1027 (owner, prd t1 topic 89485c7a): "opening one ... should open up as
// a modal dialog (on desktop and tablet), and the grid should be fully CRUD,
// and the right-most panel could be removed". In a real browser, mock
// tenant, at 1440 and 1024 (phones keep level 3: issues-mobile.test.mjs):
//   M  the modal - open, edit, close (Esc / X / backdrop), Back, deep link,
//      a picker over it
//   C  create in a new top row (+ and C), with a cell set before Enter
//   U  update every cell in place (title, status, prio, assignee, labels,
//      deadline) and by keyboard (arrows, Enter, Esc)
//   D  delete with the one confirm; a parent with a live subtask is refused
// Each operation carries a control: the same gesture cancelled changes nothing.
//
//   pnpm run test:e2e issues-crud
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-crud
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.ISSUES_SHOTS || mkdtempSync(join(tmpdir(), 'spool-issues-crud-'))
const WIDTHS = (process.env.WIDTHS || '1440,1024').split(',').map(Number)

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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const row = (key) => `[data-test=issues-row][data-key="${key}"]`
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const server = await startServer()
const browser = await launch()
try {
  for (const W of WIDTHS) {
    console.log(`-- ${W} px`)
    const p = await browser.newPage()
    await p.setViewport({ width: W, height: 900 })
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e && e.message)))
    await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=issues-table]', { visible: true, timeout: NAV_TIMEOUT })

    const keys = () => p.$$eval('[data-test=issues-row]', (els) => els.map((e) => e.getAttribute('data-key')))
    const modalUp = () => p.$('[data-test=issues-detail]').then(Boolean)
    const waitModal = (up) => p.waitForFunction((u) => Boolean(document.querySelector('[data-test=issues-detail]')) === u, { timeout: 5000 }, up).then(() => true, () => false)
    const issueParam = () => p.evaluate(() => new URL(location.href).searchParams.get('issue'))
    /* the router writes the URL a tick after the modal changes: read it once it settles */
    const paramSettles = (want) => p.waitForFunction((w) => new URL(location.href).searchParams.get('issue') === w, { timeout: 5000 }, want).then(() => want, () => issueParam())
    const cellOn = () => p.evaluate(() => {
      const td = document.querySelector('[data-test=issues-row] td[data-cell-on="true"]')
      return td ? { key: td.closest('[data-test=issues-row]').getAttribute('data-key'), col: td.getAttribute('data-col'), focused: document.activeElement === td } : null
    })
    async function createRow(title, before) {
      await p.click('[data-test=issues-new]')
      await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
      await p.type('[data-test=issues-newrow-title]', title)
      if (before) await before()
      await p.focus('[data-test=issues-newrow-title]')
      await p.keyboard.press('Enter')
      return p.waitForFunction((want) => {
        const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === want)
        return !document.querySelector('[data-test=issues-newrow]') && r ? r.getAttribute('data-key') : false
      }, { timeout: 5000 }, title).then((h) => h.jsonValue(), () => '')
    }

    /* ---- C: create ------------------------------------------------------------ */
    const n0 = (await keys()).length
    await p.keyboard.press('KeyC')
    const cRow = await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 }).then(() => p.evaluate(() => ({
      focused: document.activeElement?.getAttribute('data-test'),
      top: document.querySelector('[data-test=issues-newrow]').compareDocumentPosition(document.querySelector('[data-test=issues-table] tbody.issues-group') || document.body) & Node.DOCUMENT_POSITION_FOLLOWING,
    })), () => null)
    await p.type('[data-test=issues-newrow-title]', 'dropped by Esc')
    await p.keyboard.press('Escape')
    await sleep(200)
    const cCtl = { newrow: await p.$('[data-test=issues-newrow]').then(Boolean), n: (await keys()).length }
    ok(`C1 ${W}: C puts a new row on top with its title focused; Esc drops it and stores nothing (control)`,
      Boolean(cRow && cRow.focused === 'issues-newrow-title') && !cCtl.newrow && cCtl.n === n0, { cRow, cCtl, n0 })

    const a = await createRow('Alpha row')
    const afterA = await cellOn()
    ok(`C2 ${W}: + then a title and Enter stores the row; the cursor moves on to its Status cell`,
      Boolean(a) && (await keys()).length === n0 + 1 && afterA && afterA.key === a && afterA.col === 'status' && afterA.focused, { a, afterA })
    const b = await createRow('Beta row', () => p.select('[data-test=issues-newrow-priority]', '2'))
    const bPrio = b ? await p.$eval(row(b), (el) => el.getAttribute('data-priority')) : ''
    ok(`C3 ${W}: a cell set on the new row before Enter is stored with it (prio 2)`, Boolean(b) && bPrio === '2', { b, bPrio })
    const c = await createRow('Gamma row')

    /* ---- U: update every cell in place ----------------------------------------- */
    await p.click(`${row(a)} [data-test=issues-row-title-edit]`)
    await p.waitForSelector('[data-test=issues-row-title-input]', { visible: true, timeout: 5000 })
    await p.$eval('[data-test=issues-row-title-input]', (el) => el.select())
    await p.type('[data-test=issues-row-title-input]', 'Not kept')
    await p.keyboard.press('Escape')
    await sleep(200)
    const tCtl = await p.$eval(`${row(a)} .issues-title`, (el) => el.textContent.trim())
    await p.click(`${row(a)} [data-test=issues-row-title-edit]`)
    await p.waitForSelector('[data-test=issues-row-title-input]', { visible: true, timeout: 5000 })
    await p.$eval('[data-test=issues-row-title-input]', (el) => el.select())
    await p.type('[data-test=issues-row-title-input]', 'Alpha renamed')
    await p.keyboard.press('Enter')
    await p.waitForFunction((sel) => document.querySelector(sel)?.textContent.trim() === 'Alpha renamed', { timeout: 5000 }, `${row(a)} .issues-title`).catch(() => {})
    const tNew = await p.$eval(`${row(a)} .issues-title`, (el) => el.textContent.trim())
    ok(`U1 ${W}: the title is edited in place, Enter saves; Esc keeps the old title (control)`,
      tCtl === 'Alpha row' && tNew === 'Alpha renamed' && !(await modalUp()), { tCtl, tNew })

    await p.click(`${row(a)} [data-test=issues-row-status]`)
    await p.waitForSelector('[data-test=issues-menu-option][data-value="wip"]', { visible: true, timeout: 5000 })
    await p.click('[data-test=issues-menu-option][data-value="wip"]')
    await p.waitForFunction((sel) => document.querySelector(sel)?.getAttribute('data-status') === 'wip', { timeout: 5000 }, `${row(a)} [data-test=issues-row-status]`).catch(() => {})
    await p.select(`${row(a)} [data-test=issues-row-priority]`, '1')
    await p.waitForFunction((sel) => document.querySelector(sel)?.getAttribute('data-priority') === '1', { timeout: 5000 }, row(a)).catch(() => {})
    const sp = await p.$eval(row(a), (el) => ({ status: el.querySelector('[data-test=issues-row-status]').getAttribute('data-status'), prio: el.getAttribute('data-priority') }))
    ok(`U2 ${W}: the Status picker and the prio select save in place`, sp.status === 'wip' && sp.prio === '1', sp)

    await p.click(`${row(a)} [data-test=issues-row-assignee]`)
    await p.waitForSelector('[data-test=issues-menu][data-kind="assign"]', { visible: true, timeout: 5000 })
    const who = await p.$$eval('[data-test=issues-menu-option]', (els) => els.map((e) => e.getAttribute('data-value')).filter(Boolean))
    if (who[0]) await p.click(`[data-test=issues-menu-option][data-value="${who[0]}"]`)
    await p.waitForFunction((sel, want) => document.querySelector(sel)?.getAttribute('data-assignee') === want, { timeout: 5000 }, `${row(a)} [data-test=issues-row-assignee]`, who[0] || '?').catch(() => {})
    const asg = await p.$eval(`${row(a)} [data-test=issues-row-assignee]`, (el) => el.getAttribute('data-assignee'))
    ok(`U3 ${W}: the Assignee cell picks a person in place`, Boolean(who[0]) && asg === who[0], { who: who.slice(0, 3), asg })

    const addBtn = await p.$(`${row(a)} [data-test=issues-row-label-add]`)
    if (addBtn) await addBtn.click()
    await p.waitForSelector('[data-test=issues-menu][data-kind="label"]', { visible: true, timeout: 5000 }).catch(() => {})
    await p.click('[data-test=issues-menu-option][data-value="bug"]').catch(() => {})
    await p.waitForFunction((sel) => [...document.querySelectorAll(sel)].some((e) => e.textContent.includes('Bug')), { timeout: 5000 }, `${row(a)} [data-test=issues-row-label]`).catch(() => {})
    await p.keyboard.press('Escape')
    const lbl = await p.$$eval(`${row(a)} [data-test=issues-row-label]`, (els) => els.map((e) => e.textContent.trim()))
    ok(`U4 ${W}: an empty Labels cell has a + that opens the picker; the label shows on the row`, Boolean(addBtn) && lbl.includes('Bug'), { addBtn: Boolean(addBtn), lbl })

    await p.click(`${row(a)} [data-test=issues-row-deadline]`)
    await p.waitForSelector('[data-test=issues-row-deadline-input]', { visible: true, timeout: 5000 })
    await p.keyboard.press('Escape')
    await sleep(200)
    const dCtl = await p.$eval(`${row(a)} [data-test=issues-row-deadline]`, (el) => el.textContent.trim()).catch(() => 'still-open')
    await p.click(`${row(a)} [data-test=issues-row-deadline]`)
    await p.waitForSelector('[data-test=issues-row-deadline-input]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-row-deadline-input]', '2026-10-02 07:45')
    await p.keyboard.press('Enter')
    await p.waitForFunction((sel) => document.querySelector(sel)?.textContent.trim() === '2026-10-02 07:45', { timeout: 5000 }, `${row(a)} [data-test=issues-row-deadline]`).catch(() => {})
    const dNew = await p.$eval(`${row(a)} [data-test=issues-row-deadline]`, (el) => el.textContent.trim()).catch(() => '')
    ok(`U5 ${W}: the Deadline cell opens the calendar field in place and saves YYYY-MM-DD HH:MM; Esc leaves it empty (control)`,
      dCtl === '' && dNew === '2026-10-02 07:45', { dCtl, dNew })

    /* keyboard: arrows move a cell cursor, Enter edits, Esc cancels */
    await p.click('[data-test=issues-heading]')
    await p.keyboard.press('Escape') /* no cell cursor yet */
    const first = (await keys())[0]
    await p.keyboard.press('ArrowRight')
    const k1 = await cellOn()
    await p.keyboard.press('ArrowRight')
    const k2 = await cellOn()
    await p.keyboard.press('Enter')
    const kIn = await p.waitForSelector('[data-test=issues-row-title-input]', { visible: true, timeout: 3000 }).then(() => true, () => false)
    if (kIn) {
      await p.keyboard.press('End')
      await p.type('[data-test=issues-row-title-input]', ' K')
      await p.keyboard.press('Enter')
    }
    await sleep(300)
    const kTitle = await p.$eval(`${row(first)} .issues-title`, (el) => el.textContent.trim())
    const k3 = await cellOn()
    await p.keyboard.press('ArrowRight')
    await p.keyboard.press('Enter')
    const kMenu = await p.waitForSelector('[data-test=issues-menu][data-kind="status"]', { visible: true, timeout: 3000 }).then(() => true, () => false)
    await p.keyboard.press('Escape')
    const kMenuGone = !(await p.$('[data-test=issues-menu]'))
    await p.keyboard.press('ArrowDown')
    const k4 = await cellOn()
    await p.keyboard.press('Escape')
    const k5 = await cellOn()
    ok(`U6 ${W}: arrows move the cell cursor, Enter edits the title / opens the Status picker, Esc closes it, Down keeps the column`,
      k1?.col === 'key' && k1.key === first && k2?.col === 'title' && k2.focused && kIn && kTitle.endsWith(' K') && k3?.col === 'title' &&
        kMenu && kMenuGone && k4?.col === 'status' && k4.key !== first && k5 === null && !(await modalUp()),
      { k1, k2, kIn, kTitle, k3, kMenu, kMenuGone, k4, k5 })

    /* ---- M: the issue is a modal ------------------------------------------------- */
    await p.click(`${row(b)} .issues-c-key`)
    const opened = await waitModal(true)
    /* the router writes ?issue= a tick after the modal shows (public CI, run
       36395470020 read it too early): wait for it, M8 covers the window */
    await p.waitForFunction((k) => new URL(location.href).searchParams.get('issue') === k, { timeout: 5000 }, b).catch(() => {})
    const m1 = await p.evaluate(() => {
      const dlg = document.querySelector('[data-test=issues-detail]')?.closest('[data-testid=ui-dialog]')
      return {
        modal: dlg?.getAttribute('aria-modal'), title: dlg?.querySelector('.ui-dialog__title')?.textContent.trim(),
        focusIn: Boolean(dlg && dlg.contains(document.activeElement)), focusOn: document.activeElement?.getAttribute('data-testid'),
        aside: document.querySelectorAll('aside.issues-detail').length, divider: Boolean(document.querySelector('[data-testid=pane-divider-issue]')),
        hasTalk: Boolean(dlg?.querySelector('[data-test=issues-talk]')), hasDesc: Boolean(dlg?.querySelector('[data-test=issues-description]')),
        hasSubs: Boolean(dlg?.querySelector('[data-test=issues-subtasks]')), width: Math.round(dlg?.getBoundingClientRect().width || 0),
      }
    })
    ok(`M1 ${W}: a row click opens the issue as a modal (title = key, description, subtasks, discussion), no right pane, focus inside, ?issue= in the URL`,
      opened && m1.modal === 'true' && m1.title === b && m1.focusIn && m1.focusOn === 'ui-dialog-close' && m1.aside === 0 && !m1.divider && m1.hasTalk && m1.hasDesc && m1.hasSubs && (await issueParam()) === b, m1)
    await p.screenshot({ path: `${SHOTS}/modal-${W}.png` })

    await p.$eval('[data-test=issues-detail-title]', (el) => { el.focus(); el.select() })
    await p.type('[data-test=issues-detail-title]', 'Beta via modal')
    await p.click('[data-test=issues-detail-rendered]')
    await p.waitForSelector('[data-test=issues-detail-body]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-detail-body]', 'described in the modal')
    await p.keyboard.press('Escape')
    await p.waitForFunction(() => document.querySelector('[data-test=issues-detail-rendered]')?.textContent.trim() === 'described in the modal', { timeout: 5000 }).catch(() => {})
    const m2 = await p.evaluate((sel) => ({
      rowTitle: document.querySelector(sel)?.textContent.trim(),
      desc: document.querySelector('[data-test=issues-detail-rendered]')?.textContent.trim(),
      still: Boolean(document.querySelector('[data-test=issues-detail]')),
    }), `${row(b)} .issues-title`)
    ok(`M2 ${W}: the title and description are edited in the modal; Esc in the description leaves it (saved) and the modal stays`,
      m2.rowTitle === 'Beta via modal' && m2.desc === 'described in the modal' && m2.still, m2)

    await p.keyboard.press('KeyS')
    const m3menu = await p.waitForSelector('[data-test=issues-menu][data-kind="status"]', { visible: true, timeout: 3000 }).then(() => p.evaluate(() => {
      const m = document.querySelector('[data-test=issues-menu]')
      const r = m.getBoundingClientRect()
      const top = document.elementFromPoint(r.left + r.width / 2, r.top + 12)
      /* it opens under the modal's Status field, not at a corner of the page */
      const f = document.querySelector('[data-test=issues-detail] [data-test=issues-status]').getBoundingClientRect()
      return { onTop: Boolean(top && m.contains(top)), z: getComputedStyle(m).zIndex, under: Math.abs(r.top - (f.bottom + 4)) <= 2 && Math.abs(r.left - f.left) <= 2 }
    }), () => null)
    await p.keyboard.press('Escape')
    const m3 = { menuGone: !(await p.$('[data-test=issues-menu]')), still: await modalUp() }
    ok(`M3 ${W}: S opens the Status picker above the modal, under its Status field; Esc closes the picker only`, Boolean(m3menu?.onTop && m3menu.under) && m3.menuGone && m3.still, { m3menu, m3 })

    await p.keyboard.press('Escape')
    const escClosed = await waitModal(false)
    const m4issue = await paramSettles(null)
    const m4 = await p.evaluate((k) => ({ focusRow: document.activeElement?.closest('[data-test=issues-row]')?.getAttribute('data-key') === k }), b)
    m4.issue = m4issue
    ok(`M4 ${W}: Esc closes the modal, ?issue= goes, focus returns to the row`, escClosed && m4.focusRow && m4.issue === null, m4)

    await p.click(`${row(c)} .issues-c-key`)
    await waitModal(true)
    /* the modal shows at once; the router writes ?issue= a tick later. Back
       before that entry exists goes one entry too far and leaves nothing to
       go Forward to (a fast hosted runner, workflow 11 run 36393403727) */
    await p.waitForFunction((k) => new URL(location.href).searchParams.get('issue') === k, { timeout: 5000 }, c)
    const pathBefore = await p.evaluate(() => location.pathname)
    await p.goBack()
    const backClosed = await waitModal(false)
    const m5 = { issue: await paramSettles(null), path: await p.evaluate(() => location.pathname) }
    await p.goForward()
    const fwdOpen = await waitModal(true)
    const fwdKey = await paramSettles(c)
    await p.click('[data-testid=ui-dialog-close]')
    await waitModal(false)
    ok(`M5 ${W}: browser Back closes the modal and stays on the sheet; Forward opens it again; X closes`,
      backClosed && m5.path === pathBefore && m5.issue === null && fwdOpen && fwdKey === c, { backClosed, m5, fwdOpen, fwdKey })

    await p.click(`${row(c)} .issues-c-key`)
    await waitModal(true)
    await p.mouse.click(4, 450)
    const bdClosed = await waitModal(false)
    ok(`M6 ${W}: a click on the backdrop closes the modal`, bdClosed, { bdClosed })

    /* ---- D: delete ------------------------------------------------------------------ */
    await p.click(`${row(c)} [data-test=issues-row-delete]`)
    await p.waitForSelector('[data-testid=issues-delete-cancel]', { visible: true, timeout: 5000 })
    const dAsk = await p.$eval('[data-testid=issues-delete-body]', (el) => ({ key: el.getAttribute('data-key'), text: el.textContent.trim() }))
    await p.click('[data-testid=issues-delete-cancel]')
    await p.waitForFunction(() => !document.querySelector('[data-testid=issues-delete-cancel]'), { timeout: 5000 })
    const dCtl2 = (await keys()).includes(c)
    await p.click(`${row(c)} [data-test=issues-row-delete]`)
    await p.waitForSelector('[data-testid=issues-delete-confirm]', { visible: true, timeout: 5000 })
    await p.click('[data-testid=issues-delete-confirm]')
    await p.waitForFunction((sel) => !document.querySelector(sel), { timeout: 5000 }, row(c)).catch(() => {})
    const dGone = !(await keys()).includes(c)
    const dDlg = await p.$('[data-testid=ui-dialog]').then(Boolean)
    ok(`D1 ${W}: the row delete asks with the one confirm (key + title); Cancel keeps the row (control); Delete removes it`,
      dAsk.key === c && dAsk.text.includes('Gamma row') && dCtl2 && dGone && !dDlg, { dAsk, dCtl2, dGone, dDlg })

    /* a parent with a live subtask is refused, and the row stays */
    await p.click(`${row(b)} .issues-c-key`)
    await waitModal(true)
    await p.click('[data-test=issues-subtask-open]')
    await p.waitForFunction(() => document.activeElement?.getAttribute('data-test') === 'issues-subtask-input', { timeout: 5000 })
    await p.type('[data-test=issues-subtask-input]', 'a child')
    await p.keyboard.press('Enter')
    await p.waitForSelector('[data-test=issues-subtask]', { visible: true, timeout: 5000 }).catch(() => {})
    // CLE-77854: Delete is its own button in the modal header, not the body
    await p.click('[data-test=issues-detail-delete]')
    await p.waitForSelector('[data-testid=issues-delete-confirm]', { visible: true, timeout: 5000 })
    await p.click('[data-testid=issues-delete-confirm]')
    const refused = await p.waitForSelector('[data-testid=issues-delete-error]', { visible: true, timeout: 5000 }).then((h) => h.evaluate((el) => el.textContent.trim()), () => '')
    await p.click('[data-testid=issues-delete-cancel]')
    await sleep(200)
    const d2 = { stays: (await keys()).includes(b), modal: await modalUp() }
    ok(`D2 ${W}: deleting a parent with a live subtask is refused with a reason; the issue stays open`,
      refused === 'Delete or move its subtasks first.' && d2.stays && d2.modal, { refused, d2 })
    await p.keyboard.press('Escape')
    await waitModal(false)

    /* M8: Esc inside the window before the router has written ?issue= (a
       slow router: every navigation waits 400 ms). The modal must stay
       closed - before the fix the late push reopened it - and no ?issue=. */
    await p.evaluate(() => { window.__slowOff = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.beforeEach(() => new Promise((r) => setTimeout(r, 400))) })
    await p.click(`${row(a)} .issues-c-key`)
    await waitModal(true)
    await p.keyboard.press('Escape')
    await sleep(1500)
    const m8 = await p.evaluate(() => ({ modal: Boolean(document.querySelector('[data-test=issues-detail]')), issue: new URL(location.href).searchParams.get('issue') }))
    await p.evaluate(() => window.__slowOff && window.__slowOff())
    ok(`M8 ${W}: Esc before the router wrote ?issue= keeps the modal closed and leaves no ?issue=`, !m8.modal && m8.issue === null, m8)

    /* deep link: a reload is a fresh mock tenant, whose one issue is the epic SPL-1 */
    await p.goto(server.base + '/issues?issue=SPL-1', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const deep = await waitModal(true)
    const deepTitle = await p.$eval('[data-test=issues-detail]', (el) => el.closest('[data-testid=ui-dialog]')?.querySelector('.ui-dialog__title')?.textContent.trim()).catch(() => '')
    await p.keyboard.press('Escape')
    const deepClosed = await waitModal(false)
    const deepParam = await paramSettles(null)
    ok(`M7 ${W}: a deep link ?issue=SPL-1 opens it as the modal; Esc closes it and drops ?issue=`, deep && deepTitle === 'SPL-1' && deepClosed && deepParam === null, { deep, deepTitle, deepClosed, deepParam })

    const wide = await p.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }))
    ok(`X1 ${W}: no horizontal page scroll`, wide.sw <= wide.cw + 1, wide)
    const mine = errors.filter((e) => !/Failed to fetch dynamically imported module|ResizeObserver loop/.test(e))
    ok(`X2 ${W}: no page errors`, mine.length === 0, mine)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed (shots: ${SHOTS})`)
if (failed.length) {
  console.log(failed.map((r) => r.name).join('\n'))
  process.exit(1)
}
