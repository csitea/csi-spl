// Spec 079 (one unread model, shown on the row), AC4 + AC5, in a REAL browser
// against the mock bundle at 1440 px. One line naming the reader in an
// #alerts topic gives that topic one unread:
//
//   AC4  the #alerts row in Channels shows 1, the Channels rail counts it,
//        and the tab title carries a number
//   AC5  opening the topic from the Flow list drops the row to nothing, the
//        Channels rail and the title by that 1 - the rail checked one
//        requestAnimationFrame after the row clears (FR-009), the title once
//        the head has written it (see AC5 below)
//
// The Topics list (its row and rail number) was AC4/AC5's place until the
// Topics view went (owner HUM-10, t1 e4bfddb1): the row is now the topic's
// channel's.
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
const ROW = '#sidebar-panel-channels a.nav-item[data-key="alerts"]'
const FLOW = `[data-testid=left-list][data-mode=flow] [data-msg-id="${TASK}"]`

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

/* The #alerts row's badge, the Channels rail, the title's number (0 when none), and no Topics surface. */
const READ = (row) => {
  const n = (el) => parseInt(el?.textContent.trim() || '0', 10) || 0
  const m = /^\((\d+)\+?\) /.exec(document.title)
  return {
    row: n(document.querySelector(`${row} [data-testid=channel-unread]`)),
    rail: n(document.querySelector('[data-testid=sidebar-tab-channels-count]')),
    title: m ? Number(m[1]) : 0,
    listed: Boolean(document.querySelector(row)),
    topics: Boolean(document.querySelector('#sidebar-tab-topics, #sidebar-panel-topics, .spool-main .topic-row')),
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
  await p.waitForSelector(`${ROW} [data-testid=channel-unread]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})

  const before = await p.evaluate(READ, ROW)
  ok('AC4: the topic\'s channel is listed in Channels', before.listed, before)
  ok('AC4: no Topics tab, panel or list (t1 e4bfddb1)', !before.topics, before)
  ok('AC4: the #alerts row shows 1', before.row === 1, before)
  ok('AC4: the Channels rail counts it', before.rail >= 1, before)
  ok('AC4: the tab title carries the unread', before.title >= 1, before)

  /* a CDP evaluate, not an in-page eval: the bundle's CSP stays untouched */
  await p.evaluate(`window.__unreadRead = ${READ}`)
  await p.click('[data-testid=sidebar-tab-flow]')
  await p.waitForSelector(FLOW, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
  await p.click(FLOW).catch(() => {})
  /* the row clears, then ONE frame: every other surface must already agree */
  await p.waitForFunction((row) => !document.querySelector(`${row} [data-testid=channel-unread]`), { timeout: 8000 }, ROW).catch(() => {})
  const after = await p.evaluate((row) => new Promise((resolve) => {
    requestAnimationFrame(() => resolve(window.__unreadRead(row)))
  }), ROW)
  ok('AC5: the #alerts row drops to nothing', after.row === 0, after)
  ok('AC5: the Channels rail drops by that 1', after.rail === before.rail - 1, { before, after })
  /* The title is the model's number too, but unhead writes document.title
     on a setTimeout after the reactive tick and holds it from page:start to
     page:finish (nuxt/dist/head/runtime/plugins/unhead.js): the Flow click
     navigates, so the DOM title can lag the row by more than one frame. It
     read 2 -> 2 one frame after the row cleared on 11/12 ubuntu-latest runs,
     so the title gets until the head has flushed. */
  await p.waitForFunction((want) => {
    const m = /^\((\d+)\+?\) /.exec(document.title)
    return (m ? Number(m[1]) : 0) === want
  }, { timeout: 8000 }, before.title - 1).catch(() => {})
  const titled = await p.evaluate(READ, ROW)
  ok('AC5: the title drops by that 1', titled.title === before.title - 1, { before, after, titled })
  ok('no page error', errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
  await ctx.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
