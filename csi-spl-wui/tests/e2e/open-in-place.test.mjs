// CLE-77882 (Flow + Search rework, lane A): /m/<msg_id> opens a message in
// its ORIGINAL place, cold, in a real browser on the mock tenant (1440 + 390):
//   - a topic message: its channel, the topic open, the card marked
//   - a reply: its thread open, the reply marked (open-focus)
//   - a DM: the DM with the other end
//   - an unknown id: a notice that says so (data-reason=not_found), no navigation
//   - the /m/ page replaces itself (Back does not land on it again)
//
//   node tests/e2e/open-in-place.test.mjs          (mock tenant, nuxi dev)
//   BASE_URL=<generated bundle> node tests/e2e/open-in-place.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.OPEN_IN_PLACE_SHOTS || mkdtempSync(join(tmpdir(), 'spool-open-in-place-'))
/* the mock tenant (utils/mock-data.mjs) */
const TOPIC_MSG = '22222222-2222-4222-8222-222222222222'
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const REPLY = '33333333-3333-4333-8333-333333333333'
const ALERT = '66666666-6666-4666-8666-666666666666'
const DM = '77777777-7777-4777-8777-777777777777'
const UNKNOWN = '0badc0de-0bad-4bad-8bad-0badc0de0bad'
const LOBBY_REPLY = '55555555-5555-4555-8555-555555555555'
const WIDTHS = [{ width: 1440, height: 900 }, { width: 390, height: 844, isMobile: true, hasTouch: true }]

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
        defaultViewport: WIDTHS[0],
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** the message marked and inside its own scroller's visible band */
async function markedInView(p, id) {
  /* any VISIBLE copy: on a phone the middle card is hidden behind the thread pane */
  const marked = await p.waitForFunction((sel) => [...document.querySelectorAll(sel)].some((el) => el.getBoundingClientRect().height > 0),
    { timeout: 15000, polling: 50 }, `.msg[data-msg-id="${id}"].open-focus`).then(() => true).catch(() => false)
  if (!marked) return { marked, inView: false }
  const inView = await p.$$eval(`.msg[data-msg-id="${id}"]`, (els) => els.some((el) => {
    const r = el.getBoundingClientRect()
    const box = (el.closest('.feed-body') || document.documentElement).getBoundingClientRect()
    return r.height > 0 && r.bottom > box.top && r.top < box.bottom
  }))
  return { marked, inView }
}

const server = await startServer()
const browser = await launch()
mkdirSync(SHOTS, { recursive: true })
const errors = []
try {
  for (const vp of WIDTHS) {
    const W = vp.width
    console.log(`-- ${W} px`)
    const p = await browser.newPage()
    await p.setViewport(vp)
    p.on('pageerror', (e) => errors.push(String(e && e.message)))
    await p.evaluateOnNewDocument(() => {
      try { localStorage.setItem('spool.flow-scope', 'all'); localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
    })
    const open = async (id) => {
      await p.goto(server.base + '/m/' + id, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      await p.waitForFunction(() => !location.pathname.includes('/m/') || document.querySelector('[data-testid=open-msg-notice]'), { timeout: NAV_TIMEOUT }).catch(() => null)
      return new URL(p.url())
    }

    /* 1: a reply -> the channel, its thread open, the reply marked */
    await p.goto(server.base + '/', { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    let url = await open(REPLY)
    ok(`${W} 1 reply: /channel/lobby?topic=<thread>#<reply>`, url.pathname.endsWith('/channel/lobby') && url.searchParams.get('topic') === TOPIC && url.hash === '#' + REPLY, url.href)
    let m = await markedInView(p, REPLY)
    ok(`${W} 2 reply: marked open-focus and in view`, m.marked && m.inView, m)
    await p.screenshot({ path: `${SHOTS}/${W}-reply.png` })
    await p.goBack({ waitUntil: 'domcontentloaded' }).catch(() => null)
    ok(`${W} 3 Back does not land on /m/ again`, !new URL(p.url()).pathname.includes('/m/'), p.url())

    /* 4: a topic message -> its channel, the topic open, the card marked */
    url = await open(TOPIC_MSG)
    ok(`${W} 4 topic message: its channel with the topic`, url.pathname.endsWith('/channel/lobby') && url.searchParams.get('topic') === TOPIC, url.href)
    m = await markedInView(p, TOPIC_MSG)
    ok(`${W} 5 topic message: marked and in view`, m.marked && m.inView, m)

    /* 6: another channel */
    url = await open(ALERT)
    ok(`${W} 6 #alerts message: /channel/alerts`, url.pathname.endsWith('/channel/alerts'), url.href)
    m = await markedInView(p, ALERT)
    ok(`${W} 7 #alerts message: marked`, m.marked, m)

    /* 8: a DM -> the DM with the other end */
    url = await open(DM)
    ok(`${W} 8 DM: /dm/GRK-03`, /\/dm\/GRK-03/.test(decodeURIComponent(url.pathname)), url.href)
    m = await markedInView(p, DM)
    ok(`${W} 9 DM: marked`, m.marked, m)
    await p.screenshot({ path: `${SHOTS}/${W}-dm.png` })

    /* 10: unknown -> a notice, stays put */
    url = await open(UNKNOWN)
    const reason = await p.$eval('[data-testid=open-msg-notice]', (el) => el.getAttribute('data-reason')).catch(() => '')
    ok(`${W} 10 unknown id: notice data-reason=not_found, no navigation`, reason === 'not_found' && url.pathname.includes('/m/'), { reason, url: url.href })
    await p.screenshot({ path: `${SHOTS}/${W}-notice.png` })
    const sw = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    ok(`${W} 11 no horizontal scroll`, sw <= 0, sw)
    /* 12 (lane B repro): one channel's topic open, then a reply in ANOTHER
       channel from the Flow list - the old target must not strip ?topic= */
    if (W > 820) {
      await p.goto(server.base + '/', { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      await p.waitForSelector('[data-testid=sidebar-tab-flow]', { visible: true, timeout: NAV_TIMEOUT })
      await p.click('[data-testid=sidebar-tab-flow]')
      const entry = (id) => `[data-testid=left-list] [data-testid=left-entry][data-msg-id="${id}"]`
      await p.waitForSelector(entry(ALERT), { visible: true, timeout: NAV_TIMEOUT })
      await p.click(entry(ALERT))
      await p.waitForFunction(() => location.pathname.endsWith('/channel/alerts'), { timeout: 15000 }).catch(() => null)
      await markedInView(p, ALERT)
      await p.click(entry(LOBBY_REPLY))
      await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 15000 }).catch(() => null)
      /* the open path is the Flow list's own; this pins that the thread opens and stays */
      const shown = await p.waitForFunction((id) => [...document.querySelectorAll(`aside.live-pane .msg[data-msg-id="${id}"], .topic-pane .msg[data-msg-id="${id}"]`)].some((el) => el.getBoundingClientRect().height > 0),
        { timeout: 15000, polling: 100 }, LOBBY_REPLY).then(() => true).catch(() => false)
      await new Promise((r) => setTimeout(r, 1000))
      url = new URL(p.url())
      ok(`${W} 12 Flow: #alerts then a #lobby reply - ?topic= kept, the reply shown in its thread`, url.searchParams.get('topic') === TOPIC && shown, { url: url.href, shown })
    }
    await p.close()
  }
  console.log(`  screenshots ${SHOTS}`)
  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('12 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`open-in-place: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
