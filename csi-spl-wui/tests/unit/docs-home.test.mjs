// SPL-1882 (owner HUM-10, t1 2a2a4694): /docs alone goes to Docs (Qto),
// /workspace/docs; a doc's own /docs/<path> stays where it is.
// Control: before SPL-1882 src/utils/docs-home.mjs does not exist, so the
// import fails and every check fails.
//
// Run: node tests/unit/docs-home.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { docsHomeTarget } from '../../src/utils/docs-home.mjs'

describe('docsHomeTarget', () => {
  it('/docs, with or without a locale or a trailing slash, goes to /workspace/docs', () => {
    assert.equal(docsHomeTarget('/docs'), '/workspace/docs')
    assert.equal(docsHomeTarget('/docs/'), '/workspace/docs')
    assert.equal(docsHomeTarget('/fi/docs'), '/fi/workspace/docs')
    assert.equal(docsHomeTarget('/he/docs/'), '/he/workspace/docs')
  })
  it('a doc address, Docs (Qto) itself and look-alikes stay', () => {
    for (const p of ['/docs/README.md', '/fi/docs/csi-spl-doc/doc/md/x.md', '/docs/ws/a.md', '/docs/api', '/workspace/docs', '/docsx', '/x/y/docs', '', undefined]) {
      assert.equal(docsHomeTarget(p), '', String(p))
    }
  })
})
