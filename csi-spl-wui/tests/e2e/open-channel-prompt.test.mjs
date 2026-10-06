// t1 2b15a748 option A: a one-word line that names a visible channel asks
// "Open #name?" before it posts. Open lands in that channel and clears the
// box. Post anyway sends the text. A sentence and an unknown word post with
// no choice. Esc keeps the text. The buttons are tap targets on a phone.
//
//   node tests/e2e/open-channel-prompt.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/open-channel-prompt.test.mjs
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport } from './lib/viewport.mjs'
import { loadPuppeteer } from './lib/proof.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const BOX = '[data-test=top-bar-omnibox] textarea'
const ASK = '[data-test=composer-open-channel]'
const OPEN = '[data-test=composer-open-channel-yes]'
const POST = '[data-test=composer-open-channel-post]'
const PHONE = { width: 390, height: 844 }

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const path = (p) => new URL(p.url()).pathname
const posted = (p, body) => p.$$eval('article.msg', (els, body) => els.some((e) => (e.textContent || '').includes(body)), body)

async function gotoAlerts(p, base) {
  await p.goto(base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(BOX, { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-move-id="lobby"]', { timeout: NAV_TIMEOUT })
  await sleep(300)
}

async function setLine(p, line) {
  await p.click(BOX)
  await p.keyboard.down('Control')
  await p.keyboard.press('KeyA')
  await p.keyboard.up('Control')
  await p.keyboard.press('Backspace')
  if (line) await p.type(BOX, line)
  const got = await p.$eval(BOX, (el) => el.value)
  if (got !== line) throw new Error('box holds ' + JSON.stringify(got))
}

async function enter(p, line) {
  await setLine(p, line)
  await p.keyboard.press('Enter')
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
  await gotoAlerts(p, server.base)

  await enter(p, 'lobby')
  const ask = await p.waitForSelector(ASK, { visible: true, timeout: 8000 }).then(() => true).catch(() => false)
  const label = ask ? await p.$eval(OPEN, (el) => el.textContent || '') : ''
  ok('1 lobby asks Open #lobby and does not post', ask && label.includes('#lobby') && path(p).endsWith('/channel/alerts') && !(await posted(p, 'lobby')), { url: p.url(), label })
  if (ask) {
    await p.click(OPEN)
    await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  }
  const title = await p.$eval('h2.feed-header__title', (el) => el.textContent || '').catch(() => '')
  const cleared = await p.$eval(BOX, (el) => el.value).catch(() => 'missing')
  ok('2 Open lands in #lobby and clears the box', path(p).endsWith('/channel/lobby') && title.includes('#lobby') && cleared === '', { url: p.url(), title, cleared })

  await gotoAlerts(p, server.base)
  await enter(p, 'lobby')
  await p.waitForSelector(POST, { visible: true, timeout: 8000 })
  await p.click(POST)
  await p.waitForFunction((body) => [...document.querySelectorAll('article.msg')].some((e) => (e.textContent || '').includes(body)), { timeout: 8000 }, 'lobby').catch(() => null)
  ok('3 Post anyway posts lobby and stays on the page', path(p).endsWith('/channel/alerts') && await posted(p, 'lobby') && !(await p.$(ASK)), { url: p.url() })

  await setLine(p, 'hello world')
  await p.keyboard.press('Enter')
  await p.waitForFunction((body) => [...document.querySelectorAll('article.msg')].some((e) => (e.textContent || '').includes(body)), { timeout: 8000 }, 'hello world').catch(() => null)
  ok('4 hello world posts with no choice', await posted(p, 'hello world') && !(await p.$(ASK)), { url: p.url() })

  await setLine(p, 'nosuchchannel')
  await p.keyboard.press('Enter')
  await p.waitForFunction((body) => [...document.querySelectorAll('article.msg')].some((e) => (e.textContent || '').includes(body)), { timeout: 8000 }, 'nosuchchannel').catch(() => null)
  ok('5 nosuchchannel posts with no choice', await posted(p, 'nosuchchannel') && !(await p.$(ASK)), { url: p.url() })

  await setLine(p, 'lobby')
  await p.keyboard.press('Enter')
  await p.waitForSelector(ASK, { visible: true, timeout: 8000 })
  await p.keyboard.type('x')
  await sleep(200)
  ok('6 typing more dismisses the choice and keeps the text', !(await p.$(ASK)) && (await p.$eval(BOX, (el) => el.value)) === 'lobbyx')

  await setLine(p, 'lobby')
  await p.keyboard.press('Enter')
  await p.waitForSelector(ASK, { visible: true, timeout: 8000 })
  await p.keyboard.press('Tab')
  const focused = await p.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-test'))
  await p.keyboard.press('Escape')
  await sleep(150)
  ok('7 Tab reaches Open and Esc keeps the text', focused === 'composer-open-channel-yes' && !(await p.$(ASK)) && (await p.$eval(BOX, (el) => el.value)) === 'lobby', { focused })

  await applyViewport(p, PHONE)
  await p.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, PHONE)
  await p.waitForSelector(BOX, { visible: true, timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-move-id="lobby"]', { timeout: NAV_TIMEOUT })
  await sleep(300)
  await setLine(p, 'lobby')
  await p.keyboard.press('Enter')
  const phoneAsk = await p.waitForSelector(ASK, { visible: true, timeout: 8000 }).then(() => true).catch(() => false)
  const taps = phoneAsk ? await p.$$eval(ASK + ' button', (els) => els.map((el) => {
    const r = el.getBoundingClientRect()
    return { h: Math.round(r.height), w: Math.round(r.width), top: Math.round(r.top), bottom: Math.round(r.bottom) }
  })) : []
  const ih = await p.evaluate(() => window.innerHeight)
  const tappable = taps.length === 2 && taps.every((b) => b.h >= 44 && b.w >= 44 && b.top >= 0 && b.bottom <= ih + 1)
  ok('8 phone buttons are on screen and at least 44px', phoneAsk && tappable, { taps, ih })
  if (phoneAsk) {
    await p.keyboard.press('Enter')
    await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  }
  ok('9 phone Enter opens #lobby', path(p).endsWith('/channel/lobby'), { url: p.url() })

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('10 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`open-channel-prompt: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
