// Owner, t1 56b8cc17 (HUM-10): on the phone, opening a topic - from the
// Topics list, or Channels > a channel > a topic - left every unread number
// where it was. Proved in a REAL browser against the mock bundle, at 390 and
// 1440 px: opening an unread topic drops its row badge and the section
// totals by what was read. The mock stands in for the hub's cover rule
// (contract flow-v1 section 3): a t:/ch:/dm: read mark at or past a line.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e unread-drops-on-read
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SIZES = [{ width: 390, height: 844 }, { width: 1440, height: 900 }]
const TASK = '5e5e5e5e-5e5e-4e5e-8e5e-5e5e5e5e5e5e'
/* two lines that name the reader in one #alerts topic: two unread for HUM-1 */
const EXTRA = [
  { v: 1, msg_id: TASK, task_id: TASK, ts: '2026-09-18T11:00:00Z', from: 'GRK-03', from_box: 'box-a', to: '@channel', to_box: 'box-wui', kind: 'note', body: '@HUM-1 the alerts topic needs you', channel: 'alerts', parent_task_id: null, files: [] },
  { v: 1, msg_id: '5f5f5f5f-5f5f-4f5f-8f5f-5f5f5f5f5f5f', task_id: TASK, ts: '2026-09-18T11:01:00Z', from: 'CLE-07', from_box: 'box-a', to: '@channel', to_box: 'box-wui', kind: 'note', body: '@HUM-1 and a second line', channel: 'alerts', parent_task_id: null, files: [] },
]

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

/* The rail numbers and the topic row's badge, read from the DOM (a hidden level still holds them). */
function counts(page) {
  return page.evaluate((task) => {
    const n = (sel) => parseInt(document.querySelector(sel)?.textContent.trim() || '0', 10) || 0
    const row = document.querySelector(`#sidebar-panel-topics .nav-item[data-key="${task}"]`)
    return {
      topics: n('[data-testid=sidebar-tab-topics-count]'),
      channels: n('[data-testid=sidebar-tab-channels-count]'),
      row: parseInt(row?.querySelector('[data-testid=topic-unread]')?.textContent.trim() || '0', 10) || 0,
      listed: Boolean(row),
    }
  }, TASK)
}

async function settle(page, before) {
  await page.waitForFunction((task, t) => {
    const c = parseInt(document.querySelector('[data-testid=sidebar-tab-topics-count]')?.textContent.trim() || '0', 10) || 0
    return c < t
  }, { timeout: 8000 }, TASK, before.topics).catch(() => {})
  return counts(page)
}

async function fresh(browser, size) {
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
  await setPageViewport(p, size)
  return { ctx, p, errors }
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`

    /* 1. Topics > the topic */
    {
      const { ctx, p, errors } = await fresh(browser, size)
      await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      await p.click('[data-testid=sidebar-tab-topics]')
      await p.waitForSelector(`#sidebar-panel-topics .nav-item[data-key="${TASK}"] [data-testid=topic-unread]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
      const before = await counts(p)
      ok(`${tag} topics: the seeded topic is listed unread (2), the Topics total counts it`, before.listed && before.row === 2 && before.topics >= 2, before)
      await p.click(`#sidebar-panel-topics .nav-item[data-key="${TASK}"]`)
      const after = await settle(p, before)
      ok(`${tag} topics: opening it drops the Topics total by what was read`, after.topics === before.topics - before.row, { before, after })
      ok(`${tag} topics: the row's own number goes`, after.row === 0, after)
      ok(`${tag} topics: the Channels total drops with it`, after.channels === Math.max(0, before.channels - before.row), { before, after })
      ok(`${tag} topics: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
      await ctx.close()
    }

    /* 2. Channels > #alerts > the topic */
    {
      const { ctx, p, errors } = await fresh(browser, size)
      await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      await p.click('[data-testid=sidebar-tab-topics]')
      await p.waitForSelector(`#sidebar-panel-topics .nav-item[data-key="${TASK}"] [data-testid=topic-unread]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
      const before = await counts(p)
      await p.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      const card = `.msg[data-msg-id="${TASK}"]`
      await p.waitForSelector(card, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
      await p.evaluate((sel) => {
        const el = [...document.querySelectorAll(sel)].find((e) => e.getBoundingClientRect().width > 0)
        el?.click()
      }, card)
      const after = await settle(p, before)
      ok(`${tag} channel: opening the channel's topic drops the Topics total`, after.topics === before.topics - before.row && before.row === 2, { before, after })
      ok(`${tag} channel: the topic row's number goes`, after.row === 0, after)
      ok(`${tag} channel: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
      await ctx.close()
    }
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
