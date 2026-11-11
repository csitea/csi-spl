// A table in a post sorts by its column header (md-tables panel plan v1.0
// section 3.2, SPL-2466 rows 05 + 09; owner HUM-10, t1 8f983920: "Make all
// of the tables in the topics' msgs sortable"), on the phone (412x915, a
// finger tap) and the desktop (1280x800, a mouse click and the keyboard).
//
// A click cycles ascending, descending, the author's order; th aria-sort
// follows; sizes compare by value (149.4 KB < 900 KB < 1.2 MB) and an empty
// cell stays last both ways. A 2-row table gets no sort buttons (the plan's
// >= 3 body rows). The click never opens or leaves the topic, the zebra band
// still paints, and the post's own text keeps the author's order.
//
// Red control: on the c10b3ce97 bundle (before row 05) no header is a
// button: every sort check fails; the zebra and 2-row checks pass there.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/markdown-table.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const FROM = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
/* the post rides the mock feed's own hook (spool.mock.extra-messages), not
   the channel store: the mock refresh every 4 s (useSpoolEvents) replaces
   the store's rows, and a body written there is gone 3.8 s later (R7 W1) */
const REPLY = '52925292-5292-4529-8529-529252925292'
const BODY = [
  '## Sizes',
  '',
  '| name | size | when |',
  '|---|---|---|',
  '| gamma | 1.2 MB | 2026-11-03 |',
  '| alpha | 149.4 KB | 2026-11-01 |',
  '| delta | - | 2026-11-04 |',
  '| beta | 900 KB | 2026-11-02 |',
  '',
  '| k | v |',
  '|---|---|',
  '| two | 2 |',
  '| one | 1 |',
  '',
].join('\n')
const AUTHOR = ['gamma', 'alpha', 'delta', 'beta']

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function openPost(page, base) {
  const row = {
    v: 1, msg_id: REPLY, task_id: 'e5292e52-92e5-4292-8e52-92e5292e5292', ts: '2026-09-18T10:02:30Z',
    from: 'CLE-07', from_box: 'box-a', to: 'HUM-1', to_box: 'box-wui', kind: 'note', body: BODY,
    files: [], channel: 'lobby', parent_task_id: FROM,
  }
  await page.evaluateOnNewDocument((r) => {
    localStorage.setItem('spool-card-clip-thread', 'full')
    localStorage.setItem('spool-card-clip', 'full')
    sessionStorage.setItem('spool-card-clip-session-thread', 'full')
    localStorage.setItem('spool.mock.extra-messages', JSON.stringify([r]))
  }, row)
  await page.goto(`${base}/channel/lobby?topic=${FROM}`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell')
  await page.waitForFunction(() => {
    const t = document.querySelector('.spool-shell > .topic [data-testid=md-block][data-rendered=true] .md-table table')
    return Boolean(t && t.getBoundingClientRect().width > 0)
  }, { timeout: 30000 })
  /* the feed slides rows under a new post for a moment */
  await page.waitForFunction(() => !document.querySelector('.prepend-move, .append-move'), { timeout: 2000 }).catch(() => {})
  await sleep(300)
}

/** The two tables of the post: header state, first column, zebra, the topic still open. */
const read = (page) => page.evaluate((id, body) => {
  const tables = [...document.querySelectorAll('.spool-shell > .topic [data-testid=md-block] .md-table table')]
  const big = tables[0]
  const small = tables[1]
  const ths = big ? [...big.querySelectorAll('thead th')] : []
  const rows = big ? [...big.querySelectorAll('tbody tr')] : []
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const msg = pinia?._s.get('channel')?.messages.find((m) => m.msg_id === id)
  return {
    tables: tables.length,
    buttons: ths.map((th) => Boolean(th.querySelector('button.md-th-sort'))),
    aria: ths.map((th) => th.getAttribute('aria-sort')),
    marks: ths.map((th) => th.querySelector('.md-th-sort__mark')?.textContent || ''),
    label: ths[1]?.querySelector('button')?.getAttribute('aria-label') || null,
    names: rows.map((r) => r.querySelector('td')?.textContent?.trim()),
    zebra: rows[1] ? getComputedStyle(rows[1]).backgroundColor : null,
    smallButtons: small ? small.querySelectorAll('button').length : -1,
    path: location.pathname + location.search,
    pane: Boolean(document.querySelector('.spool-shell > .topic')),
    bodyKept: Boolean(msg && msg.body === body),
  }
}, REPLY, BODY)

/** The centre of header button `col`, and whether a finger there hits it. */
const headPoint = (page, col) => page.evaluate((j) => {
  const big = document.querySelector('.spool-shell > .topic [data-testid=md-block] .md-table table')
  const b = big?.querySelectorAll('thead th')[j]?.querySelector('button.md-th-sort')
  if (!b) return null
  b.scrollIntoView({ block: 'center', inline: 'nearest' })
  const r = b.getBoundingClientRect()
  const x = Math.round(r.left + r.width / 2)
  const y = Math.round(r.top + r.height / 2)
  const at = document.elementFromPoint(x, y)
  return { x, y, hit: Boolean(at && at.closest('button') === b) }
}, col)

async function press(page, col, touch) {
  const pt = await headPoint(page, col)
  if (!pt || !pt.hit) return pt
  if (touch) {
    await page.touchscreen.tap(pt.x, pt.y)
  } else {
    await page.mouse.click(pt.x, pt.y)
  }
  await sleep(250)
  return pt
}

async function cycle(page, label, touch) {
  let s = await read(page)
  ok(`${label}: the 3-row table's headers are sort buttons, aria-sort none, named for a screen reader`,
    same(s.buttons, [true, true, true]) && same(s.aria, ['none', 'none', 'none']) && s.label === 'Sort by size, currently not sorted', s)
  ok(`${label}: a 2-row table gets no sort button (plan: >= 3 body rows)`, s.tables === 2 && s.smallButtons === 0, s)
  ok(`${label}: the zebra band still paints the even row`, Boolean(s.zebra) && s.zebra !== 'rgba(0, 0, 0, 0)', s.zebra)
  const start = s.path
  const pt = await press(page, 1, touch)
  s = await read(page)
  ok(`${label}: size ascending by value, the empty cell last`,
    Boolean(pt && pt.hit) && same(s.names, ['alpha', 'beta', 'gamma', 'delta']) && same(s.aria, ['none', 'ascending', 'none']) && s.marks[1] === '▲', { pt, ...s })
  ok(`${label}: the header press stays in the open topic`, s.path === start && s.pane, { start, now: s.path })
  await press(page, 1, touch)
  s = await read(page)
  ok(`${label}: size descending, the empty cell still last`,
    same(s.names, ['gamma', 'beta', 'alpha', 'delta']) && same(s.aria, ['none', 'descending', 'none']) && s.marks[1] === '▼', s)
  await press(page, 1, touch)
  s = await read(page)
  ok(`${label}: a third press is the author's order again`, same(s.names, AUTHOR) && same(s.aria, ['none', 'none', 'none']), s)
  ok(`${label}: the post's text keeps the author's order`, s.bodyKept, s)
}

const srv = await startServer()
const browser = await launch()
try {
  const phone = await browser.newPage()
  phone.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await phone.setViewport({ width: 412, height: 915, isMobile: true, hasTouch: true })
  await openPost(phone, srv.base)
  await applyViewport(phone, { width: 412, height: 915, isMobile: true, hasTouch: true })
  await cycle(phone, 'phone 412x915', true)
  await phone.close()

  const desk = await browser.newPage()
  desk.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await desk.setViewport({ width: 1280, height: 800 })
  await openPost(desk, srv.base)
  await applyViewport(desk, { width: 1280, height: 800 })
  await cycle(desk, 'desktop 1280x800', false)
  /* the keyboard: Enter, then Space, on the name header */
  const focused = await desk.evaluate(() => {
    const b = document.querySelector('.spool-shell > .topic .md-table thead th button.md-th-sort')
    b?.focus()
    return document.activeElement === b && Boolean(b)
  })
  await desk.keyboard.press('Enter')
  await sleep(200)
  let s = await read(desk)
  ok('desktop: Enter on a focused header sorts ascending', focused && same(s.names, ['alpha', 'beta', 'delta', 'gamma']) && s.aria[0] === 'ascending', s)
  await desk.keyboard.press('Space')
  await sleep(200)
  s = await read(desk)
  ok('desktop: Space sorts descending', same(s.names, ['gamma', 'delta', 'beta', 'alpha']) && s.aria[0] === 'descending', s)
  await desk.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmarkdown-table: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
