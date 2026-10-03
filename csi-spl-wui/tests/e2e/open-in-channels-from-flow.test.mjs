// HUM-10 (topic c15b557e, 13:19Z): "Open in channels view" on a card the
// reader reached from the Flow lands fully in Channels. The owner: "if am
// browsing the flow, I would expect that jump to channel view, will change
// the first left panel from flow to channels, the correct channel will be
// selected, the correct topic and the correct reply msg selected".
//
// Against the mock bundle, at 1440 and 390 px: the Flow tab, the #lobby reply
// 5555... opened from its entry, then its card menu "Open in channels view".
// Four checks after the jump: (1) the left panel is Channels, not Flow;
// (2) #lobby is the selected channel row; (3) its topic bbbb... is open, the
// topic card selected; (4) the reply is selected (focused) in the thread and
// in view. CONTROL: before the jump the left panel still shows the Flow.
//
//   pnpm run test:e2e open-in-channels-from-flow
//   BASE_URL=<generated bundle> pnpm run test:e2e open-in-channels-from-flow
//   SHOT_DIR=/tmp/shots ...                         (keep the screenshots)
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* the mock tenant (utils/mock-data.mjs): a reply in #lobby, its topic and the topic's card */
const REPLY = '55555555-5555-4555-8555-555555555555'
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const TOPIC_CARD = '22222222-2222-4222-8222-222222222222'
const CHANNEL = 'lobby'
const SIZES = [{ width: 1440, height: 900 }, { width: 390, height: 844 }]
const LIST = '[data-testid=sidebar-panel-flow] [data-testid=left-list][data-mode=flow]'
const ENTRY = `${LIST} [data-testid=left-entry][data-msg-id="${REPLY}"]`
const THREAD_REPLY = `aside.live-pane article.msg[data-msg-id="${REPLY}"]`

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

/** The four things the reader sees, plus the phone level. */
function facts(p) {
  return p.evaluate(({ reply, topic, topicCard, channel }) => {
    const tab = (id) => document.querySelector(`[data-testid=sidebar-tab-${id}]`)?.getAttribute('aria-selected')
    const row = document.querySelector('[data-testid=sidebar-panel-channels] .nav-item.active')
    const card = document.querySelector(`.spool-main article.msg[data-msg-id="${topicCard}"]`)
    const r = document.querySelector(`aside.live-pane article.msg[data-msg-id="${reply}"]`)
    const sc = r && r.closest('.feed-body')
    const rr = r && r.getBoundingClientRect()
    const sr = sc && sc.getBoundingClientRect()
    const u = new URL(location.href)
    return {
      level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || null,
      flowTab: tab('flow'),
      channelsTab: tab('channels'),
      channelsPanel: Boolean(document.querySelector('[data-testid=sidebar-panel-channels]')),
      activeChannel: row ? row.getAttribute('data-key') : null,
      path: decodeURIComponent(u.pathname),
      topic: u.searchParams.get('topic'),
      hash: u.hash,
      topicCardSelected: Boolean(card && card.getAttribute('data-selected') === 'true'),
      pane: Boolean(document.querySelector('aside.live-pane')),
      replyFound: Boolean(r),
      replyFocused: Boolean(r && (document.activeElement === r || r.contains(document.activeElement))),
      replyInView: Boolean(rr && sr && rr.height > 0 && rr.top >= sr.top - 1 && rr.top < sr.bottom),
      onChannel: decodeURIComponent(u.pathname).endsWith('/channel/' + channel),
      topicOk: u.searchParams.get('topic') === topic,
    }
  }, { reply: REPLY, topic: TOPIC, topicCard: TOPIC_CARD, channel: CHANNEL })
}

