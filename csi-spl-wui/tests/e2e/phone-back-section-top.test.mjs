// SPL-6356 (owner HUM-10, t1 acfc125c, poll e70d1a05 answer A: "Back to that
// exact topic, like the browser's Back"): on a phone, another section opened
// from inside a topic (a tap on its control in the strip, which stays on top
// of level 3) and Back pressed at that section's TOP returns to that exact
// topic: the channel and the topic that were open, level 3. Every in-app Back
// does it: the top chevron, the dock's Back, a swipe. Spec 087 section 3.4,
// FR-009.
//
// Cells, entry x section x method x width:
//   entries   store   `/`, Channels, #lobby, the topic opened by its store
//             card    the same, the topic opened by a tap on its card
//             deep    a fresh tab at `/channel/lobby?topic=`
//             notify  a notification open (`/m/<msg_id>`)
//   sections  docs (Docs, /workspace/docs), help, settings (Workspace
//             settings), issues, notes, archive, calendar, monitoring,
//             reporting: each opened by its strip control at level 3;
//             docs-drill and docs-doc walk Docs down (a level, a document)
//             and back up to its top first
//   methods   chevron  the section head's "<" (MobileBack)
//             dock     the dock's Back, where the section draws a dock
//             edge     a swipe right from x = 8
//             browser  browser Back (the reference the owner named)
//   widths    360x780, 390x844
// A cell passes when one Back lands on the URL the topic was on, at level
// 3. A method whose control the section does not draw is SKIPPED (printed,
// not counted); a section where NO in-app method has a control fails. The
// methods of one entry x section x width share a tab while each Back lands
// on the topic (the next one starts there); after any other result the next
// method gets a fresh tab.
//
// Measured on origin/master aea828942 (n = 1 per cell): every cell passes,
// so this file is the gate of the rule, not a fix. Red control (n = 1, CI
// default): the discussion rule of SPL-5232 (`below` must be a lower level)
// applied to every section in utils/mobile-stack.mjs mobileBackStep fails
// all 23 cells counted; reverted, 22/22 pass.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/phone-back-section-top.test.mjs
// The default (CI) runs entry card, width 390 and the in-app methods (chevron,
// dock, edge) over every section; `all` in any of ENTRIES, METHODS, WIDTHS
// runs that axis in full (the whole matrix is ~45 min on a box, too slow for
// a CI shard). Narrow: ENTRIES=card SECTIONS=docs,help METHODS=chevron WIDTHS=360
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TOPIC = `/channel/lobby?topic=${TASK}`
const SIZES = { 360: 780, 390: 844 }
const SWIPE_Y = 420
/* section -> [its strip control, the path its top opens on] */
const ALL_SECTIONS = {
  docs: ['[data-testid=qto-open]', '/workspace/docs'],
  /* Docs, then down a level and Back up to its top before the Back measured */
  'docs-drill': ['[data-testid=qto-open]', '/workspace/docs', ['Handbook', 'Introduction']],
  /* Docs, then a document opened and Back up to the top */
  'docs-doc': ['[data-testid=qto-open]', '/workspace/docs', ['Handbook', 'Glossary']],
  help: ['[data-testid=help-open]', '/help'],
  settings: ['[data-testid=tenant-settings-open]', '/tenant-settings'],
  issues: ['[data-testid=sidebar-tab-issues]', '/issues'],
  notes: ['[data-testid=sidebar-tab-notes]', '/notes'],
  archive: ['[data-testid=sidebar-tab-archive]', '/archive'],
  calendar: ['[data-testid=sidebar-tab-calendar]', '/calendar'],
  monitoring: ['[data-testid=sidebar-tab-monitoring]', '/monitoring'],
  reporting: ['[data-testid=sidebar-tab-reporting]', '/reporting'],
}
const ALL_METHODS = ['chevron', 'dock', 'edge', 'browser']
const ALL_ENTRIES = ['store', 'card', 'deep', 'notify']
const pick = (env, all, def = all) => (!env ? def : env === 'all' ? all : env.split(',').filter((x) => all.includes(x)))
const SECTIONS = pick(process.env.SECTIONS, Object.keys(ALL_SECTIONS))
const METHODS = pick(process.env.METHODS, ALL_METHODS, ['chevron', 'dock', 'edge'])
const ENTRIES = pick(process.env.ENTRIES, ALL_ENTRIES, ['card'])
const REPLY = '33333333-3333-4333-8333-333333333333'
const WIDTHS = pick(process.env.WIDTHS, ['360', '390'], ['390']).map(Number)
const MEMBER = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

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

