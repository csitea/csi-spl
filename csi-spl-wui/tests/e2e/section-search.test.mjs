// SPL-4901 (owner HUM-10, t1 7da30ebd msg 5af63dee; t1 2f4311d9 msgs
// 1497d676, acf9d324): the search button opens on the section's entities.
// The map is utils/section-search.mjs (unit: tests/unit/section-search.test.mjs).
//
//   390x844 phone (hasTouch):
//     P1 /workspace/docs: the search button opens the dock on `/search type:doc `
//     P2 then /channel/general: the Omnibox is normal again (empty, no search mode)
//     P3 /notes: the dock and the strip are collapsed, the search button is
//        there; a tap focuses the Notes filter, the dock stays collapsed
//     P4 then /channel/general: the dock is back, no search mode
//     P5 /calendar: the calendar's own search button opens its search
//     P6 CONTROL /channel/general: no collapsed-dock search button
//   1440x900, the Omnibox at the bottom (Settings -> Behaviour):
//     D1 /workspace/docs: the top bar's search button opens `/search type:doc `
//     D2 then /channel/general: the line is empty again
//     D3 /calendar: the button opens the calendar search; a result opens its entry
//     D4 /notes: the button focuses the Notes filter
//     D5 CONTROL /channel/general: the button opens the plain `/search `
//
// Run:
//   pnpm run test:e2e section-search
//   BASE_URL=<generated bundle> SHOTS=<dir> pnpm run test:e2e section-search
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const FORM = 'form.composer.omnibox--global'
const DOCK = 'form.composer.composer--dock'
const OPEN = '[data-test=docs-search-open]'
const BAR_SEARCH = '[data-test=top-bar-search]'
const FILTER = '[data-test=notes-filter]'
const CALBOX = '[data-test=calphone-searchbox]'
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const SHOTS = process.env.SHOTS || ''

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function until(read, want, max = 8000) {
  const end = Date.now() + max
  let s = await read()
  while (!want(s) && Date.now() < end) {
    await sleep(100)
    s = await read()
  }
  return s
}

const shot = async (p, name) => { if (SHOTS) await p.screenshot({ path: join(SHOTS, `section-search-${name}.png`) }) }

/* signed in as the mock member, the Omnibox where `pos` says (undefined = top) */
const signIn = (p, pos) => p.evaluate((pos) => {
  const session = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('session')
  if (!session) return false
  const c = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }
  if (pos) c.composer_position = pos
  session.adopt(c)
  return true
}, pos)
const go = async (p, path) => {
  await p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
  await sleep(700)
}

/* what the reader sees of the Omnibox and the section's own searches */
function state(sel) {
  const h = (el) => {
    if (!el) return 0
    const cs = getComputedStyle(el)
    return cs.display === 'none' || cs.visibility === 'hidden' ? 0 : Math.round(el.getBoundingClientRect().height)
  }
  const form = document.querySelector(sel.FORM)
  const field = form?.querySelector('textarea')
  const active = document.activeElement
  return {
    line: field ? field.value : null,
    search: Boolean(form && form.classList.contains('omnibox--search')),
    focused: Boolean(field && active === field),
    dock: h(document.querySelector(sel.DOCK)),
    open: Boolean(document.querySelector(sel.OPEN)),
    filterFocused: Boolean(active && active.matches(sel.FILTER)),
    calbox: Boolean(document.querySelector(sel.CALBOX)),
    calInputFocused: Boolean(active && active.matches('[data-test=calphone-search-input]')),
    path: location.pathname,
    query: location.search,
  }
}
const SEL = { FORM, DOCK, OPEN, FILTER, CALBOX }
const read = (p) => p.evaluate(state, SEL)

