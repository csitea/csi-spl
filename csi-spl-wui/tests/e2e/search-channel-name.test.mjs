// t1 2b15a748: a member typed `lobby`, `/csi-fina` into the Omnibox to find a
// channel; each one was POSTED as a message, and search never named a channel
// written as `#lobby`. A one-word `#lobby` or `/lobby` that names a visible
// channel now asks "Open #name?" (option A) instead of searching or posting.
// `/search lobby` still lists the channel, and that hit still opens it. A
// line that only mentions a channel is still a post.
//
//   node tests/e2e/search-channel-name.test.mjs          (mock tenant, nuxi dev)
//   BASE_URL=<generated bundle> node tests/e2e/search-channel-name.test.mjs
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { loadPuppeteer } from './lib/proof.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const BOX = '[data-test=top-bar-omnibox] textarea'
const ASK = '[data-test=composer-open-channel]'
const OPEN = '[data-test=composer-open-channel-yes]'
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

/** The Omnibox line, typed on page `from`, then Enter. `go` clicks the search
 *  GO button: Enter on `/search lobby` completes `in:#lobby` instead. */
async function enter(p, base, from, line, submit = 'enter') {
  await p.goto(base + from, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-move-id="lobby"]', { timeout: NAV_TIMEOUT })
  await sleep(300)
  await p.click(BOX)
  await p.type(BOX, line)
  await p.$eval(BOX, (el, line) => { if (el.value !== line) throw new Error('box holds ' + el.value) }, line)
  if (submit === 'go') await p.$eval('[data-test=omnibox-search]', (el) => el.click())
  else await p.keyboard.press('Enter')
  await sleep(600)
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
  const asked = Boolean(await p.$(ASK))
  ok('1 `#lobby` asks to open the channel, it is not posted or searched', asked && !query(p) && !(await posted(p, '#lobby')), { url: p.url() })
  if (asked) {
    await p.click(OPEN)
    await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  }
  ok('2 Open from `#lobby` lands in the channel', path(p).endsWith('/channel/lobby'), { url: p.url() })

  await enter(p, server.base, '/channel/alerts', '/search lobby', 'go')
  const hit = await p.waitForSelector(CHANNEL_HIT, { visible: true, timeout: 15000 }).then(() => true).catch(() => false)
  const text = hit ? await p.$eval(CHANNEL_HIT, (el) => el.textContent || '') : ''
  ok('3 `/search lobby` lists the channel #lobby as a hit', query(p) === 'lobby' && hit && /lobby/.test(text), { url: p.url(), text })
  if (hit) {
    await p.click(CHANNEL_HIT)
    await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  }
  ok('4 the channel hit opens the channel', path(p).endsWith('/channel/lobby'), { url: p.url() })

  await enter(p, server.base, '/channel/alerts', '/lobby')
  ok('5 `/lobby` asks to open the channel, it is not a search', Boolean(await p.$(ASK)) && !query(p), { url: p.url() })

  /* CONTROL: a line that names a channel inside a sentence is a message */
  const line = 'see #lobby ' + Date.now().toString(36)
  await enter(p, server.base, '/channel/alerts', line)
  ok('6 CONTROL: `see #lobby …` is still posted, no search', path(p).endsWith('/channel/alerts') && !query(p) && await posted(p, line) && !(await p.$(ASK)), { url: p.url() })

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('7 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`search-channel-name: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
