import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

/*
 * r56-04: the client's public identity fields (sessionMethods' return), read
 * by no other unit test. A swap of `tenant` and `root` there was green over
 * every client test before this file.
 */
describe('spool-client session outputs', () => {
  it('a live client hands back its base without the trailing slash, its tenant and its configError', () => {
    const c = createSpoolClient({ base: 'https://hub.example.com/', tenant: 't1', configError: 'e', mock: false })
    assert.equal(c.base, 'https://hub.example.com')
    assert.equal(c.tenant, 't1')
    assert.equal(c.configError, 'e')
    assert.equal(c.mock, false)
  })

  it('the defaults are empty strings and mock mode', () => {
    const c = createSpoolClient({})
    assert.equal(c.base, '')
    assert.equal(c.tenant, '')
    assert.equal(c.configError, '')
    assert.equal(c.mock, true)
  })
})