async function newPage(browser, vp, pos) {
  const p = await browser.newPage()
  p.__errors = []
  p.on('pageerror', (e) => p.__errors.push(String(e.message || e)))
  await p.setViewport(vp)
  await p.goto(`${browser.__base}/`, { waitUntil: 'networkidle2', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  if (!(await signIn(p, pos))) throw new Error('no session store')
  await p.waitForSelector(FORM, { timeout: 20000 })
  return p
}

async function phone(browser) {
  const tag = '390'
  const p = await newPage(browser, { width: 390, height: 844, isMobile: true, hasTouch: true })

  await go(p, '/workspace/docs')
  await p.waitForSelector(OPEN, { timeout: 15000 }).catch(() => {})
  await shot(p, `${tag}-docs-before-tap`)
  if (await p.$(OPEN)) {
    await p.click(OPEN)
    const s = await until(() => read(p), (x) => x.search && x.focused && x.line === '/search type:doc ')
    await shot(p, `${tag}-docs-after-tap`)
    ok(`${tag} P1 docs: the search button opens the dock on "/search type:doc "`, s.search && s.focused && s.line === '/search type:doc ' && s.dock >= 40, s)
  } else ok(`${tag} P1 docs: the search button opens the dock on "/search type:doc "`, false, 'no search button')

  await go(p, '/channel/general')
  const n = await until(() => read(p), (x) => x.line === '' && !x.search)
  ok(`${tag} P2 docs -> /channel/general: the Omnibox is normal (empty, no search mode)`, n.line === '' && !n.search && n.dock > 0, n)

  await go(p, '/notes')
  await p.waitForSelector(FILTER, { timeout: NAV }).catch(() => {})
  const c = await until(() => read(p), (x) => x.dock === 0 && x.open)
  await shot(p, `${tag}-notes-before-tap`)
  ok(`${tag} P3 notes: the dock is collapsed and the search button is there`, c.dock === 0 && c.open, c)
  if (c.open) {
    await p.click(OPEN)
    const f = await until(() => read(p), (x) => x.filterFocused)
    await shot(p, `${tag}-notes-after-tap`)
    ok(`${tag} P3 notes: a tap focuses the Notes filter, the dock stays collapsed`, f.filterFocused && f.dock === 0 && !f.search, f)
  }

  await go(p, '/channel/general')
  const b = await until(() => read(p), (x) => x.dock > 0)
  ok(`${tag} P4 notes -> /channel/general: the dock is back, no search mode`, b.dock > 0 && !b.search && !b.open, b)
  ok(`${tag} P6 CONTROL /channel/general: no collapsed-dock search button`, !b.open, b)

  await go(p, '/calendar')
  await p.waitForSelector('[data-test=calphone-search]', { visible: true, timeout: NAV }).catch(() => {})
  await shot(p, `${tag}-calendar-before-tap`)
  if (await p.$('[data-test=calphone-search]')) {
    await p.click('[data-test=calphone-search]')
    const k = await until(() => read(p), (x) => x.calbox && x.calInputFocused)
    await shot(p, `${tag}-calendar-after-tap`)
    ok(`${tag} P5 calendar: its search button opens the calendar search`, k.calbox && k.calInputFocused, k)
  } else ok(`${tag} P5 calendar: its search button opens the calendar search`, false, 'no calendar search button')

  ok(`${tag} no page error`, p.__errors.length === 0, p.__errors)
  await p.close()
}

async function desktop(browser) {
  const tag = '1440'
  const p = await newPage(browser, { width: 1440, height: 900 }, 'bottom')

  await go(p, '/workspace/docs')
  await p.waitForSelector(BAR_SEARCH, { visible: true, timeout: 15000 }).catch(() => {})
  await shot(p, `${tag}-docs-before-click`)
  await p.click(BAR_SEARCH)
  const d = await until(() => read(p), (x) => x.line === '/search type:doc ' && x.focused)
  await shot(p, `${tag}-docs-after-click`)
  ok(`${tag} D1 docs: the search button opens "/search type:doc "`, d.line === '/search type:doc ' && d.search && d.focused, d)

  await go(p, '/channel/general')
  const n = await until(() => read(p), (x) => x.line === '')
  ok(`${tag} D2 docs -> /channel/general: the line is empty again`, n.line === '' && !n.search, n)

  await go(p, '/calendar')
  await p.waitForSelector('[data-test=calendar-page]', { timeout: NAV })
  await sleep(500)
  await p.click(BAR_SEARCH)
  const k = await until(() => read(p), (x) => x.calbox && x.calInputFocused)
  ok(`${tag} D3 calendar: the search button opens the calendar search, field focused`, k.calbox && k.calInputFocused && k.line === '', k)
  const input = await p.$('[data-test=calphone-search-input]')
  if (input) await input.type('Release')
  const row = input ? await p.waitForSelector('[data-test=calphone-search-row]', { visible: true, timeout: 15000 }).catch(() => null) : null
  await shot(p, `${tag}-calendar-after-click`)
  if (row) {
    const id = await row.evaluate((el) => el.getAttribute('data-id'))
    await row.click()
    const o = await until(() => read(p), (x) => !x.calbox && x.query.includes(`event=${id}`))
    ok(`${tag} D3 calendar: a result closes the search and opens its entry (?event=)`, !o.calbox && o.query.includes(`event=${id}`), o)
  } else ok(`${tag} D3 calendar: a result closes the search and opens its entry (?event=)`, false, 'no result row')

  await go(p, '/notes')
  await p.waitForSelector(FILTER, { visible: true, timeout: NAV }).catch(() => {})
  await p.click(BAR_SEARCH)
  const f = await until(() => read(p), (x) => x.filterFocused)
  await shot(p, `${tag}-notes-after-click`)
  ok(`${tag} D4 notes: the search button focuses the Notes filter`, f.filterFocused && !f.search, f)

  await go(p, '/channel/general')
  await p.click(BAR_SEARCH)
  const g = await until(() => read(p), (x) => x.line === '/search ' && x.focused)
  ok(`${tag} D5 CONTROL /channel/general: the button opens the plain "/search "`, g.line === '/search ' && g.search, g)

  ok(`${tag} no page error`, p.__errors.length === 0, p.__errors)
  await p.close()
}

const srv = await startServer()
const browser = await launch()
browser.__base = srv.base
try {
  await phone(browser)
  await desktop(browser)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((x) => !x.ok)
console.log(`\nsection-search: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
