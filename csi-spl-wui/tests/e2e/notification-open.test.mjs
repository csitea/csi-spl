// CLE-77890 (owner, t1 bd6d7291: tapping an Android alert "does not jump to
// the actual UI of the announcement, but just keeps me there where I was"):
// a tapped alert opens its message, in a real browser on the mock tenant
// (1440 + 390 touch).
//
// The tap itself is the service worker's (public/sw.js, unit-tested in
// tests/unit/sw-notification-click.test.mjs); what reaches the page is the
// worker's hand-over: a `message` event on navigator.serviceWorker carrying
// { type: 'spool:notification-open', msgId, url: /m/<msg_id> } and a port.
// This test dispatches exactly that event from another page (the Issues tab,
// "where I was") and asserts:
//   - the page answers on the port (so the worker does not reload the tab)
//   - the app leaves where it was for the message's channel, topic open
//   - the message is marked (open-focus) and in view
//   - a foreign url in the hand-over goes nowhere
//   - a tap cut short by the tab's own new-version reload opens after it
//   - built bundle only: the REAL sw.js's notificationclick, fired inside the
//     worker, opens the message (and an alert with no target, from an older
//     page, opens its feed from the tag) in the open tab
//
//   node tests/e2e/notification-open.test.mjs          (mock tenant, nuxi dev)
//   BASE_URL=<generated bundle> node tests/e2e/notification-open.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* the mock tenant (utils/mock-data.mjs): a reply in #lobby's topic, and an #alerts message */
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const REPLY = '33333333-3333-4333-8333-333333333333'
const ALERT = '66666666-6666-4666-8666-666666666666'
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

/** What sw.js posts to an open tab on a tap; resolves whether the page answered. */
function handOver(p, msgId, url) {
  return p.evaluate((msgId, url) => new Promise((resolve) => {
    const ch = new MessageChannel()
    const t = setTimeout(() => { ch.port1.close(); resolve(false) }, 1500)
    ch.port1.onmessage = () => { clearTimeout(t); ch.port1.close(); resolve(true) }
    navigator.serviceWorker.dispatchEvent(new MessageEvent('message', {
      data: { type: 'spool:notification-open', msgId, url },
      ports: [ch.port2],
    }))
  }), msgId, url)
}