const server = await startServer()
const browser = await launch()
try {
  for (const size of SIZES) {
    const tag = `${size.width}`
    const phone = size.width <= 820
    const p = await browser.newPage()
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e && e.message).slice(0, 200)))
    await p.evaluateOnNewDocument(() => { try { localStorage.setItem('spool.flow-scope', 'all'); localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'hum-1@example.com', name: 'FirstName LastName', t: 't1' })) } catch { /* about:blank */ } })
    await setPageViewport(p, size)
    /* warm the dev server's dynamic imports (a cold nuxi dev drops the first one) */
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.goto(server.base + '/', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, size)

    /* browsing the Flow: the reply's entry opens it in its thread */
    await p.waitForSelector('[data-testid=sidebar-tab-flow]', { visible: true, timeout: NAV_TIMEOUT })
    await p.click('[data-testid=sidebar-tab-flow]')
    await p.waitForSelector(ENTRY, { visible: true, timeout: NAV_TIMEOUT })
    await p.click(ENTRY)
    await p.waitForFunction((c) => location.pathname.endsWith('/channel/' + c), { timeout: NAV_TIMEOUT }, CHANNEL)
    await p.waitForSelector(THREAD_REPLY, { visible: true, timeout: NAV_TIMEOUT })
    await sleep(500)
    let f = await facts(p)
    ok(`${tag}: CONTROL - opened from the Flow, the left panel still shows the Flow`, f.flowTab === 'true' && f.channelsTab !== 'true', f)

    /* the card menu on the reply: Open in channels view */
    await p.click(THREAD_REPLY + ' .msg-body', { button: 'right' })
    await p.waitForSelector('[data-testid=msg-menu]', { visible: true, timeout: 5000 })
    const label = await p.$eval('[data-testid=msg-menu-parent]', (el) => el.textContent.trim()).catch(() => '')
    ok(`${tag}: the reply's menu reads "Open in channels view"`, label === 'Open in channels view', { label })
    await p.click('[data-testid=msg-menu-parent]')
    await p.waitForFunction(() => document.querySelector('[data-testid=sidebar-tab-channels]')?.getAttribute('aria-selected') === 'true', { timeout: 10000 }).catch(() => null)
    await sleep(1200)
    f = await facts(p)

    ok(`${tag}: 1 the first left panel switched from Flow to Channels`, f.channelsTab === 'true' && f.flowTab !== 'true' && f.channelsPanel, f)
    ok(`${tag}: 2 #${CHANNEL} is the selected channel`, f.onChannel && f.activeChannel === CHANNEL, { path: f.path, activeChannel: f.activeChannel })
    ok(`${tag}: 3 its topic is open, the topic card selected`, f.topicOk && f.pane && (phone || f.topicCardSelected), { topic: f.topic, pane: f.pane, topicCardSelected: f.topicCardSelected, level: f.level })
    ok(`${tag}: 4 the reply is selected and in view`, f.replyFound && f.replyFocused && f.replyInView && f.hash === '#' + REPLY, { replyFocused: f.replyFocused, replyInView: f.replyInView, hash: f.hash })
    if (phone) ok(`${tag}: phone - the thread is the screen`, f.level === '3', f.level)
    if (phone) {
      /* phone: Back to the first panel shows Channels with #lobby selected */
      for (let i = 0; i < 3 && (await facts(p)).level !== '1'; i++) {
        await p.goBack({ timeout: NAV_TIMEOUT }).catch(() => {})
        await sleep(400)
      }
      f = await facts(p)
      const shown = await p.$eval('[data-testid=sidebar-panel-channels]', (el) => el.offsetParent !== null).catch(() => false)
      ok(`${tag}: phone - Back to the first panel shows Channels, #${CHANNEL} selected`, f.level === '1' && shown && f.channelsTab === 'true' && f.activeChannel === CHANNEL, { level: f.level, shown, channelsTab: f.channelsTab, activeChannel: f.activeChannel })
    }

    if (process.env.SHOT_DIR) {
      mkdirSync(process.env.SHOT_DIR, { recursive: true })
      await p.screenshot({ path: join(process.env.SHOT_DIR, `open-in-channels-from-flow-${tag}.png`) })
    }
    const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
    ok(`${tag}: no page errors`, mine.length === 0, mine)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log(failed.map((r) => r.name).join('\n'))
  process.exit(1)
}
