// P5-06 (perf round 5): the hub's issue list stops carrying `description`;
// the sheet paints none, and opening an issue reads it by number before the
// modal paints. In a real browser, mock tenant (its list drops the text the
// same way, utils/issues.mjs), three seeded issues with a description each:
//   1  a click on a row opens the modal with that issue's description
//   2  a second row, opened after the first closed, shows its own
//   3  a deep link (?issue=) opens with its description
//   4  CONTROL: the list row itself has no description, so the text in the
//      modal can only come from the by-number read
//
//   pnpm run test:e2e issues-open-description
//   BASE_URL=<generated bundle> pnpm run test:e2e issues-open-description
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
        defaultViewport: { width: 1440, height: 900 },
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const row = (key) => `[data-test=issues-row][data-key="${key}"]`

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e && e.message)))
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => localStorage.setItem('spool.mock.issues-seed', '3'))
  await p.goto(server.base + '/issues', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector(row('SPL-2'), { visible: true, timeout: NAV_TIMEOUT })

  /* the modal's key and rendered description once it shows `key` (or what it shows after 5 s) */
  const shown = async (key) => {
    await p.waitForFunction((k) => {
      const d = document.querySelector('[data-test=issues-detail]')
      return d && d.textContent.includes(k) && d.querySelector('[data-test=issues-detail-rendered]')?.textContent.includes('text')
    }, { timeout: 5000 }, key).catch(() => {})
    return p.evaluate(() => {
      const d = document.querySelector('[data-test=issues-detail]')
      return { up: Boolean(d), desc: d?.querySelector('[data-test=issues-detail-rendered]')?.textContent.trim() || '' }
    })
  }

  /* CONTROL: the sheet's row shows no description text (the mock list drops
     it, tests/unit/issues-sheet-description.test.mjs), so the modal's text
     can only come from the by-number read */
  const seeded = await p.$eval(row('SPL-2'), (el) => el.textContent)
  ok('4 CONTROL: the listed row carries no description text', !seeded.includes('mock issue 1 text'), { seeded: seeded.trim().slice(0, 80) })

  await p.click(`${row('SPL-2')} .issues-c-key`)
  const first = await shown('SPL-2')
  ok('1 a clicked row opens with its description', first.up && first.desc.includes('mock issue 1 text'), first)

  /* a second row, opened after the first closed, shows its own text */
  await p.keyboard.press('Escape')
  await p.waitForFunction(() => !document.querySelector('[data-test=issues-detail]'), { timeout: 5000 }).catch(() => {})
  await p.click(`${row('SPL-3')} .issues-c-key`)
  const second = await shown('SPL-3')
  ok('2 the next row opened shows its own description', second.up && second.desc.includes('mock issue 2 text'), second)

  await p.goto(server.base + '/issues?issue=SPL-4', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const linked = await shown('SPL-4')
  ok('3 a deep link opens with its description', linked.up && linked.desc.includes('mock issue 3 text'), linked)

  await p.evaluate(() => localStorage.removeItem('spool.mock.issues-seed'))
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
