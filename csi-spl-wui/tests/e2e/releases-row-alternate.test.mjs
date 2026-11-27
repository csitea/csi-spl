// SPL-6611 (owner HUM-10, t1 25970d1c, msg 35543c11: "this table listing
// must have as any other one alternating colors"): the Reporting > Releases
// commit rows of a day alternate like every other list (SPL-2120). On
// /reporting/releases against the mock bundle, in the dark and the light
// theme, at 1440x900 and 390x844:
//   S1 row 2 of the day with the most commits paints a different background
//      than row 1, and it is the house --color-row-alt veil;
//   S2 row 3 paints like row 1 (the shading alternates, it does not run on);
//   S3 desktop: a hovered shaded row shows --color-surface-hover over the
//      shading, and so does an opened one (the first shaded row with notes:
//      the mock leaves every 5th commit bare, so a fixed row 2 had no toggle at
//      UTC hours 4, 9, 14 and 19, SPL-6703).
// CONTROL: origin/master fea2cc504 (no alternate-row rule) fails S1 at every size
// and theme (row 1 and row 2 paint the same background).
//
// Run:
//   BASE_URL=<generated bundle> pnpm run test:e2e releases-row-alternate
//   SHOT_DIR=<dir> keeps a screenshot per size and theme.
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
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

const SIZES = [
  { width: 1440, height: 900, touch: false, desktop: true },
  { width: 390, height: 844, touch: true },
]

async function page(browser, base, { width, height, touch }, theme) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width, height, isMobile: touch, hasTouch: touch })
  await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
  await p.goto(base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.evaluate(() => {
    localStorage.setItem('spool.mock.session', JSON.stringify({ hum: 'HUM-1', name: 'Admin', email: 'admin@example.com', t: 'mock' }))
    localStorage.setItem('spool.mock.me', JSON.stringify({ role: 'admin', permissions: [] }))
  })
  await p.goto(base + '/reporting/releases', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('[data-test=releases-commit]', { visible: true, timeout: 20000 })
  return { ctx, p }
}

/** The first three rows of the day with the most commits (the mock days
 *  count back from now, so just after 00:00 UTC the first day holds one),
 *  their painted backgrounds and the tokens, resolved the same way. The
 *  first shaded (even) row that has notes to open is tagged
 *  data-alt-probe-open for S3. */
function measure() {
  const days = [...document.querySelectorAll('[data-test=releases-day]')]
  const rowsOf = (d) => [...d.querySelectorAll('[data-test=releases-commit]')]
  const rows = days.map(rowsOf).sort((a, b) => b.length - a.length)[0] || []
  rows.slice(0, 3).forEach((r, i) => r.setAttribute('data-alt-probe', String(i + 1)))
  const openIdx = rows.findIndex((r, i) => i % 2 === 1 && r.querySelector('[data-test=releases-commit-toggle]'))
  if (openIdx >= 0) rows[openIdx].setAttribute('data-alt-probe-open', String(openIdx + 1))
  const resolve = (token) => {
    const probe = document.createElement('div')
    probe.style.background = `var(${token})`
    rows[0]?.parentElement?.appendChild(probe)
    const bg = getComputedStyle(probe).backgroundColor
    probe.remove()
    return bg
  }
  return {
    theme: document.documentElement.getAttribute('data-theme'),
    n: rows.length,
    bgs: rows.slice(0, 3).map((r) => getComputedStyle(r).backgroundColor),
    rowAlt: resolve('--color-row-alt'),
    hover: resolve('--color-surface-hover'),
    openRow: openIdx + 1,
  }
}

const bgOf = (p, sel) => p.$eval(sel, (r) => getComputedStyle(r).backgroundColor)
/** The row's background once it reads `want`, or what it reads after 3 s:
 *  the row fades its background (transition 0.12s), so a read right after
 *  the hover or the click lands mid-fade. */
const settledBg = async (p, sel, want) => {
  await p.waitForFunction((s, w) => getComputedStyle(document.querySelector(s)).backgroundColor === w,
    { timeout: 3000 }, sel, want).catch(() => {})
  return bgOf(p, sel)
}

const server = await startServer()
const browser = await launch()
let code = 0
try {
  for (const theme of ['dark', 'light']) {
    for (const size of SIZES) {
      const tag = `${size.width}px ${theme}`
      const { ctx, p } = await page(browser, server.base, size, theme)
      const m = await p.evaluate(measure)
      console.log(`  measure ${tag}: ${JSON.stringify(m)}`)
      ok(`S0 ${tag}: the theme is ${theme} and a day has 3+ commits`, String(m.theme).startsWith(theme) && m.n >= 3, [m.theme, m.n])
      ok(`S1 ${tag}: row 2 paints a different background than row 1`, m.bgs[1] !== undefined && m.bgs[1] !== m.bgs[0], m.bgs.slice(0, 2))
      ok(`S1 ${tag}: row 2 is the --color-row-alt veil`, m.bgs[1] === m.rowAlt, [m.bgs[1], m.rowAlt])
      ok(`S2 ${tag}: row 3 paints like row 1`, m.bgs[2] !== undefined && m.bgs[2] === m.bgs[0], [m.bgs[0], m.bgs[2]])
      if (process.env.SHOT_DIR) await p.screenshot({ path: `${process.env.SHOT_DIR}/releases-alternate-${size.width}-${theme}.png` })
      if (size.desktop && m.n >= 2) {
        await p.hover('[data-alt-probe="2"] [data-test=releases-commit-subject]')
        const hovered = await settledBg(p, '[data-alt-probe="2"]', m.hover)
        ok(`S3 ${tag}: a hovered shaded row shows the hover fill`, hovered === m.hover && hovered !== m.rowAlt, [hovered, m.hover])
        const openSel = `[data-alt-probe-open="${m.openRow}"]`
        const toggle = m.openRow ? await p.$(`${openSel} [data-test=releases-commit-toggle]`) : null
        if (toggle) {
          await toggle.click()
          await p.mouse.move(0, 0)
          await p.waitForSelector(`${openSel} [data-test=releases-commit-notes]`, { visible: true, timeout: 5000 })
          const opened = await settledBg(p, openSel, m.hover)
          ok(`S3 ${tag}: an opened shaded row (row ${m.openRow}) shows the open fill`, opened === m.hover, [opened, m.hover])
        } else ok(`S3 ${tag}: a shaded row has notes to open`, false)
      }
      await ctx.close()
    }
  }
} catch (e) {
  console.error(e)
  code = 1
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((r) => !r.ok)
console.log(`\nreleases-row-alternate: ${results.length - failed.length}/${results.length} passed`)
process.exit(code || (failed.length || !results.length ? 1 : 0))
