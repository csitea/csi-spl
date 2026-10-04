// HUM-10 (t1 f77c9f87): "on the left most panel - the list of the boxes, on
// the second panel the list of the resources per box - agents, hardware, OS,
// RUN-TIMES ETC." and "on the right panel some statistics on those".
//
// At 1440 px, light and dark: /boxes, a click on box-a in the sidebar's Boxes
// list opens its resources in the middle; the three panes stand left to
// right (boxes list | resources | statistics) with no topic panel beside
// them. Agents opens the agents statistics (one row per agent on box-a);
// Hardware opens the empty box-stats state ("no history yet" - the mock
// serves no samples, and never invents any) plus the named GCP VM slot; OS
// reads "not reported yet". No horizontal page scroll.
//
// At 390 px (phone): one pane at a time - the list, the resources, the
// statistics - and Back steps down one pane, to the list.
//
// Screenshots for the owner post land in $SHOT_DIR when it is set.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e boxes-three-panes
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
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

/* every visible column, left to right */
const panes = (p) => p.evaluate(() => {
  const shown = (el) => {
    if (!el) return null
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && getComputedStyle(el).display !== 'none' ? r : null
  }
  const cols = []
  const add = (name, el) => { const r = shown(el); if (r) cols.push({ name, left: Math.round(r.left), right: Math.round(r.right) }) }
  add('boxes-list', document.querySelector('[data-testid=sidebar-panel-boxes]'))
  add('resources', document.querySelector('[data-test=box-card]'))
  add('stats', document.querySelector('[data-test=box-stats]'))
  add('topic', document.querySelector('[data-test=topic-section]'))
  return cols.sort((a, b) => a.left - b.left)
})
const visible = (p, sel) => p.evaluate((s) => {
  const el = document.querySelector(s)
  if (!el) return false
  const r = el.getBoundingClientRect()
  return r.width > 0 && r.height > 0 && getComputedStyle(el).display !== 'none'
}, sel)
const count = (p, sel) => p.$$eval(sel, (els) => els.length)
const noXScroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth + 1)
const query = (p) => p.evaluate(() => new URL(location.href).searchParams.get('r') || '')
async function shot(p, name) {
  if (!SHOT_DIR) return
  mkdirSync(SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(SHOT_DIR, name + '.png') })
}
async function click(p, sel) {
  await p.waitForSelector(sel, { visible: true, timeout: NAV_TIMEOUT })
  await p.click(sel)
}

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) {
    console.log(`-- 1440x900 ${theme}`)
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/boxes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })

    /* left: the sidebar's boxes list; a click opens the box in the middle */
    await click(p, '[data-testid=sidebar-panel-boxes] a[data-key="box-a"]')
    await p.waitForSelector('[data-test=box-resources]', { visible: true, timeout: NAV_TIMEOUT })
    await sleep(300)
    const cols = await panes(p)
    ok(`${theme}: three panes, list | resources | statistics`,
      cols.map((c) => c.name).join(',') === 'boxes-list,resources,stats', cols)
    ok(`${theme}: the panes do not overlap`, cols.every((c, i) => i === 0 || c.left >= cols[i - 1].right - 1), cols)
    ok(`${theme}: every resource row is listed`,
      await count(p, '[data-test^=box-resource-]:not([data-test^=box-resource-sum])') === 4)
    ok(`${theme}: no resource picked yet - the right pane says so`, await visible(p, '[data-test=box-stats-pick]'))

    /* agents -> the agents statistics on the right */
    await click(p, '[data-test=box-resource-agents]')
    await p.waitForSelector('[data-test=box-stats-pane][data-resource=agents]', { visible: true, timeout: NAV_TIMEOUT })
    ok(`${theme}: agents - one row per agent on box-a`, await count(p, '[data-test=box-stats-agent]') === 2)
    ok(`${theme}: agents - totals`, await p.$eval('[data-test=box-stats-agents-total]', (e) => e.textContent.trim()) === '2')
    ok(`${theme}: agents - the selection rides the URL`, await query(p) === 'agents')
    ok(`${theme}: agents - the row is marked current`, await p.$eval('[data-test=box-resource-agents]', (e) => e.getAttribute('aria-current')) === 'true')
    await shot(p, `boxes-agents-1440-${theme}`)

    /* hardware -> the empty box-stats state and the GCP slot, no error */
    await click(p, '[data-test=box-resource-hardware]')
    await p.waitForSelector('[data-test=box-stats-pane][data-resource=hardware]', { visible: true, timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=box-stats-empty]', { visible: true, timeout: NAV_TIMEOUT })
    ok(`${theme}: hardware - "no history yet"`, await visible(p, '[data-test=box-stats-empty]'))
    ok(`${theme}: hardware - not an error`, !(await visible(p, '[data-test=box-stats-failed]')))
    ok(`${theme}: hardware - no invented numbers`, await count(p, '[data-test=box-stats-hour]') === 0)
    ok(`${theme}: hardware - the GCP VM slot is named`, await visible(p, '[data-test=box-stats-gcp]'))
    await shot(p, `boxes-hardware-1440-${theme}`)

    /* OS -> not reported yet (the hub serves none in the mock) */
    await click(p, '[data-test=box-resource-os]')
    await p.waitForSelector('[data-test=box-stats-pane][data-resource=os]', { visible: true, timeout: NAV_TIMEOUT })
    ok(`${theme}: os - "not reported yet"`, await visible(p, '[data-test=box-stats-not-reported]'))
    ok(`${theme}: no horizontal page scroll`, await noXScroll(p))
    await p.close()
  }

  for (const theme of ['light', 'dark']) {
    console.log(`-- 390x844 ${theme} (phone)`)
    const vp = { width: 390, height: 844 }
    const p = await browser.newPage()
    await setPageViewport(p, vp)
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await p.waitForSelector('[data-testid=sidebar-rail]', { visible: true, timeout: NAV_TIMEOUT })
    await sleep(600)
    /* level 1: the Boxes section's list (the tab may sit off screen in the strip) */
    await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-boxes]')?.click())
    await click(p, '[data-testid=sidebar-panel-boxes] a[data-key="box-a"]')
    await p.waitForSelector('[data-test=box-resources]', { visible: true, timeout: NAV_TIMEOUT })
    await sleep(300)
    ok(`${theme}: phone - the resources alone`,
      (await visible(p, '[data-test=box-card]')) && !(await visible(p, '[data-test=box-stats]')) && !(await visible(p, '[data-testid=sidebar-panel-boxes]')))

    await click(p, '[data-test=box-resource-hardware]')
    await p.waitForSelector('[data-test=box-stats-empty]', { visible: true, timeout: NAV_TIMEOUT })
    await sleep(300)
    ok(`${theme}: phone - the statistics alone`,
      (await visible(p, '[data-test=box-stats]')) && !(await visible(p, '[data-test=box-card]')))
    ok(`${theme}: phone - empty box-stats state`, await visible(p, '[data-test=box-stats-empty]'))
    ok(`${theme}: phone - no horizontal page scroll`, await noXScroll(p))
    await shot(p, `boxes-hardware-390-${theme}`)

    /* Back: statistics -> resources */
    await click(p, '[data-testid=mobile-back]')
    await p.waitForSelector('[data-test=box-card]', { visible: true, timeout: NAV_TIMEOUT })
    await sleep(500)
    ok(`${theme}: phone - Back returns to the resources`,
      (await visible(p, '[data-test=box-card]')) && !(await visible(p, '[data-test=box-stats]')) && (await query(p)) === '', { r: await query(p) })

    /* Back: resources -> the boxes list */
    await click(p, '[data-testid=mobile-back]')
    await p.waitForSelector('[data-testid=sidebar-panel-boxes] a[data-key="box-a"]', { visible: true, timeout: NAV_TIMEOUT })
    ok(`${theme}: phone - Back again returns to the boxes list`, !(await visible(p, '[data-test=box-card]')))
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
