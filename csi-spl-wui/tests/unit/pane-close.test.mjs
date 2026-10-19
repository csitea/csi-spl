// SPL-2552: Shift + W closes the rightmost pane. The pure half is
// utils/pane-close.mjs; the wiring is read from useGlobalKeys.ts.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { PANE_CLOSE_X, inTextField, isCloseKey, rightmostClose } from '../../src/utils/pane-close.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (rel) => readFileSync(join(SRC, rel), 'utf8')

/** an element that matches the given selectors with closest() */
const at = (...sels) => ({ closest: (sel) => (sels.some((s) => sel.split(', ').includes(s)) ? {} : null) })

describe('SPL-2552: Shift + W', () => {
  it('is Shift + W by key or by place, nothing else', () => {
    assert.equal(isCloseKey({ key: 'W', shiftKey: true }), true)
    assert.equal(isCloseKey({ key: 'Ц', code: 'KeyW', shiftKey: true }), true)
    assert.equal(isCloseKey({ key: 'w' }), false)
    assert.equal(isCloseKey({ key: 'W', shiftKey: true, ctrlKey: true }), false)
    assert.equal(isCloseKey({ key: 'W', shiftKey: true, metaKey: true }), false)
    assert.equal(isCloseKey({ key: 'W', shiftKey: true, altKey: true }), false)
    assert.equal(isCloseKey({ key: 'W', shiftKey: true, repeat: true }), false)
    assert.equal(isCloseKey({ key: 'W', shiftKey: true, isComposing: true }), false)
    assert.equal(isCloseKey({ key: 'Q', shiftKey: true }), false)
    assert.equal(isCloseKey(null), false)
  })

  it('a text field types the W; a card, a row or a list hit does not', () => {
    for (const sel of ['textarea', 'input', '[contenteditable="true"]', '[role="textbox"]']) assert.equal(inTextField(at(sel)), true, sel)
    assert.equal(inTextField({ isContentEditable: true, closest: () => null }), true)
    assert.equal(inTextField(at('article.msg')), false)
    assert.equal(inTextField(at('[role="listbox"]')), false)
    assert.equal(inTextField(null), false)
  })

  it('picks the pane furthest right; a tie goes to the later one; none is null', () => {
    const left = { id: 'search', x: 64 }
    const mid = { id: 'section', x: 300 }
    const right = { id: 'topic', x: 900 }
    assert.equal(rightmostClose([left, right, mid], (b) => b.x), right)
    assert.equal(rightmostClose([left, mid], (b) => b.x), mid)
    assert.equal(rightmostClose([{ id: 'a', x: 5 }, { id: 'b', x: 5 }], (b) => b.x).id, 'b')
    assert.equal(rightmostClose([{ id: 'nan', x: NaN }], (b) => b.x), null)
    assert.equal(rightmostClose([], (b) => b.x), null)
  })

  it('names the X of every closable pane', () => {
    for (const sel of ['button.topic-close', 'users-pane-close', '-panel-close"]', 'section-close', 'side-search-close']) {
      assert.ok(PANE_CLOSE_X.includes(sel), sel)
    }
  })

  it('the global listener runs it: off on a phone, over a dialog and with the setting off', () => {
    const src = read('composables/useGlobalKeys.ts')
    assert.match(src, /if \(isCloseKey\(ev\)\) \{\n\s+if \(!phone\.value && !paletteOpen\.value && shortcutsOn\(session\.claims\?\.keyboard_shortcuts\) && !document\.querySelector\(OVERLAY_OPEN\)\) onCloseKey\(ev\)/)
    assert.match(src, /x\.click\(\)/)
  })
})
