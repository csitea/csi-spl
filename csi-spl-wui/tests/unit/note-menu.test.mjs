// Spec 155 2.10 (SPL-5255, owner HUM-10 t1 b7eb7c9a): a note's menu
// (utils/note-menu.mjs): its items, in order, and the first post of the
// discussion a note becomes.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { NOTE_DISCUSSION_CHANNEL, noteDiscussionBody, noteHasText, noteMenuItems } from '../../src/utils/note-menu.mjs'

const ids = (items) => items.map((i) => i.id)

describe('note-menu: the items', () => {
  it('a note: Archive, Turn into a discussion, Delete (danger), none locked', () => {
    const items = noteMenuItems({ archived: false, title: 'Plan', snippet: '' })
    assert.deepEqual(ids(items), ['archive', 'discuss', 'delete'])
    assert.deepEqual(items.map((i) => i.labelKey), ['notes.archive', 'notes.menu.discuss', 'notes.delete'])
    assert.equal(items[2].danger, true)
    assert.ok(items.every((i) => !i.disabled))
  })
  it('an archived note offers Unarchive in Archive\'s place', () => {
    assert.deepEqual(ids(noteMenuItems({ archived: true, title: 'Old' })), ['unarchive', 'discuss', 'delete'])
  })
  it('an empty note cannot become a discussion: the item is locked with its reason', () => {
    const discuss = noteMenuItems({ title: ' ', snippet: '', items_total: 0 })[1]
    assert.equal(discuss.disabled, true)
    assert.equal(discuss.hintKey, 'notes.menu.discuss_empty')
  })
  it('no note at all still draws the three items', () => {
    assert.deepEqual(ids(noteMenuItems(null)), ['archive', 'discuss', 'delete'])
  })
})

describe('note-menu: noteHasText', () => {
  it('a title, a text, a snippet or a checklist line is text; blanks are not', () => {
    assert.equal(noteHasText({ title: 'T' }), true)
    assert.equal(noteHasText({ body: 'b' }), true)
    assert.equal(noteHasText({ snippet: 's' }), true)
    assert.equal(noteHasText({ items_total: 2 }), true)
    assert.equal(noteHasText({ items: [{ text: 'x' }] }), true)
    assert.equal(noteHasText({ title: '  ', body: '\n', items: [] }), false)
    assert.equal(noteHasText(undefined), false)
  })
})

describe('note-menu: the discussion\'s first post', () => {
  it('title first (the subject), then the text, then the checklist', () => {
    const body = noteDiscussionBody({ title: ' Plan ', body: 'Line one\nLine two\n', items: [{ text: 'Done it', done: true }, { text: 'To do', done: false }, { text: '  ' }] })
    assert.equal(body, 'Plan\n\nLine one\nLine two\n\n- [x] Done it\n- [ ] To do')
  })
  it('blank parts are left out', () => {
    assert.equal(noteDiscussionBody({ title: '', body: 'Only text', items: [] }), 'Only text')
    assert.equal(noteDiscussionBody({ title: 'Only title' }), 'Only title')
    assert.equal(noteDiscussionBody({ title: '', body: '', items: [] }), '')
    assert.equal(noteDiscussionBody(null), '')
  })
  it('starts in the lobby, which every member of a workspace has', () => {
    assert.equal(NOTE_DISCUSSION_CHANNEL, 'lobby')
  })
})
