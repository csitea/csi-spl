// SPL-994 (epic SPL-988): on a phone, Back closes the top overlay first. A
// dialog or a bottom sheet is the TOP level while open (useMobileStack
// overlay()): browser Back / the Android gesture closes it and the page and
// the level under it stay put; a second Back pops the level. Closing by the
// overlay's own X leaves no history behind (the next Back pops the level).
// At 1440 px nothing changes: opening a dialog writes no history entry.
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/mobile-overlay.test.mjs
// (starts `nuxi dev` with the mock tenant when BASE_URL is unset)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const WIDTHS = (process.env.WIDTHS || '360,390,820').split(',').map(Number)

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
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

/** The level, the URL, how deep history is, and which overlay is up. */
const state = (p) => p.evaluate(() => {
  const vis = (s) => [...document.querySelectorAll(s)].some((e) => {
    const r = e.getBoundingClientRect()
    return getComputedStyle(e).display !== 'none' && getComputedStyle(e).visibility !== 'hidden' && r.width > 0 && r.height > 0
  })
  return {
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || null,
    path: location.pathname + location.search,
    hist: history.length,
    dialog: vis('[data-testid=ui-dialog]'),
    menu: vis('[data-test=user-menu-panel]'),
    filters: vis('[data-test=issues-filter-sheet]'),
  }
})
const click = (p, sel) => p.evaluate((s) => {
  const e = [...document.querySelectorAll(s)].find((x) => x.getBoundingClientRect().width > 0)
  if (!e) return false
  e.click()
  return true
}, sel)
/* the mock bundle has no session: sign a member in through the store (as top-bar-mobile does) */
const signIn = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const session = pinia?._s.get('session')
  if (!session) return false
  session.adopt({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })
  return true
})
/* Polls the state until want(s) holds on two polls in a row with the same
   state, so a late second change (a Back that also pops the level) still
   shows; gives up after max ms and returns the last state for the check.
   Fixed sleeps after each step were most of the file's 77 s on the hosted
   runner (spec 133 round 17). */
async function until(p, want, max = 8000) {
  const end = Date.now() + max
  let prev = ''
  let s = await state(p)
  while (Date.now() < end) {
    const key = want(s) ? JSON.stringify(s) : ''
    if (key && key === prev) return s
    prev = key
    await sleep(150)
    s = await state(p)
  }
  return s
}
/* waits until a selector has a laid-out element (the next click needs it) */
const shown = (p, sel) => p.waitForFunction((q) => [...document.querySelectorAll(q)].some((e) => e.getBoundingClientRect().width > 0), { timeout: 8000 }, sel).catch(() => {})
const back = async (p, want) => { await p.goBack().catch(() => {}); return until(p, want) }

