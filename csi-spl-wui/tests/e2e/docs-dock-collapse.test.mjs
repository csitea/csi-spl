// SPL-2516 (qto reading panel row 02, csi-spl-doc/doc/md/qto-reading-panel-plan.md):
// on a phone (<= 820 px) the reading routes `/docs` and `/workspace/docs` get
// the bottom 73-95 px back: the OmniBox composer dock and the status strip
// under it collapse to height 0. Search stays one tap away: the layout's
// compact search button calls useOmniboxStore().openSearch(), which brings
// the dock back in search mode.
//
//   412x915 and 800x915 (hasTouch):
//     1 /workspace/docs and /docs: the dock and the strip take 0 px, and
//       --composer-dock-h is 0px (red on master: the dock takes >= 50 px)
//     2 /workspace/docs: the search button opens the dock in search mode with
//       the field focused; a second tap on the dock's own Search button leaves
//       search and the dock collapses again
//     3 CONTROL /channel/general: the dock is there, >= 50 px with the strip,
//       and there is no docs search button
//   1280x900 CONTROL: /workspace/docs keeps the top-bar Omnibox, not docked,
//     no docs search button
//
// Run:
//   pnpm run test:e2e docs-dock-collapse
//   BASE_URL=<generated bundle> pnpm run test:e2e docs-dock-collapse   # what CI does
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const FORM = 'form.composer.omnibox--global'
const DOCK = 'form.composer.composer--dock'
const OPEN = '[data-test=docs-search-open]'
const STRIP = '[data-test=status-strip]'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
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

async function newPage(browser, vp) {
  const p = await browser.newPage()
  p.__errors = []
  p.on('pageerror', (e) => p.__errors.push(String(e.message || e)))
  await p.setViewport(vp)
  await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
  return p
}

/* the bottom room the dock and the strip take, as the reader sees it */
function bottomRoom(sel) {
  const h = (el) => {
    if (!el) return 0
    const cs = getComputedStyle(el)
    return cs.display === 'none' || cs.visibility === 'hidden' ? 0 : Math.round(el.getBoundingClientRect().height)
  }
  const form = document.querySelector(sel.FORM)
  return {
    docked: Boolean(document.querySelector(sel.DOCK)),
    dock: h(document.querySelector(sel.DOCK)),
    strip: h(document.querySelector(sel.STRIP)),
    dockVar: getComputedStyle(document.documentElement).getPropertyValue('--composer-dock-h').trim(),
    open: Boolean(document.querySelector(sel.OPEN)),
    search: Boolean(form && form.classList.contains('omnibox--search')),
    focused: Boolean(form && document.activeElement && form.contains(document.activeElement) && document.activeElement.tagName === 'TEXTAREA'),
  }
}
const SEL = { FORM, DOCK, OPEN, STRIP }
const room = (p) => p.evaluate(bottomRoom, SEL)

async function visit(p, base, path) {
  await p.goto(`${base}${path}`, { waitUntil: 'networkidle2' })
  await p.waitForSelector(FORM, { timeout: 20000 })
  await sleep(600)
}

async function phone(browser, base, vp) {
  const tag = `${vp.width}x${vp.height}`
  const p = await newPage(browser, { ...vp, isMobile: true, hasTouch: true })
  for (const path of ['/workspace/docs', '/docs']) {
    await visit(p, base, path)
    const r = await until(() => room(p), (s) => s.dock === 0 && s.strip === 0 && s.dockVar === '0px')
    ok(`${tag} 1 ${path}: the dock and the strip collapse to 0 px`, r.docked && r.dock === 0 && r.strip === 0 && r.dockVar === '0px', r)
    ok(`${tag} 1 ${path}: the compact search button is there`, r.open, r)
  }

  await visit(p, base, '/workspace/docs')
  if (await p.$(OPEN)) {
    await p.click(OPEN)
    const s = await until(() => room(p), (x) => x.search && x.dock >= 40 && x.focused)
    ok(`${tag} 2 the search button opens the dock in search mode, field focused`, s.search && s.dock >= 40 && s.focused && !s.open, s)
    await p.click(`${DOCK} [data-test=search-syntax-help]`)
    const c = await until(() => room(p), (x) => !x.search && x.dock === 0)
    ok(`${tag} 2 leaving search collapses the dock again, the button is back`, !c.search && c.dock === 0 && c.open, c)
  } else {
    ok(`${tag} 2 the search button opens the dock in search mode, field focused`, false, 'no search button')
  }

  await visit(p, base, '/channel/general')
  const ch = await until(() => room(p), (x) => x.dock + x.strip >= 50)
  ok(`${tag} 3 CONTROL /channel/general keeps the dock (>= 50 px), no docs button`, ch.docked && ch.dock + ch.strip >= 50 && ch.dock > 0 && !ch.open, ch)
  ok(`${tag} no page error`, p.__errors.length === 0, p.__errors)
  await p.close()
}

const srv = await startServer()
const browser = await launch()
try {
  for (const vp of [{ width: 412, height: 915 }, { width: 800, height: 915 }]) await phone(browser, srv.base, vp)

  const d = await newPage(browser, { width: 1280, height: 900 })
  await visit(d, srv.base, '/workspace/docs')
  const dr = await room(d)
  const form = await d.$eval(FORM, (f) => Math.round(f.getBoundingClientRect().height))
  ok('1280 CONTROL /workspace/docs: top-bar Omnibox, not docked, no docs button', !dr.docked && !dr.open && form > 0, { ...dr, form })
  ok('1280 no page error', d.__errors.length === 0, d.__errors)
  await d.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((x) => !x.ok)
console.log(`\ndocs-dock-collapse: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
