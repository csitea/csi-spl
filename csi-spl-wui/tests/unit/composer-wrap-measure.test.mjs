// Perf round 19 row 02 (SPL-6654): the top-bar draft's one-line width comes
// from a canvas measureText, no longer from a hidden span read with
// getBoundingClientRect on every key (one forced layout per key). The width
// decides whether the draft lifts the glyph and the chip onto their own row
// (owner, t1 26282b6e), so the canvas must give what the span gave: within
// 1 px for every sample, in every fixture font below.
//
// The span half is the code row 02 replaced, verbatim; the canvas half is
// src/composables/useComposerWrap.ts's own `meterFont` + `meterWidth`,
// transpiled and run in the page. Headless Chrome, a page of its own (no
// bundle, no server); the e2e font config pins sans-serif to DejaVu Sans.
// No Chrome is a failure, never a skip.
//
// Run: node tests/unit/composer-wrap-measure.test.mjs
import { describe, it, before, after } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const FONTS = join(WUI, '../csi-spl-orc/src/bash/scripts/wui-e2e-fonts.conf')

/** meterFont + meterWidth of useComposerWrap.ts as a function body returning both. */
function canvasMeterSource() {
  const file = join(WUI, 'src/composables/useComposerWrap.ts')
  const js = ts.transpileModule(readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
    fileName: file,
  }).outputText
  /* the module's other functions are declarations only: their auto-imported
     vue helpers are never called here */
  const body = js.replace(/^import .*$/gm, '').replace(/^export /gm, '')
  return `${body}\nreturn { meterFont, meterWidth }`
}

async function launch() {
  const require = createRequire(import.meta.url)
  const mod = await import(pathToFileURL(require.resolve(process.env.PUPPETEER_CORE || 'puppeteer-core')).href)
  const puppeteer = mod.default ?? mod
  return puppeteer.launch({
    executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu', '--force-device-scale-factor=1'],
    env: { ...process.env, ...(existsSync(FONTS) && !process.env.FONTCONFIG_FILE ? { FONTCONFIG_FILE: FONTS } : {}) },
  })
}

/* the field's font as the top bar can have it, plus spacings the field does
   not set today, so a change there cannot slip past the check */
const FONTS_CASES = [
  { name: 'sans 15px', css: 'font: 15px sans-serif' },
  { name: 'DejaVu bold italic 17px', css: "font: italic 700 17px 'DejaVu Sans', sans-serif" },
  { name: 'serif 13.5px', css: 'font: 13.5px serif' },
  { name: 'mono 14px', css: 'font: 14px monospace' },
  { name: 'letter-spacing 0.05em', css: 'font: 15px sans-serif; letter-spacing: 0.05em' },
  { name: 'word-spacing 3px', css: 'font: 15px sans-serif; word-spacing: 3px' },
]
const SAMPLES = [
  'the quick brown fox jumps over a lazy do',
  'Hello, World! 1234567890 ()[]{}<>?/\\|',
  '  leading and trailing spaces  ',
  'Ünïcödé àçcénts: Öl, Straße, café, naïve',
  'Кирилица: всяка жаба да си знае гьола',
  'a'.repeat(120),
  ' and then some more words'.repeat(12),
  'W'.repeat(60) + 'i'.repeat(60),
  'tab-free  double  spaces  and no-break spaces',
]

describe('useComposerWrap: the canvas draft width equals the old span width (owner t1 26282b6e)', () => {
  let browser
  let page
  before(async () => {
    browser = await launch()
    page = await browser.newPage()
    await page.setContent('<!doctype html><html><body><textarea id="field"></textarea></body></html>')
  })
  after(async () => { await browser?.close() })

  for (const fc of FONTS_CASES) {
    it(`${fc.name}: every sample within 1 px`, async () => {
      const rows = await page.evaluate((css, samples, src) => {
        const el = document.getElementById('field')
        el.style.cssText = css
        /* the old useDraftMeter.draftWidth, as row 02 found it */
        const span = document.createElement('span')
        span.setAttribute('aria-hidden', 'true')
        span.style.cssText = 'position:fixed;inset-inline-start:0;top:0;visibility:hidden;white-space:pre;pointer-events:none;'
        document.body.appendChild(span)
        const spanWidth = (value) => {
          const cs = getComputedStyle(el)
          span.style.fontStyle = cs.fontStyle
          span.style.fontWeight = cs.fontWeight
          span.style.fontSize = cs.fontSize
          span.style.fontFamily = cs.fontFamily
          span.style.letterSpacing = cs.letterSpacing
          span.style.wordSpacing = cs.wordSpacing
          span.textContent = value
          return span.getBoundingClientRect().width
        }
        const { meterFont, meterWidth } = new Function(src)()
        const ctx = document.createElement('canvas').getContext('2d')
        const f = meterFont(getComputedStyle(el))
        const out = samples.map((s) => ({ s: s.slice(0, 24), span: spanWidth(s), canvas: meterWidth(ctx, f, s) }))
        span.remove()
        return out
      }, fc.css, SAMPLES, canvasMeterSource())
      const off = rows.filter((r) => !(Math.abs(r.canvas - r.span) <= 1))
      for (const r of rows) assert.ok(r.span > 0, `${fc.name}: the span measured 0 for "${r.s}"`)
      assert.deepEqual(off, [], `${fc.name}: canvas vs span differ by more than 1 px`)
    })
  }
})
