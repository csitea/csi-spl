// 080 T006 (FR-009, AC8; mobile §3.3): send when the network is back. A
// member on a train presses Enter with no signal: before T006 the row went
// away after the ack timeout and Retry posted under a NEW msg_id.
//
//   mock tenant, signed in as HUM-1 (spool.mock.session), 1440x900:
//     AC8 CDP Network.emulateNetworkConditions offline, send a line on
//         #feedback -> its row stays, marked "waiting for network"
//         (data-waiting=network), and the box is empty
//     AC8 back online -> the row is sent: exactly ONE card with that text,
//         no longer waiting, under the msg_id the waiting row had
//     CONTROL: before T006 the offline send was stored at once by the mock
//         (no waiting mark: the first check fails).
//
// Run:
//   pnpm run test:e2e offline-send-queue
//   BASE_URL=<generated bundle> pnpm run test:e2e offline-send-queue   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per step there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
const HUM = 'HUM-1'
const BOX = 'form.composer.omnibox--global textarea'
const TEXT = `q offline ${Date.now().toString(36)}`

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

async function settle(p) {
  await p.waitForSelector(BOX, { timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)
}

/* every card in the feed whose body is our line */
const cards = (p, text) => p.evaluate((t) => [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')]
  .filter((el) => (el.querySelector('.msg-body')?.textContent || '').trim() === t)
  .map((el) => ({
    msgId: el.getAttribute('data-msg-id'),
    waiting: el.querySelector('[data-test=msg-sending]')?.getAttribute('data-waiting') || '',
    label: (el.querySelector('[data-test=msg-sending]')?.textContent || '').trim(),
  })), text)

async function network(cdp, offline) {
  await cdp.send('Network.emulateNetworkConditions', { offline, latency: 0, downloadThroughput: -1, uploadThroughput: -1 })
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(server.base + '/channel/feedback', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate((hum) => {
    localStorage.removeItem('spool.drafts')
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum, name: 'Admin', email: 'admin@example.com', t: 'mock' }))
  }, HUM)
  await p.reload({ waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await settle(p)
  const cdp = await p.createCDPSession()
  await cdp.send('Network.enable')

  /* AC8: offline -> the row waits */
  await network(cdp, true)
  await p.waitForFunction(() => navigator.onLine === false, { timeout: 10000 })
  await p.focus(BOX)
  await p.type(BOX, TEXT)
  await p.click('form.composer.omnibox--global [data-testid=send]')
  await p.waitForFunction((t) => [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')]
    .some((el) => (el.querySelector('.msg-body')?.textContent || '').trim() === t), { timeout: 10000 }, TEXT).catch(() => null)
  await sleep(500)
  const offline = await cards(p, TEXT)
  const boxAfter = await p.evaluate((sel) => { const el = document.querySelector(sel); return el ? el.value : null }, BOX)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'offline-send-queue-waiting.png') })
  ok('AC8 offline: the sent line stays as one row marked "waiting for network"',
    offline.length === 1 && offline[0].waiting === 'network' && offline[0].label.length > 0, { offline })
  ok('AC8 offline: the box is empty (the line is held, not handed back)', boxAfter === '', { boxAfter })
  await sleep(1500)
  const stillOne = await cards(p, TEXT)
  ok('AC8 offline: nothing is sent while offline', stillOne.length === 1 && stillOne[0].waiting === 'network', { stillOne })

  /* AC8: online -> exactly one message, same msg_id */
  await network(cdp, false)
  await p.waitForFunction((t) => {
    const hit = [...document.querySelectorAll('.spool-main article.msg[data-msg-id]')]
      .filter((el) => (el.querySelector('.msg-body')?.textContent || '').trim() === t)
    return hit.length >= 1 && hit.every((el) => !el.querySelector('[data-test=msg-sending]'))
  }, { timeout: 15000 }, TEXT).catch(() => null)
  await sleep(800)
  const online = await cards(p, TEXT)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, 'offline-send-queue-sent.png') })
  ok('AC8 online: exactly one message, sent under the same msg_id, no longer waiting',
    online.length === 1 && online[0].waiting === '' && online[0].msgId === (offline[0] && offline[0].msgId), { offline, online })
  ok('no page error', errors.length === 0, errors)
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
