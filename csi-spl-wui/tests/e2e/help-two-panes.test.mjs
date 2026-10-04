// t1 67f91532 (owner): "the help section should have only 2 panes - in the
// left one should be the links ... and in the right one the actual
// documents", and "if one clicks from the channel view - of course the 3rd
// panel with the content of the channel view should be closed".
//
// At 1440 px, light and dark: from /channel/lobby with its topic panel (the
// 3rd panel) open, the rail's Help opens /help showing exactly two panes -
// the help page list on the left, the document on the right - the sidebar
// keeps its icon rail only and no topic panel is left; a click on a left
// link swaps the document on the right.
//
// Control: before the change the sidebar's channel list and the topic panel
// both stay beside help (4 columns), so the pane checks FAIL.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e help-two-panes
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/* every visible column of the shell, left to right, wider than the icon rail */
const panes = (p) => p.evaluate(() => {
  const shown = (el) => {
    if (!el) return null
    const r = el.getBoundingClientRect()
    return r.width > 0 && r.height > 0 && getComputedStyle(el).display !== 'none' ? r : null
  }
  const cols = []
  const add = (name, el) => { const r = shown(el); if (r) cols.push({ name, left: Math.round(r.left), right: Math.round(r.right) }) }
  add('sidebar-list', document.querySelector('.sidebar-body'))
  add('help-nav', document.querySelector('[data-test=help-nav]'))
  add('help-content', document.querySelector('[data-test=help-content]'))
  add('topic', document.querySelector('[data-test=topic-section]'))
  return cols.sort((a, b) => a.left - b.left)
})

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) {
    console.log(`-- 1440x900 ${theme}`)
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/channel/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await p.waitForSelector('[data-test=top-bar]', { timeout: NAV_TIMEOUT })
    await sleep(600)
    /* the channel view's 3rd panel: a topic open beside the lobby */
    const armed = await p.evaluate((id) => {
      const topic = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia?._s.get('topic')
      if (!topic) return 'no-store'
      topic.openTopic(id)
      return 'ok'
    }, TASK)
    const third = await p.waitForSelector('[data-test=topic-section]', { visible: true, timeout: 8000 }).catch(() => null)
    ok(`${theme}: setup - the channel view has its 3rd (topic) panel open`, armed === 'ok' && Boolean(third), armed)

    await p.click('[data-testid=help-open]')
    await p.waitForFunction(() => location.pathname === '/help', { timeout: 10000 }).catch(() => {})
    await p.waitForSelector('[data-test=help-content] [data-testid=md-block][data-rendered=true]', { timeout: 15000 }).catch(() => {})
    await sleep(500)
    ok(`${theme}: Help opens /help`, new URL(p.url()).pathname === '/help', p.url())
    const cols = await panes(p)
    const names = cols.map((c) => c.name)
    ok(`${theme}: exactly two panes, the link list left and the document right`, names.join(',') === 'help-nav,help-content', cols)
    ok(`${theme}: no channel topic panel is left beside help`, !(await p.$('[data-test=topic-section]')))
    ok(`${theme}: the sidebar keeps its icon rail`, Boolean(await p.$('[data-testid=sidebar-rail]')) && (await p.$eval('nav.sidebar', (el) => el.getAttribute('data-help-rail'))) === '1')
    const links = await p.$$eval('[data-test=help-nav] a', (as) => as.map((a) => a.getAttribute('data-test')))
    ok(`${theme}: the left pane lists the help pages (pages.json)`, links.length >= 12 && links.includes('help-nav-archive'), links.length)

    await p.click('[data-test=help-nav-archive]')
    await p.waitForFunction(() => document.querySelector('[data-test=help-content]')?.getAttribute('data-page') === 'archive', { timeout: 10000 }).catch(() => {})
    await p.waitForSelector('[data-test=help-content] [data-testid=md-block][data-rendered=true]', { timeout: 15000 }).catch(() => {})
    const page = await p.$eval('[data-test=help-content]', (el) => el.getAttribute('data-page'))
    ok(`${theme}: a left link swaps the document on the right`, page === 'archive' && new URL(p.url()).pathname === '/help/archive', page)
    const active = await p.$eval('[data-test=help-nav-archive]', (a) => a.getAttribute('aria-current'))
    ok(`${theme}: the current page is highlighted in the list`, active === 'page', active)
    const after = (await panes(p)).map((c) => c.name).join(',')
    ok(`${theme}: still two panes after the swap`, after === 'help-nav,help-content', after)
    const sw = await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)
    ok(`${theme}: no sideways scroll`, sw)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `help-two-panes: ${failed} FAILED` : `help-two-panes: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
