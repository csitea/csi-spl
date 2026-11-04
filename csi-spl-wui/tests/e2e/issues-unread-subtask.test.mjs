// SPL-4800 (csitea HUM-24, 2026-11-03/04): "I opened all the available tasks,
// the icon with the number 1 still stays on Tasks". The badge counts every
// unopened task assigned to me, a subtask too (issues-v1 2.1: "not a level-1
// row"), but the Unread list read the hub with the sheet's kind=issue, so an
// unopened subtask kept the badge at 1 over an empty list. In a REAL browser,
// against the mock bundle: a teammate assigned me SPL-2 (an issue) and SPL-3,
// a subtask of SPL-2 (spool.mock.issues-new = 1, issues-new-sub = 1).
//
//   1  the badge reads 2 and its click lists both rows, the subtask too
//   2  open SPL-2 (the parent), back: the badge is 1 and the list still
//      holds SPL-3 (the reported bug: 1 over an empty list)
//   3  open SPL-3 from that list, back: the badge and the list are empty
//   4  CONTROL: Unread off, the sheet lists SPL-2 but not the subtask
//      (kind=issue, unchanged)
//
// Run:
//   BASE_URL=<generated mock bundle> pnpm run test:e2e issues-unread-subtask
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const until = (p, fn, arg, ms) => p.waitForFunction(fn, { timeout: ms }, arg).then(() => true, () => false)

const BADGE = '[data-testid=sidebar-tab-issues-count]'
const ROW = '[data-test=issues-row]'
const keys = (p) => p.$$eval(ROW, (els) => els.map((e) => e.getAttribute('data-key')).sort())
const badge = (p) => p.$eval(BADGE, (e) => e.textContent.trim()).catch(() => '')

/* open a row's issue, then close it with Escape */
async function openAndClose(p, key) {
  await p.click(`${ROW}[data-key="${key}"] .issues-title`)
  const opened = await until(p, () => Boolean(document.querySelector('[data-test=issues-detail]')), null, 8000)
  await p.keyboard.press('Escape')
  const closed = await until(p, () => !document.querySelector('[data-test=issues-detail]'), null, 8000)
  return opened && closed
}

const server = await startServer()
const browser = await launch()
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
  await p.evaluateOnNewDocument(() => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
      localStorage.setItem('spool.mock.issues-new', '1')
      localStorage.setItem('spool.mock.issues-new-sub', '1')
    } catch { /* about:blank */ }
  })
  const vp = { width: 1280, height: 800 }
  await setPageViewport(p, vp)
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, vp)
  await p.evaluate(() => document.getElementById('nuxt-devtools-container')?.remove())

  await p.waitForSelector(`${ROW}[data-key="SPL-2"]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const two = await until(p, (s) => document.querySelector(s)?.textContent?.trim() === '2', BADGE, 8000)
  await p.click(BADGE)
  await until(p, () => new URL(window.location.href).searchParams.get('unread') === '1', null, 8000)
  const both = await until(p, (s) => document.querySelectorAll(s).length === 2, ROW, 8000)
  ok('1 the badge reads 2 and its list holds both rows, the subtask too', two && both && (await keys(p)).join() === 'SPL-2,SPL-3', { badge: await badge(p), rows: await keys(p) })

  const parent = await openAndClose(p, 'SPL-2')
  const one = await until(p, (s) => document.querySelector(s)?.textContent?.trim() === '1', BADGE, 8000)
  const sub = await until(p, (s) => document.querySelectorAll(s).length === 1 && Boolean(document.querySelector(`${s}[data-key="SPL-3"]`)), ROW, 8000)
  ok('2 open the parent: the badge is 1 and the list still shows the subtask behind it', parent && one && sub, { parent, badge: await badge(p), rows: await keys(p) })

  const child = sub && await openAndClose(p, 'SPL-3')
  const gone = await until(p, (s) => !document.querySelector(s), BADGE, 8000)
  const empty = await until(p, (s) => document.querySelectorAll(s).length === 0, ROW, 8000)
  ok('3 open the subtask: the badge and the Unread list are both empty', Boolean(child) && gone && empty, { child, badge: await badge(p), rows: await keys(p) })

  await p.click('[data-test=issues-filter-unread]')
  const off = await until(p, (s) => Boolean(document.querySelector(`${s}[data-key="SPL-2"]`)) && !new URL(window.location.href).searchParams.has('unread'), ROW, 8000)
  const sheet = await keys(p)
  ok('4 CONTROL: Unread off, the sheet lists SPL-2 and not the subtask', off && sheet.includes('SPL-2') && !sheet.includes('SPL-3'), { off, sheet })
  ok('no unexpected page errors', errors.length === 0, errors)
  await ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nissues-unread-subtask: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) process.exit(1)