function boot(member) {
  try {
    localStorage.setItem('spool.mock.session', JSON.stringify(member))
    localStorage.setItem('spool.was-signed-in', '1')
  } catch { /* private mode */ }
}

const state = (p) => p.evaluate(() => ({
  level: Number(document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || 0),
  path: location.protocol === 'about:' ? 'about:blank' : location.pathname + location.search,
})).catch(() => ({ level: 0, path: 'about:blank' }))

/** Poll until `want(state)` holds, then settle and read again (an overshoot shows). */
async function until(p, want, ms = 6000) {
  const t0 = Date.now()
  let s = await state(p)
  while (!want(s) && Date.now() - t0 < ms) {
    await sleep(100)
    s = await state(p)
  }
  await sleep(500)
  return state(p)
}

/* the first drawn, enabled match of `sel`; `press` clicks it */
const shown = (p, sel, press) => p.evaluate((q, go) => {
  const e = [...document.querySelectorAll(q)].find((x) => x.getBoundingClientRect().width > 0 && !x.disabled)
  if (e && go) e.click()
  return Boolean(e)
}, sel, press)

async function swipe(p, x0) {
  const cdp = await p.target().createCDPSession()
  const t = (type, x) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y: SWIPE_Y }] })
  await t('touchStart', x0)
  for (let i = 1; i <= 6; i++) { await t('touchMove', x0 + i * 25); await sleep(16) }
  await t('touchEnd', x0 + 150)
  await cdp.detach()
}

/* the phone's Docs list (WorkspaceDocsPage): tap `rows` down one by one, then
   the page's chevron as many times, back up to the top (no ?in=, no ?doc=) */
const DOCS_ROWS = '[data-test=ws-docs-page] [data-test=qto-file-tree] [data-test=file-tree-row]'
async function docsWalk(p, rows) {
  for (const name of rows) {
    await p.waitForFunction((sel, n) => [...document.querySelectorAll(sel)].some((e) => e.textContent.trim() === n), { timeout: 8000 }, DOCS_ROWS, name).catch(() => {})
    const before = await state(p)
    const row = await p.evaluateHandle((sel, n) => [...document.querySelectorAll(sel)].find((e) => e.textContent.trim() === n) || null, DOCS_ROWS, name)
    if (!(await row.evaluate((e) => Boolean(e)))) return `no Docs row ${name}`
    await row.tap()
    await until(p, (x) => x.path !== before.path)
  }
  for (let i = 0; i < rows.length; i++) {
    const before = await state(p)
    await shown(p, '[data-test=ws-docs-page] [data-testid=mobile-back]', true)
    await until(p, (x) => x.path !== before.path)
  }
  const s = await state(p)
  return s.path === '/workspace/docs' ? '' : `Docs did not walk back to its top: ${s.path}`
}

const CONTROL = { chevron: '[data-testid=mobile-back]', dock: '[data-testid=dock-back]' }

/** One Back by `method`; false when the section draws no control for it. */
async function back(p, method) {
  if (CONTROL[method]) return shown(p, CONTROL[method], true)
  if (method === 'edge') { await swipe(p, 8); return true }
  await p.goBack({ timeout: 8000 }).catch(() => null)
  return true
}

