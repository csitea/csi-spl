// SPL-2083: Monitoring -> Boxes rows must left-align in one column on phone.
// At 412x915 (phone), every row's icon left edge must be equal (max-min <= 1 px),
// and the name must start at the same x on every row. No horizontal scroll.
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e monitoring-boxes-align
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { join } from 'node:path'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS, applyViewport, setPageViewport } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOT_DIR = process.env.SHOT_DIR || ''
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

/** Icon left edge and name start x for every visible row */
const rowPositions = async (p) => {
  return p.evaluate(() => {
    const rows = Array.from(document.querySelectorAll('[data-test=monitoring-box] .nav-row > .nav-item'))
    return rows.map((row) => {
      const icon = row.querySelector('svg')
      const label = row.querySelector('.label')
      if (!icon || !label) return null
      const iconRect = icon.getBoundingClientRect()
      const labelRect = label.getBoundingClientRect()
      return {
        iconLeft: Math.round(iconRect.left),
        labelLeft: Math.round(labelRect.left),
      }
    }).filter(Boolean)
  })
}

const noXScroll = (p) => p.evaluate(() => document.scrollingElement.scrollWidth <= window.innerWidth + 1)

async function shot(p, name) {
  if (!SHOT_DIR) return
  mkdirSync(SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(SHOT_DIR, name + '.png') })
}

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) {
    console.log(`-- 412x915 ${theme} (phone)`)
    const vp = { width: 412, height: 915 }
    const p = await browser.newPage()
    await setPageViewport(p, vp)
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/monitoring/boxes', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    await applyViewport(p, vp)
    await sleep(600) // Wait for layout

    const positions = await rowPositions(p)
    const iconLefts = positions.map((pos) => pos.iconLeft)
    const labelLefts = positions.map((pos) => pos.labelLeft)
    const iconMin = Math.min(...iconLefts)
    const iconMax = Math.max(...iconLefts)
    const labelMin = Math.min(...labelLefts)
    const labelMax = Math.max(...labelLefts)

    ok(`${theme}: at least 4 rows visible`, positions.length >= 4, { rows: positions.length })
    ok(`${theme}: every row's icon left edge is equal (max-min <= 1 px)`, (iconMax - iconMin) <= 1, { iconMin, iconMax })
    ok(`${theme}: every row's name starts at the same x`, (labelMax - labelMin) <= 1, { labelMin, labelMax })
    ok(`${theme}: no horizontal page scroll`, await noXScroll(p))
    await shot(p, `monitoring-boxes-align-412-${theme}`)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} passed`)
process.exit(failed.length ? 1 : 0)
