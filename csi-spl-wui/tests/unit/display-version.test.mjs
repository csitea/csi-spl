// displayVersion: one leading "v" on a version a person reads.
// Bare semver from NUXT_PUBLIC_APP_VERSION ("1.2.3") becomes "v1.2.3".
// A value that already starts with v stays ("v1.2.3", never "vv1.2.3").
// "dev" and empty stay as they are. Run: node tests/unit/display-version.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { displayVersion } from '../../src/utils/display-version.mjs'
import { formatRecords } from '../../src/composables/errorJournal.mjs'

describe('displayVersion', () => {
  it('adds one v to a bare semver', () => {
    assert.equal(displayVersion('1.2.3'), 'v1.2.3')
    assert.equal(displayVersion('  1.2.4  '), 'v1.2.4')
    assert.equal(displayVersion('0.1.0-dev'), 'v0.1.0-dev')
  })

  it('never makes vv', () => {
    assert.equal(displayVersion('v1.2.3'), 'v1.2.3')
    assert.equal(displayVersion('v1.0.1-c2'), 'v1.0.1-c2')
    assert.equal(displayVersion('V1.2.3'), 'V1.2.3')
  })

  it('leaves dev and empty alone', () => {
    assert.equal(displayVersion('dev'), 'dev')
    assert.equal(displayVersion(''), '')
    assert.equal(displayVersion('   '), '')
    assert.equal(displayVersion(null), '')
    assert.equal(displayVersion(undefined), '')
  })
})

describe('diagnostics text', () => {
  it('version 1.7.5 becomes version v1.7.5, and an existing v is not doubled', () => {
    const bare = formatRecords([], { version: '1.7.5' })
    assert.match(bare, /version v1\.7\.5/)
    assert.doesNotMatch(bare, /vv1\.7\.5/)
    const prefixed = formatRecords([], { version: 'v1.7.5' })
    assert.match(prefixed, /version v1\.7\.5/)
    assert.doesNotMatch(prefixed, /vv1\.7\.5/)
  })
})
