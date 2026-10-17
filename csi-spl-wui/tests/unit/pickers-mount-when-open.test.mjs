// CLE-35075: the card's EmojiPicker and the kind badge's KindPicker are
// mounted only while open. A closed picker per card still registered a
// useMobileStack overlay (a watcher, plus a copy of the whole dockSheets
// array: O(N^2) for N cards), a document-level Teleport anchor and an `open`
// watcher. Mounted open, each picker must do its open work (outside-click
// listener, placement, focus) on mount, since `open` never changes then.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (f) => readFileSync(join(SRC, f), 'utf8')

describe('pickers mount only while open', () => {
  it('MessageCard mounts EmojiPicker behind v-if="pickerOpen" (lazy: its code loads on the first open, r13-01)', () => {
    assert.match(read('components/MessageCard.vue'), /<LazyEmojiPicker\s+v-if="pickerOpen"/)
  })
  it('KindBadge mounts KindPicker only for a settable, open badge', () => {
    assert.match(read('components/KindBadge.vue'), /<span v-if="settable && open" style="display: contents">\s*<KindPicker\b/)
  })
  /* p6-05: KindPicker is its own chunk, loaded on the first open, so the
     card chunk index.html preloads does not carry it (ci_home_gzip_kb
     352.0 -> 351.3 KB). The v-if stays on a wrapper: a bare v-if on an
     async component threw Vue's insertBefore (08ca5b58d, 7d3ef2cb5). */
  it('KindBadge loads KindPicker on demand, behind a wrapper v-if', () => {
    const src = read('components/KindBadge.vue')
    assert.match(src, /const KindPicker = defineAsyncComponent\(\(\) => import\('@\/components\/KindPicker\.vue'\)\)/)
    assert.doesNotMatch(src, /<KindPicker\s+v-if=/)
  })
  for (const f of ['components/EmojiPicker.vue', 'components/KindPicker.vue']) {
    it(`${f} runs its open work when mounted open, and on a later change`, () => {
      const src = read(f)
      assert.match(src, /onMounted\(\(\) => \{ if \(props\.open\) void onOpenChange\(true\) \}\)/)
      assert.match(src, /watch\(\(\) => props\.open, onOpenChange\)/)
      assert.match(src, /document\.addEventListener\('pointerdown', onDocPointer, true\)/)
      /* the outside-click listener is removed on unmount; a picker may also run
         its own cleanup in the same hook (EmojiPicker clears its long-press timer) */
      assert.match(src, /onBeforeUnmount\(\(\) => \{?\s*document\.removeEventListener\('pointerdown', onDocPointer, true\)/)
    })
  }
})
