// specs/058 (CLE-77932, owner 2026-10-02): "I should be able to distinguish
// between those 2 by their name in the ui". An agent is <ID>@<box>; the same id
// on two boxes is two agents. Real browser, mock tenant (src/utils/mock-data.mjs
// seats CLE-07 on box-a AND box-b), 1440 and 390:
//
//   list     the DM list has one row per box, each named with its box
//   dm       each DM opens on its own <ID>@<box> header, and a line sent in one
//            is not in the other (separate histories), its stored row naming
//            that box (to_box)
//   mention  the @ picker offers both, each with its box; picking box-b writes
//            @CLE-07@box-b, and the dispatch it sends names box-b
//
//   node tests/e2e/agent-at-box.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/agent-at-box.test.mjs
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const A = 'CLE-07@box-a'
const B = 'CLE-07@box-b'
const OMNI = 'form.omnibox--global textarea'

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The DM rows' keys and the names they show. */
const dmRows = (p) => p.evaluate(() => [...document.querySelectorAll('#sidebar-panel-dm a.nav-item[data-key]')]
  .map((a) => ({ key: a.getAttribute('data-key'), text: a.querySelector('.label')?.textContent.trim() || '', tip: a.querySelector('.human-name')?.getAttribute('title') || '' })))

async function openDmTab(p) {
  await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: NAV })
  await p.evaluate(() => document.querySelector('[data-testid=sidebar-tab-dm]').click())
  await p.waitForSelector(`#sidebar-panel-dm a.nav-item[data-key="${A}"]`, { timeout: NAV })
}

async function openDm(p, peer, base) {
  /* a phone shows one level: the rail is on /, an open DM covers it */
  if (base) {
    /* in-app, not a reload: the mock tenant's sends live in the tab */
    await p.evaluate(() => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push('/'))
    await p.waitForFunction(() => location.pathname === '/' || /^\/[a-z]{2}\/?$/.test(location.pathname), { timeout: NAV })
    await sleep(400)
  }
  await openDmTab(p)
  await p.evaluate((peer) => document.querySelector(`#sidebar-panel-dm a.nav-item[data-key="${peer}"]`).click(), peer)
  await p.waitForFunction((peer) => decodeURIComponent(location.pathname).endsWith('/dm/' + peer), { timeout: NAV }, peer)
  await sleep(600)
}

const headerTitle = (p) => p.$eval('[data-pane=msgs] .feed-header__title', (e) => e.textContent.trim()).catch(() => '')

/** Send through the channel store, as the composer does; the stored row's to / to_box. */
const sendAndRead = (p, text, body = text) => p.evaluate(async (text, body) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const ch = pinia?._s.get('channel')
  if (!ch) return null
  await ch.send(text)
  const m = ch.messages.find((x) => x.body === body)
  return m ? { to: m.to, to_box: m.to_box } : null
}, text, body)

const held = (p, body) => p.evaluate((body) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const ch = pinia?._s.get('channel')
  return ch ? ch.messages.some((x) => x.body === body) : null
}, body)

async function run(browser, base, width) {
  const p = await browser.newPage()
  /* the mock roster still carries legacy ids (CLE-07): pin the clock before
     their deadline, or the @ picker hides them as no longer active (dc6d5e3f) */
  await p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })
  const phone = width < 600
  await p.setViewport({ width, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  await p.goto(`${base}/`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('.spool-shell', { timeout: NAV })

  /* list: two rows, each with its box in the name and on hover */
  await openDmTab(p)
  const rows = (await dmRows(p)).filter((r) => r.key.startsWith('CLE-07@'))
  ok(`${width}: the DM list has CLE-07 once per box`, rows.length === 2 && rows.some((r) => r.key === A) && rows.some((r) => r.key === B), rows)
  ok(`${width}: each row shows its box`, rows.every((r) => r.text === r.key && r.tip === r.key), rows)
  if (SHOT_DIR) {
    mkdirSync(SHOT_DIR, { recursive: true })
    await p.screenshot({ path: `${SHOT_DIR}/agent-at-box-dm-list-${width}.png` })
  }

  /* dm: separate histories */
  const tag = `box-a only ${width} ${Date.now().toString(36)}`
  await openDm(p, A, phone ? base : '')
  ok(`${width}: the box-a DM is titled ${A}`, (await headerTitle(p)) === A, await headerTitle(p))
  const sent = await sendAndRead(p, tag)
  ok(`${width}: a DM line to ${A} is stored for box-a`, Boolean(sent) && sent.to === 'CLE-07' && sent.to_box === 'box-a', sent)
  await openDm(p, B, phone ? base : '')
  ok(`${width}: the box-b DM is titled ${B}`, (await headerTitle(p)) === B, await headerTitle(p))
  const inB = await p.evaluate((tag) => document.querySelector('[data-pane=msgs]')?.textContent.includes(tag), tag)
  const heldB = await held(p, tag)
  ok(`${width}: the box-a line is not in the box-b DM`, inB === false && heldB === false, { inB, heldB })
  await openDm(p, A, phone ? base : '')
  await p.waitForFunction((tag) => document.querySelector('[data-pane=msgs]')?.textContent.includes(tag), { timeout: 10000 }, tag).catch(() => null)
  const inA = await p.evaluate((tag) => document.querySelector('[data-pane=msgs]')?.textContent.includes(tag), tag)
  ok(`${width}: and it is back in the box-a DM`, inA === true, { inA })

  /* mention: both offered with their box; the pick routes to box-b */
  if (!phone) {
    await p.goto(`${base}/lobby`, { waitUntil: 'load', timeout: NAV })
    await p.waitForSelector(OMNI, { visible: true, timeout: NAV })
    await p.click(OMNI)
    await p.keyboard.type('@CLE-07')
    await p.waitForSelector('[data-test=mention-list]', { visible: true, timeout: 8000 }).catch(() => null)
    const opts = await p.evaluate(() => [...document.querySelectorAll('[data-test=mention-option]')].map((b) => b.querySelector('.mention-label')?.textContent.trim() || ''))
    ok('the @ picker offers CLE-07 on both boxes, named with the box', opts.includes(A) && opts.includes(B), opts)
    const iB = opts.indexOf(B)
    if (iB >= 0) await p.evaluate((i) => document.querySelectorAll('[data-test=mention-option]')[i].dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true })), iB)
    await sleep(200)
    const value = await p.$eval(OMNI, (el) => el.value)
    ok('picking box-b writes @CLE-07@box-b', value === `@${B} `, { value })
    await p.$eval(OMNI, (el) => { el.value = ''; el.dispatchEvent(new Event('input', { bubbles: true })) })
    const word = `route ${Date.now().toString(36)}`
    const routed = await sendAndRead(p, `@${B} ${word}`, word)
    ok('the dispatch to the picked agent names box-b', Boolean(routed) && routed.to === 'CLE-07' && routed.to_box === 'box-b', routed)
  }
  await p.close()
}

const srv = await startServer()
const browser = await launch()
try {
  for (const w of [1440, 390]) await run(browser, srv.base, w)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nagent-at-box: ${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
