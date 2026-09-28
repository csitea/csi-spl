// SPL-1132 (owner, prd t1 topic beb4024f): "the columns of the issues grid
// should be resizeable". In a real browser, mock tenant, 1440 px:
//   R0  control: no stored width = today's layout (Title takes the rest)
//   R1  dragging the Status header's edge by +120 px widens exactly that
//       column; a drag never sorts
//   R2  the body cells follow the header, in the list and in By status
//   R3  shrinking Assignee below its content clips the cells, it never
//       overflows into the next column
//   R4  keyboard: ArrowRight on the focused grip, Alt+ArrowLeft on the
//       header's sort button; a plain click on the header still sorts
//   R5  Title has its own floor (160 px), not the common 48 px
//   R6  a reload keeps the widths (per browser)
//   R7  a double-click fits the column to its content; Delete on the grip
//       gives the automatic width back
//   R8  signed in, the widths are the person's (SPL-1132): the
//       issues_columns claim sizes the sheet, one drag sends ONE PUT
//       {"issues_columns": ...} after release, and the per-browser store is
//       left alone
//
//   pnpm run test:e2e:issues-col-resize
//   BASE_URL=<generated bundle> pnpm run test:e2e:issues-col-resize
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
/* the header cell and every body cell of one column, in px */
const widths = (p, col) => p.evaluate((col) => {
  const r = (el) => Math.round(el.getBoundingClientRect().width)
  const th = document.querySelector(`[data-test=issues-table] .issues-names th[data-col="${col}"]`)
  const tds = [...document.querySelectorAll(`[data-test=issues-row] td[data-col="${col}"]`)]
  const table = document.querySelector('[data-test=issues-table]')
  return { th: th ? r(th) : 0, tds: tds.map(r), table: r(table), sorted: th?.getAttribute('aria-sort') || '' }
}, col)

