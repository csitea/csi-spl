// perf round 6 row 06 (SPL-2580, Refs SPL-2051): the cold first batch of a
// feed renders statically, a later live row still animates in.
//
// WHY: LiveFeed.vue wraps its rows in a <TransitionGroup>, so every row of
// the first non-empty batch used to run an enter transition (an
// `*-enter-active` class, a transform and an opacity fade per row) during the
// first paint. The feed now turns the group's CSS on (`:css="transitionsReady"`)
// only once its rows have settled for 400 ms: #lobby lands in two batches (the
// room task's row, then the channel's topic cards ~60 ms later in the mock),
// so the first nextTick that sees rows would still animate the second one.
//
// Measured in the page, not asserted: every `classList.add` of a
// `*-enter-active` token is counted (Vue's addTransitionClass adds one per
// entering row). The seeded tenant of the perf runner (perf-fixture.mjs, row
// 12) puts 15 extra rows in #lobby and 15 in #alerts.
//   cold load   -> 0 additions (red control: one per row before the gate)
//   2 live rows -> 2 additions (the gate opened; live rows still animate)
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { PERF_FIXTURE, perfStorage } from '../../src/node/test/perf-fixture.mjs'

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox'] })
    } catch { /* try next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* runs before the page's own scripts: the fixture and the counter */
function pageInit(storage) {
  try { for (const [k, v] of Object.entries(storage)) localStorage.setItem(k, v) } catch { /* opaque origin */ }
  window.__enterActive = 0
  const add = DOMTokenList.prototype.add
  DOMTokenList.prototype.add = function (...tokens) {
    for (const t of tokens) if (/-enter-active$/.test(t)) window.__enterActive++
    return add.apply(this, tokens)
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const fails = []
const ok = (name, pass, ev) => { console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name} ${JSON.stringify(ev)}`); if (!pass) fails.push(name) }
const perChannel = PERF_FIXTURE.messages / 2
const srv = await startServer()
const browser = await launch()
try {
  for (const path of ['/lobby', '/channel/alerts']) {
    const p = await browser.newPage()
    await p.setViewport({ width: 1280, height: 800 })
    await p.evaluateOnNewDocument(pageInit, perfStorage())
    await p.goto(`${srv.base}${path}`, { waitUntil: 'networkidle2' })
    await p.waitForFunction((n) => document.querySelectorAll('.live-rows > article.msg').length >= n, { timeout: 60000 }, perChannel)
    await sleep(800)
    const cold = await p.evaluate(() => ({ rows: document.querySelectorAll('.live-rows > article.msg').length, enterActive: window.__enterActive }))
    ok(`${path}: the cold batch of ${cold.rows} rows renders with no enter transition`, cold.rows >= perChannel && cold.enterActive === 0, cold)
    if (path === '/lobby') {
      /* a live frame: two new topics through the page's own Pinia store (as
         scroll-anchor.test.mjs); #lobby shows one card per topic, so each
         row is a copy of a lobby row with its own msg_id and task_id */
      const live = await p.evaluate(async () => {
        window.__enterActive = 0
        const pinia = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia
        const s = pinia._s.get('live-main')
        const like = s.messages.find((m) => m.channel === 'lobby')
        const rows = [0, 1].map((i) => {
          const ts = new Date(Date.now() + i * 1000).toISOString()
          return { ...like, msg_id: `live-${i}-${Date.now()}`, task_id: `live-topic-${i}-${Date.now()}`, ts, received_at: ts, body: `live ${i}` }
        })
        const before = document.querySelectorAll('.live-rows > article.msg').length
        s.messages = [...s.messages, ...rows]
        await new Promise((r) => setTimeout(r, 600))
        return { added: document.querySelectorAll('.live-rows > article.msg').length - before, enterActive: window.__enterActive }
      })
      ok(`${path}: 2 live rows still animate in`, live.added === 2 && live.enterActive === 2, live)
    }
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}
console.log(fails.length ? `\n${fails.length} failed` : '\nall live-feed-transition-gate checks passed')
process.exit(fails.length ? 1 : 0)
