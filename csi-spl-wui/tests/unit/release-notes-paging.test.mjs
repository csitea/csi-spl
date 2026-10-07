// Owner, t1 ee8cd6f2: "the release notes should enable loading of older
// version up till the first entry", and "vim like hjkl type of nagivation
// between each of the version .. on the Desktop" ("double esc is better").
// The paging merge, the end-of-list cursor and the dialog's keys
// (ReleaseNotesDialog.vue), against the mock tenant's 70 versions / 140 changes.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import {
  mergeReleasePages, mockReleaseNotes, nextReleaseCursor, releaseKeyFor, releaseNoteCount,
} from '../../src/utils/release-notes-api.mjs'

const TOP = 'v1.4.2'
const page = (before) => mockReleaseNotes(`/v1/release-notes?limit=30${before ? '&before=' + before : ''}`, TOP)

describe('release notes paging: older pages back to the first entry', () => {
  it('pages through every version once, then stops at the end', () => {
    let body = page('')
    let have = body.versions
    let at = nextReleaseCursor(body, '')
    let reads = 1
    while (at) {
      body = page(at)
      have = mergeReleasePages(have, body.versions)
      at = nextReleaseCursor(body, at)
      reads++
      assert.ok(reads < 10, 'the paging never ends')
    }
    assert.equal(reads, 3)
    assert.equal(have.length, 70)
    assert.equal(releaseNoteCount(have), 140)
    const shas = have.flatMap((v) => v.notes.map((n) => n.sha))
    assert.equal(new Set(shas).size, 140, 'no change twice')
    const seqs = have.flatMap((v) => v.notes.map((n) => n.seq))
    assert.deepEqual(seqs, Array.from({ length: 140 }, (_, i) => 140 - i), 'newest first down to # 1')
  })

  it('a page read twice adds nothing', () => {
    const p1 = page('')
    const twice = mergeReleasePages(p1.versions, p1.versions)
    assert.equal(releaseNoteCount(twice), releaseNoteCount(p1.versions))
    assert.equal(twice.length, p1.versions.length)
  })

  it('a version split across two pages stays one group, without duplicates', () => {
    const a = { sha: 'a'.repeat(40) }
    const b = { sha: 'b'.repeat(40) }
    const c = { sha: 'c'.repeat(40) }
    const out = mergeReleasePages([{ version: 'v1.0.2', notes: [a] }], [{ version: 'v1.0.2', notes: [a, b] }, { version: 'v1.0.1', notes: [c] }])
    assert.deepEqual(out.map((v) => [v.version, v.notes.map((n) => n.sha[0])]), [['v1.0.2', ['a', 'b']], ['v1.0.1', ['c']]])
  })

  it('the cursor ends on an empty page, a missing cursor or the same cursor again', () => {
    assert.equal(nextReleaseCursor({ versions: [{}], next_before: 'v1.0.1' }, 'v1.0.5'), 'v1.0.1')
    assert.equal(nextReleaseCursor({ versions: [], next_before: 'v1.0.1' }, 'v1.0.5'), '')
    assert.equal(nextReleaseCursor({ versions: [{}], next_before: '' }, 'v1.0.5'), '')
    assert.equal(nextReleaseCursor({ versions: [{}], next_before: 'v1.0.5' }, 'v1.0.5'), '')
    assert.equal(nextReleaseCursor(null, ''), '')
  })
})

describe('release notes keys: j / k, Enter, h / l, Escape one level at a time', () => {
  const key = (k, extra = {}) => ({ key: k, ...extra })
  it('the list: j / k step, Enter opens only on a version row, Escape stays the dialog\'s', () => {
    assert.deepEqual(releaseKeyFor(key('j')), { type: 'step', step: 1 })
    assert.deepEqual(releaseKeyFor(key('k')), { type: 'step', step: -1 })
    assert.deepEqual(releaseKeyFor(key('Enter'), { onVersion: true }), { type: 'open' })
    assert.equal(releaseKeyFor(key('Enter'), { onVersion: false }), null)
    assert.equal(releaseKeyFor(key('h')), null)
    assert.equal(releaseKeyFor(key('Escape')), null)
  })
  it('an opened version: h / l older / newer, Escape back to the list', () => {
    const view = 'version'
    assert.deepEqual(releaseKeyFor(key('h'), { view }), { type: 'turn', step: 1 })
    assert.deepEqual(releaseKeyFor(key('l'), { view }), { type: 'turn', step: -1 })
    assert.deepEqual(releaseKeyFor(key('Escape'), { view }), { type: 'back' })
    assert.equal(releaseKeyFor(key('Enter'), { view, onVersion: true }), null)
  })
  it('off: the switch, a phone (enabled=false), a note, a modifier, typing, IME', () => {
    assert.equal(releaseKeyFor(key('j'), { enabled: false }), null)
    assert.equal(releaseKeyFor(key('Escape'), { enabled: false, view: 'version' }), null)
    assert.equal(releaseKeyFor(key('j'), { view: 'note' }), null)
    assert.equal(releaseKeyFor(key('Escape'), { view: 'note' }), null)
    assert.equal(releaseKeyFor(key('j', { ctrlKey: true })), null)
    assert.equal(releaseKeyFor(key('J', { shiftKey: true })), null)
    assert.equal(releaseKeyFor(key('j', { isComposing: true })), null)
    assert.equal(releaseKeyFor(key('j', { target: { closest: (s) => (s.includes('input') ? {} : null) } })), null)
    assert.equal(releaseKeyFor(key('j', { target: { isContentEditable: true, closest: () => null } })), null)
  })
})
