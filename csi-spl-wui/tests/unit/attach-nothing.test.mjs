// Owner, 2026-09-25: eight attach tries, eight messages with no file, and
// nothing on screen said so. A double-click in the GTK file dialog lost the
// pick; Select + Open worked. The composer now says when the dialog closed
// with nothing, and names the two ways that work.
//
// Run: node tests/unit/attach-nothing.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const box = read('src/components/MessageComposer.vue')

describe('an empty file dialog is not silent', () => {
  it('the file input listens for cancel as well as change', () => {
    assert.match(box, /data-testid="attach-input"\s+@change="onFiles"\s+@cancel="onPickCancel"/)
  })

  it('cancel, and a change with no files, both raise the notice', () => {
    assert.match(box, /function onPickCancel\(\) \{\s+clearPickWait\(\)\s+pickLost\.value = true/)
    assert.match(box, /input\.files\.length === 0\) \{\s+pickLost\.value = true\s+return/)
  })

  it('a close that fires neither is caught when the window gets the focus back', () => {
    assert.match(box, /window\.addEventListener\('focus', onWindowFocusAfterPick\)/)
    assert.match(box, /if \(awaitingPick\) pickLost\.value = true/)
    assert.match(box, /onBeforeUnmount\(clearPickWait\)/)
  })

  it('a pick, a paste or a drop that attaches clears it', () => {
    const cleared = box.match(/pickLost\.value = false/g) || []
    assert.ok(cleared.length >= 4, `openFiles, onFiles, onPaste, onWindowDrop: got ${cleared.length}`)
  })

  it('the notice is shown under the box with its own test id', () => {
    assert.match(box, /<p v-if="pickLost"[^>]*data-testid="attach-nothing"[^>]*>[\s\S]*?t\('composer\.attach_nothing'\)/)
  })

  it('every locale has the notice text', () => {
    const dir = join(WUI, 'i18n/locales')
    for (const f of readdirSync(dir).filter((n) => n.endsWith('.json'))) {
      const j = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      const s = j.composer && j.composer.attach_nothing
      assert.ok(typeof s === 'string' && s.length > 20, `${f}: composer.attach_nothing`)
    }
  })
})