const srv = await startServer()
const browser = await launch()
try {
  for (const width of WIDTHS) {
    const page = await browser.newPage()
    page.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await page.setViewport({ width, height: 844, isMobile: true, hasTouch: true })
    const at = `${width}px`

    /* level 1 -> a channel (level 2) */
    await page.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
    await page.waitForSelector('.spool-shell')
    await sleep(1000)
    await signIn(page)
    await click(page, '[data-testid=sidebar-tab-channels]')
    await shown(page, '#sidebar-panel-channels .nav-item')
    await click(page, '#sidebar-panel-channels .nav-item')
    const l2 = await until(page, (s) => s.level === '2' && s.path.includes('/channel/'))
    ok(`${at} setup: a channel on level 2`, l2.level === '2' && l2.path.includes('/channel/'), l2)

    /* the avatar sheet: Back closes it, the level stays; Back again pops */
    await click(page, '[data-test=user-menu-trigger]')
    let s = await until(page, (s) => s.menu)
    ok(`${at} the avatar sheet opens`, s.menu, s)
    s = await back(page, (s) => !s.menu)
    ok(`${at} Back closes the avatar sheet, level and URL unchanged`, !s.menu && s.level === '2' && s.path === l2.path, s)
    s = await back(page, (s) => s.level === '1')
    ok(`${at} Back again pops the level (2 -> 1)`, s.level === '1', s)

    /* a dialog at level 1 (the new-channel dialog, nothing saved) */
    await click(page, '[data-testid=sidebar-tab-channels]')
    await shown(page, '[data-testid=create-channel]')
    const l1 = await until(page, () => true)
    const opened = await click(page, '[data-testid=create-channel]')
    s = await until(page, (s) => s.dialog)
    ok(`${at} the new-channel dialog opens`, opened && s.dialog, s)
    s = await back(page, (s) => !s.dialog)
    ok(`${at} Back closes the dialog, URL and level unchanged`, !s.dialog && s.level === l1.level && s.path === l1.path, { l1, s })

    /* a dialog at level 2: Back closes it, a second Back pops the level */
    await click(page, '#sidebar-panel-channels .nav-item')
    const c2 = await until(page, (s) => s.path.includes('/channel/'))
    await click(page, '[data-testid=sidebar-tab-channels]')
    const d2 = await page.evaluate(() => {
      /* the channel's own dialog is not needed: the same UiDialog opened from the rail */
      const b = document.querySelector('[data-testid=create-channel]')
      if (!b) return false
      b.click()
      return true
    })
    s = d2 ? await until(page, (s) => s.dialog) : await state(page)
    if (d2 && s.dialog) {
      s = await back(page, (s) => !s.dialog)
      ok(`${at} a dialog over level ${c2.level}: Back closes it, level unchanged`, !s.dialog && s.level === c2.level && s.path === c2.path, { c2, s })
      s = await back(page, (s) => Number(s.level) === Number(c2.level) - 1)
      ok(`${at} ... and a second Back pops the level`, !s.dialog && Number(s.level) === Number(c2.level) - 1, s)
    }

    /* closing by its own X leaves no history: the next Back pops the level */
    await page.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
    await sleep(1000)
    await signIn(page)
    await click(page, '[data-testid=sidebar-tab-channels]')
    await shown(page, '#sidebar-panel-channels .nav-item')
    await click(page, '#sidebar-panel-channels .nav-item')
    const x0 = await until(page, (s) => s.level === '2' && s.path.includes('/channel/'))
    await click(page, '[data-test=user-menu-trigger]')
    const x1 = await until(page, (s) => s.menu)
    await click(page, '[data-test=user-menu-scrim]')
    s = await until(page, (s) => !s.menu)
    ok(`${at} closing the sheet itself steps back over its entry`, x1.menu && !s.menu && s.level === '2' && s.path === x0.path, { x1, s })
    s = await back(page, (s) => s.level === '1')
    ok(`${at} ... so the next Back pops 2 -> 1 (no drift)`, s.level === '1', s)

    /* SPL-1005: the search sheet (and the floating GO that opened it) is
       gone - `/search` is typed in the docked composer on every level */

    /* M4: the issues filter sheet, and a filter written while it is open survives Back */
    await page.goto(`${srv.base}/issues`, { waitUntil: 'networkidle2' })
    await sleep(1500)
    const i0 = await state(page)
    await click(page, '[data-test=issues-filters-open]')
    s = await until(page, (s) => s.filters)
    ok(`${at} the issues filter sheet opens`, s.filters, s)
    const picked = await page.evaluate(() => {
      const r = document.querySelector('[data-test=issues-filter-status-m] [role=radio]:not([aria-checked=true])')
      if (!r) return false
      r.click()
      return true
    })
    const i1 = picked ? await until(page, (s) => s.path !== i0.path, 3000) : await state(page)
    s = await back(page, (s) => !s.filters)
    ok(`${at} Back closes the filter sheet, stays on /issues at level ${i0.level}`, !s.filters && s.level === i0.level && s.path.startsWith('/issues'), s)
    if (picked && i1.path !== i0.path) ok(`${at} the filter chosen in the sheet survives the Back`, s.path === i1.path, { i1, s })

    /* a pick that closes the sort sheet AND writes ?sort= (replaceState) keeps the sort */
    await click(page, '[data-test=issues-sort-open]')
    await shown(page, '[data-test=issues-sort-opt][data-value="key"]')
    await click(page, '[data-test=issues-sort-opt][data-value="key"]')
    s = await until(page, (s) => !s.filters && /[?&]sort=key/.test(s.path) && /[?&]dir=asc/.test(s.path))
    ok(`${at} picking a sort closes the sheet and keeps ?sort=key&dir=asc`, !s.filters && /[?&]sort=key/.test(s.path) && /[?&]dir=asc/.test(s.path), s)
    await page.close()
  }

  /* desktop: a dialog writes no history, Back is what it always was */
  const page = await browser.newPage()
  await page.setViewport({ width: 1440, height: 900 })
  await page.goto(`${srv.base}/channel/lobby`, { waitUntil: 'networkidle2' })
  await sleep(1500)
  const d0 = await state(page)
  await click(page, '[data-testid=create-channel]')
  const d1 = await until(page, (s) => s.dialog)
  ok('1440px a dialog opens and writes no history entry', d1.dialog && d1.hist === d0.hist && d1.path === d0.path, { d0, d1 })
  await page.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmobile-overlay: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
