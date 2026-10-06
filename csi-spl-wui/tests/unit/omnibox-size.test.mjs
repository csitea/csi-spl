// The top-bar omnibox collapses to one line on blur and on Ctrl+Enter.
// Focusing it again opens the size it had: a drag, or the height it grew to.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { omniboxFocusHeight, omniboxIsMultiline, omniboxOneLinePad, omniboxRememberHeight } from '../../src/utils/omnibox-size.mjs'

describe('omnibox size across a collapse', () => {
  it('a drag reopens at that height, capped by the window', () => {
    assert.equal(omniboxFocusHeight(640, 200, 800), 640)
    assert.equal(omniboxFocusHeight(900, 200, 800), 800)
  })

  it('a grown field reopens at the height it had', () => {
    assert.equal(omniboxFocusHeight(null, 280, 800), 280)
  })

  it('one line stays one line', () => {
    assert.equal(omniboxFocusHeight(null, null, 800), null)
    assert.equal(omniboxFocusHeight(null, 36, 800), null)
    assert.equal(omniboxFocusHeight(36, 280, 800), 280)
  })

  it('collapsing a tall field remembers that height', () => {
    assert.equal(omniboxRememberHeight({
      userHeight: null, openHeight: null, measured: 280, keep: false,
    }), 280)
    assert.equal(omniboxRememberHeight({
      userHeight: 640, openHeight: 280, measured: 640, keep: false,
    }), 640)
  })

  it('a one-line field forgets a stored size, unless it is already collapsed', () => {
    assert.equal(omniboxRememberHeight({
      userHeight: null, openHeight: 280, measured: 36, keep: false,
    }), null)
    assert.equal(omniboxRememberHeight({
      userHeight: null, openHeight: 280, measured: 36, keep: true,
    }), 280)
  })
})

describe('omnibox multi-line rule', () => {
  it('a newline is more than one line, a fitting line is not', () => {
    assert.equal(omniboxIsMultiline({ text: '' }), false)
    assert.equal(omniboxIsMultiline({ text: 'hello', textWidth: 40, contentWidth: 200 }), false)
    assert.equal(omniboxIsMultiline({ text: 'hello\nthere', textWidth: 40, contentWidth: 200 }), true)
    assert.equal(omniboxIsMultiline({ text: 'hello\r\nthere' }), true)
    assert.equal(omniboxIsMultiline({ text: '\n' }), true)
  })

  it('a line wider than the one-line box wraps', () => {
    assert.equal(omniboxIsMultiline({ text: 'hello', textWidth: 220, contentWidth: 200 }), true)
    assert.equal(omniboxIsMultiline({ text: 'hello', textWidth: 200, contentWidth: 200 }), false)
    assert.equal(omniboxIsMultiline({ text: 'hello', textWidth: 200.5, contentWidth: 200 }), false)
    assert.equal(omniboxIsMultiline({ text: 'hello', textWidth: 200.6, contentWidth: 200 }), true)
    assert.equal(omniboxIsMultiline({ text: 'hello' }), false)
    assert.equal(omniboxIsMultiline({ text: 'hello', textWidth: 10, contentWidth: 0 }), false)
    assert.equal(omniboxIsMultiline({ text: 'hello', textWidth: Number.NaN, contentWidth: 200 }), false)
  })

  it('the one-line pad is the glyph, the chip, or both', () => {
    assert.equal(omniboxOneLinePad(), 0)
    assert.equal(omniboxOneLinePad({ glyph: true }), 24)
    assert.equal(omniboxOneLinePad({ chip: true, chipWidth: 80 }), 86)
    assert.equal(omniboxOneLinePad({ glyph: true, chip: true, chipWidth: 80 }), 106)
    assert.equal(omniboxOneLinePad({ glyph: true, phone: true }), 24)
    assert.equal(omniboxOneLinePad({ chip: true, chipWidth: 40, phone: true }), 46)
    assert.equal(omniboxOneLinePad({ glyph: true, chip: true, chipWidth: 40, phone: true }), 70)
    assert.equal(omniboxOneLinePad({ chip: true, chipWidth: -3 }), 6)
  })

  it('the composer asks this rule and lifts the prefix with a 0.25rem gap', () => {
    const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageComposer.vue'), 'utf8')
    assert.match(vue, /omniboxIsMultiline\(/)
    assert.match(vue, /omniboxOneLinePad\(/)
    assert.match(vue, /'is-multiline': multilineLayout/)
    assert.match(vue, /row-gap:\s*0\.25rem/)
    assert.match(vue, /\.omnibox-field\.is-multiline textarea[\s\S]*padding-inline-start:\s*0/)
  })
})
