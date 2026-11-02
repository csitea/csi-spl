// Spec 155 B8 (SPL-4578): "Add to note" on an object (utils/add-to-note.mjs).
// C27's unit half: each object becomes a link of its kind and workspace,
// labelled by the object's title, that the B7 href builder opens on the
// object's own page. The picker lists the notes latest first (D3), and the
// issue menu puts the item right before Archive (spec 1.2 row 17).
// Run: node tests/unit/add-to-note.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { ADD_TO_NOTE_ID, channelNoteLink, eventNoteLink, issueNoteLink, msgNoteLink, pickerNotes, withNoteItem } from '../../src/utils/add-to-note.mjs'
import { noteLinkPath } from '../../src/utils/note-links.mjs'

const UUID = '0b7f2c3e-1d2a-4b5c-8d9e-0f1a2b3c4d5e'
const MSG = '7c1d9a2b-3e4f-4a5b-8c6d-9e0f1a2b3c4d'
const path = (link) => noteLinkPath(link)

describe('add-to-note: the link of each object (C27)', () => {
  it('a topic card links its topic, labelled by its first line', () => {
    const link = msgNoteLink({ msg_id: MSG, task_id: UUID, body: '\n  Release plan  \nthe rest' }, { topic: true, workspace: 'w1' })
    assert.deepEqual(link, { kind: 'topic', workspace_id: 'w1', ref: UUID, label: 'Release plan' })
    assert.equal(path(link), `/t/${UUID}`)
  })
  it('any other message links itself, labelled by its first 80 characters', () => {
    const body = 'x'.repeat(100)
    const link = msgNoteLink({ msg_id: MSG, task_id: UUID, body }, { workspace: 'w1' })
    assert.deepEqual(link, { kind: 'msg', workspace_id: 'w1', ref: MSG, label: 'x'.repeat(80) })
    assert.equal(path(link), `/m/${MSG}`)
  })
  it('an issue links its key, labelled by its title', () => {
    const link = issueNoteLink({ key: 'SPL-12', title: 'Fix the login' }, 'w1')
    assert.deepEqual(link, { kind: 'issue', workspace_id: 'w1', ref: 'SPL-12', label: 'Fix the login' })
    assert.equal(path(link), '/issues?issue=SPL-12')
  })
  it('a calendar entry links its id and the day it is on', () => {
    const link = eventNoteLink({ id: 'ev-1', title: 'Standup' }, 'w1', '2026-11-03')
    assert.deepEqual(link, { kind: 'event', workspace_id: 'w1', ref: 'ev-1', label: 'Standup', day: '2026-11-03' })
    assert.equal(path(link), '/calendar?d=2026-11-03&event=ev-1')
  })
  it('an issue deadline on the calendar links that issue', () => {
    assert.deepEqual(eventNoteLink({ id: 'SPL-7', title: 'Ship', source: 'issue' }, 'w1', '2026-11-03'),
      { kind: 'issue', workspace_id: 'w1', ref: 'SPL-7', label: 'Ship' })
  })
  it('a channel row links the id its route takes, labelled by its name', () => {
    const link = channelNoteLink({ id: 'devel', name: 'spool-hub-devel' }, 'w1')
    assert.deepEqual(link, { kind: 'channel', workspace_id: 'w1', ref: 'devel', label: 'spool-hub-devel' })
    assert.equal(path(link), '/channel/devel')
  })
  it('a label is cut at 200 characters', () => {
    assert.equal(issueNoteLink({ key: 'SPL-1', title: 'y'.repeat(300) }, 'w1').label.length, 200)
  })
  it('no workspace or no id: no link (the hub would refuse it)', () => {
    assert.equal(msgNoteLink({ msg_id: MSG, body: 'x' }, { workspace: '' }), null)
    assert.equal(issueNoteLink({ key: '', title: 'x' }, 'w1'), null)
    assert.equal(eventNoteLink({ id: 'ev-1' }, 'w1', ''), null)
    assert.equal(channelNoteLink(null, 'w1'), null)
    /* CONTROL: the same message with a workspace is a link */
    assert.equal(msgNoteLink({ msg_id: MSG, body: 'x' }, { workspace: 'w1' })?.kind, 'msg')
  })
})

describe('add-to-note: the picker list (D3)', () => {
  const list = [
    { id: 'a', title: 'Old', snippet: '', archived: false, updated_at: '2026-10-01T00:00:00Z' },
    { id: 'b', title: 'New', snippet: 'groceries', archived: false, updated_at: '2026-10-03T00:00:00Z' },
    { id: 'c', title: 'Gone', snippet: '', archived: true, updated_at: '2026-10-04T00:00:00Z' },
  ]
  it('latest changed first, archived ones left out', () => {
    assert.deepEqual(pickerNotes(list, '').map((n) => n.id), ['b', 'a'])
  })
  it('the filter matches the title or the text', () => {
    assert.deepEqual(pickerNotes(list, 'GROC').map((n) => n.id), ['b'])
    assert.deepEqual(pickerNotes(list, 'old').map((n) => n.id), ['a'])
    assert.deepEqual(pickerNotes(list, 'gone').map((n) => n.id), [], 'an archived note is never offered')
  })
})

describe('add-to-note: the issue menu item', () => {
  const item = { id: ADD_TO_NOTE_ID, icon: 'notes', labelKey: 'issues_menu.add_to_note' }
  const ids = (list) => list.map((i) => i.id)
  it('goes right before Archive', () => {
    assert.deepEqual(ids(withNoteItem([{ id: 'open' }, { id: 'archive' }, { id: 'delete' }], true, item)), ['open', ADD_TO_NOTE_ID, 'archive', 'delete'])
  })
  it('at the end when there is no Archive; once only', () => {
    const once = withNoteItem([{ id: 'open' }], true, item)
    assert.deepEqual(ids(once), ['open', ADD_TO_NOTE_ID])
    assert.deepEqual(ids(withNoteItem(once, true, item)), ['open', ADD_TO_NOTE_ID])
  })
  it('notes off: no item', () => {
    assert.deepEqual(ids(withNoteItem([{ id: 'open' }, { id: 'archive' }], false, item)), ['open', 'archive'])
  })
})
