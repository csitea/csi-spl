import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Owner 2026-09-26 (topic 1a9a8a84): "the note, task, blocker, message buttons
// on the top bar MUST be removed - only the attach button and the send button
// must be there". A person's post is a note; its kind is set afterwards from
// the card's badge menu (KindBadge / KindPicker, SPL-952).
const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const icons = read('src/utils/uiIcons.ts')

describe('the composer has no kind control', () => {
  it('no kind buttons and no kind dropdown in the composer', () => {
    const vue = read('src/components/MessageComposer.vue')
    assert.equal(vue.includes('composer-kind'), false)
    assert.doesNotMatch(vue, /<select/)
    assert.equal(existsSync(join(WUI, 'src/utils/composer-kind.mjs')), false)
  })
  it('every send path posts a note', () => {
    for (const p of ['src/stores/live.ts', 'src/stores/channel.ts', 'src/utils/spool-client.mjs']) {
      const src = read(p)
      assert.equal(src.includes('composerKind'), false, p)
    }
    assert.match(read('src/stores/live.ts'), /const kind = 'note'/)
    assert.match(read('src/stores/channel.ts'), /kind: 'note'/)
  })
  it('the card badge is still the way to set a kind', () => {
    assert.match(read('src/components/MessageCard.vue'), /<KindBadge [^>]*:msg="msg"/)
  })
  it('the note glyph is writing lines and no frame', () => {
    const start = icons.indexOf('"kind-note"')
    const slice = icons.slice(start, start + 120)
    assert.match(slice, /M6 7h12/)
    assert.equal(slice.includes('M5 3h14'), false)
    assert.equal(slice.includes('M15 3v4'), false)
  })
})
