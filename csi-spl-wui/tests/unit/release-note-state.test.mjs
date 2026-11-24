// spec 065 L11 (owner HUM-10, t1 5a91349c): a note the hub stored as missing
// says "committed before notes were required" only for a commit from before
// the push gate refused it; a later commit says it landed without one.
// utils/release-note-state.mjs is pure:
//   1 missing before the switch -> state_missing
//   2 missing at or after the switch -> state_missing_required
//   3 missing with no or a bad commit time -> state_missing (the old label)
//   4 the other states keep their key; ok and unknown show none
//   5 the cutoff is a real time, and the switch key exists in every locale
//
// Run: node tests/unit/release-note-state.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { NOTES_REQUIRED_SINCE, noteStateKey } from '../../src/utils/release-note-state.mjs'

const since = Date.parse(NOTES_REQUIRED_SINCE)
const iso = (ms) => new Date(ms).toISOString()

describe('release-note state label', () => {
  it('1 missing before the switch reads "committed before notes were required"', () => {
    assert.equal(noteStateKey('missing', iso(since - 1000)), 'state_missing')
  })
  it('2 missing at or after the switch says it landed without one', () => {
    assert.equal(noteStateKey('missing', iso(since)), 'state_missing_required')
    assert.equal(noteStateKey('missing', iso(since + 86400000)), 'state_missing_required')
  })
  it('3 no or a bad commit time keeps the old label', () => {
    assert.equal(noteStateKey('missing', undefined), 'state_missing')
    assert.equal(noteStateKey('missing', 'not a time'), 'state_missing')
  })
  it('4 the other states', () => {
    for (const s of ['backfill', 'skip', 'revert']) assert.equal(noteStateKey(s, iso(since + 1)), 'state_' + s)
    assert.equal(noteStateKey('ok', iso(since + 1)), '')
    assert.equal(noteStateKey('', undefined), '')
  })
  it('5 the cutoff is a time, and every locale carries both keys', () => {
    assert.ok(Number.isFinite(since), NOTES_REQUIRED_SINCE)
    const dir = join(dirname(fileURLToPath(import.meta.url)), '../../i18n/locales')
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const rn = JSON.parse(readFileSync(join(dir, f), 'utf8')).release_notes || {}
      assert.ok(rn.state_missing && rn.state_missing_required, f)
      assert.notEqual(rn.state_missing, rn.state_missing_required, f)
    }
  })
})
