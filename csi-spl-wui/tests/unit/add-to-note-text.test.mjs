// SPL-5710: a note written for a task kept no text. The person typed the
// note in the "Add to note" picker's box and pressed New note (twice); the
// hub got a note titled by the task, with an empty body. The text typed in
// the box is now the new note's body, and Enter with no matching note makes
// that note instead of doing nothing.
// Run: node tests/unit/add-to-note-text.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import * as atn from '../../src/utils/add-to-note.mjs'

const LINK = { kind: 'issue', workspace_id: 'w1', ref: 'CSI-77', label: 'Pay the bill by 20.11.' }
const picker = readFileSync(new URL('../../src/components/AddToNotePicker.vue', import.meta.url), 'utf8')

describe('add-to-note: New note keeps the typed text (SPL-5710)', () => {
  it('the typed text is the body, the object label the title', () => {
    assert.equal(typeof atn.newNoteFields, 'function', 'newNoteFields is missing: New note drops the typed text')
    assert.deepEqual(atn.newNoteFields(LINK, '  Invoice registered, payment ordered on the due date.\n'),
      { title: LINK.label, body: 'Invoice registered, payment ordered on the due date.' })
  })
  it('a blank box leaves the body empty (CONTROL: the old note shape)', () => {
    assert.deepEqual(atn.newNoteFields?.(LINK, '   '), { title: LINK.label, body: '' })
  })
  it('the body is cut at the hub limit', () => {
    assert.equal(atn.newNoteFields?.(LINK, 'x'.repeat(atn.NOTE_BODY_MAX + 5)).body.length, 20000)
  })
  it('Enter: the first match, else a new note of the text, else nothing', () => {
    assert.equal(typeof atn.pickerEnter, 'function', 'pickerEnter is missing: Enter on unmatched text does nothing')
    assert.equal(atn.pickerEnter(2, 'groc'), 'row')
    assert.equal(atn.pickerEnter(0, 'a note for the task'), 'new')
    assert.equal(atn.pickerEnter(0, '  '), null)
  })
  it('the picker writes those fields on New note and takes Enter from pickerEnter', () => {
    assert.match(picker, /newNoteFields\(link\.value, query\.value\)/, 'pickNew must pass the typed text')
    assert.match(picker, /pickerEnter\(rows\.value\.length, query\.value\)/, 'Enter must ask pickerEnter')
  })
})
