// t1 404cd808 (owner, HUM-10: "being here /dm/<peer>?topic=<id> and coming
// from topics, I could not undertand was this archived or not" - "it must be
// a clear indication in this view if somethign is archived"). Real browser,
// mock tenant, 1440 and 390:
//
//   archived  a DM opened on an ARCHIVED topic (?topic=) shows the Archived
//             badge (archive glyph + the word) in view, the topic's title
//             muted beside it in the DM header
//   control   the same DM on a LIVE topic shows no badge
//
//   BASE_URL=<generated bundle> node tests/e2e/dm-archived-mark.test.mjs
//   SHOT_DIR=<dir> ... also writes a screenshot per width
import { createRequire } from 'node:module'
import { mkdirSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const results = []
function check(name, pass, ev) {
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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, defaultViewport: null, args: CHROME_LAUNCH_ARGS })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const NAV = Number(process.env.NAV_TIMEOUT ?? 90000)
const SHOT_DIR = process.env.SHOT_DIR || ''
const PEER = 'CLE-11@box-desk'
const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }

async function until(p, fn, arg, ms = 8000) {
  const t0 = Date.now()
  while (Date.now() - t0 < ms) {
    if (await p.evaluate(fn, arg)) return true
    await sleep(150)
  }
  return false
}

/* A DM opens from its rail row, as a person opens it: in the mock a cold
   /dm/<peer> load lands on / before the roster exists. */
async function openDm(p, base, peer) {
  await p.goto(`${base}/`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-testid=sidebar-tab-dm]', { timeout: NAV })
  await p.click('[data-testid=sidebar-tab-dm]')
  await p.waitForSelector(`a.nav-item[data-key="${peer}"]`, { timeout: NAV })
  await p.evaluate((peer) => document.querySelector(`a.nav-item[data-key="${peer}"]`).click(), peer)
  await p.waitForSelector('[data-test=feed-header-status-text]', { timeout: NAV })
  await sleep(600)
}

/* Two topics with a reply each in this DM; the first is then archived the way
   the card menu archives it (the mock hub's archiveTopic). */
const seed = (p, width) => p.evaluate(async (width) => {
  const app = document.querySelector('#__nuxt').__vue_app__
  const ch = app.config.globalProperties.$pinia._s.get('channel')
  const arch = await ch.send(`404cd808 archived topic ${width}`, undefined, undefined, undefined, 1)
  await ch.send('a reply in the archived topic', arch.task_id, undefined, undefined, 0)
  const live = await ch.send(`404cd808 live topic ${width}`, undefined, undefined, undefined, 1)
  await ch.send('a reply in the live topic', live.task_id, undefined, undefined, 0)
  return { arch: { msg_id: arch.msg_id, task_id: arch.task_id }, live: { msg_id: live.msg_id, task_id: live.task_id } }
}, width)

async function archiveFromMenu(p, msgId) {
  const sel = `.spool-main article.msg[data-msg-id="${msgId}"]`
  await p.waitForSelector(sel, { timeout: 10000 })
  for (let i = 0; i < 3; i++) {
    await p.evaluate((sel) => document.querySelector(`${sel} [data-testid=msg-menu-btn]`)?.click(), sel)
    if (await until(p, () => Boolean(document.querySelector('[data-testid=msg-menu-archive]')), null, 3000)) break
  }
  await p.evaluate(() => document.querySelector('[data-testid=msg-menu-archive]')?.click())
  return until(p, (sel) => !document.querySelector(sel), sel)
}

const openTopic = (p, peer, task) => p.evaluate(async ({ peer, task }) => {
  const r = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router
  await r.push({ path: '/dm/' + encodeURIComponent(peer), query: { topic: task } })
}, { peer, task })

/** The Archived marks on screen: the DM header's, and any badge in view. */
const marks = (p) => p.evaluate(() => {
  const inView = (el) => {
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth
  }
  const head = document.querySelector('[data-test=feed-header] [data-test=feed-header-archived]')
  const badge = head && head.querySelector('[data-test=archived-badge]')
  return {
    header: Boolean(head),
    headerBadge: badge ? badge.textContent.trim() : null,
    headerInView: Boolean(badge && inView(badge)),
    title: head ? (head.querySelector('.feed-header__topic-title')?.textContent.trim() || '') : null,
    muted: Boolean(head && head.classList.contains('is-archived')),
    anyInView: [...document.querySelectorAll('[data-test=archived-badge]')].some(inView),
    xScroll: document.documentElement.scrollWidth > innerWidth + 1,
  }
})

async function run(browser, base, width) {
  const p = await browser.newPage()
  const phone = width < 600
  await p.setViewport({ width, height: phone ? 844 : 900, isMobile: phone, hasTouch: phone })
  await p.evaluateOnNewDocument((claims) => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
    try { localStorage.setItem('spool.mock.session', JSON.stringify(claims)) } catch { /* */ }
  }, CLAIMS)
  /* warm the cold nuxi-dev dynamic imports before the real page */
  await p.goto(`${base}/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })

  await openDm(p, base, PEER)
  const ids = await seed(p, width)
  check(`${width}: archived the topic card from its menu (it left the feed)`, await archiveFromMenu(p, ids.arch.msg_id), ids.arch)

  await openTopic(p, PEER, ids.arch.task_id)
  await until(p, () => Boolean(document.querySelector('[data-test=feed-header-archived]')))
  await sleep(400)
  const a = await marks(p)
  check(`${width}: archived topic -> "Archived" badge in the DM header, title muted beside it`,
    a.header && a.headerBadge === 'Archived' && a.muted && a.title === `404cd808 archived topic ${width}`, a)
  check(`${width}: archived topic -> an Archived badge is in view`, a.anyInView, a)
  check(`${width}: no sideways scroll`, !a.xScroll, a)
  if (SHOT_DIR) { mkdirSync(SHOT_DIR, { recursive: true }); await p.screenshot({ path: `${SHOT_DIR}/dm-archived-${width}.png` }) }

  await openTopic(p, PEER, ids.live.task_id)
  await sleep(1200)
  const l = await marks(p)
  check(`${width}: live topic -> no Archived mark (control)`, !l.header && !l.anyInView, l)
  if (SHOT_DIR) await p.screenshot({ path: `${SHOT_DIR}/dm-live-${width}.png` })

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
console.log(`\ndm-archived-mark: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
