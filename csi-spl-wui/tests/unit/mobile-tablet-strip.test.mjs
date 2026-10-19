// SPL-2145: the tablet strip's pure half (utils/mobile-stack.mjs).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { MOBILE_STACK_MAX_PX, MOBILE_TABLET_MIN_PX, MOBILE_TABLET_QUERY, mobileChannelInitials } from '../../src/utils/mobile-stack.mjs'

describe('SPL-2145: tablet strip', () => {
  it('covers 600..820 px, inside the one-panel range', () => {
    assert.equal(MOBILE_TABLET_MIN_PX, 600)
    assert.equal(MOBILE_TABLET_QUERY, `(min-width: 600px) and (max-width: ${MOBILE_STACK_MAX_PX}px)`)
  })
  it('names a channel by its initials', () => {
    assert.equal(mobileChannelInitials('lobby'), 'LO')
    assert.equal(mobileChannelInitials('dev-ops'), 'DO')
    assert.equal(mobileChannelInitials('release_notes x'), 'RN')
    assert.equal(mobileChannelInitials('общи'), 'ОБ')
    assert.equal(mobileChannelInitials('a'), 'A')
    assert.equal(mobileChannelInitials('---'), '#')
    assert.equal(mobileChannelInitials(''), '#')
  })
})
