// E08 (perf 20261004): phone level 1 does not mount the middle pane.
// The CSS used to hide it (display:none, ~120 nodes still in the document).
// A URL that opens level 2 or 3 still mounts the page, and desktop keeps it.
//
//   node tests/e2e/phone-stack-mount.test.mjs
//   BASE_URL=<generated bundle> node tests/e2e/phone-stack-mount.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
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

const census = (p) => p.evaluate(() => {
  const main = document.querySelector('.spool-shell > .spool-main')
  const topic = document.querySelector('.spool-shell > .topic')
  const vis = (e) => {
    if (!e) return false
    const r = e.getBoundingClientRect()
    return getComputedStyle(e).display !== 'none' && r.width > 0 && r.height > 0
  }
  return {
    level: document.querySelector('.spool-shell')?.getAttribute('data-mobile-level') || '',
    mainInDom: Boolean(main),
    mainNodes: main ? main.querySelectorAll('*').length + 1 : 0,
    mainVisible: vis(main),
    topicVisible: vis(topic),
    path: location.pathname + location.search,
  }
})

const srv = await startServer()
const browser = await launch()
try {
  const phone = await browser.newPage()
  phone.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await phone.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })

  await phone.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
  await phone.waitForSelector('[data-testid=sidebar-tab-dm]', { visible: true })
  await sleep(800)
  let c = await census(phone)
  ok('390px / leaves the middle pane out of the document', c.level === '1' && c.mainInDom === false && c.mainNodes === 0, c)

  await phone.goto(`${srv.base}/channel/lobby`, { waitUntil: 'networkidle2' })
  await sleep(1200)
  c = await census(phone)
  ok('390px /channel/lobby mounts the page (level 2)', c.level === '2' && c.mainInDom === true && c.mainVisible === true, c)

  await phone.goto(`${srv.base}/channel/lobby?topic=${TASK}`, { waitUntil: 'networkidle2' })
  await sleep(1500)
  c = await census(phone)
  ok('390px ?topic= opens the topic and keeps the page mounted', c.level === '3' && c.topicVisible === true && c.mainInDom === true && c.mainVisible === false, c)
  await phone.close()

  const desk = await browser.newPage()
  desk.setDefaultNavigationTimeout(NAV_TIMEOUT)
  await desk.setViewport({ width: 1440, height: 900 })
  await desk.goto(`${srv.base}/`, { waitUntil: 'networkidle2' })
  await desk.waitForSelector('.spool-shell > .spool-main', { visible: true })
  await sleep(800)
  c = await census(desk)
  ok('1440px / still mounts the middle pane', c.mainInDom === true && c.mainVisible === true && c.mainNodes > 0, c)
  await desk.close()
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nphone-stack-mount: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
