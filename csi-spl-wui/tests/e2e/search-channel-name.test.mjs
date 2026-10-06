// t1 2b15a748: a member typed `lobby`, `/csi-fina` into the Omnibox to find a
// channel; each one was POSTED as a message, and search never named a channel
// written as `#lobby`. In a real browser on the mock tenant: a one-word
// `#lobby` or `/lobby` line in the Omnibox runs a search instead of a post,
// the search lists the channel as a hit, and that hit opens the channel. A
// line that only mentions a channel is still a post.
//
//   node tests/e2e/search-channel-name.test.mjs          (mock tenant, nuxi dev)
//   BASE_URL=<generated bundle> node tests/e2e/search-channel-name.test.mjs
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { loadPuppeteer } from './lib/proof.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const BOX = '[data-test=top-bar-omnibox] textarea'
const CHANNEL_HIT = '[data-testid=sidebar-panel-search] [data-testid=left-list][data-mode=search] [data-testid=left-entry][data-type=channels]'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const query = (p) => new URL(p.url()).searchParams.get('q')
const path = (p) => new URL(p.url()).pathname
const posted = (p, body) => p.$$eval('article.msg', (els, body) => els.some((e) => (e.textContent || '').includes(body)), body)

/** The Omnibox line, typed and sent with Enter, on page `from`. */
async function enter(p, base, from, line) {
  await p.goto(base + from, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { visible: true, timeout: NAV_TIMEOUT })
  await sleep(500) // hydration: a key before it is lost
  await p.click(BOX)
  await p.type(BOX, line)
  await p.$eval(BOX, (el, line) => { if (el.value !== line) throw new Error('box holds ' + el.value) }, line)
  await p.keyboard.press('Enter')
  await sleep(1500)
}

const server = await startServer()
const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  defaultViewport: { width: 1440, height: 900 },
  args: CHROME_LAUNCH_ARGS,
})
try {
  const errors = []
  const p = await browser.newPage()
  p.on('pageerror', (e) => errors.push(String(e && e.message)))

  await enter(p, server.base, '/channel/alerts', '#lobby')
  ok('1 `#lobby` alone in the Omnibox runs a search, it is not posted', query(p) === '#lobby' && !(await posted(p, '#lobby')), { url: p.url() })
  const hit = await p.waitForSelector(CHANNEL_HIT, { visible: true, timeout: 15000 }).then(() => true).catch(() => false)
  const text = hit ? await p.$eval(CHANNEL_HIT, (el) => el.textContent || '') : ''
  ok('2 the search lists the channel #lobby as a hit', hit && /lobby/.test(text), { text })
  if (hit) {
    await p.click(CHANNEL_HIT)
    await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  }
  ok('3 the channel hit opens the channel', path(p).endsWith('/channel/lobby'), { url: p.url() })

  await enter(p, server.base, '/channel/alerts', '/lobby')
  const hit2 = await p.waitForSelector(CHANNEL_HIT, { visible: true, timeout: 15000 }).then(() => true).catch(() => false)
  ok('4 `/lobby` (no such command) searches `lobby` and lists the channel', query(p) === 'lobby' && hit2, { url: p.url() })

  /* CONTROL: a line that names a channel inside a sentence is a message */
  const line = 'see #lobby ' + Date.now().toString(36)
  await enter(p, server.base, '/channel/alerts', line)
  ok('5 CONTROL: `see #lobby …` is still posted, no search', path(p).endsWith('/channel/alerts') && !query(p) && await posted(p, line), { url: p.url() })

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('6 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`search-channel-name: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
