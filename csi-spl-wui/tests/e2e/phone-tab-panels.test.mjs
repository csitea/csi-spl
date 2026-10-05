// E08 (perf 20261004): a phone drops a rail panel it has left. Desktop
// keeps the panel, so a switch back does not rebuild it.
//
//   node tests/e2e/phone-tab-panels.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/phone-tab-panels.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
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
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const panels = (p) => p.evaluate(() => ({
  dm: Boolean(document.getElementById('sidebar-panel-dm')),
  flow: Boolean(document.getElementById('sidebar-panel-flow')),
  tab: document.querySelector('.sidebar-tab[aria-selected="true"]')?.getAttribute('data-testid') || '',
}))

const srv = await startServer()
const browser = await launch()
try {
  const phone = await browser.newPage()
  phone.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await phone.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await phone.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
  await phone.waitForSelector('[data-testid=sidebar-tab-dm]', { visible: true })
  await sleep(600)
  let c = await panels(phone)
  ok('390px / starts with the messages panel', c.dm === true && c.flow === false && c.tab === 'sidebar-tab-dm', c)
  await phone.click('[data-testid=sidebar-tab-flow]')
  await sleep(800)
  c = await panels(phone)
  ok('390px leaving messages drops that panel', c.dm === false && c.flow === true && c.tab === 'sidebar-tab-flow', c)
  await phone.click('[data-testid=sidebar-tab-dm]')
  await sleep(800)
  c = await panels(phone)
  ok('390px opening messages builds the panel again', c.dm === true && c.flow === false, c)
  await phone.close()

  const desk = await browser.newPage()
  desk.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await desk.setViewport({ width: 1440, height: 900 })
  await desk.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
  await desk.waitForSelector('[data-testid=sidebar-tab-dm]', { visible: true })
  await sleep(600)
  /* / on a wide screen opens Topics, so the messages panel is built on the first visit */
  await desk.click('[data-testid=sidebar-tab-dm]')
  await sleep(600)
  await desk.click('[data-testid=sidebar-tab-flow]')
  await sleep(800)
  c = await panels(desk)
  ok('1440px keeps the messages panel after leaving it', c.dm === true && c.flow === true && c.tab === 'sidebar-tab-flow', c)
  await desk.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nphone-tab-panels: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
