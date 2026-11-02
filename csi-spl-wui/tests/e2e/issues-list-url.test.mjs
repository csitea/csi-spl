// SPL-4648 (owner, t1 e04820a5, msgs f30329a2 + 9e36c1a2: "the full state of the
// issues listing should be setable from the URL of it", "point to a certain set
// of issues by simply copy asting the url"). In a REAL browser, mock bundle, at
// 1440 and 390. localStorage spool.mock.issues-shaped: SPL-2 matches every
// filter below, SPL-3..8 each miss exactly one (a listed row is always level 2), so a dropped parameter shows a row.
//
//   1  a URL with every parameter: those filters selected, exactly those rows
//   2  it stays in the address once the page has settled
//   3  reload keeps it
//   4  changing one filter rewrites the URL and the rows
//   4b a pick that closes its phone sheet still lands in the URL
//   5  Clear filters clears them from the URL
//   6  Back and Forward follow the URL
//   7  bad values: ignored, no error, the list shows, the URL drops them
//   8  a link of today's parameters still works
//   9  a parameter beats a stored choice; no parameter takes it and completes the URL
//  10  the copied URL, a second member in a fresh browser: the same rows
//  11  a move to another page on its way is not cancelled by the list's own replace
//  11b that move refused: the address catches up with the filter
//
//   BASE_URL=<generated mock bundle> pnpm run test:e2e issues-list-url
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined || pass ? '' : ' ' + JSON.stringify(ev)}`)
}

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const VIEWPORTS = [
  { tag: '1440', vp: { width: 1440, height: 900 }, row: '[data-test=issues-row]' },
  { tag: '390', vp: { width: 390, height: 844, isMobile: true, hasTouch: true }, row: '[data-test=issues-card]' },
]
const SHAPED = 'status=wip&priority=2&level=2&assignee=HUM-2&label=bug&deadline=2026-12-02T12:00&epic=SPL-1'
const SHAPED_ME = SHAPED.replace('HUM-2', 'HUM-1')
const FULL = `/issues?view=status&sort=title&dir=desc&${SHAPED_ME}&fold=eval`
const HOME = (hum) => JSON.stringify({ hum, name: 'FirstName LastName', email: 'member@example.com', t: 'mock' })

async function open(browser, vp, path, seed = {}) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  const store = { 'spool.mock.session': HOME('HUM-1'), 'spool.mock.issues-shaped': '1', ...seed }
  await p.evaluateOnNewDocument((s) => {
    try { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, v) } catch { /* about:blank */ }
  }, store)
  await setPageViewport(p, vp)
  await p.goto(server.base + path, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  return { p, ctx, errors }
}

const keys = (p, sel) => p.$$eval(sel, (els) => els.map((e) => e.getAttribute('data-key')).sort())
const params = (p) => p.evaluate(() => Object.fromEntries(new URL(window.location.href).searchParams))
const param = (p, k) => params(p).then((q) => q[k])
const settle = (p, sel, want) => p.waitForFunction((s, w) => [...document.querySelectorAll(s)].map((e) => e.getAttribute('data-key')).sort().join() === w, { timeout: 8000 }, sel, want).then(() => true, () => false)
const urlHas = (p, k, v) => p.waitForFunction((a, b) => (new URL(window.location.href).searchParams.get(a) ?? '') === b, { timeout: 8000 }, k, v).then(() => true, () => false)

/* the controls say the filters; on a phone they live in the filter sheet */
async function controls(p, phone) {
  if (phone) {
    await p.click('[data-test=issues-filters-open]')
    await p.waitForSelector('[data-test=issues-filter-priority]', { visible: true, timeout: 8000 })
  }
  const got = await p.evaluate((isPhone) => {
    const val = (t) => document.querySelector(`[data-test=${t}]`)?.value
    return {
      status: isPhone ? document.querySelector('[data-test=issues-filter-status-m-opt][aria-checked=true]')?.getAttribute('data-value') : document.querySelector('[data-test=issues-filter-status-btn]')?.textContent.trim(),
      priority: val('issues-filter-priority'),
      level: val('issues-filter-level'),
      label: val('issues-filter-label'),
      deadline: document.querySelector('[data-test=issues-filter-deadline-date]')?.value ?? document.querySelector('[data-test=issues-filter-deadline-date-open]')?.textContent.trim(),
      view: document.querySelector('[data-test=issues-view][aria-checked=true]')?.getAttribute('data-value') || '',
      sort: document.querySelector('[aria-sort=descending]')?.getAttribute('data-col') || document.querySelector('[data-test=issues-sorted-by]')?.getAttribute('data-sort') || '',
    }
  }, phone)
  if (phone) {
    await p.click('[data-test=issues-filter-sheet-done]')
    await p.waitForFunction(() => !document.querySelector('[data-test=issues-filter-sheet-done]'), { timeout: 8000 })
  }
  return got
}

const server = await startServer()
const browser = await launch()
try {
  for (const { tag, vp, row } of VIEWPORTS) {
    const phone = tag === '390'
    const a = await open(browser, vp, FULL)
    const { p } = a
    const one = await settle(p, row, 'SPL-2')
    const c = await controls(p, phone)
    const filtersShown = c.priority === '2' && c.level === '2' && c.label === 'bug' && String(c.deadline || '').includes('2026-12-02') && (phone ? c.status === 'wip' && c.sort === 'title:desc' : c.status !== '' && c.status !== 'All' && c.view === 'status' && c.sort === 'title')
    ok(`1 ${tag}: every parameter: those filters selected, only SPL-2 (each other row misses one)`, one && filtersShown, { one, c, rows: await keys(p, row) })
    if (!phone) {
      const fold = await p.$eval('[data-test=issues-group-h][data-status=eval] [data-test=issues-group-fold]', (e) => e.getAttribute('aria-expanded'))
      ok(`1b ${tag}: ?fold=eval folds that group and leaves wip open`, fold === 'false' && (await keys(p, `[data-test=issues-group][data-status=wip] ${row}`)).join() === 'SPL-2', { fold })
    }
    const lvl = await open(browser, vp, '/issues?view=list&level=1')
    await lvl.p.waitForFunction((s) => !document.querySelector(s), { timeout: 8000 }, row).catch(() => null)
    ok(`1c ${tag}: ?level= is honoured: no listed issue is level 1, and the URL keeps it`, (await keys(lvl.p, row)).length === 0 && (await param(lvl.p, 'level')) === '1', await params(lvl.p))
    await lvl.ctx.close()
    const q0 = await params(p)
    const whole = { view: 'status', sort: 'title', dir: 'desc', status: 'wip', priority: '2', level: '2', assignee: 'HUM-1', label: 'bug', deadline: '2026-12-02T12:00', epic: 'SPL-1', fold: 'eval' }
    ok(`2 ${tag}: the address still names all of them`, JSON.stringify(Object.entries(q0).sort()) === JSON.stringify(Object.entries(whole).sort()), q0)
    await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    ok(`3 ${tag}: reload keeps it`, (await settle(p, row, 'SPL-2')) && JSON.stringify(Object.entries(await params(p)).sort()) === JSON.stringify(Object.entries(whole).sort()), await params(p))

    if (phone) {
      await p.click('[data-test=issues-filters-open]')
      await p.waitForSelector('[data-test=issues-filter-priority]', { visible: true, timeout: 8000 })
    }
    await p.select('[data-test=issues-filter-priority]', '')
    const dropped = await urlHas(p, 'priority', '')
    const grew = await settle(p, row, 'SPL-2,SPL-4')
    ok(`4 ${tag}: a changed filter rewrites the URL and the rows`, dropped && grew, { dropped, grew, rows: await keys(p, row), q: await params(p) })

    await p.click('[data-test=issues-filter-clear]')
    await p.waitForFunction(() => !new URL(window.location.href).searchParams.has('status'), { timeout: 8000 }).catch(() => null)
    if (phone) {
      await p.click('[data-test=issues-filter-sheet-done]')
      await p.waitForFunction(() => !document.querySelector('[data-test=issues-filter-sheet-done]'), { timeout: 8000 })
    }
    const after = await params(p)
    const clearedAll = ['sort', 'dir', 'status', 'priority', 'level', 'assignee', 'label', 'deadline'].every((k) => !(k in after))
    ok(`5 ${tag}: Clear filters clears them from the URL; the epic and the view are no filters`, clearedAll && after.epic === 'SPL-1' && after.view === 'status', after)
    await a.ctx.close()

    if (phone) {
      const s = await open(browser, vp, '/issues?view=list&epic=SPL-1')
      await s.p.click('[data-test=issues-sort-open]')
      await s.p.waitForSelector('[data-test=issues-sort-sheet]', { visible: true, timeout: 8000 })
      await s.p.click('[data-test=issues-sort-opt][data-value="key"]')
      const landed = await urlHas(s.p, 'sort', 'key')
      await new Promise((r) => setTimeout(r, 500))
      const q = await params(s.p)
      await s.p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      const sortedBy = await s.p.$eval('[data-test=issues-sorted-by]', (e) => e.getAttribute('data-sort'))
      ok(`4b ${tag}: a sort picked in its sheet, which closes on the pick, stays in the URL and over a reload`, landed && q.sort === 'key' && q.dir === 'asc' && q.epic === 'SPL-1' && sortedBy === 'key:asc', { landed, q, sortedBy })
      await s.ctx.close()
    }

    const b = await open(browser, vp, '/issues?status=wip&view=list')
    await settle(b.p, row, 'SPL-2,SPL-4,SPL-5,SPL-6,SPL-7,SPL-8')
    await b.p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/issues?status=todo&view=list'))
    const pushed = await settle(b.p, row, 'SPL-3')
    await b.p.goBack()
    const back = (await settle(b.p, row, 'SPL-2,SPL-4,SPL-5,SPL-6,SPL-7,SPL-8')) && (await param(b.p, 'status')) === 'wip'
    await b.p.goForward()
    const forward = (await settle(b.p, row, 'SPL-3')) && (await param(b.p, 'status')) === 'todo'
    ok(`6 ${tag}: Back and Forward follow the URL`, pushed && back && forward, { pushed, back, forward, rows: await keys(b.p, row) })
    await b.ctx.close()

    const bad = await open(browser, vp, '/issues?view=grid&sort=nope&dir=up&status=nope&priority=9&level=x&assignee=NO-ONE&label=nolabel&deadline=2026-13-45T99:99&epic=SPL-999&fold=zz')
    const allRows = await settle(bad.p, row, 'SPL-2,SPL-3,SPL-4,SPL-5,SPL-6,SPL-7,SPL-8')
    const left = await params(bad.p)
    const alerts = await bad.p.$$eval('[role=alert]', (els) => els.map((e) => e.textContent.trim()).filter(Boolean))
    const cleanUrl = ['status', 'priority', 'level', 'assignee', 'label', 'deadline', 'epic', 'sort', 'dir', 'fold'].every((k) => !(k in left))
    ok(`7 ${tag}: bad values are ignored: the list shows, no error, the URL drops them`, allRows && cleanUrl && alerts.length === 0 && bad.errors.length === 0, { rows: await keys(bad.p, row), left, alerts, errors: bad.errors })
    await bad.ctx.close()

    const old = await open(browser, vp, '/issues?sort=priority&dir=desc&epic=SPL-1')
    const oldRows = await settle(old.p, row, 'SPL-2,SPL-3,SPL-4,SPL-5,SPL-6,SPL-7')
    const oldQ = await params(old.p)
    ok(`8 ${tag}: a link of today's parameters still works`, oldRows && oldQ.sort === 'priority' && oldQ.dir === 'desc' && oldQ.epic === 'SPL-1', { oldQ, rows: await keys(old.p, row) })
    await old.ctx.close()

    if (!phone) {
      const claim = { 'spool.issues-folded': JSON.stringify(['todo']) }
      const named = await open(browser, vp, '/issues?view=status&fold=wip', claim)
      await named.p.waitForSelector('[data-test=issues-group-h][data-status=wip]', { timeout: 8000 })
      const foldOf = (pg, st) => pg.$eval(`[data-test=issues-group-h][data-status=${st}] [data-test=issues-group-fold]`, (e) => e.getAttribute('aria-expanded'))
      ok(`9 ${tag}: ?fold= beats the stored folds`, (await foldOf(named.p, 'wip')) === 'false' && (await foldOf(named.p, 'todo')) === 'true', await params(named.p))
      await named.ctx.close()
      const none = await open(browser, vp, '/issues?view=status', claim)
      await none.p.waitForSelector('[data-test=issues-group-h][data-status=wip]', { timeout: 8000 })
      ok(`9b ${tag}: a URL with ?view= is complete: the stored folds do not apply to it`, (await foldOf(none.p, 'todo')) === 'true', await params(none.p))
      await none.ctx.close()
      const bare = await open(browser, vp, '/issues?unread=', claim)
      await bare.p.click('[data-test=issues-view][data-value=status]')
      await urlHas(bare.p, 'view', 'status')
      const foldedOn = await foldOf(bare.p, 'todo').catch(() => '')
      ok(`9c ${tag}: no ?view= takes the stored folds and writes them to the URL`, foldedOn === 'false' && (await param(bare.p, 'fold')) === 'todo', { foldedOn, q: await params(bare.p) })
      await bare.ctx.close()
    }

    if (!phone) {
      const slowMove = (pg, refuse) => pg.evaluate((no) => {
        const r = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router
        window.__slowOff = r.beforeEach((to) => (to.path === '/issues' ? undefined : new Promise((res) => setTimeout(() => res(no ? false : undefined), 800))))
        void r.push('/channel/lobby')
      }, refuse)
      const l = await open(browser, vp, '/issues?view=list')
      await settle(l.p, row, 'SPL-2,SPL-3,SPL-4,SPL-5,SPL-6,SPL-7,SPL-8')
      await slowMove(l.p, false)
      await l.p.select('[data-test=issues-filter-priority]', '2')
      const moved = await l.p.waitForFunction(() => window.location.pathname.endsWith('/channel/lobby'), { timeout: 8000 }).then(() => true, () => false)
      ok(`11 ${tag}: a filter changed while a move to another page is on its way does not cancel the move`, moved, l.p.url())
      await l.ctx.close()
      const r = await open(browser, vp, '/issues?view=list')
      await settle(r.p, row, 'SPL-2,SPL-3,SPL-4,SPL-5,SPL-6,SPL-7,SPL-8')
      await slowMove(r.p, true)
      await r.p.select('[data-test=issues-filter-priority]', '2')
      const caught = await urlHas(r.p, 'priority', '2')
      ok(`11b ${tag}: that move refused: the page stays and the address catches up with the filter`, caught && new URL(r.p.url()).pathname === '/issues', r.p.url())
      await r.ctx.close()
    }

    const first = await open(browser, vp, FULL.replace('&fold=eval', ''))
    await settle(first.p, row, 'SPL-2')
    const copied = first.p.url()
    const second = await open(browser, vp, new URL(copied).pathname + new URL(copied).search, { 'spool.mock.session': HOME('HUM-2') })
    const same = await settle(second.p, row, 'SPL-2')
    ok(`10 ${tag}: the copied URL, another member in a fresh browser: the same rows, the same person`, same && (await param(second.p, 'assignee')) === 'HUM-1', { copied, rows: await keys(second.p, row), q: await params(second.p) })
    ok(`X ${tag}: no page errors`, first.errors.length === 0 && second.errors.length === 0, [...first.errors, ...second.errors])
    await first.ctx.close()
    await second.ctx.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nissues-list-url: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
