// Spec 079 (one unread model, shown on the row), AC4 + AC5, in a REAL browser
// against the mock bundle at 1440 px. One line naming the reader in an
// #alerts topic gives that topic one unread:
//
//   AC4  the sidebar Topics row and the middle Topics list row both show 1,
//        the Topics rail counts it, and the tab title carries a number
//   AC5  opening the topic from the middle list drops both rows to nothing,
//        the Topics rail and the title by that 1 - checked one
//        requestAnimationFrame after the first row clears (FR-009)
//
// The card's "<new>/<total>" reads the model with T006; its e2e are
// topic-unread-count and channel-thread-unread.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e unread-on-row
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SIZE = { width: 1440, height: 900 }
const TASK = '79797979-7979-4979-8979-797979797979'
/* one line that names the reader in one #alerts topic: one unread for HUM-1 */
const EXTRA = [
  { v: 1, msg_id: TASK, task_id: TASK, ts: '2026-09-18T11:00:00Z', from: 'GRK-03', from_box: 'box-a', to: '@channel', to_box: 'box-wui', kind: 'note', body: '@HUM-1 one line for the row', channel: 'alerts', parent_task_id: null, files: [] },
]
const SIDE = `#sidebar-panel-topics .nav-item[data-key="${TASK}"]`
const MID = `.topic-row[data-key="${TASK}"]`

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

/* Both rows' badges, the Topics rail and the title's number (0 when none). */
const READ = (side, mid) => {
  const n = (el) => parseInt(el?.textContent.trim() || '0', 10) || 0
  const m = /^\((\d+)\+?\) /.exec(document.title)
  return {
    side: n(document.querySelector(`${side} [data-testid=topic-unread]`)),
    mid: n(document.querySelector(`${mid} [data-testid=topic-row-unread]`)),
    rail: n(document.querySelector('[data-testid=sidebar-tab-topics-count]')),
    title: m ? Number(m[1]) : 0,
    listed: Boolean(document.querySelector(side)) && Boolean(document.querySelector(mid)),
  }
}

const server = await startServer()
const browser = await launch()
try {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((extra) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' }))
      localStorage.setItem('spool.mock.extra-messages', JSON.stringify(extra))
    } catch { /* about:blank */ }
  }, EXTRA)
  await setPageViewport(p, SIZE)
  await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, SIZE)
  await p.click('[data-testid=sidebar-tab-topics]')
  await p.waitForSelector(`${SIDE} [data-testid=topic-unread]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
  await p.waitForSelector(`${MID} [data-testid=topic-row-unread]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})

  const before = await p.evaluate(READ, SIDE, MID)
  ok('AC4: the topic is listed in the sidebar and in the middle Topics list', before.listed, before)
  ok('AC4: the sidebar Topics row shows 1', before.side === 1, before)
  ok('AC4: the middle Topics row shows the same 1', before.mid === 1, before)
  ok('AC4: the Topics rail counts it', before.rail >= 1, before)
  ok('AC4: the tab title carries the unread', before.title >= 1, before)

  /* a CDP evaluate, not an in-page eval: the bundle's CSP stays untouched */
  await p.evaluate(`window.__unreadRead = ${READ}`)
  await p.click(MID)
  /* the first row to clear, then ONE frame: every other surface must already agree */
  await p.waitForFunction((side, mid) => !document.querySelector(`${side} [data-testid=topic-unread]`) || !document.querySelector(`${mid} [data-testid=topic-row-unread]`), { timeout: 8000 }, SIDE, MID).catch(() => {})
  const after = await p.evaluate((side, mid) => new Promise((resolve) => {
    requestAnimationFrame(() => resolve(window.__unreadRead(side, mid)))
  }), SIDE, MID)
  ok('AC5: the sidebar row drops to nothing', after.side === 0, after)
  ok('AC5: the middle row drops to nothing', after.mid === 0, after)
  ok('AC5: the Topics rail drops by that 1', after.rail === before.rail - 1, { before, after })
  ok('AC5: the title drops by that 1', after.title === before.title - 1, { before, after })
  ok('no page error', errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
  await ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