/** the message marked and inside its own scroller's visible band */
async function markedInView(p, id) {
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

/** wait until the app has left `from` and the /m/ page has replaced itself */
async function settle(p, from) {
  await p.waitForFunction((from) => location.pathname !== from && (!location.pathname.includes('/m/') || document.querySelector('[data-testid=open-msg-notice]')),
    { timeout: NAV_TIMEOUT, polling: 50 }, from).catch(() => null)
  return new URL(p.url())
}

/** the app is up when its listener answers a hand-over that names the page it is on */
async function appReady(p) {
  for (let i = 0; i < 60; i++) {
    if (await handOver(p, '', await p.evaluate(() => location.pathname))) return true
    await new Promise((r) => setTimeout(r, 500))
  }
  return false
}

const server = await startServer()
const browser = await launch()
const errors = []
try {
  for (const vp of WIDTHS) {
    const W = vp.width
    console.log(`-- ${W} px`)
    const p = await browser.newPage()
    await p.setViewport(vp)
    p.on('pageerror', (e) => errors.push(String(e && e.message)))
    await p.evaluateOnNewDocument(() => {
      try { localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* private mode */ }
    })

    /* "where I was": the Issues tab, nowhere near the message */
    await p.goto(server.base + '/issues', { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    const hasSw = await p.evaluate(() => 'serviceWorker' in navigator)
    ok(`${W} 0 the browser has navigator.serviceWorker`, hasSw)
    ok(`${W} 0b the app's listener is up`, await appReady(p))
    const from = new URL(p.url()).pathname

    /* 1: a reply -> its channel, its thread open, the reply marked */
    const answered = await handOver(p, REPLY, '/m/' + REPLY)
    ok(`${W} 1 the page answers the worker's hand-over (no reload)`, answered)
    let url = await settle(p, from)
    ok(`${W} 2 the reply's channel with its thread: /channel/lobby?topic=<thread>#<reply>`,
      url.pathname.endsWith('/channel/lobby') && url.searchParams.get('topic') === TOPIC && url.hash === '#' + REPLY, url.href)
    let m = await markedInView(p, REPLY)
    ok(`${W} 3 the reply is marked open-focus and in view`, m.marked && m.inView, m)

    /* 4: another tap while a channel is open -> the other channel */
    await handOver(p, ALERT, '/m/' + ALERT)
    url = await settle(p, url.pathname)
    ok(`${W} 4 an #alerts alert opens /channel/alerts`, url.pathname.endsWith('/channel/alerts'), url.href)
    m = await markedInView(p, ALERT)
    ok(`${W} 5 the #alerts message is marked`, m.marked, m)

    /* 6: a foreign url is never followed */
    const before = p.url()
    await handOver(p, 'x', 'https://evil.example.com/x')
    await handOver(p, 'x', '//evil.example.com/x')
    await new Promise((r) => setTimeout(r, 500))
    ok(`${W} 6 a foreign url in the hand-over goes nowhere`, p.url() === before, p.url())
    /* 8: a tap the tab's own new-version reload cut short opens on boot */
    await p.goto(server.base + '/issues', { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    await appReady(p)
    await p.evaluate((url) => sessionStorage.setItem('spool.notify-open', JSON.stringify({ url, at: Date.now() })), '/m/' + REPLY)
    await p.reload({ waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    url = await settle(p, '/issues')
    m = await markedInView(p, REPLY)
    ok(`${W} 8 a tap cut short by a reload opens after it`, url.hash === '#' + REPLY && m.marked, { url: url.href, m })

    /* 9..: the REAL worker (a built bundle registers public/sw.js; nuxi dev does not) */
    if (W === WIDTHS[0].width) {
      await p.goto(server.base + '/issues', { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      const controlled = await p.waitForFunction(() => Boolean(navigator.serviceWorker.controller), { timeout: 15000 }).then(() => true).catch(() => false)
      if (!controlled) {
        console.log('  SKIP 9..11 real worker: no service worker in this run (nuxi dev); BASE_URL=<generated bundle> runs them')
      } else {
        await appReady(p)
        const target = await browser.waitForTarget((t) => t.type() === 'service_worker' && t.url().endsWith('/sw.js'), { timeout: 15000 })
        const sw = await target.worker()
        /* the worker's own notificationclick listener, fired inside the worker (headless Chrome shows no tray to tap) */
        const tap = (data, tag) => sw.evaluate((data, tag) => {
          const e = new Event('notificationclick')
          Object.defineProperty(e, 'notification', { value: { data, tag, close() {} } })
          e.waitUntil = (job) => job
          self.dispatchEvent(e)
        }, data, tag)
        const tabsBefore = (await browser.pages()).length
        let from = new URL(p.url()).pathname
        await tap({ msgId: REPLY, url: '/m/' + REPLY }, 'ch:lobby')
        url = await settle(p, from)
        m = await markedInView(p, REPLY)
        ok(`${W} 9 real sw.js: a tap opens the reply in its thread, marked`, url.searchParams.get('topic') === TOPIC && url.hash === '#' + REPLY && m.marked, { url: url.href, m })
        from = url.pathname
        await tap(null, 'ch:alerts')
        url = await settle(p, from)
        ok(`${W} 10 real sw.js: an alert with no target (an older page) opens its feed from the tag`, url.pathname.endsWith('/channel/alerts'), url.href)
        const tabsAfter = (await browser.pages()).length
        ok(`${W} 11 real sw.js: the open tab is used, no new window`, tabsAfter === tabsBefore, { tabsBefore, tabsAfter })
      }
    }
    await p.close()
  }
  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('7 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`notification-open: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
