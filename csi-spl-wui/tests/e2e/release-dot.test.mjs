// Release-time test (owner 2026-10-01): a black dot mid-screen on mobile only.
//
// At 390x844 [data-test=release-dot] is visible, black, centred and lets taps
// through (pointer-events: none); at 1440x900 it is not displayed.
//
//   node tests/e2e/release-dot.test.mjs
//   BASE_URL=http://127.0.0.1:3000 node tests/e2e/release-dot.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const CHROME = process.env.CHROME_PATH || '/usr/bin/google-chrome'
const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 30000)

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  const mod = await import(pathToFileURL(require.resolve(process.env.PUPPETEER_CORE || 'puppeteer-core')).href)
  return mod.default ?? mod
}

const PROBE = `(() => {
  const el = document.querySelector('[data-test=release-dot]')
  if (!el) return { present: false }
  const cs = getComputedStyle(el)
  const r = el.getBoundingClientRect()
  return { present: true, display: cs.display, bg: cs.backgroundColor, pe: cs.pointerEvents,
    cx: r.left + r.width / 2, cy: r.top + r.height / 2, w: r.width, vw: innerWidth, vh: innerHeight }
})()`

let failed = 0
const check = (name, cond, extra) => {
  if (!cond) failed++
  console.log(`  ${cond ? 'OK  ' : 'FAIL'} ${name}${extra ? ' ' + extra : ''}`)
}

;(async () => {
  const puppeteer = await loadPuppeteer()
  const server = await startServer()
  console.log(`release-dot E2E against ${server.base}`)
  const browser = await puppeteer.launch({ executablePath: CHROME, headless: true, args: CHROME_LAUNCH_ARGS })
  try {
    const page = await browser.newPage()
    for (const vp of [{ width: 390, height: 844, mobile: true }, { width: 1440, height: 900, mobile: false }]) {
      await page.setViewport({ width: vp.width, height: vp.height, isMobile: vp.mobile, hasTouch: vp.mobile })
      await page.goto(`${server.base}/login`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
      await page.waitForSelector('[data-test=release-dot]', { timeout: NAV_TIMEOUT })
      const m = await page.evaluate(PROBE)
      const tag = `${vp.width}x${vp.height}`
      if (vp.mobile) {
        check(`${tag} dot shown`, m.display === 'block' && m.w >= 100, JSON.stringify(m))
        check(`${tag} dot black`, m.bg === 'rgb(0, 0, 0)')
        check(`${tag} dot centred`, Math.abs(m.cx - m.vw / 2) <= 2 && Math.abs(m.cy - m.vh / 2) <= 2)
        check(`${tag} dot lets taps through`, m.pe === 'none')
      } else {
        check(`${tag} dot hidden`, m.display === 'none', JSON.stringify(m))
      }
    }
  } finally {
    await browser.close().catch(() => {})
    await server.stop()
  }
  console.log(failed === 0 ? '\nrelease-dot: all checks passed' : `\nrelease-dot: ${failed} failed`)
  process.exit(failed === 0 ? 0 : 1)
})().catch((e) => { console.error(e); process.exit(1) })
