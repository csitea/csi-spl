import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { COMPOSER_KINDS, composerKind, setComposerKind } from '../../src/utils/composer-kind.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const vue = readFileSync(join(WUI, 'src/components/MessageComposer.vue'), 'utf8')
const icons = readFileSync(join(WUI, 'src/utils/uiIcons.ts'), 'utf8')

describe('the next message kind is an icon, not a menu', () => {
  it('starts as a note and a click changes it', () => {
    assert.equal(composerKind(), 'note')
    assert.deepEqual(COMPOSER_KINDS, ['note', 'task', 'blocker', 'msg'])
    assert.equal(setComposerKind('task'), 'task')
    assert.equal(composerKind(), 'task')
    assert.equal(setComposerKind('nope'), 'task')
    setComposerKind('note')
  })
  it('the composer offers the icons and no kind dropdown', () => {
    assert.match(vue, /data-testid="composer-kinds"/)
    assert.match(vue, /data-testid="`composer-kind-\$\{k\}`"/)
    assert.match(vue, /tabindex="-1"/)
    assert.doesNotMatch(vue, /<select/)
  })
  it('the note glyph is writing lines and no frame', () => {
    const start = icons.indexOf('"kind-note"')
    const slice = icons.slice(start, start + 120)
    assert.match(slice, /M6 7h12/)
    assert.equal(slice.includes('M5 3h14'), false)
    assert.equal(slice.includes('M15 3v4'), false)
  })
})
