// Row 08 of ui-animations-panel-plan.md (SPL-2795, epic SPL-2403): in
// Settings -> Appearance -> Thinking animation, ticking a drawing pops an
// accent ring round its sample once; unticking plays nothing.
//
//   • the change handler calls playTapAnim(<the ring>, 'pop') only on a tick
//     the list accepts (on, and the set changed), never on an untick
//   • the ring holds no svg, so the pop class goes on the ring itself and
//     comes off on animationend; 0 classes under prefers-reduced-motion
//   • transform and opacity only, 0 px layout shift: the ring is absolute
//     over a relative box, its keyframes move transform and opacity, it ends
//     unseen (opacity 0), and the keyframe name keeps the tap- prefix that
//     useTapAnim's animationend handler matches
//
// Run: node --test tests/unit/await-anim-preview.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const SFC = readFileSync(join(WUI, 'src/components/AwaitAnimSetting.vue'), 'utf8')
const TEMPLATE = SFC.slice(0, SFC.indexOf('<script'))
const SCRIPT = SFC.slice(SFC.indexOf('<script'), SFC.indexOf('</script>'))
const STYLE = SFC.slice(SFC.indexOf('<style'))

/** useTapAnim.ts transpiled to a temp .mjs, then imported */
async function load() {
  const tmp = mkdtempSync(join(tmpdir(), 'await-anim-preview-'))
  try {
    const src = readFileSync(join(WUI, 'src/composables/useTapAnim.ts'), 'utf8')
    const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
    writeFileSync(join(tmp, 'useTapAnim.mjs'), js)
    return await import(pathToFileURL(join(tmp, 'useTapAnim.mjs')).href)
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}

/** the ring: classList and listeners, no svg inside */
function fakeRing() {
  const classes = new Set()
  const listeners = {}
  const el = {
    classes,
    classList: {
      add: (...c) => c.forEach((x) => classes.add(x)),
      remove: (...c) => c.forEach((x) => classes.delete(x)),
      contains: (c) => classes.has(c),
    },
    get offsetWidth() { return 10 },
    querySelector: () => null,
    addEventListener: (t, f) => { (listeners[t] ||= new Set()).add(f) },
    removeEventListener: (t, f) => { listeners[t]?.delete(f) },
    fire(type, animationName) {
      for (const f of listeners[type] || []) f({ type, animationName, target: el })
    },
  }
  return el
}

function withMotion(reduce, fn) {
  const prev = globalThis.matchMedia
  globalThis.matchMedia = (q) => ({ matches: reduce && q.includes('reduce') })
  try { return fn() } finally { globalThis.matchMedia = prev }
}

/** the text of `function <name>(...) { ... }` in the component's script */
function fnBody(name) {
  const at = SCRIPT.search(new RegExp(`function ${name}\\s*\\(`))
  assert.ok(at >= 0, `function ${name} in AwaitAnimSetting.vue`)
  return SCRIPT.slice(at, SCRIPT.indexOf('\n}', at))
}

/** the declarations of the first `<sel> { ... }` rule in the style */
function rule(sel) {
  const m = STYLE.match(new RegExp(`(?:^|\\n)${sel}\\s*\\{([^}]*)\\}`))
  assert.ok(m, `rule ${sel}`)
  return m[1]
}

const mod = await load()

describe('AwaitAnimSetting: a tick pops the sample ring', () => {
  it('imports playTapAnim from useTapAnim', () => {
    assert.match(SCRIPT, /import\s*\{[^}]*\bplayTapAnim\b[^}]*\}\s*from\s*'~\/composables\/useTapAnim'/)
  })

  it('every sample sits in a box with one ring that holds no svg', () => {
    const box = TEMPLATE.match(/<span class="await-anim-setting__preview">([\s\S]*?)<\/span>\s*<span>/)
    assert.ok(box, 'the preview box round LazyAwaitReply')
    assert.match(box[1], /<LazyAwaitReply\b/)
    const ring = box[1].match(/<span class="await-anim-setting__ring"[^>]*\/>/)
    assert.ok(ring, 'the ring, an empty span')
    assert.match(ring[0], /aria-hidden="true"/)
  })

  it("the box's change passes the event to toggle, which pops only on a tick", () => {
    const change = TEMPLATE.match(/@change="toggle\(id,[^"]*\$event\)"/)
    assert.ok(change, 'toggle(id, checked, $event)')
    const body = fnBody('toggle')
    const guard = body.indexOf('if (next === set.value) return')
    const pop = body.search(/if \(on\) popRing\(/)
    assert.ok(guard >= 0 && pop > guard, 'a refused or no-op toggle returns before the pop')
    assert.doesNotMatch(body.replace(/if \(on\) popRing\([^)]*\)/, ''), /popRing|playTapAnim/, 'no other pop path: an untick plays nothing')
  })

  it("popRing plays 'pop' on the ring of the same label", () => {
    const body = fnBody('popRing')
    assert.match(body, /closest\('label'\)/)
    assert.match(body, /querySelector\('\.await-anim-setting__ring'\)/)
    assert.match(body, /playTapAnim\(ring,\s*'pop'\)/)
  })
})

