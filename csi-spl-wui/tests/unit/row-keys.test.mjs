// CLE-77840 (owner, t1 topic bc1fd547): walk the messages with the keyboard,
// Delete on the selected one. Topic-level (is_parent 1) asks first; a reply
// goes at once with a "Deleted · Undo" snackbar. The decisions are
// utils/row-keys.mjs; the browser half is tests/e2e/kbd-delete-undo.test.mjs.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { deleteKeyAction, isReply, listRowKey, rowStep, stepRow } from '../../src/utils/row-keys.mjs'

const row = {}
const key = (k, extra = {}) => ({ key: k, target: row, currentTarget: row, ...extra })
const reply = { msg_id: 'r', is_parent: 0 }
const opener = { msg_id: 'o', is_parent: 1 }

describe('rowStep: ArrowDown / ArrowUp on the row itself walk the feed', () => {
  it('down is +1, up is -1, anything else 0', () => {
    assert.equal(rowStep(key('ArrowDown')), 1)
    assert.equal(rowStep(key('ArrowUp')), -1)
    assert.equal(rowStep(key('ArrowLeft')), 0)
    assert.equal(rowStep(key('j')), 0)
  })
  it('never inside a child control (a textarea, a button) - control', () => {
    assert.equal(rowStep({ key: 'ArrowDown', target: {}, currentTarget: row }), 0)
  })
  it('no modifier, no IME composition', () => {
    for (const m of ['ctrlKey', 'metaKey', 'altKey', 'shiftKey', 'isComposing']) assert.equal(rowStep(key('ArrowDown', { [m]: true })), 0, m)
  })
})

describe('stepRow', () => {
  const a = { n: 'a' }, b = { n: 'b' }, c = { n: 'c' }
  it('next / previous in document order, null past the ends', () => {
    assert.equal(stepRow([a, b, c], b, 1), c)
    assert.equal(stepRow([a, b, c], b, -1), a)
    assert.equal(stepRow([a, b, c], c, 1), null)
    assert.equal(stepRow([a, b, c], a, -1), null)
  })
  it('a row not in the list, or no step: null', () => {
    assert.equal(stepRow([a, b], c, 1), null)
    assert.equal(stepRow([a, b], a, 0), null)
  })
})

describe('isReply: only an explicit is_parent 0', () => {
  it('0 is a reply; 1 and a missing field are topic-level (they ask first)', () => {
    assert.equal(isReply(reply), true)
    assert.equal(isReply(opener), false)
    assert.equal(isReply({ msg_id: 'x' }), false)
    assert.equal(isReply(null), false)
  })
})

describe('deleteKeyAction', () => {
  it('a reply the viewer may delete: at once, with Undo', () => {
    assert.equal(deleteKeyAction(key('Delete'), reply, { editable: true }), 'delete-undo')
    assert.equal(deleteKeyAction(key('Backspace'), reply, { editable: true }), 'delete-undo')
  })
  it('is_parent 1 with the topic menu Delete: the topic confirm', () => {
    assert.equal(deleteKeyAction(key('Delete'), opener, { topicDelete: true, editable: true }), 'confirm-topic')
  })
  it('is_parent 1 without topic delete but own: the message confirm, never at once', () => {
    assert.equal(deleteKeyAction(key('Delete'), opener, { editable: true }), 'confirm-message')
  })
  it('permissions stay: nothing the menu would not offer', () => {
    assert.equal(deleteKeyAction(key('Delete'), reply, { topicDelete: true }), '')
    assert.equal(deleteKeyAction(key('Delete'), opener, {}), '')
  })
  it('control: a key typed inside a child control (the editor) deletes nothing', () => {
    assert.equal(deleteKeyAction({ key: 'Delete', target: {}, currentTarget: row }, reply, { editable: true }), '')
    assert.equal(deleteKeyAction(key('Delete', { ctrlKey: true }), reply, { editable: true }), '')
    assert.equal(deleteKeyAction(key('x'), reply, { editable: true }), '')
  })
})

describe('wiring (source pins)', () => {
  const here = dirname(fileURLToPath(import.meta.url))
  const src = (p) => readFileSync(join(here, '../../src', p), 'utf8')
  it('the shell mounts the Deleted snackbar eagerly, like the Archived one', () => {
    const layout = src('layouts/default.vue')
    assert.match(layout, /<DeleteUndoToast v-if=/)
    assert.doesNotMatch(layout, /LazyDeleteUndoToast|LazyArchiveUndoToast/)
  })
  it('the card opens both confirms from eager code (the Delete key path)', () => {
    const card = src('components/MessageCard.vue')
    assert.match(card, /<TopicDeleteDialog\b/)
    assert.match(card, /<MessageDeleteDialog\b/)
    assert.doesNotMatch(card, /LazyTopicDeleteDialog|LazyMessageDeleteDialog/)
  })
  it('the delete is a delayed commit: the DELETE goes when the snackbar closes', () => {
    const c = src('composables/useDeleteUndo.ts')
    assert.match(c, /function dismiss\(\) \{\s*toast\.value = null\s*commit\(\)/)
    assert.match(c, /addEventListener\('pagehide'/)
  })
})

describe('listRowKey: HUM-10 (t1 7d9e1681) the arrows walk the Channels list after a click', () => {
  const src = (p) => readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src', p), 'utf8')
  it('ArrowDown / ArrowUp next / prev, Home / End first / last, Enter enter', () => {
    assert.equal(listRowKey(key('ArrowDown')), 'next')
    assert.equal(listRowKey(key('ArrowUp')), 'prev')
    assert.equal(listRowKey(key('Home')), 'first')
    assert.equal(listRowKey(key('End')), 'last')
    assert.equal(listRowKey(key('Enter')), 'enter')
    assert.equal(listRowKey(key('ArrowLeft')), '')
    assert.equal(listRowKey(key('x')), '')
  })
  it('j / k only while the keyboard shortcuts switch is on (control: off = nothing)', () => {
    assert.equal(listRowKey(key('j')), 'next')
    assert.equal(listRowKey(key('k')), 'prev')
    assert.equal(listRowKey(key('j'), { letters: false }), '')
    assert.equal(listRowKey(key('k'), { letters: false }), '')
    assert.equal(listRowKey(key('ArrowDown'), { letters: false }), 'next')
  })
  it('never inside a child control, with a modifier or an IME (control)', () => {
    assert.equal(listRowKey({ key: 'ArrowDown', target: {}, currentTarget: row }), '')
    for (const m of ['ctrlKey', 'metaKey', 'altKey', 'shiftKey', 'isComposing']) assert.equal(listRowKey(key('ArrowDown', { [m]: true })), '', m)
    assert.equal(listRowKey(null), '')
  })
  it('ChannelSidebar wires it on the channel rows, desktop only, and opens the stepped-to channel', () => {
    const v = src('components/ChannelSidebar.vue')
    assert.match(v, /:to="localePath\('\/channel\/' \+ c\.channel_id\)"\s*@click="keepRowFocus"\s*@keydown="onChannelRowKey"/)
    assert.match(v, /function onChannelRowKey\(e: KeyboardEvent\) \{\s*if \(phone\.value\) return/)
    assert.match(v, /listRowKey\(e, \{ letters: session\.claims\?\.keyboard_shortcuts !== false \}\)/)
    assert.match(v, /void navigateTo\(localePath\('\/channel\/' \+ to\.dataset\.key\)\)/)
  })
})
