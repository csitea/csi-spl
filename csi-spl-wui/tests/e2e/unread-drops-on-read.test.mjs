// Owner, t1 56b8cc17 (HUM-10): on the phone, opening a topic - from the
// Topics list, or Channels > a channel > a topic - left every unread number
// where it was. The Topics list went (t1 e4bfddb1): Channels > #alerts and the
// topic's own address (/t/<id>) are the ways in now. Proved in a REAL browser against the mock bundle, at 390 and
// 1440 px: opening an unread topic drops its row badge and the section
// totals by what was read. The mock stands in for the hub's cover rule
// (contract flow-v1 section 3): a t:/ch:/dm: read mark at or past a line.
//
// Add-on, same topic, ~14:46Z: "anything that is archived should not be part
// of the unread messages counter", and an unread topic must not turn red
// once archived: archiving it from its card menu leaves no number and no
// badge on it.
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

/* Owner HUM-10 (t1 e4bfddb1): the Topics view is gone. A topic's unread now
   reads on its channel's row (Channels list, `channel-unread`), the Channels
   rail number and the tab title; `/` shows the Channels list (a phone, level
   1) or #lobby with it beside (a desktop). */
const CH_ROW = '#sidebar-panel-channels a.nav-item[data-key="alerts"]'

/* The rail's Channels number, the #alerts row's badge and the title's number, read from the DOM (a hidden level still holds them). */
function counts(page) {
  return page.evaluate((rowSel) => {
    const n = (sel) => parseInt(document.querySelector(sel)?.textContent.trim() || '0', 10) || 0
    const m = /^\((\d+)\+?\) /.exec(document.title)
    return {
      channels: n('[data-testid=sidebar-tab-channels-count]'),
      row: n(`${rowSel} [data-testid=channel-unread]`),
      title: m ? Number(m[1]) : 0,
      listed: Boolean(document.querySelector(rowSel)),
    }
  }, CH_ROW)
}

async function settle(page, before) {
  await page.waitForFunction((t) => {
    const c = parseInt(document.querySelector('[data-testid=sidebar-tab-channels-count]')?.textContent.trim() || '0', 10) || 0
    return c < t
  }, { timeout: 8000 }, before.channels).catch(() => {})
  return counts(page)
}

async function home(p, size) {
  await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, size)
  /* a phone's `/` is level 1, which keeps the section last shown there: pick Channels */
  if (!(await p.$(CH_ROW))) await p.click('[data-testid=sidebar-tab-channels]').catch(() => {})
  await p.waitForSelector(`${CH_ROW} [data-testid=channel-unread]`, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
  return counts(p)
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

    /* 1. Channels > #alerts > the topic */
    {
      const { ctx, p, errors } = await fresh(browser, size)
      const before = await home(p, size)
      ok(`${tag} channels: the #alerts row carries the topic's 2 unread, the Channels total and the title count them`, before.listed && before.row === 2 && before.channels >= 2 && before.title >= 2, before)
      await p.click(CH_ROW)
      const card = `.msg[data-msg-id="${TASK}"]`
      await p.waitForSelector(card, { visible: true, timeout: NAV_TIMEOUT }).catch(() => {})
      await p.evaluate((sel) => {
        const el = [...document.querySelectorAll(sel)].find((e) => e.getBoundingClientRect().width > 0)
        el?.click()
      }, card)
      /* t1 e4bfddb1 (c-201, 2026-10-11): in the same page the Channels number,
         the row and the title kept the 2 until a reload, while the same topic
         opened from the Flow dropped them at once. The card's open now pushes
         its read mark as the Flow's does. */
      const live = await settle(p, before)
      ok(`${tag} channels: opening it drops the Channels total in the same page`, live.channels === before.channels - before.row, { before, live })
      ok(`${tag} channels: the row's number goes in the same page`, live.row === 0, live)
      ok(`${tag} channels: the title drops in the same page`, live.title === before.title - before.row, { before, live })
      /* read back on `/` after a reload: what the reader finds when they come back */
      await new Promise((r) => setTimeout(r, 1500))
      const after = await home(p, size)
      ok(`${tag} channels: opening it drops the Channels total by what was read (after a reload)`, after.channels === before.channels - before.row, { before, after })
      ok(`${tag} channels: the row's own number goes`, after.row === 0, after)
      ok(`${tag} channels: the title drops with it`, after.title === before.title - before.row, { before, after })
      ok(`${tag} channels: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
      await ctx.close()
    }

    /* 2. the topic's own address (/t/<id>, a copied link): the thread is read */
    {
      const { ctx, p, errors } = await fresh(browser, size)
      const before = await home(p, size)
      await p.goto(server.base + '/t/' + TASK, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      await p.waitForSelector(`[data-test=topic-browse-thread] .msg[data-msg-id="${TASK}"]`, { timeout: NAV_TIMEOUT }).catch(() => {})
      const after = await settle(p, before)
      ok(`${tag} topic page: opening the topic drops the Channels total by its 2`, before.row === 2 && after.channels === before.channels - before.row, { before, after })
      ok(`${tag} topic page: the #alerts row's number goes`, after.row === 0, after)
      ok(`${tag} topic page: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
      await ctx.close()
    }

    /* 3. #alerts > the topic card's menu > Archive: an archived topic is never
       counted again and shows no red (the Topics row menu that archived an
       UNREAD topic went with the Topics view; opening the channel reads it) */
    {
      const { ctx, p, errors } = await fresh(browser, size)
      await p.evaluateOnNewDocument(() => {
        try {
          localStorage.setItem('spool.mock.archive_policy', 'everyone')
          localStorage.setItem('spool.mock.role', 'admin')
        } catch { /* about:blank */ }
      })
      const before = await home(p, size)
      await p.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
      await applyViewport(p, size)
      const card = `.spool-main article.msg[data-msg-id="${TASK}"]`
      await p.waitForSelector(card, { timeout: NAV_TIMEOUT }).catch(() => {})
      const read = await settle(p, before)
      let item = null
      for (let i = 0; i < 2 && !item; i++) {
        await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), card)
        item = await p.waitForSelector('[data-testid=msg-menu-archive]', { timeout: 5000 }).catch(() => null)
      }
      ok(`${tag} archive: the card menu offers Archive`, Boolean(item))
      if (item) await p.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())
      const gone = await p.waitForFunction((sel) => !document.querySelector(sel), { timeout: 8000 }, card).then(() => true, () => false)
      await new Promise((r) => setTimeout(r, 1500))
      const after = await counts(p)
      const red = await p.evaluate((task) => [...document.querySelectorAll(`[data-key="${task}"] .badge-unread, [data-msg-id="${task}"] [data-test=topic-unread]`)]
        .filter((b) => b.getBoundingClientRect().width > 0).map((b) => b.textContent.trim()), TASK)
      ok(`${tag} archive: the archived card leaves the feed`, gone)
      ok(`${tag} archive: the Channels total does not count the archived topic again`, before.row === 2 && after.channels === read.channels && after.channels === before.channels - before.row, { before, read, after })
      ok(`${tag} archive: nothing of the archived topic shows red`, red.length === 0 && after.row === 0, { red, after })
      ok(`${tag} archive: no page error`, errors.filter((e) => !/dynamically imported module/.test(e)).length === 0, errors)
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
