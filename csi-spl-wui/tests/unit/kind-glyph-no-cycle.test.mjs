// CLE-77804: KindBadge renders KindPicker (its popup) and KindPicker used to
// render the whole KindBadge for each option, so the two components imported
// each other. Nuxt auto-imports turn that into a static ES import cycle, and in
// the minified, code-split production build it crashed with
// `ReferenceError: Cannot access 'X' before initialization` (a temporal dead
// zone, journalled as source "vue"). The leaf KindGlyph carries the shared
// glyph so the graph is acyclic (KindBadge -> KindPicker -> KindGlyph). The
// build-time guard (nuxt.config onwarn) fails any app-code cycle; this cheap
// test locks THIS one so it cannot creep back before a full generate runs.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (f) => readFileSync(join(SRC, f), 'utf8')

describe('KindBadge / KindPicker no longer reference each other (no TDZ)', () => {
  it('KindPicker renders the KindGlyph leaf, not the whole KindBadge', () => {
    const s = read('components/KindPicker.vue')
    assert.match(s, /<KindGlyph\s+:kind="k"\s*\/>/)
    assert.doesNotMatch(s, /<KindBadge\b/)
  })
  it('KindGlyph is a leaf: it renders neither KindPicker nor KindBadge', () => {
    const s = read('components/KindGlyph.vue')
    assert.doesNotMatch(s, /<KindPicker\b/)
    assert.doesNotMatch(s, /<KindBadge\b/)
  })
  it('KindBadge still owns the popup: it renders KindPicker while open', () => {
    assert.match(read('components/KindBadge.vue'), /<KindPicker\s+v-if="settable && open"/)
  })
})
