// The top-bar omnibox collapses to one line on blur and on Ctrl+Enter.
// Focusing it again opens the size it had: a drag, or the height it grew to.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { omniboxFocusHeight, omniboxRememberHeight } from '../../src/utils/omnibox-size.mjs'

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
