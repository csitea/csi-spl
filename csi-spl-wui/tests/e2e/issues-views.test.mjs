// SPL-1028 (owner, prd t1 topic 89485c7a): "introduce the Linear-style
// grouping of issues in views, i.e. the default is a list, but there could be
// a view by status as well". In a real browser, mock tenant, 1440 px:
//   V0  control: the default is the list - no group headers
//   V1  By status: one group per status in the workflow order, each with its
//       count, every row under its own status
//   V2  a group folds and unfolds; the count stays
//   V3  a row dragged onto another group takes that status
//   V4  a group's + files the new row straight into that status
//   V5  the Status cell moves a row to its new group; the cells stay editable
//   V6  signed in, the view is the person's (the issues_view claim) and a
//       switch is sent to the hub as {"issues_view": ...}
//
//   pnpm run test:e2e:issues-views
//   BASE_URL=<generated bundle> pnpm run test:e2e:issues-views
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const ORDER = ['eval', 'todo', 'wip', 'diss', 'blocked', 'onhold', 'qas', 'done']
const row = (key) => `[data-test=issues-row][data-key="${key}"]`

/* what the sheet shows: each group's status, count and the rows under it */
const layout = (p) => p.evaluate(() => [...document.querySelectorAll('[data-test=issues-group]')].map((g) => ({
  status: g.getAttribute('data-status'),
  head: Boolean(g.querySelector('[data-test=issues-group-h]')),
  count: Number(g.querySelector('[data-test=issues-group-count]')?.textContent || -1),
  rows: [...g.querySelectorAll('[data-test=issues-row]')].map((r) => ({ key: r.getAttribute('data-key'), status: r.querySelector('[data-test=issues-row-status]').getAttribute('data-status') })),
})))

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-table]', { visible: true, timeout: NAV_TIMEOUT })

  async function createRow(title, status) {
    await p.click('[data-test=issues-new]')
    await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-newrow-title]', title)
    await p.keyboard.press('Enter')
    const key = await p.waitForFunction((want) => {
      const r = [...document.querySelectorAll('[data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === want)
      return r ? r.getAttribute('data-key') : false
    }, { timeout: 5000 }, title).then((h) => h.jsonValue())
    if (status && status !== 'todo') {
      await p.click(`${row(key)} [data-test=issues-row-status]`)
      await p.waitForSelector(`[data-test=issues-menu-option][data-value="${status}"]`, { visible: true, timeout: 5000 })
      await p.click(`[data-test=issues-menu-option][data-value="${status}"]`)
      await p.waitForFunction((sel, st) => document.querySelector(sel)?.getAttribute('data-status') === st, { timeout: 5000 }, `${row(key)} [data-test=issues-row-status]`, status)
    }
    return key
  }
  const a = await createRow('Todo one', 'todo')
  const b = await createRow('Todo two', 'todo')
  const c = await createRow('In progress', 'wip')
  const d = await createRow('Being checked', 'qas')

  /* V0: the control */
  const v0 = await layout(p)
  const radios0 = await p.$$eval('[data-test=issues-view]', (els) => els.map((e) => [e.getAttribute('data-value'), e.getAttribute('aria-checked')]))
  ok('V0 the default view is the list: one group, no headers; the switch reads List',
    v0.length === 1 && !v0[0].head && v0[0].rows.length === 4 && JSON.stringify(radios0) === JSON.stringify([['list', 'true'], ['status', 'false']]), { v0: v0.map((g) => [g.status, g.head, g.rows.length]), radios0 })

  /* V1: by status */
  await p.click('[data-test=issues-view][data-value="status"]')
  await p.waitForSelector('[data-test=issues-group-h]', { visible: true, timeout: 5000 })
  const v1 = await layout(p)
  const placed = v1.every((g) => g.rows.every((r) => r.status === g.status) && g.count === g.rows.length)
  const counts = Object.fromEntries(v1.map((g) => [g.status, g.count]))
  /* the header is a full-width table row (a stale rule once made it a narrow flex box) */
  const hw = await p.evaluate(() => {
    const tr = document.querySelector('[data-test=issues-group-h]')
    return { tr: getComputedStyle(tr).display, w: Math.round(tr.querySelector('th').getBoundingClientRect().width), table: Math.round(document.querySelector('[data-test=issues-table]').getBoundingClientRect().width) }
  })
  ok('V1a each group header is a table row as wide as the sheet', hw.tr === 'table-row' && hw.w >= hw.table - 2, hw)
  ok('V1 By status: one group per status in the workflow order, each with its count, every row under its status',
    JSON.stringify(v1.map((g) => g.status)) === JSON.stringify(ORDER) && v1.every((g) => g.head) && placed &&
      counts.todo === 2 && counts.wip === 1 && counts.qas === 1 && counts.eval === 0, { order: v1.map((g) => g.status), counts, placed })
  await p.screenshot({ path: `${process.env.ISSUES_SHOTS || '/tmp'}/views-status.png` }).catch(() => {})

  /* V2: fold and unfold */
  await p.click('[data-test=issues-group][data-status="todo"] [data-test=issues-group-fold]')
  await sleep(200)
  const fold = await p.$eval('[data-test=issues-group][data-status="todo"]', (g) => ({ rows: g.querySelectorAll('[data-test=issues-row]').length, count: g.querySelector('[data-test=issues-group-count]').textContent.trim(), exp: g.querySelector('[data-test=issues-group-fold]').getAttribute('aria-expanded') }))
  await p.click('[data-test=issues-group][data-status="todo"] [data-test=issues-group-fold]')
  await sleep(200)
  const unfold = await p.$eval('[data-test=issues-group][data-status="todo"]', (g) => g.querySelectorAll('[data-test=issues-row]').length)
  ok('V2 a group folds (rows hidden, count kept, aria-expanded false) and unfolds', fold.rows === 0 && fold.count === '2' && fold.exp === 'false' && unfold === 2, { fold, unfold })

  /* V3: drag a row onto another group (the page's own drag handlers, a real DataTransfer) */
  await p.evaluate((from, toStatus) => {
    const src = document.querySelector(from)
    const dst = document.querySelector(`[data-test=issues-group][data-status="${toStatus}"]`)
    const dt = new DataTransfer()
    src.dispatchEvent(new DragEvent('dragstart', { bubbles: true, cancelable: true, dataTransfer: dt }))
    dst.dispatchEvent(new DragEvent('dragover', { bubbles: true, cancelable: true, dataTransfer: dt }))
    dst.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt }))
    src.dispatchEvent(new DragEvent('dragend', { bubbles: true, cancelable: true, dataTransfer: dt }))
  }, row(a), 'blocked')
  await p.waitForFunction((k) => document.querySelector(`[data-test=issues-group][data-status="blocked"] [data-test=issues-row][data-key="${k}"]`), { timeout: 5000 }, a).catch(() => {})
  const v3 = await layout(p)
  const byStatus = Object.fromEntries(v3.map((g) => [g.status, g.rows.map((r) => r.key)]))
  const drag = await p.$eval(row(a), (el) => el.getAttribute('draggable'))
  ok('V3 a row dragged onto 05-blocked takes that status and moves there (the drag is the status change)',
    drag === 'true' && byStatus.blocked.includes(a) && !byStatus.todo.includes(a) && byStatus.todo.includes(b), { drag, blocked: byStatus.blocked, todo: byStatus.todo })

  /* V4: a group's + */
  await p.click('[data-test=issues-group][data-status="onhold"] [data-test=issues-group-add]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  const draftStatus = await p.$eval('[data-test=issues-newrow-status]', (el) => el.getAttribute('data-status'))
  await p.type('[data-test=issues-newrow-title]', 'Waiting on purpose')
  await p.keyboard.press('Enter')
  const e = await p.waitForFunction(() => {
    const r = [...document.querySelectorAll('[data-test=issues-group][data-status="onhold"] [data-test=issues-row]')].find((x) => x.querySelector('.issues-title')?.textContent.trim() === 'Waiting on purpose')
    return r ? r.getAttribute('data-key') : false
  }, { timeout: 5000 }).then((h) => h.jsonValue(), () => '')
  ok('V4 a group\'s + opens the new row already in that status; Enter stores it in that group', draftStatus === 'onhold' && Boolean(e), { draftStatus, e })

  /* V5: the Status cell moves the row; a title still edits in place */
  await p.click(`${row(c)} [data-test=issues-row-status]`)
  await p.waitForSelector('[data-test=issues-menu-option][data-value="done"]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-menu-option][data-value="done"]')
  await p.waitForFunction((k) => document.querySelector(`[data-test=issues-group][data-status="done"] [data-test=issues-row][data-key="${k}"]`), { timeout: 5000 }, c).catch(() => {})
  await p.click(`${row(d)} [data-test=issues-row-title-edit]`)
  await p.waitForSelector('[data-test=issues-row-title-input]', { visible: true, timeout: 5000 })
  await p.keyboard.press('End')
  await p.type('[data-test=issues-row-title-input]', ' again')
  await p.keyboard.press('Enter')
  await sleep(300)
  const v5 = await layout(p)
  const v5s = Object.fromEntries(v5.map((g) => [g.status, g.rows.map((r) => r.key)]))
  const dTitle = await p.$eval(`${row(d)} .issues-title`, (el) => el.textContent.trim())
  ok('V5 the Status cell moves a row to its new group; the title still edits in place in the grouped view',
    v5s.done.includes(c) && !v5s.wip.includes(c) && dTitle === 'Being checked again', { done: v5s.done, wip: v5s.wip, dTitle })

  /* back to the list: the same rows, flat */
  await p.click('[data-test=issues-view][data-value="list"]')
  await sleep(300)
  const back = await layout(p)
  ok('V0b List again: one flat group with every row', back.length === 1 && !back[0].head && back[0].rows.length === 5, back.map((g) => [g.status, g.rows.length]))

  /* V6: signed in, the view is the person's claim; a switch goes to the hub */
  const puts = []
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (req.method() === 'PUT' && req.url().includes('/preferences')) {
      puts.push(req.postData())
      const body = JSON.parse(req.postData() || '{}')
      return req.respond({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': new URL(server.base).origin, 'access-control-allow-credentials': 'true' }, body: JSON.stringify(body) })
    }
    return req.continue()
  })
  await p.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    s.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', issues_view: 'status' })
  })
  await sleep(400)
  const claimView = await p.$$eval('[data-test=issues-group-h]', (els) => els.length)
  await p.click('[data-test=issues-view][data-value="list"]')
  await sleep(600)
  const after = await p.evaluate(() => ({
    heads: document.querySelectorAll('[data-test=issues-group-h]').length,
    claim: document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session').claims?.issues_view,
  }))
  ok('V6 signed in, the issues_view claim picks the view (status); List is sent as {"issues_view":"list"} and the claim follows',
    claimView === 8 && after.heads === 0 && after.claim === 'list' && puts.some((x) => JSON.parse(x).issues_view === 'list'), { claimView, after, puts })

  const wide = await p.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth }))
  ok('X1 no horizontal page scroll', wide.sw <= wide.cw + 1, wide)
  const mine = errors.filter((x) => !/Failed to fetch dynamically imported module|ResizeObserver loop/.test(x))
  ok('X2 no page errors', mine.length === 0, mine)
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