const load = async (p, base, path) => {
  await p.goto(base + path, { waitUntil: 'domcontentloaded' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
}

/** The entry onto a topic; resolves to the state at level 3 (or where it stopped). */
async function toTopic(p, base, entry) {
  if (entry === 'deep') {
    await load(p, base, TOPIC)
    return until(p, (s) => s.level === 3, 8000)
  }
  if (entry === 'notify') {
    await load(p, base, `/m/${REPLY}`)
    return until(p, (s) => s.level === 3, 8000)
  }
  /* `/`, Channels, #lobby, then a topic: by the store (store) or a tap on its card (card) */
  await load(p, base, '/')
  await until(p, (s) => s.level === 1)
  await shown(p, '[data-testid=sidebar-tab-channels]', true)
  await sleep(300)
  await p.evaluate(() => {
    const row = [...document.querySelectorAll('#sidebar-panel-channels .nav-item')].find((e) => (e.getAttribute('href') || '').endsWith('/channel/lobby'))
    row?.click()
  })
  await until(p, (s) => s.level === 2)
  if (entry === 'card') {
    await sleep(600)
    await shown(p, '[aria-describedby=feed-open-hint]', true)
  } else {
    await p.evaluate((id) => {
      const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
      pinia?._s.get('topic')?.openTopic(id)
    }, TASK)
  }
  return until(p, (s) => s.level === 3 && s.path.includes('topic='), 8000)
}

/** A fresh tab on a topic by `entry`: { ctx, p, topic } or a setup failure text. */
async function openTab(browser, base, width, entry) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width, height: SIZES[width], isMobile: true, hasTouch: true })
  await p.evaluateOnNewDocument(boot, MEMBER)
  const s3 = await toTopic(p, base, entry)
  if (s3.level === 3) return { ctx, p, topic: s3.path }
  await ctx.close().catch(() => {})
  return `setup: not on a topic (${s3.path} L${s3.level})`
}

/** On the topic: open the section, walk Docs if asked, one Back by `method`. 'pass' | 'skip' | a failure text. */
async function cell(tab, section, method) {
  const [control, top, rows] = ALL_SECTIONS[section]
  const { p, topic } = tab
  if (!(await shown(p, control, true))) return `setup: no ${control} at level 3`
  const s = await until(p, (x) => x.path.startsWith(top) && x.level !== 3, 8000)
  if (!s.path.startsWith(top)) return `setup: the control opened ${s.path} L${s.level}, not ${top}`
  await sleep(400)
  const walked = rows ? await docsWalk(p, rows) : ''
  if (walked) return `setup: ${walked}`
  if (!(await back(p, method))) return 'skip'
  const after = await until(p, (x) => x.path === topic && x.level === 3, 8000)
  return after.path === topic && after.level === 3 ? 'pass' : `${topic} -> ${s.path} L${s.level} -> ${after.path} L${after.level}`
}

/* Every method of one width x entry x section in one tab: a Back that lands
   on the topic leaves the tab where the next method starts; anything else
   (a failure, a skipped method) gets a fresh tab for the next one. */
async function row(browser, base, w, entry, section) {
  const out = []
  let tab = null
  for (const method of METHODS) {
    tab ||= await openTab(browser, base, w, entry).catch((e) => `error: ${e.message}`)
    let r = typeof tab === 'string' ? tab : null
    if (!r) r = await cell(tab, section, method).catch((e) => `error: ${e.message}`)
    out.push([method, r])
    if (r !== 'pass') {
      if (typeof tab !== 'string') await tab.ctx.close().catch(() => {})
      tab = null
    }
  }
  if (tab && typeof tab !== 'string') await tab.ctx.close().catch(() => {})
  return out
}

const server = await startServer()
const browser = await launch()
let passed = 0
let failed = 0
try {
  console.log(`phone-back-section-top on ${server.base}`)
  for (const w of WIDTHS) {
    for (const entry of ENTRIES) for (const section of SECTIONS) {
      let inApp = 0
      for (const [method, r] of await row(browser, server.base, w, entry, section)) {
        const name = `${w} ${entry}/${section}/${method}`
        if (r === 'skip') { console.log(`  SKIP ${name}: no control drawn`); continue }
        if (method !== 'browser') inApp++
        if (r === 'pass') passed++
        else failed++
        console.log(`  ${r === 'pass' ? 'OK  ' : 'FAIL'} ${name}: Back at the top returns to the topic${r === 'pass' ? '' : ' - ' + r}`)
      }
      if (!inApp && METHODS.some((m) => m !== 'browser')) {
        failed++
        console.log(`  FAIL ${w} ${entry}/${section}: no in-app Back control at all`)
      }
    }
  }
} finally {
  await browser.close().catch(() => {})
  await server.stop()
}
console.log(`phone-back-section-top: ${passed}/${passed + failed} passed`)
process.exit(failed ? 1 : 0)