async function drag(p, col, dx) {
  const box = await p.$eval(`[data-test="issues-col-grip-${col}"]`, (g) => {
    const b = g.getBoundingClientRect()
    return { x: b.x + b.width / 2, y: b.y + b.height / 2 }
  })
  await p.mouse.move(box.x, box.y)
  await p.mouse.down()
  for (let i = 1; i <= 6; i++) await p.mouse.move(box.x + (dx * i) / 6, box.y)
  await p.mouse.up()
  await sleep(150)
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-table]', { visible: true, timeout: NAV_TIMEOUT })
  await p.evaluate(() => { try { localStorage.removeItem('spool.issues.colw') } catch { /* none */ } })

  for (const title of ['A short one', 'A much longer issue title that needs a lot of room on the sheet to be read in full']) {
    await p.click('[data-test=issues-new]')
    await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
    await p.type('[data-test=issues-newrow-title]', title)
    await p.keyboard.press('Enter')
    await p.waitForFunction((want) => [...document.querySelectorAll('[data-test=issues-row] .issues-title')].some((x) => x.textContent.trim() === want), { timeout: 5000 }, title)
  }

  /* R0 */
  const t0 = await widths(p, 'title')
  const s0 = await widths(p, 'status')
  const grips = await p.$$eval('.issues-col-grip', (g) => g.map((x) => x.getAttribute('data-test')))
  /* "the rest" is measured, not a fixed px: the runner's fonts move it
     (CI Title 262 px, this box 306 px) - the table fills its scroller and
     Title is above its own 160 px floor */
  const fill = await p.evaluate(() => {
    const table = document.querySelector('[data-test=issues-table]')
    return { table: Math.round(table.getBoundingClientRect().width), box: Math.round(table.parentElement.clientWidth) }
  })
  ok('R0 control: nine grips, no stored width, Title takes the rest of the sheet',
    grips.length === 9 && t0.th > 160 && Math.abs(fill.table - fill.box) <= 1 && !(await p.$('[data-test=issues-table][class*="issues-w-"]')), { grips: grips.length, t0, s0, fill })

  /* R1 + R2 */
  await drag(p, 'status', 120)
  const s1 = await widths(p, 'status')
  ok('R1 dragging the Status edge +120 px widens exactly Status; the drag did not sort',
    Math.abs(s1.th - (s0.th + 120)) <= 3 && s1.sorted === s0.sorted, { before: s0.th, after: s1.th, sorted: s1.sorted })
  ok('R2 every Status body cell follows its header', s1.tds.length >= 2 && s1.tds.every((w) => Math.abs(w - s1.th) <= 1), s1)
  await p.click('[data-test=issues-view][data-value="status"]')
  await p.waitForSelector('[data-test=issues-group-h]', { visible: true, timeout: 5000 })
  const s1g = await widths(p, 'status')
  ok('R2 By status keeps the same width in every group', s1g.th === s1.th && s1g.tds.every((w) => Math.abs(w - s1.th) <= 1), s1g)
  await p.click('[data-test=issues-view][data-value="list"]')
  await sleep(200)

  /* R3 */
  await drag(p, 'title', -2000)
  const t3 = await widths(p, 'title')
  const clip = await p.evaluate(() => {
    const td = document.querySelector('[data-test=issues-row] td[data-col="title"]')
    const next = td.nextElementSibling
    return { ov: getComputedStyle(td).overflowX, tdRight: Math.round(td.getBoundingClientRect().right), nextLeft: Math.round(next.getBoundingClientRect().left) }
  })
  ok('R5 Title stops at its own 160 px floor', Math.abs(t3.th - 160) <= 1, t3)
  ok('R3 a narrowed column clips its cells; nothing runs into the next column', clip.ov === 'hidden' && clip.tdRight <= clip.nextLeft + 1, clip)

  /* R4 */
  const k0 = (await widths(p, 'status')).th
  await p.focus('[data-test="issues-col-grip-status"]')
  await p.keyboard.press('ArrowRight')
  await sleep(100)
  const k1 = (await widths(p, 'status')).th
  await p.focus('[data-test="issues-sort-status"]')
  await p.keyboard.down('Alt')
  await p.keyboard.press('ArrowLeft')
  await p.keyboard.up('Alt')
  await sleep(100)
  const k2 = await widths(p, 'status')
  ok('R4 ArrowRight on the grip +16 px, Alt+ArrowLeft on the header -16 px, no sort', k1 === k0 + 16 && k2.th === k0 && k2.sorted === s0.sorted, { k0, k1, k2: k2.th, sorted: k2.sorted })
  await p.click('[data-test="issues-sort-status"]')
  await sleep(150)
  const sorted = (await widths(p, 'status')).sorted
  ok('R4 a plain click on the header still sorts', sorted === 'ascending' || sorted === 'descending', { sorted })

  /* R6 */
  const before = { status: (await widths(p, 'status')).th, title: (await widths(p, 'title')).th }
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-table]', { visible: true, timeout: NAV_TIMEOUT })
  await sleep(200)
  const after = { status: (await widths(p, 'status')).th, title: (await widths(p, 'title')).th }
  ok('R6 a reload keeps the widths', Math.abs(after.status - before.status) <= 1 && Math.abs(after.title - before.title) <= 1, { before, after })

  /* R7: fit, then automatic */
  for (const title of ['A short one', 'A much longer issue title that needs a lot of room on the sheet to be read in full']) {
    const has = await p.evaluate((want) => [...document.querySelectorAll('[data-test=issues-row] .issues-title')].some((x) => x.textContent.trim() === want), title)
    if (!has) {
      await p.click('[data-test=issues-new]')
      await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
      await p.type('[data-test=issues-newrow-title]', title)
      await p.keyboard.press('Enter')
      await sleep(300)
    }
  }
  const box = await p.$eval('[data-test="issues-col-grip-title"]', (g) => { const b = g.getBoundingClientRect(); return { x: b.x + b.width / 2, y: b.y + b.height / 2 } })
  /* a real double-click is two presses (puppeteer's clickCount: 2 sends one) */
  await p.mouse.move(box.x, box.y)
  await p.mouse.down()
  await p.mouse.up()
  await p.mouse.down({ clickCount: 2 })
  await p.mouse.up({ clickCount: 2 })
  await sleep(250)
  const fit = await p.evaluate(() => {
    const spans = [...document.querySelectorAll('[data-test=issues-row] td[data-col="title"] .issues-title')]
    return { th: Math.round(document.querySelector('.issues-names th[data-col="title"]').getBoundingClientRect().width), clipped: spans.filter((s) => s.scrollWidth > s.clientWidth + 1).length, n: spans.length }
  })
  ok('R7 a double-click on the Title edge fits it to the longest title: none clipped', fit.n >= 2 && fit.clipped === 0 && fit.th > 160, fit)
  await p.focus('[data-test="issues-col-grip-title"]')
  await p.keyboard.press('Delete')
  await p.focus('[data-test="issues-col-grip-status"]')
  await p.keyboard.press('Delete')
  await sleep(150)
  const back = { title: await widths(p, 'title'), stored: await p.evaluate(() => localStorage.getItem('spool.issues.colw')) }
  ok('R7 Delete on a grip gives the automatic width back (Title takes the rest again, as in R0)', Math.abs(back.title.th - t0.th) <= 2 && back.stored === '{}', { th: back.title.th, r0: t0.th, stored: back.stored })

  /* R8: signed in, the claim is the source and a gesture is one PUT */
  const puts = []
  await p.setRequestInterception(true)
  p.on('request', (req) => {
    if (req.method() === 'PUT' && req.url().includes('/preferences')) {
      puts.push(JSON.parse(req.postData() || '{}'))
      return req.respond({ status: 200, contentType: 'application/json', headers: { 'access-control-allow-origin': new URL(server.base).origin, 'access-control-allow-credentials': 'true' }, body: req.postData() || '{}' })
    }
    return req.continue()
  })
  const stored0 = await p.evaluate(() => localStorage.getItem('spool.issues.colw'))
  await p.evaluate(() => {
    const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
    s.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1', issues_columns: { status: 200 } })
  })
  await sleep(300)
  const c0 = (await widths(p, 'status')).th
  await drag(p, 'status', 60)
  const moved = (await widths(p, 'status')).th
  await sleep(900)
  const r8 = {
    c0, moved, puts,
    claim: await p.evaluate(() => {
      const s = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('session')
      return { state: s.state, cols: JSON.parse(JSON.stringify(s.claims?.issues_columns ?? null)) }
    }),
    stored: await p.evaluate(() => localStorage.getItem('spool.issues.colw')),
  }
  ok('R8 signed in, the issues_columns claim sizes Status (200 px); a +60 drag is ONE PUT of issues_columns, the claim follows, localStorage untouched',
    Math.abs(c0 - 200) <= 1 && Math.abs(moved - 260) <= 3 && puts.length === 1 && Math.abs((puts[0].issues_columns?.status ?? 0) - moved) <= 1 &&
    Object.keys(puts[0]).length === 1 && r8.claim.state === 'in' && Math.abs((r8.claim.cols?.status ?? 0) - moved) <= 1 && r8.stored === stored0, r8)

  ok('no page errors', errors.length === 0, errors)
} catch (e) {
  ok('harness', false, String(e && e.stack || e))
} finally {
  await browser.close()
  await server.stop?.()
}
const failed = results.filter((r) => !r.ok).length
console.log(`\nissues-col-resize: ${results.length - failed}/${results.length} passed`)
process.exit(failed ? 1 : 0)
