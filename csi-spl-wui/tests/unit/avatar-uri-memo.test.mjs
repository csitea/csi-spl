// CLE-35075: avatarDataUri remembers each id@box picture. It is pure, so
// the memo must return exactly the encoded SVG a fresh call builds.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { avatarDataUri, avatarSvg } from '../../src/utils/avatar.mjs'

describe('avatarDataUri memo', () => {
  it('equals the encoded SVG for humans, agents, boxes and repeats', () => {
    for (const [id, box] of [['HUM-1', ''], ['HUM-1', 'box-a'], ['CLE-7', 'box-desk'], ['CLE-7', undefined], ['', ''], ['GRK-2', null]]) {
      const want = `data:image/svg+xml;utf8,${encodeURIComponent(avatarSvg(id, box))}`
      assert.equal(avatarDataUri(id, box), want)
      assert.equal(avatarDataUri(id, box), want)
    }
  })
  it('stays correct past the bound (1000 ids)', () => {
    for (let i = 0; i < 1200; i++) avatarDataUri('HUM-' + i, 'b')
    assert.equal(avatarDataUri('HUM-5', 'b'), `data:image/svg+xml;utf8,${encodeURIComponent(avatarSvg('HUM-5', 'b'))}`)
  })
})
