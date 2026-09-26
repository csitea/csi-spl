// CLE-34996 (SPL-15): "Open parent section" from a search result, in a real
// browser. Search -> open a thread hit -> the thread line's menu -> Open
// parent section (keyboard only) -> the channel, its rail tab, the parent
// card selected in the middle and the thread still open on the right.
//
//   node tests/e2e/open-parent-section.test.mjs          (mock tenant, nuxi dev)
//   BASE_URL=<generated bundle> node tests/e2e/open-parent-section.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.PARENT_SHOTS || mkdtempSync(join(tmpdir(), 'spool-parent-'))
/* the mock tenant (utils/mock-data.mjs): a #lobby topic and one of its replies */
const ROOT_MSG = '22222222-2222-4222-8222-222222222222'
const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const REPLY = '33333333-3333-4333-8333-333333333333'

const results = []
const ok = (name, pass, ev) => {
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
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: { width: 1400, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/search?q=Applying', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const hit = `[data-test=search-results] .search-row[data-type=messages]`
  await p.waitForSelector(hit, { visible: true, timeout: NAV_TIMEOUT })
  await p.click(hit)
  const line = `aside.live-pane [data-msg-id="${REPLY}"]`
  await p.waitForSelector(line, { visible: true, timeout: 10000 })
  ok('1 a thread hit opens its thread on the right', true)

  /* the pointer path shows the item, right after Open */
  const box = await (await p.$(line)).boundingBox()
  await p.mouse.click(box.x + 40, box.y + 12, { button: 'right' })
  await p.waitForSelector('[data-testid=msg-menu]', { visible: true, timeout: 5000 })
  const ids = await p.$$eval('[data-testid=msg-menu] [role=menuitem]', (els) => els.map((e) => e.getAttribute('data-testid')))
  const label = await p.$eval('[data-testid=msg-menu-parent]', (el) => el.textContent.trim()).catch(() => '')
  ok('2 the thread line menu offers Open parent section after Open', ids[0] === 'msg-menu-open' && ids[1] === 'msg-menu-parent' && label === 'Open parent section', { ids, label })
  await p.keyboard.press('Escape')
  await p.waitForSelector('[data-testid=msg-menu]', { hidden: true, timeout: 5000 })

  /* the keyboard path: the row's menu button, Enter, ArrowDown, Enter */
  await p.$eval(`${line} [data-testid=msg-menu-btn]`, (el) => el.focus())
  await p.keyboard.press('Enter')
  await p.waitForSelector('[data-testid=msg-menu]', { visible: true, timeout: 5000 })
  await p.keyboard.press('ArrowDown')
  const focused = await p.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-testid'))
  ok('3 the item is reachable from the keyboard', focused === 'msg-menu-parent', { focused })
  await p.keyboard.press('Enter')

  await p.waitForFunction(() => location.pathname.endsWith('/channel/lobby'), { timeout: 10000 }).catch(() => null)
  const url = new URL(p.url())
  ok('4 the address is the channel with the topic open and the message as the hash',
    url.pathname.endsWith('/channel/lobby') && url.searchParams.get('topic') === TOPIC && url.hash === '#' + REPLY, p.url())

  const tab = await p.waitForSelector('[data-testid=sidebar-tab-channels][aria-selected="true"]', { timeout: 5000 }).then(() => true).catch(() => false)
  ok('5 the Channels rail tab is selected', tab)

  const card = `.spool-main [data-msg-id="${ROOT_MSG}"][data-selected="true"]`
  const selected = await p.waitForSelector(card, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const inView = selected && await p.$eval(card, (el) => {
    const r = el.getBoundingClientRect()
    const s = el.closest('.feed-body').getBoundingClientRect()
    return r.top >= s.top - 1 && r.top < s.bottom
  })
  ok('6 the parent card is selected and in view in the middle', Boolean(selected && inView), { selected, inView })

  /* the channel's own topic pane, as a click on the parent card opens it */
  const thread = `aside.live-pane[data-section="channel"] [data-msg-id="${REPLY}"]`
  const open = await p.waitForSelector(thread, { visible: true, timeout: 10000 }).then(() => true).catch(() => false)
  const panes = await p.$$eval('aside.live-pane', (els) => els.length)
  ok('7 the thread stays open on the right with the message in it', open && panes === 1, { open, panes })

  mkdirSync(SHOTS, { recursive: true })
  await p.screenshot({ path: `${SHOTS}/open-parent-section.png` })
  console.log(`  screenshot ${SHOTS}/open-parent-section.png`)
  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('8 no page errors', mine.length === 0, mine)
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  console.log(failed.map((r) => r.name).join('\n'))
  process.exit(1)
}
