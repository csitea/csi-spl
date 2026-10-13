// SPL-1643 (owner HUM-10, t1 1ccf3a20, msgs 4913b500 + d6300003): closing an
// epic that has open issues asks first, naming the count ("Close SPL-1 and
// its 1 open issue?"), then the epic and its issues leave the list (closed
// and archived). Controls: before the confirm nothing changed; an issue that
// is not an epic closes with no confirm.
//
//   pnpm run test:e2e issues-epic-close
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-epic-close
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
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

async function newIssue(p, title) {
  await p.click('[data-test=issues-new]')
  await p.waitForSelector('[data-test=issues-newrow-title]', { visible: true, timeout: 5000 })
  await p.type('[data-test=issues-newrow-title]', title)
  await p.keyboard.press('Enter')
  return p.waitForFunction((want) => {
    const row = [...document.querySelectorAll('[data-test=issues-row]')].find((r) => r.querySelector('.issues-title')?.textContent.trim() === want)
    return !document.querySelector('[data-test=issues-newrow]') && row ? row.getAttribute('data-key') : false
  }, { timeout: 5000 }, title).then((h) => h.jsonValue())
}
const row = (k) => `[data-test=issues-row][data-key="${k}"]`
async function setStatus(p, key, status) {
  await p.click(`${row(key)} [data-test=issues-row-status]`)
  await p.waitForSelector(`[data-test=issues-menu-option][data-value="${status}"]`, { visible: true, timeout: 5000 })
  await p.click(`[data-test=issues-menu-option][data-value="${status}"]`)
}

const shot = process.env.SHOT_DIR || mkdtempSync(join(tmpdir(), 'spl-e2e-'))
const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))

  // two issues under the seeded epic SPL-1; one page load (the mock hub lives in the tab)
  await p.goto(server.base + '/issues?epic=SPL-1', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=issues-page]', { visible: true, timeout: NAV_TIMEOUT })
  const child = await newIssue(p, 'An open issue of the epic')
  const other = await newIssue(p, 'An issue closed on its own')

  // control: closing an issue (not an epic) asks nothing and it stays listed
  await setStatus(p, other, 'done')
  await p.waitForFunction((sel) => document.querySelector(sel)?.getAttribute('data-status') === 'done', { timeout: 5000 }, `${row(other)} [data-test=issues-row-status]`).catch(() => {})
  const otherStatus = await p.$eval(`${row(other)} [data-test=issues-row-status]`, (el) => el.getAttribute('data-status')).catch(() => '')
  ok('1 an issue closes with no confirm (control)', otherStatus === 'done' && !(await p.$('[data-testid=issues-epic-close-body]')), { otherStatus })

  // closing the epic from its detail asks first, naming the open count (1: the other is done)
  await p.click('[data-test=issues-epic-menu]')
  await p.waitForSelector('[data-test=issues-ctxmenu-edit]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-ctxmenu-edit]')
  await p.waitForSelector('[data-test=issues-detail] [data-test=issues-status]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-detail] [data-test=issues-status]')
  await p.waitForSelector('[data-test=issues-menu-option][data-value="done"]', { visible: true, timeout: 5000 })
  await p.click('[data-test=issues-menu-option][data-value="done"]')
  await p.waitForSelector('[data-testid=issues-epic-close-confirm]', { visible: true, timeout: 5000 })
  const ask = await p.$eval('[data-testid=issues-epic-close-body]', (el) => ({ key: el.getAttribute('data-key'), count: el.getAttribute('data-count') }))
  const text = await p.evaluate(() => document.body.innerText)
  await p.screenshot({ path: `${shot}/SPL-1643-confirm.png` })
  ok('2 the confirm names the epic and its open-issue count', ask.key === 'SPL-1' && ask.count === '1' && /Close SPL-1 and its 1 open issue\?/.test(text), ask)
  ok('3 nothing changed before the confirm (control)', Boolean(await p.$(row(child))) && Boolean(await p.$(row(other))))

  await p.click('[data-testid=issues-epic-close-confirm]')
  await p.waitForFunction((a, b) => !document.querySelector('[data-test=issues-detail]') && !document.querySelector(a) && !document.querySelector(b),
    { timeout: 5000 }, row(child), row(other)).catch(() => {})
  const left = { detail: Boolean(await p.$('[data-test=issues-detail]')), child: Boolean(await p.$(row(child))), other: Boolean(await p.$(row(other))) }
  ok('4 confirmed: the epic closes and both of its issues leave the list', !left.detail && !left.child && !left.other, left)

  const mine = errors.filter((e) => !/Failed to fetch dynamically imported module/.test(e))
  ok('5 no page errors', mine.length === 0, mine)
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