describe('playTapAnim on the ring', () => {
  it('adds tap-anim tap-anim--pop on the ring and removes them on animationend', () => withMotion(false, () => {
    const el = fakeRing()
    mod.playTapAnim(el, 'pop')
    assert.deepEqual([...el.classes].sort(), ['tap-anim', 'tap-anim--pop'])
    el.fire('animationend', 'tap-await-ring-data-v-1a2b3c')
    assert.equal(el.classes.size, 0)
  }))

  it('adds 0 classes under prefers-reduced-motion', () => withMotion(true, () => {
    const el = fakeRing()
    mod.playTapAnim(el, 'pop')
    assert.equal(el.classes.size, 0)
  }))
})

describe('transform and opacity only, 0 px layout shift', () => {
  it('the ring is absolute over a relative box, unseen at rest, never a target', () => {
    assert.match(rule('\\.await-anim-setting__preview'), /position:\s*relative/)
    const ring = rule('\\.await-anim-setting__ring')
    assert.match(ring, /position:\s*absolute/)
    assert.match(ring, /opacity:\s*0;/)
    assert.match(ring, /pointer-events:\s*none/)
    assert.doesNotMatch(ring, /transition/)
  })

  it('a theme colour, one ring no wider than 3 px', () => {
    const m = rule('\\.await-anim-setting__ring').match(/border:\s*(\d+(?:\.\d+)?)px solid (var\(--[a-z-]+\))/)
    assert.ok(m, 'border: <n>px solid var(--token)')
    assert.ok(Number(m[1]) <= 3, `${m[1]}px <= 3px`)
  })

  it('the pop on the ring runs its own tap- keyframes, transform and opacity only, ending unseen', () => {
    const on = rule('\\.await-anim-setting__ring\\.tap-anim--pop')
    const name = on.match(/animation-name:\s*([\w-]+)/)
    assert.ok(name, 'animation-name')
    assert.match(name[1], /^tap-/, 'the tap- prefix useTapAnim removes on')
    const kf = STYLE.match(new RegExp(`@keyframes ${name[1]}\\s*\\{((?:[^{}]*\\{[^}]*\\})*)\\s*\\}`))
    assert.ok(kf, `@keyframes ${name[1]}`)
    const props = new Set([...kf[1].matchAll(/([a-z-]+)\s*:/g)].map((m) => m[1]))
    assert.deepEqual([...props].sort(), ['opacity', 'transform'])
    assert.match(kf[1], /100%\s*\{\s*opacity:\s*0/, 'ends unseen')
  })

  it('no inline style (CSP)', () => {
    assert.doesNotMatch(TEMPLATE, /\s:?style=/)
    assert.doesNotMatch(TEMPLATE, /v-html/)
  })
})
