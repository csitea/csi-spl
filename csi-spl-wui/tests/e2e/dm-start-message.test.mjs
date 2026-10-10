// t1 3eb98913 (owner 2026-10-10: "I should be able to direct msg any type of
// agents - antigravity, claude, mistral, grok" ... "it dos not even have a msg
// button"). His screenshot was /dm/<agy agent>@<box>: online, "No messages yet.", and
// nothing to click - the DM's composer is the Omnibox. Real browser, mock
// tenant, 1440 and 390, one agent of each kind (a-, c-, g-, m-):
//
//   button   an empty DM shows a Message button (data-test=dm-start-message)
//   focus    a click puts the caret in the Omnibox
//   send     a line typed there and sent reaches that agent: the stored row's
//            to / to_box are the peer, and the button is gone
//
//   BASE_URL=<generated bundle> node tests/e2e/dm-start-message.test.mjs
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const PEERS = ['a-101@box-a', 'c-101@box-a', 'g-101@box-a', 'm-101@box-a']
const OMNI = 'form.omnibox--global textarea'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }

const results = []
const check = (name, pass, ev) => {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* in-app, not a reload: a cold /dm/<peer> in the mock lands on / first */
async function openDm(p, peer) {
  await p.evaluate((peer) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/dm/' + encodeURIComponent(peer)), peer)
  await p.waitForFunction((peer) => decodeURIComponent(location.pathname).endsWith('/dm/' + peer), { timeout: NAV }, peer)
  await sleep(800)
}

const startButton = (p) => p.evaluate(() => {
  const b = document.querySelector('[data-test=dm-start-message]')
  if (!b) return null
  const r = b.getBoundingClientRect()
  return { text: b.textContent.trim(), visible: r.width > 0 && r.height > 0 && r.top >= 0 && r.bottom <= innerHeight && r.right <= innerWidth }
})

async function run(browser, base, width) {
  const p = await browser.newPage()
  await p.setViewport({ width, height: width < 600 ? 844 : 900, isMobile: width < 600, hasTouch: width < 600 })
  await p.evaluateOnNewDocument((claims) => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
    try { localStorage.setItem('spool.mock.session', JSON.stringify(claims)) } catch { /* */ }
  }, CLAIMS)
  await p.goto(`${base}/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })
  await sleep(500)

  for (const peer of PEERS) {
    const id = peer.split('@')[0]
    await openDm(p, peer)
    const btn = await startButton(p)
    check(`${width} ${id}: an empty DM shows a Message button, in view`, Boolean(btn && btn.visible && btn.text === 'Message'), btn)
    if (SHOT_DIR) { mkdirSync(SHOT_DIR, { recursive: true }); await p.screenshot({ path: `${SHOT_DIR}/dm-start-${width}-${id}.png` }) }
    if (!btn) continue
    await p.click('[data-test=dm-start-message]')
    await sleep(200)
    const focused = await p.evaluate((sel) => document.activeElement === document.querySelector(sel), OMNI)
    check(`${width} ${id}: Message puts the caret in the Omnibox`, focused)
    const line = `DM probe to ${id} at ${width}`
    await p.keyboard.type(line)
    await p.keyboard.down('Control'); await p.keyboard.press('Enter'); await p.keyboard.up('Control')
    await sleep(800)
    const row = await p.evaluate((body) => {
      const ch = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('channel')
      const m = ch.messages.find((x) => x.body === body)
      return m ? { to: m.to, to_box: m.to_box || '' } : null
    }, line)
    check(`${width} ${id}: the line goes to ${peer}`, Boolean(row && row.to === id && (!row.to_box || row.to_box === 'box-a')), row)
    check(`${width} ${id}: the button is gone once the DM has a line`, (await startButton(p)) === null)
  }

  const errs = (await p.evaluate(() => window.__errs || [])).filter((e) => !/dynamically imported module/.test(e))
  check(`${width}: no window error`, errs.length === 0, { errs })
  await p.close()
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const w of [1440, 390]) await run(browser, server.base, w)
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\ndm-start-message: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
