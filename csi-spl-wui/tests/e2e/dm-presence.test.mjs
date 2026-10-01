// CLE-77862 (HUM-24): "isn't this green dot MY status? to see the other
// person's I have to scroll back up". Real browser, mock tenant, 1440 and 390:
//
//   peer      a DM header prints the PEER's presence in words beside the name,
//             inside the viewport, with the feed scrolled to its top and to its
//             bottom: "online" for an online agent, "offline · queued" for a
//             never-seen member, "last seen <YYYY-MM-DD HH:MM>" once the
//             roster carries a last_seen (whole, not clipped: on a phone the
//             words sit under the name)
//   own       the reader's own dot (the DM rail's "you" row) is labelled as
//             theirs: tooltip and accessible name "Your status: online"
//
//   BASE_URL=http://127.0.0.1:3111 node tests/e2e/dm-presence.test.mjs
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
const AGENT = 'CLE-11@box-desk'
const MEMBER = 'HUM-2@box-wui'
const SEEN = '2026-09-30T08:05:00.000Z'

const CLAIMS = { hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' }

/** The header's presence words, and whether they sit inside the viewport. */
const header = (p) => p.evaluate(() => {
  const el = document.querySelector('[data-test=feed-header-status-text]')
  const dot = document.querySelector('[data-test=feed-header-status]')
  if (!el) return { text: null }
  const r = el.getBoundingClientRect()
  const visible = r.width > 0 && r.height > 0 && r.top >= 0 && r.bottom <= innerHeight && r.left >= 0 && r.right <= innerWidth
  return { text: el.textContent.trim(), visible, whole: el.scrollWidth <= el.clientWidth + 1, dotOn: dot ? dot.classList.contains('on') : null, dotTitle: dot ? dot.getAttribute('title') : null }
})

const scrollFeed = (p, where) => p.evaluate((where) => {
  const f = document.querySelector('.feed-body')
  if (f) f.scrollTop = where === 'top' ? 0 : f.scrollHeight
  return Boolean(f)
}, where)

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

async function run(browser, base, width) {
  const p = await browser.newPage()
  const height = width < 600 ? 844 : 900
  await p.setViewport({ width, height, isMobile: width < 600, hasTouch: width < 600 })
  await p.evaluateOnNewDocument((claims) => {
    window.__errs = []
    window.addEventListener('error', (e) => window.__errs.push(String(e.message || '')))
    try { localStorage.setItem('spool.mock.session', JSON.stringify(claims)) } catch { /* */ }
  }, CLAIMS)
  /* warm the cold nuxi-dev dynamic imports before the real page */
  await p.goto(`${base}/lobby`, { waitUntil: 'load', timeout: NAV })
  await p.waitForSelector('[data-test=top-bar]', { timeout: NAV })

  await openDm(p, base, AGENT)
  for (const where of ['top', 'bottom']) {
    await scrollFeed(p, where)
    await sleep(200)
    const h = await header(p)
    check(`${width}: online agent, feed at ${where}: "online" beside the name, in view`, h.text === 'online' && h.visible && h.dotOn === true, h)
  }
  if (SHOT_DIR) { mkdirSync(SHOT_DIR, { recursive: true }); await p.screenshot({ path: `${SHOT_DIR}/dm-presence-after-${width}-online.png` }) }

  await openDm(p, base, MEMBER)
  const never = await header(p)
  check(`${width}: never-seen member: "offline · queued", grey dot`, never.text === 'offline · queued' && never.visible && never.dotOn === false, never)

  await p.evaluate((seen) => {
    const r = document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$pinia._s.get('roster')
    r.humansDetail = { ...r.humansDetail, 'HUM-2': { owner: false, interests: '', last_seen: seen } }
  }, SEEN)
  await sleep(300)
  const seen = await header(p)
  const want = await p.evaluate((iso) => {
    const d = new Date(iso); const pad = (n) => String(n).padStart(2, '0')
    return `last seen ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`
  }, SEEN)
  check(`${width}: member with last_seen: "${want}", not clipped`, seen.text === want && seen.visible && seen.whole && seen.dotTitle === want, seen)
  if (SHOT_DIR) await p.screenshot({ path: `${SHOT_DIR}/dm-presence-after-${width}-last-seen.png` })

  if (width >= 600) {
    await p.waitForSelector('[data-test=self-status-dot]', { timeout: NAV })
    const own = await p.evaluate(() => {
      const d = document.querySelector('[data-test=self-status-dot]')
      return { title: d.getAttribute('title'), label: d.getAttribute('aria-label'), role: d.getAttribute('role'), on: d.classList.contains('on') }
    })
    check(`${width}: own dot is labelled as yours`, own.title === 'Your status: online' && own.label === own.title && own.role === 'img' && own.on, own)
    if (SHOT_DIR) await p.screenshot({ path: `${SHOT_DIR}/dm-presence-after-${width}-own.png` })
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
console.log(`\ndm-presence: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length ? 1 : 0))
