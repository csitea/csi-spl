// Row 07 of ui-animations-panel-plan.md (SPL-2794, epic SPL-2403): the undo
// snackbar - and every toast built on it - settles in when it mounts.
//
//   • the root carries row 01's `tap-anim tap-anim--settle`, so the CSS
//     animation runs once when the element is inserted; the callers key it by
//     item, so each new snackbar plays it once and nothing loops
//   • it is on the ROOT, not via playTapAnim(): that puts the class on the
//     first svg inside, which here is an icon, not the snackbar
//   • tap-settle moves only transform and opacity, and .tap-anim sets no box
//     property: 0 px layout shift
//   • the root is centred by margins, never by a transform the keyframes would
//     overwrite (a translateX(-50%) would jump it sideways while it plays)
//   • reduced motion: tap-anim.css stops every .tap-anim animation
//   • behaviour and timing unchanged: the timer, the holds, the outside tap
//
// Run: node --test tests/unit/undo-snackbar-anim.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const SFC = readFileSync(join(WUI, 'src/components/UndoSnackbar.vue'), 'utf8')
const CSS = readFileSync(join(WUI, 'src/assets/css/tap-anim.css'), 'utf8')
const TEMPLATE = SFC.slice(SFC.indexOf('<template>'), SFC.lastIndexOf('</template>'))
const SCRIPT = SFC.slice(SFC.indexOf('<script'), SFC.indexOf('</script>'))
const STYLE = SFC.slice(SFC.indexOf('<style'), SFC.indexOf('</style>'))
const BOX = /\b(width|height|margin|padding|top|left|right|bottom|inset|display|position|border|font|line-height)\s*:/

/** the root element's opening tag */
function rootTag() {
  const at = TEMPLATE.indexOf('<div')
  return TEMPLATE.slice(at, TEMPLATE.indexOf('>', TEMPLATE.indexOf('@keydown', at)) + 1)
}

/** every `.undo-snackbar { ... }` body in the style block (desktop + phone) */
function rootRules() {
  return [...STYLE.matchAll(/\.undo-snackbar\s*\{([^}]*)\}/g)].map((m) => m[1])
}

/** the body of `<selector> { ... }` or `@keyframes <name> { ... }` in tap-anim.css */
function block(head) {
  const at = CSS.indexOf(head)
  assert.ok(at >= 0, `${head} in tap-anim.css`)
  let depth = 0
  for (let i = CSS.indexOf('{', at); i < CSS.length; i++) {
    if (CSS[i] === '{') depth++
    else if (CSS[i] === '}' && --depth === 0) return CSS.slice(at, i + 1)
  }
  return ''
}

describe('row 07: the undo snackbar settles in on mount', () => {
  it('the root carries tap-anim tap-anim--settle', () => {
    const cls = rootTag().match(/\sclass="([^"]*)"/)
    assert.ok(cls, 'root has a static class')
    const list = cls[1].split(/\s+/)
    for (const c of ['undo-snackbar', 'tap-anim', 'tap-anim--settle']) {
      assert.ok(list.includes(c), `root class has ${c}: ${cls[1]}`)
    }
  })

  it('plays once: one keyed mount = one run, no loop, no timer', () => {
    assert.match(block('.tap-anim {'), /animation-iteration-count:\s*1\b/)
    assert.doesNotMatch(SFC, /infinite/)
    assert.doesNotMatch(SCRIPT, /playTapAnim|tap-anim/, 'no script side: the class plays on insertion')
    for (const f of ['ArchiveUndoToast', 'MoveUndoToast', 'DeleteUndoToast']) {
      const src = readFileSync(join(WUI, `src/components/${f}.vue`), 'utf8')
      assert.match(src, /<UndoSnackbar[^>]*:key=/s, `${f} keys the snackbar per item`)
    }
  })

  it('tap-settle moves only transform and opacity: rises and fades in', () => {
    assert.match(block('.tap-anim--settle'), /animation-name:\s*tap-settle/)
    const kf = block('@keyframes tap-settle')
    assert.match(kf, /0%\s*\{[^}]*translateY\(\d+px\)[^}]*opacity:\s*0/)
    for (const [, body] of kf.matchAll(/\{([^{}]*)\}/g)) {
      for (const decl of body.split(';').map((d) => d.trim()).filter(Boolean)) {
        assert.match(decl, /^(transform|opacity)\s*:/, `keyframe property: ${decl}`)
      }
    }
    assert.doesNotMatch(block('.tap-anim {'), BOX, '.tap-anim sets no box property')
  })

  it('0 px shift: the root is centred by margins, never by a transform', () => {
    const rules = rootRules()
    assert.ok(rules.length >= 2, 'desktop and phone root rules')
    for (const r of rules) assert.doesNotMatch(r, /transform\s*:/, 'no transform on .undo-snackbar')
    assert.match(rules[0], /left:\s*0/)
    assert.match(rules[0], /right:\s*0/)
    assert.match(rules[0], /margin-inline:\s*auto/)
    assert.match(rules[0], /width:\s*max-content/)
  })

  it('reduced motion: every .tap-anim animation stops', () => {
    const m = CSS.match(/@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{([\s\S]*?)\}\s*\}/)
    assert.ok(m, 'reduced-motion block in tap-anim.css')
    assert.match(m[1], /\.tap-anim\s*\{\s*animation:\s*none\s*!important/)
  })

  it('behaviour and timing unchanged; no inline style, no v-html', () => {
    for (const s of [
      'createUndoTimer({', 'duration: props.duration', 'touch: isTouchUi()',
      "onExpire: () => emit('dismiss')", 'clock.arm()', 'clock.stop()',
      "clock.hold('touch')", "clock.release('focus')", 'onOutsideTap(document',
    ]) assert.ok(SFC.includes(s), `keeps ${s}`)
    assert.doesNotMatch(TEMPLATE, /\s:?style=|v-html/)
  })
})
