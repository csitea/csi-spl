// SPL-3785 (owner HUM-10, t1 c3e53990 msg 1f55e7e1: "whenever one has
// entered the first level of it, it should always be shown"; msg c3c2ff9b:
// it must not "jump on and off based on the tab"): on a phone the section
// strip is on top at EVERY level and tab of a section. The routes are read
// off src/pages/** (tests/e2e/lib/page-routes.mjs), never a hand-kept list:
// a page or tab that lands is checked here the same day. A `:param` takes a
// sample from utils/mock-data.mjs; a page with its own layout (login,
// checkout, blog, public calendar) is not in the shell and is left out.
// Plus the drill-downs: a topic, a reply (?in=), a person, an agent, a box,
// a help page, an open issue.
//
// Each route: the strip is painted (on top, not under a panel) right under
// the top bar, at most one Back is painted, and there is no horizontal
// scroll. A route that opens a full-screen dialog over the top bar too
// (Settings, a release note) is listed as MODAL, not counted. Run at 390 px
// dark and 360 px light.
//
//   BASE_URL=<generated mock bundle> node tests/e2e/section-strip-every-level.test.mjs
import { createRequire } from 'node:module'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { dirname, join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { pageRoutes } from './lib/page-routes.mjs'

const PAGES_DIR = join(dirname(fileURLToPath(import.meta.url)), '../../src/pages')
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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

/* a sample per route param, from utils/mock-data.mjs */
const TOPIC = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const MSG = '11111111-1111-4111-8111-111111111111'
const SAMPLE = { name: 'lobby', peer: 'HUM-2', task_id: TOPIC, id: '', ref: 'v1.0.0' }
const ID_BY_DIR = { agents: 'CLE-07', boxes: 'box-desk', people: 'HUM-2', m: MSG, goals: 'G-1' }
function fill(path) {
  return path.replace(/\/([^/]+)\/:(\w+)/g, (_, dir, param) => `/${dir}/${encodeURIComponent((param === 'id' ? ID_BY_DIR[dir] : SAMPLE[param]) || 'x')}`)
}
const walked = pageRoutes(PAGES_DIR).filter((r) => r.layout === 'default').map((r) => fill(r.path))
const ROUTES = [...new Set([
  ...walked,
  /* drill-downs the walk reaches only by a query */
  `/channel/lobby?topic=${TOPIC}`,
  `/t/${TOPIC}?in=${MSG}`,
  '/help/getting-started',
])]

const read = (p) => p.evaluate(() => {
  /* painted: shown AND the topmost thing at its centre (not under a panel) */
  const vis = (e) => {
    if (!e) return false
    const r = e.getBoundingClientRect()
    const cs = getComputedStyle(e)
    if (cs.display === 'none' || cs.visibility === 'hidden' || !(r.width > 0 && r.height > 0)) return false
    const hit = document.elementFromPoint(Math.min(r.left + r.width / 2, innerWidth - 1), r.top + r.height / 2)
    return Boolean(hit) && (e.contains(hit) || hit.contains(e))
  }
  const shell = document.querySelector('.spool-shell')
  const strip = document.querySelector('[data-testid=sidebar-rail]')
  const bar = document.querySelector('[data-test=top-bar]')
  if (!shell || !bar) return { shell: false, path: location.pathname }
  const sr = strip ? strip.getBoundingClientRect() : null
  const br = bar.getBoundingClientRect()
  return {
    shell: true,
    /* a full-screen dialog (Settings, a release note) covers the top bar too:
       it is no level of a section, so no strip is due under it */
    modal: !vis(bar) && Boolean(document.querySelector('dialog[open], [role=dialog]')),
    path: location.pathname + location.search,
    level: shell.getAttribute('data-mobile-level'),
    strip: vis(strip),
    underBar: Boolean(sr) && Math.abs(sr.top - br.bottom) <= 1,
    back: [...document.querySelectorAll('[data-testid=mobile-back], [data-test=issues-detail-back]')].filter(vis).length,
    xscroll: document.scrollingElement.scrollWidth > innerWidth,
  }
})

async function settle(p, max = 8000) {
  const end = Date.now() + max
  let prev = ''
  while (Date.now() < end) {
    const s = await read(p)
    const key = JSON.stringify(s)
    if (s.shell && key === prev) return s
    prev = key
    await sleep(200)
  }
  return read(p)
}

const modals = []
const check = (tag, what, s) => s.modal ? (modals.push(`${tag} ${what}`), console.log(`  MODAL ${tag} ${what}: a dialog over the whole shell, top bar too`)) : ok(`${tag} ${what}: strip under the top bar, <= 1 Back, no x-scroll`, s.shell && s.strip && s.underBar && s.back <= 1 && !s.xscroll, s)

const srv = await startServer()
const browser = await launch()
try {
  /* the two widths run side by side: 2 x 56 page loads in one pass is the
     longest file the pre-push e2e cap runs (SPL-3785) */
  await Promise.all([[390, 'dark'], [360, 'light']].map(async ([width, scheme]) => {
    const tag = `${width}px ${scheme}`
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }])
    await p.evaluateOnNewDocument(() => localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'member@example.com', name: 'FirstName LastName', t: 't1' })))
    await p.setViewport({ width, height: 844, isMobile: true, hasTouch: true })
    for (const route of ROUTES) {
      await p.goto(`${srv.base}${route}`, { waitUntil: 'networkidle2' }).catch(() => null)
      check(tag, route, await settle(p))
    }
    /* level 3 by a tap: a channel's topic, then an open issue */
    await p.goto(`${srv.base}/channel/lobby`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=topic-card], .topic-card, [data-task-id]', { visible: true, timeout: 10000 }).catch(() => null)
    await p.evaluate(() => document.querySelector('[data-test=topic-card], .topic-card, [data-task-id]')?.click())
    const t3 = await settle(p)
    check(tag, `a tapped topic (level ${t3.level})`, t3)
    await p.goto(`${srv.base}/issues`, { waitUntil: 'networkidle2' })
    await p.waitForSelector('[data-test=issues-new]', { visible: true, timeout: 10000 }).catch(() => null)
    await p.click('[data-test=issues-new]').catch(() => null)
    await p.waitForSelector('[data-test=issues-detail-title]', { visible: true, timeout: 10000 }).catch(() => null)
    const i3 = await settle(p)
    check(tag, `an open issue (level ${i3.level})`, i3)
    await p.close()
  }))
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nsection-strip-every-level: ${results.length - failed.length}/${results.length} passed (${ROUTES.length} routes; ${modals.length} full-screen dialogs not counted)`)
process.exit(failed.length ? 1 : 0)
