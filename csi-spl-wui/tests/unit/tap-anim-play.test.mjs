// Row 01 of ui-animations-panel-plan.md (SPL-2479 panel, section 5): the new
// tap-anim motifs and the programmatic trigger playTapAnim(el, kind), which
// rows 02-08 call from lifecycle events (a copy, a badge, a reconnect ...).
//
//   • playTapAnim puts `tap-anim tap-anim--<kind>` on the element's icon and
//     takes both off on animationend / animationcancel
//   • a second call while it runs restarts it (classes off, reflow, back on)
//   • under prefers-reduced-motion it adds no class at all
//   • every new kind has its class and keyframes in tap-anim.css, which keeps
//     to transform and opacity and stays under 1600 B gzipped
//
// Run: node tests/unit/tap-anim-play.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { gzipSync } from 'node:zlib'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const CSS = readFileSync(join(WUI, 'src/assets/css/tap-anim.css'), 'utf8')
const NEW_KINDS = ['draw', 'swell', 'ripple', 'greeting', 'settle']

/** useTapAnim.ts transpiled to a temp .mjs, then imported */
async function load() {
  const tmp = mkdtempSync(join(tmpdir(), 'tap-anim-'))
  try {
    const src = readFileSync(join(WUI, 'src/composables/useTapAnim.ts'), 'utf8')
    const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
    writeFileSync(join(tmp, 'useTapAnim.mjs'), js)
    return await import(pathToFileURL(join(tmp, 'useTapAnim.mjs')).href)
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}

/** just enough of a DOM element: classList, listeners, a reflow counter */
function fakeEl(icon) {
  const classes = new Set()
  const listeners = {}
  const el = {
    reflows: 0,
    classList: {
      add: (...c) => c.forEach((x) => classes.add(x)),
      remove: (...c) => c.forEach((x) => classes.delete(x)),
      contains: (c) => classes.has(c),
    },
    classes,
    get offsetWidth() { el.reflows++; return 10 },
    querySelector: () => icon || null,
    addEventListener: (t, f) => { (listeners[t] ||= new Set()).add(f) },
    removeEventListener: (t, f) => { listeners[t]?.delete(f) },
    fire(type, animationName, target) {
      for (const f of listeners[type] || []) f({ type, animationName, target: target || el })
    },
  }
  return el
}

function withMotion(reduce, fn) {
  const prev = globalThis.matchMedia
  globalThis.matchMedia = (q) => ({ matches: reduce && q.includes('reduce') })
  try { return fn() } finally { globalThis.matchMedia = prev }
}

const mod = await load()

describe('playTapAnim', () => {
  it('is exported', () => {
    assert.equal(typeof mod.playTapAnim, 'function')
  })

  it('adds tap-anim tap-anim--draw and removes them on animationend', () => withMotion(false, () => {
    const el = fakeEl()
    mod.playTapAnim(el, 'draw')
    assert.deepEqual([...el.classes].sort(), ['tap-anim', 'tap-anim--draw'])
    el.fire('animationend', 'tap-draw')
    assert.equal(el.classes.size, 0)
  }))

  it('removes them on animationcancel too', () => withMotion(false, () => {
    const el = fakeEl()
    mod.playTapAnim(el, 'swell')
    el.fire('animationcancel', 'tap-swell')
    assert.equal(el.classes.size, 0)
  }))

  it("leaves classes alone on another animation's end", () => withMotion(false, () => {
    const el = fakeEl()
    mod.playTapAnim(el, 'settle')
    el.fire('animationend', 'spin')
    assert.ok(el.classes.has('tap-anim--settle'))
  }))

  it('plays on the icon (first svg) when the element has one', () => withMotion(false, () => {
    const icon = fakeEl()
    const el = fakeEl(icon)
    mod.playTapAnim(el, 'ripple')
    assert.deepEqual([...icon.classes].sort(), ['tap-anim', 'tap-anim--ripple'])
    assert.equal(el.classes.size, 0)
    el.fire('animationend', 'tap-ripple', icon)
    assert.equal(icon.classes.size, 0)
  }))

  it('a rapid second call restarts it with a reflow', () => withMotion(false, () => {
    const el = fakeEl()
    mod.playTapAnim(el, 'greeting')
    assert.equal(el.reflows, 0)
    mod.playTapAnim(el, 'draw')
    assert.equal(el.reflows, 1)
    assert.deepEqual([...el.classes].sort(), ['tap-anim', 'tap-anim--draw'])
  }))

  it('adds 0 classes under prefers-reduced-motion', () => withMotion(true, () => {
    const el = fakeEl()
    mod.playTapAnim(el, 'draw')
    assert.equal(el.classes.size, 0)
  }))
})

describe('tap-anim.css motifs', () => {
  it('lists every new kind in TAP_KINDS, keeping the SPL-2062 ones', () => {
    for (const k of [...NEW_KINDS, 'bounce', 'nudge', 'tilt']) assert.ok(mod.TAP_KINDS.includes(k), k)
  })

  for (const k of NEW_KINDS) {
    it(`has .tap-anim--${k} and @keyframes tap-${k}`, () => {
      assert.match(CSS, new RegExp(`\\.tap-anim--${k}\\s*\\{[^}]*animation-name:\\s*tap-${k}`))
      assert.match(CSS, new RegExp(`@keyframes tap-${k}\\s*\\{`))
    })
  }

  it('animates transform and opacity only', () => {
    const props = new Set()
    for (const m of CSS.matchAll(/@keyframes[^{]+\{((?:[^{}]*\{[^}]*\})*)\s*\}/g)) {
      for (const p of m[1].matchAll(/([a-z-]+)\s*:/g)) props.add(p[1])
    }
    assert.deepEqual([...props].sort(), ['opacity', 'transform'])
  })

  it('stays at most 1600 B gzipped', () => {
    const n = gzipSync(CSS, { level: 9 }).length
    assert.ok(n <= 1600, `${n} B`)
  })
})
