// GRK-3376: every visible rectangular surface has a non-zero corner radius,
// and every selected/active marker is one colour and at most 3px wide.
//
// Computed styles in headless Chrome — not a CSS-source grep.
//
//   node tests/e2e/rounded-corners.test.mjs
//   BASE_URL=http://127.0.0.1:3000 OUT=/var/tmp/GRK-3376-proof PHASE=before \
//     node tests/e2e/rounded-corners.test.mjs
//
// PHASE=before: the run is expected to FAIL on today's sharp corners; exit 1
// still means the assertion did its job. PHASE=after (default): exit 0 only
// when the sweep is clean.
import { writeFileSync, mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { INVENTORY_JS } from './lib/rounded-inventory.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const OUT = process.env.OUT || '/var/tmp/GRK-3376-proof'
const PHASE = process.env.PHASE || 'after'
const CHROME = process.env.CHROME_PATH || '/usr/bin/google-chrome'
mkdirSync(OUT, { recursive: true })

const VIEWPORTS = [
  { name: 'desktop', width: 1280, height: 800 },
  { name: 'mobile', width: 390, height: 844 },
]
const PATHS = [
  { path: '/login', wait: '.login-card', open: 'lang' },
  { path: '/lobby', wait: '.spool-shell', open: 'none' },
  { path: '/search?q=deploy', wait: '.search-page', open: 'none' },
  { path: '/settings/profile', wait: '[data-test=settings]', open: 'none' },
  { path: '/channel/lobby', wait: '.spool-shell', open: 'none' },
]

async function loadPuppeteer() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      let href = spec
      if (!spec.startsWith('file:') && !spec.includes('://')) {
        try { href = pathToFileURL(require.resolve(spec)).href }
        catch { if (spec.startsWith('/')) href = pathToFileURL(spec).href }
      }
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      if (typeof puppeteer.launch === 'function') return puppeteer
    } catch { /* next */ }
  }
  throw new Error('puppeteer-core not resolvable')
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const report = {
  phase: PHASE,
  at: new Date().toISOString(),
  scale: {
    '--radius / --radius-sm': '8px (the value the app already used most)',
    '--radius-md': '12px (cards, dialogs, composer, menus)',
    '--radius-lg': '16px',
    '--radius-pill': '999px',
  },
  pages: [],
  sharp: [],
  selectedViolations: [],
}

let failed = 0

function noteSharp(page, items) {
  for (const it of items) {
    report.sharp.push({ page, ...it })
    console.log(`  SHARP ${page} ${it.sel} r=${it.radius} ${it.w}x${it.h}`)
  }
}

function noteSelected(page, items) {
  for (const it of items) {
    const unique = [...new Set(it.colors)]
    const badWidth = it.width > 3
    const badColor = unique.length > 1
    if (badWidth || badColor) {
      report.selectedViolations.push({ page, ...it, unique })
      console.log(`  SELECT ${page} ${it.sel} width=${it.width} colors=${JSON.stringify(unique)}`)
      failed++
    }
  }
}

const puppeteer = await loadPuppeteer()
const server = await startServer()
const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
})

try {
  const page = await browser.newPage()
  for (const theme of ['dark', 'light']) {
    for (const vp of VIEWPORTS) {
      await page.setViewport({ width: vp.width, height: vp.height })
      for (const route of PATHS) {
        const url = server.base + route.path
        const label = `${theme}-${vp.name}-${route.path.replace(/[/?=]/g, '_')}`
        await page.goto(url, { waitUntil: 'networkidle2', timeout: 45000 })
        await page.waitForSelector(route.wait, { timeout: 20000 })
        await page.evaluate((t) => {
          document.documentElement.setAttribute('data-theme', t)
          try { localStorage.setItem('spool-theme', t) } catch { /* */ }
        }, theme)
        await sleep(120)
        if (route.open === 'lang') {
          const btn = await page.$('[data-test=lang-switcher-button]')
          if (btn) {
            await btn.click()
            await page.waitForSelector('[data-test=lang-switcher-options]', { timeout: 4000 }).catch(() => {})
            await sleep(80)
          }
        }
        const shot = join(OUT, `${PHASE}-${label}.png`)
        await page.screenshot({ path: shot, fullPage: false })
        const inv = await page.evaluate(INVENTORY_JS)
        inv.screenshot = shot
        report.pages.push({ label, href: inv.href, theme: inv.theme, viewport: inv.viewport, sharpCount: inv.sharpCount, okCount: inv.okCount, selected: inv.selected.length })
        if (inv.sharpCount) {
          failed += inv.sharpCount
          noteSharp(label, inv.sharp)
        } else {
          console.log(`  OK    ${label} surfaces=${inv.okCount}`)
        }
        noteSelected(label, inv.selected)
        if (route.open === 'lang') {
          await page.keyboard.press('Escape').catch(() => {})
        }
      }
    }
  }
} finally {
  await browser.close().catch(() => {})
  await server.stop()
}

writeFileSync(join(OUT, `${PHASE}-inventory.json`), JSON.stringify(report, null, 2))
console.log(`\nphase=${PHASE} sharp=${report.sharp.length} selectedViolations=${report.selectedViolations.length}`)
console.log(`wrote ${join(OUT, PHASE + '-inventory.json')}`)

if (PHASE === 'before') {
  if (report.sharp.length === 0) {
    console.error('BEFORE proof did not fail: expected sharp corners on today\'s code')
    process.exit(1)
  }
  console.log('BEFORE proof failed as required (sharp corners present)')
  process.exit(1)
}

if (failed) {
  console.error(`FAIL: ${failed} rounded-corner / selected-border assertion(s)`)
  process.exit(1)
}
console.log('PASS rounded-corners')
