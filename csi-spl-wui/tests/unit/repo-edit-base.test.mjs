// spec 075 repo-edit: an editor opened again after a save, without a
// reload, sends the base the hub serves NOW, not the one load() read. The
// PUT answers the base it was given; the served base moves when the worker
// pushes the edit (X-Spool-Doc-Base = the pushed text's blob, e3cdedc8), so
// the page re-reads it (one GET) when the editor opens after a save.
//
// Run: node tests/unit/repo-edit-base.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { editBase } from '../../src/utils/repo-edit.mjs'

const read = (p) => readFileSync(new URL('../../' + p, import.meta.url), 'utf8')
const OLD = 'a'.repeat(40)
const PUSHED = 'b'.repeat(40)

describe('editBase', () => {
  it('a second edit after a save sends the base the hub serves now', async () => {
    let gets = 0
    const b = editBase(async () => { gets++; return PUSHED })
    b.loaded(OLD)
    assert.equal(await b.open(), OLD, 'the first edit uses the loaded base, no GET')
    assert.equal(gets, 0)
    b.saved()
    assert.equal(await b.open(), PUSHED)
    assert.equal(gets, 1, 'one GET')
    assert.equal(await b.open(), PUSHED, 'read once per save')
    assert.equal(gets, 1)
  })
  it('CONTROL a re-read that fails keeps the base it had (the hub answers 409 if it moved)', async () => {
    const b = editBase(async () => { throw new Error('offline') })
    b.loaded(OLD)
    b.saved()
    assert.equal(await b.open(), OLD)
  })
})

describe('the docs page', () => {
  const s = read('src/pages/docs.vue')
  it('marks the base stale on a save and opens the editor through it', () => {
    assert.match(s, /function onSaved\([^)]*\) \{[^}]*docBase\.saved\(\)/)
    assert.match(s, /data-test="repo-edit-open" @click="openEditor"/)
    assert.match(s, /async function openEditor\(\) \{[^}]*base\.value = await docBase\.open\(\)/)
  })
})
