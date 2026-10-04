// The topics view (/t/:id) left list opens the same menu as that topic's
// card in a channel: same entries, in the same order, locked the same way.
// Desktop only (1440 and 1280, light and dark). A phone long-press is left
// alone. Archive from the list removes the row.
//
// Run:
//   node tests/e2e/topic-list-row-menu.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/topic-list-row-menu.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const CARD = '22222222-2222-4222-8222-222222222222'
const OTHER = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const WIDTHS = [1440, 1280]
const THEMES = ['light', 'dark']
const OUT = process.env.OUT || mkdtempSync(join(tmpdir(), 'topic-list-menu-'))
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: Boolean(pass) })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

async function launch() {
  const require = createRequire(import.meta.url)
  const href = pathToFileURL(require.resolve('puppeteer-core')).href
  const mod = await import(href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    defaultViewport: null,
    args: CHROME_LAUNCH_ARGS,
  })
}

async function go(p, url) {
  let last
  for (let i = 0; i < 3; i++) {
    try {
      await p.goto(url, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      return
    } catch (e) {
      last = e
      await sleep(400)
    }
  }
  throw last
}

async function theme(p, name) {
  await p.evaluate((t) => {
    document.documentElement.setAttribute('data-theme', t)
    try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ }
  }, name)
}

async function menuItems(p) {
  return p.evaluate(() => [...document.querySelectorAll('[data-testid=msg-menu] [role=menuitem]')].map((e) => (
    e.getAttribute('data-testid') + (e.getAttribute('aria-disabled') === 'true' ? ':off' : '')
  )))
}

async function waitMenu(p) {
  for (let i = 0; i < 40; i++) {
    const got = await menuItems(p)
    if (got.length) return got
    await sleep(150)
  }
  return []
}

async function rightClick(p, sel) {
  const hit = await p.evaluate((sel) => {
    const el = document.querySelector(sel)
    if (!el) return false
    const r = el.getBoundingClientRect()
    el.dispatchEvent(new MouseEvent('contextmenu', {
      bubbles: true, cancelable: true, clientX: r.left + 12, clientY: r.top + 12, button: 2,
    }))
    return true
  }, sel)
  if (!hit) return []
  return waitMenu(p)
}

async function closeMenu(p) {
  await p.keyboard.press('Escape')
  await sleep(150)
}

const cardSel = `.spool-main article.msg[data-msg-id="${CARD}"]`
const rowSel = `[data-test=topic-browse-list] [data-key="${TOPIC}"]`
const otherSel = `[data-test=topic-browse-list] [data-key="${OTHER}"]`

const srv = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  p.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await p.evaluateOnNewDocument(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', email: 'dev@example.com', name: 'FirstName LastName', t: 't1' }))
    localStorage.setItem('spool.mock.archive_policy', 'everyone')
    localStorage.setItem('spool.mock.role', 'developer')
  })
  /* a cold dev server aborts the first navigation; go() retries it */
  await go(p, `${srv.base}/channel/lobby`)
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await sleep(600)

  for (const width of WIDTHS) {
    for (const name of THEMES) {
      const label = `${width} ${name}`
      await p.setViewport({ width, height: 900 })
      await go(p, `${srv.base}/channel/lobby`)
      await p.waitForSelector(cardSel, { timeout: NAV_TIMEOUT })
      await theme(p, name)
      await sleep(200)
      let card = await rightClick(p, `${cardSel} .msg-body`)
      if (!card.length) card = await rightClick(p, `${cardSel} .msg-body`)
      ok(`${label} channel card menu opens`, card.length > 0, card)
      await closeMenu(p)

      await go(p, `${srv.base}/t/${TOPIC}`)
      await p.waitForSelector(rowSel, { timeout: NAV_TIMEOUT })
      await theme(p, name)
      await sleep(200)
      let list = await rightClick(p, rowSel)
      if (!list.length) list = await rightClick(p, rowSel)
      ok(`${label} right-click list menu matches the channel card`, list.length > 0 && same(list, card), { card, list })
      await p.screenshot({ path: `${OUT}/${name}-${width}.png` })
      await closeMenu(p)

      if (width === 1440 && name === 'light') {
        await p.click(`[data-test=topic-browse-list] [data-testid=topic-list-menu][data-menu-id="${TOPIC}"]`)
        const fromBtn = await waitMenu(p)
        ok('1440 light the row button opens the same menu', same(fromBtn, card), { card, fromBtn })
        await closeMenu(p)
      }
    }
  }

  await p.setViewport({ width: 1440, height: 900 })
  await go(p, `${srv.base}/t/${TOPIC}`)
  await p.waitForSelector(otherSel, { timeout: NAV_TIMEOUT })
  let other = await rightClick(p, otherSel)
  if (!other.length) other = await rightClick(p, otherSel)
  ok('archive is on the list menu', other.includes('msg-menu-archive'), other)
  await p.click('[data-testid=msg-menu-archive]')
  let gone = false
  for (let i = 0; i < 30; i++) {
    gone = await p.evaluate((sel) => !document.querySelector(sel), otherSel)
    if (gone) break
    await sleep(150)
  }
  const toast = await p.$('[data-testid=archive-toast]')
  ok('archive from the list removes the row and offers undo', gone && Boolean(toast), { gone, toast: Boolean(toast) })

  const benign = (e) => /Failed to fetch dynamically imported module/.test(e)
  ok('no unexpected page errors', errors.filter((e) => !benign(e)).length === 0, errors)
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\ntopic-list-row-menu: ${results.length - failed.length}/${results.length} passed`)
console.log(`screenshots: ${OUT}`)
process.exit(failed.length ? 1 : 0)
