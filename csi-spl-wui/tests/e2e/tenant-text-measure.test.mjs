// W4 (perf round 4, round-3 P3-07): measureControlText draws no probe span
// any more - one canvas measureText in the control's computed font. This
// proves, in a real browser, that the canvas width stays within
// TENANT_TEXT_PAD_PX of the probe-span width it replaced (the pad absorbs
// sub-pixel canvas/DOM differences), for the drop box's own labels and a
// spread of scripts, in the select's font and with spacing/transform set.
// It also proves the measure adds nothing to the DOM.
//
// Run:
//   pnpm run test:e2e tenant-text-measure
//   BASE_URL=<generated bundle> pnpm run test:e2e tenant-text-measure
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'
import { pathToFileURL, fileURLToPath } from 'node:url'
import { startServer } from './lib/server.mjs'
import { setPageViewport, applyViewport, CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { TENANT_TEXT_PAD_PX } from '../../src/utils/tenant-switcher.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const VP = { name: '1280x800', width: 1280, height: 800 }
const SRC = readFileSync(fileURLToPath(new URL('../../src/utils/tenant-switcher.mjs', import.meta.url)), 'utf8')
const SAMPLES = [
  'csitea', 'e2e', 'Tenant', 'Acme Widgets International', 'WWWWWWWWWWWW', 'iiiiiiiiiiii',
  'AVATAR Wave Tokyo', 'Ünïcödé Ätelier', 'Ελληνικά', 'Кириллица', '日本語テナント', 'a b  c', ' lead', 'trail ', '',
]
const STYLES = [
  { name: 'select font', css: {} },
  { name: 'letter-spacing 0.5px', css: { letterSpacing: '0.5px' } },
  { name: 'word-spacing 3px', css: { wordSpacing: '3px' } },
  { name: 'uppercase', css: { textTransform: 'uppercase' } },
  { name: 'bold italic', css: { fontWeight: '700', fontStyle: 'italic' } },
]

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

const server = await startServer()
const browser = await launch()
try {
  const p = await browser.newPage()
  await p.setBypassCSP(true)
  await setPageViewport(p, VP)
  await p.goto(server.base + '/lobby', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await applyViewport(p, VP)
  await p.waitForSelector('[data-testid=tenant-switcher-select]', { timeout: NAV_TIMEOUT })
  await p.addScriptTag({ type: 'module', content: SRC + '\nwindow.__w4 = { measureControlText, measureControlTextProbe }\n' })
  await p.waitForFunction(() => !!window.__w4, { timeout: NAV_TIMEOUT })
  const out = await p.evaluate((samples, styles) => {
    const { measureControlText, measureControlTextProbe } = window.__w4
    const sel = document.querySelector('[data-testid=tenant-switcher-select]')
    const labels = [...document.querySelectorAll('[data-testid=tenant-switcher-option]')].map((o) => o.textContent || '')
    if (sel instanceof HTMLInputElement) labels.push(sel.value, sel.placeholder)
    const rows = []
    for (const st of styles) {
      const el = document.createElement('input')
      el.className = sel.className
      sel.parentElement.appendChild(el)
      Object.assign(el.style, st.css)
      const target = Object.keys(st.css).length ? el : sel
      for (const text of [...labels, ...samples]) {
        const nodesBefore = document.getElementsByTagName('*').length
        const canvas = measureControlText(target, text)
        const nodesAfter = document.getElementsByTagName('*').length
        const probe = measureControlTextProbe(target, text)
        rows.push({ style: st.name, text, canvas, probe, diff: Math.abs(canvas - probe), addedNodes: nodesAfter - nodesBefore })
      }
      el.remove()
    }
    return { font: getComputedStyle(sel).font, labels, rows }
  }, SAMPLES, STYLES)
  ok('the select carries its tenant labels', out.labels.some((l) => l.length > 0), { labels: out.labels, font: out.font })
  for (const r of out.rows) {
    ok(`${r.style} "${r.text}" canvas within ${TENANT_TEXT_PAD_PX}px of the probe`,
      Number.isFinite(r.canvas) && Number.isFinite(r.probe) && r.diff <= TENANT_TEXT_PAD_PX,
      { canvas: +r.canvas.toFixed(3), probe: +r.probe.toFixed(3), diff: +r.diff.toFixed(3) })
  }
  const maxDiff = Math.max(...out.rows.map((r) => r.diff))
  ok('canvas measure adds no node to the DOM', out.rows.every((r) => r.addedNodes === 0), { maxDiff: +maxDiff.toFixed(3) })
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(failed.length ? `FAIL: ${failed.length}/${results.length} checks failed` : `${results.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
