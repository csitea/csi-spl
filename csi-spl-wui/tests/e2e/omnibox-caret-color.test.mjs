// Owner, t1 5b75590c (2026-10-03): "There is some kind of strange vertical
// black line in the Omni box on mobile", then "Could it be the case that this
// black line is actually the cursor". It was: the caret was never styled, so
// the browser drew the default solid text-colour bar.
//
// For the FOCUSED omnibox at phone 390x844, dark and light:
//   1 the textarea's computed caret-color equals the resolved --focus-ring
//     token (the colour the focused field's border uses)
//   CONTROL: before the fix it is the text colour (caret-color: auto
//   resolves to currentcolor), so 1 fails.
//
// Run:
//   pnpm run test:e2e omnibox-caret-color
//   BASE_URL=<generated bundle> pnpm run test:e2e omnibox-caret-color   # what CI does
//   SHOTS=<dir> ... also writes a screenshot per case there
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { join } from 'node:path'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const SHOTS = process.env.SHOTS || ''
if (SHOTS) mkdirSync(SHOTS, { recursive: true })
const MOCK_SESSION = { hum: 'HUM-1', name: 'Member', email: 'member@example.com', t: 'mock' }

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
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** Focus the visible omnibox textarea, then read its caret and text colours against --focus-ring. */
function caret(p) {
  return p.evaluate(() => {
    const vis = (el) => Boolean(el) && el.getClientRects().length > 0
    const f = [...document.querySelectorAll('form.composer.omnibox--global')].find(vis)
    const ta = f && f.querySelector('textarea')
    if (!ta) return null
    ta.focus()
    const probe = document.createElement('span')
    probe.style.color = 'var(--focus-ring)'
    document.body.appendChild(probe)
    const focusRing = getComputedStyle(probe).color
    probe.remove()
    const cs = getComputedStyle(ta)
    return { active: document.activeElement === ta, focusRing, caret: cs.caretColor, text: cs.color }
  })
}

async function check(browser, vp, theme, tag) {
  const p = await browser.newPage()
  const errors = []
  p.on('pageerror', (e) => errors.push(String(e).slice(0, 200)))
  await p.evaluateOnNewDocument((s, th) => {
    try {
      localStorage.setItem('spool.mock.session', JSON.stringify(s))
      localStorage.setItem('spool-theme', th)
    } catch { /* private mode */ }
  }, MOCK_SESSION, theme)
  await p.setViewport(vp)
  await p.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await p.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await p.waitForSelector('form.composer.omnibox--global textarea', { timeout: NAV_TIMEOUT })
  const r = await caret(p)
  if (SHOTS) await p.screenshot({ path: join(SHOTS, `omnibox-caret-color-${tag.replace(/ /g, '-')}.png`) })
  ok(`${tag} 1 the focused omnibox caret-color IS the --focus-ring token`,
    Boolean(r && r.active && r.focusRing && r.caret === r.focusRing && r.caret !== r.text), r)
  ok(`${tag} no page error`, errors.length === 0, errors)
  await p.close()
}

const server = await startServer()
const browser = await launch()
try {
  /* warm the dev server's chunks: a cold nuxi dev can fail the first dynamic import */
  const warm = await browser.newPage()
  await warm.goto(server.base + '/channel/alerts', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await warm.close()
  for (const theme of ['dark', 'light']) {
    await check(browser, { width: 390, height: 844, isMobile: true, hasTouch: true }, theme, `390 ${theme}`)
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length}` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
