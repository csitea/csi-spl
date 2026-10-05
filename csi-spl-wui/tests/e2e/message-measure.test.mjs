// Spec 078 AC8 (FR-008, Q4): at 1920 a message body is capped at the
// readable measure, 100ch of the body's own font, and the card's actions
// (the header's menu at its end) follow the capped card instead of sitting
// at the far pane edge. Runs against the lde mock (no hub).
//
// Desktop 1920x1080 on /channel/lobby, with three cards seeded into the
// channel store (the mock's own bodies are all under 60 characters, so they
// could never prove the cap binds):
//   1  a long prose card: its body wraps at the measure (width within 2 % of
//      100ch, so the cap binds) and never exceeds it
//   2  every visible body is <= the measure
//   3  the long card's menu button ends inside the capped card, and the card
//      ends left of the feed's right edge (the actions followed the card)
//   4  a short card is capped the same: the card width is the measure's, not
//      its text's, so cards still line up
//   5  a code block keeps its own wrapping: no sideways scroll on the page
//
// Run:
//   pnpm test:e2e message-measure
//   BASE_URL=<generated bundle> pnpm test:e2e message-measure   # what CI does
//   OUT=<dir> ... also writes a screenshot
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const MEASURE_CH = 100
const LONG = 'The thread gets the width, but a line of prose should still end where the eye can find the next one. '.repeat(6).trim()
const CODE = '```\n' + 'x'.repeat(400) + '\n```'

if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
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

/** Three opening cards on lobby: long prose, a short line, a code block. */
/* The mock feed re-reads every 4s and replaces the list, which drops
   rows added in the page. The seeded cards have to stay for the measure,
   so later re-reads do nothing. The open's own read has already landed. */
const holdFeed = (p) => p.evaluate(() => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  const channel = pinia._s.get('channel')
  channel.refresh = async () => {}
})

const seed = (p, bodies) => p.evaluate((bodies) => {
  const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
  const channel = pinia._s.get('channel')
  const rows = bodies.map((body, i) => {
    const ts = new Date(Date.now() - (bodies.length - i) * 1000).toISOString()
    const task = `078a0806-0000-4000-8000-00000000000${i}`
    return {
      v: 1, msg_id: `m078-${i}`, task_id: task, parent_task_id: null, ts, received_at: ts,
      from: 'HUM-7', from_box: 'box-wui', to: '@channel', kind: 'note', channel: 'lobby', body, files: [],
    }
  })
  channel.messages = [...(channel.messages || []), ...rows]
  return true
}, bodies)

/** Every card's geometry, plus 100ch in the body's own font. */
const measure = (p) => p.evaluate((n) => {
  const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect(); return { l: Math.round(b.left), r: Math.round(b.right), w: Math.round(b.width) } }
  const cards = [...document.querySelectorAll('.feed-body .msg')].filter((c) => c.getClientRects().length)
  const out = cards.map((c) => {
    const body = c.querySelector('.msg-body')
    let ch = null
    if (body) {
      const probe = document.createElement('span')
      probe.style.cssText = `position:absolute;visibility:hidden;white-space:pre;width:${n}ch`
      body.appendChild(probe)
      ch = probe.getBoundingClientRect().width
      probe.remove()
    }
    const cs = body && getComputedStyle(body)
    const content = body ? body.getBoundingClientRect().width - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight) : null
    return {
      id: c.getAttribute('data-msg-id'),
      card: r(c),
      body: body && { ...r(body), content: Math.round(content) },
      measure: ch && Math.round(ch),
      menu: r(c.querySelector('[data-testid=msg-menu-btn]')),
    }
  })
  return {
    cards: out,
    feed: r(document.querySelector('.feed-body')),
    xScroll: document.documentElement.scrollWidth > document.documentElement.clientWidth,
  }
}, MEASURE_CH)

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.setViewport({ width: 1920, height: 1080 })
  await p.goto(`${srv.base}/channel/lobby`, { waitUntil: 'networkidle2' })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector('.feed-body .msg', { timeout: NAV_TIMEOUT })
  await holdFeed(p)
  await sleep(1200)
  await seed(p, [LONG, 'short line', CODE])
  await p.waitForFunction(() => document.querySelector('[data-msg-id=m078-2]'), { timeout: 8000 }).catch(() => {})
  await sleep(600)
  if (OUT) await p.screenshot({ path: `${OUT}/1920-lobby.png` })

  const m = await measure(p)
  const long = m.cards.find((c) => c.id === 'm078-0')
  const short = m.cards.find((c) => c.id === 'm078-1')
  ok('0 the seeded cards render', Boolean(long && short && m.cards.find((c) => c.id === 'm078-2')), m.cards.map((c) => c.id))

  ok('1 the long body wraps at the measure (within 2 %), so the cap binds',
    Boolean(long?.body && long.measure && long.body.content <= long.measure + 1 && long.body.content >= long.measure * 0.98),
    long && { content: long.body?.content, measure: long.measure, feed: m.feed })

  const over = m.cards.filter((c) => c.body && c.measure && c.body.content > c.measure + 1)
  ok(`2 every visible body (${m.cards.length}) is <= ${MEASURE_CH}ch of its own font`, m.cards.length > 0 && over.length === 0,
    over.map((c) => ({ id: c.id, content: c.body.content, measure: c.measure })))

  ok('3 the long card\'s menu ends inside the capped card, and the card ends well left of the feed edge',
    Boolean(long?.menu && long.menu.r <= long.card.r && long.card.r < m.feed.r - 100),
    long && { menu: long.menu, card: long.card, feed: m.feed })

  ok('4 the short card has the same capped width as the long one',
    Boolean(short && long && Math.abs(short.card.w - long.card.w) <= 1),
    short && long && { short: short.card, long: long.card })

  ok('5 a 400-character code block: no sideways scroll on the page', !m.xScroll)

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nmessage-measure: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
