// perf round 4 W5: the phone keyboard inset rides the tab's ONE passive,
// rAF-coalesced viewport source (utils/viewport-resize.mjs).
//
// On a 390x844 phone (mock tenant) it checks:
//   listeners  window + visualViewport resize/scroll from useKeyboardInset are
//              passive: none of the three it used to add actively remains
//   timing     a simulated keyboard (visualViewport.height shrunk by 300 px,
//              then a burst of vv resize + scroll events) sets --kb-inset to
//              300px BEFORE that frame paints - a rAF queued after the burst
//              already reads it - and closing the keyboard sets 0px again
//   coalesced  the burst runs `apply` once (one setProperty for the burst)
//
//   pnpm run test:e2e kb-inset
//   BASE_URL=<generated bundle> pnpm run test:e2e kb-inset
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const KB = 300

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
      return puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: CHROME_LAUNCH_ARGS })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const server = await startServer()
const browser = await launch()
let crashed = false
try {
  const page = await browser.newPage()
  await page.setViewport({ width: 390, height: 844, hasTouch: true, isMobile: true })
  await page.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await page.waitForFunction(() => document.documentElement.style.getPropertyValue('--kb-inset') !== '', { timeout: 15000 })
  await new Promise((r) => setTimeout(r, 300))

  const cdp = await page.createCDPSession()
  const listeners = async (expr) => {
    const { result } = await cdp.send('Runtime.evaluate', { expression: expr })
    const { listeners: ls } = await cdp.send('DOMDebugger.getEventListeners', { objectId: result.objectId })
    return ls.filter((l) => l.type === 'resize' || l.type === 'scroll')
  }
  const vv = await listeners('window.visualViewport')
  ok('visualViewport resize + scroll: one passive listener each', vv.length === 2 && vv.every((l) => l.passive), vv.map((l) => `${l.type}:${l.passive}`))

  const r = await page.evaluate(async (kb) => {
    const root = document.documentElement
    const proto = Object.getPrototypeOf(window.visualViewport)
    const real = Object.getOwnPropertyDescriptor(proto, 'height')
    let sets = 0
    const style = root.style
    const set = style.setProperty.bind(style)
    style.setProperty = (k, v, p) => { if (k === '--kb-inset') sets++; return set(k, v, p) }
    const burst = () => {
      for (let i = 0; i < 6; i++) {
        window.visualViewport.dispatchEvent(new Event('resize'))
        window.visualViewport.dispatchEvent(new Event('scroll'))
      }
    }
    const nextFrame = () => new Promise((res) => requestAnimationFrame(() => res(root.style.getPropertyValue('--kb-inset'))))
    const before = root.style.getPropertyValue('--kb-inset')
    Object.defineProperty(proto, 'height', { configurable: true, get() { return window.innerHeight - kb } })
    burst()
    const sync = root.style.getPropertyValue('--kb-inset')
    const open = await nextFrame()
    const openSets = sets
    Object.defineProperty(proto, 'height', real)
    burst()
    const closed = await nextFrame()
    style.setProperty = set
    return { before, sync, open, openSets, closed }
  }, KB)
  ok('--kb-inset starts at 0px', r.before === '0px', r.before)
  ok('the event handler itself does no layout read (applied in the frame)', r.sync === '0px', r.sync)
  ok(`keyboard open: --kb-inset ${KB}px before the frame paints`, r.open === `${KB}px`, r.open)
  ok('a 12-event burst runs apply once', r.openSets === 1, r.openSets)
  ok('keyboard closed: --kb-inset back to 0px', r.closed === '0px', r.closed)
  await page.close()
} catch (e) {
  crashed = true
  console.error(e)
} finally {
  await browser.close()
  await server.stop()
}
const bad = results.filter((x) => !x.ok)
console.log(`kb-inset: ${results.length - bad.length}/${results.length} OK`)
process.exit(crashed || bad.length || !results.length ? 1 : 0)
