// 080 AC4: one composer draft per place, kept per signed-in member under
// `spool.drafts`, pruned on load (30 days, newest 50), wiped on sign-out.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { memoryStore } from '../../src/utils/prefs.mjs'
import {
  DRAFTS_KEY, DRAFT_MAX_AGE_MS, DRAFT_MAX_ENTRIES,
  draftPlaceOf, pruneDrafts, loadDrafts, draftText, saveDraft, clearDraft, clearDrafts,
} from '../../src/utils/drafts.mjs'

const NOW = Date.UTC(2026, 9, 5, 12, 0, 0)
const DAY = 24 * 60 * 60 * 1000
const raw = (store) => JSON.parse(store._data[DRAFTS_KEY])

describe('draftPlaceOf', () => {
  it('a topic wins, then a peer, then a channel; nothing is no place', () => {
    assert.equal(draftPlaceOf({ taskId: 'abc-1', channel: 'lobby' }), 't:abc-1')
    assert.equal(draftPlaceOf({ peer: '@HUM-3' }), 'dm:HUM-3')
    assert.equal(draftPlaceOf({ channel: '#feedback' }), 'ch:feedback')
    assert.equal(draftPlaceOf({ channel: 'feedback' }), 'ch:feedback')
    for (const t of [null, undefined, {}, { channel: '  ' }, 42, '', 'feedback', 'x:y']) assert.equal(draftPlaceOf(t), '')
  })
  it('a formed place passes through; a new topic is its channel', () => {
    assert.equal(draftPlaceOf('ch:alerts'), 'ch:alerts')
    assert.equal(draftPlaceOf('dm:HUM-3'), 'dm:HUM-3')
    assert.equal(draftPlaceOf('t:abc-1'), 't:abc-1')
    assert.equal(draftPlaceOf('new:lobby'), 'ch:lobby')
    assert.equal(draftPlaceOf('new:#lobby'), 'ch:lobby')
  })
})

describe('pruneDrafts (AC4)', () => {
  it('drops a 31-day-old entry and keeps a 29-day-old one', () => {
    const out = pruneDrafts({ 'HUM-1': {
      'ch:old': { text: 'a', ts: NOW - 31 * DAY },
      'ch:young': { text: 'b', ts: NOW - 29 * DAY },
    } }, NOW)
    assert.deepEqual(Object.keys(out['HUM-1']), ['ch:young'])
    assert.equal(DRAFT_MAX_AGE_MS, 30 * DAY)
  })
  it('keeps the newest 50 per member, drops the 51st oldest', () => {
    const places = {}
    for (let i = 0; i < 51; i++) places[`ch:c${i}`] = { text: `t${i}`, ts: NOW - i * 1000 }
    const out = pruneDrafts({ 'HUM-1': places, 'HUM-2': { 'ch:c50': { text: 'x', ts: NOW } } }, NOW)
    assert.equal(DRAFT_MAX_ENTRIES, 50)
    assert.equal(Object.keys(out['HUM-1']).length, 50)
    assert.ok(!('ch:c50' in out['HUM-1']), 'the oldest of 51 is dropped')
    assert.ok('ch:c0' in out['HUM-1'])
    assert.deepEqual(out['HUM-2'], { 'ch:c50': { text: 'x', ts: NOW } }, 'the cap is per member')
  })
  it('drops junk: bad places, empty text, no ts, empty members, non-objects', () => {
    for (const v of [null, undefined, 'x', 7, []]) assert.deepEqual(pruneDrafts(v, NOW), {})
    const out = pruneDrafts({
      '': { 'ch:a': { text: 'a', ts: NOW } },
      'HUM-1': { 'feedback': { text: 'a', ts: NOW }, 'ch:b': { text: '', ts: NOW }, 'ch:c': { text: 'c' }, 'ch:d': 'd' },
      'HUM-2': [],
    }, NOW)
    assert.deepEqual(out, {})
  })
})

describe('save / load / clear, keyed by human id', () => {
  it('saves per place and loads back per member', () => {
    const s = memoryStore()
    assert.ok(saveDraft(s, 'HUM-1', 'ch:feedback', 'abc', NOW))
    assert.ok(saveDraft(s, 'HUM-1', { taskId: 'tid-9' }, 'xyz', NOW))
    assert.ok(saveDraft(s, 'HUM-2', 'ch:feedback', 'other', NOW))
    assert.deepEqual(loadDrafts(s, 'HUM-1', NOW), {
      'ch:feedback': { text: 'abc', ts: NOW },
      't:tid-9': { text: 'xyz', ts: NOW },
    })
    assert.equal(draftText(s, 'HUM-1', 'ch:alerts', NOW), '')
    assert.equal(draftText(s, 'HUM-1', { channel: '#feedback' }, NOW), 'abc')
    assert.equal(draftText(s, 'HUM-2', 'ch:feedback', NOW), 'other')
    assert.deepEqual(loadDrafts(s, 'HUM-3', NOW), {}, 'a second member sees none of the first one\'s drafts')
    assert.deepEqual(Object.keys(raw(s)).sort(), ['HUM-1', 'HUM-2'])
  })
  it('no member or no place writes nothing', () => {
    const s = memoryStore()
    assert.equal(saveDraft(s, '', 'ch:a', 'x', NOW), false)
    assert.equal(saveDraft(s, 'HUM-1', 'nowhere', 'x', NOW), false)
    assert.equal(s._data[DRAFTS_KEY], undefined)
    assert.deepEqual(loadDrafts(s, null, NOW), {})
  })
  it('blank text clears the place; a send clears only its place', () => {
    const s = memoryStore()
    saveDraft(s, 'HUM-1', 'ch:a', 'one', NOW)
    saveDraft(s, 'HUM-1', 'ch:b', 'two', NOW)
    saveDraft(s, 'HUM-1', 'ch:a', '   ', NOW)
    assert.deepEqual(Object.keys(loadDrafts(s, 'HUM-1', NOW)), ['ch:b'])
    clearDraft(s, 'HUM-1', 'ch:b', NOW)
    assert.deepEqual(raw(s), {}, 'the member with no drafts left is gone')
  })
  it('load prunes and writes the pruned value back', () => {
    const s = memoryStore({ [DRAFTS_KEY]: JSON.stringify({ 'HUM-1': {
      'ch:old': { text: 'a', ts: NOW - 31 * DAY }, 'ch:new': { text: 'b', ts: NOW },
    } }) })
    assert.deepEqual(Object.keys(loadDrafts(s, 'HUM-1', NOW)), ['ch:new'])
    assert.deepEqual(Object.keys(raw(s)['HUM-1']), ['ch:new'])
  })
  it('a corrupt value reads as no drafts and is replaced on save', () => {
    const s = memoryStore({ [DRAFTS_KEY]: '{not json' })
    assert.deepEqual(loadDrafts(s, 'HUM-1', NOW), {})
    saveDraft(s, 'HUM-1', 'ch:a', 'x', NOW)
    assert.deepEqual(raw(s), { 'HUM-1': { 'ch:a': { text: 'x', ts: NOW } } })
  })
})

describe('clearDrafts on sign-out (FR-008)', () => {
  it('drops every draft of that member and keeps the others', () => {
    const s = memoryStore()
    saveDraft(s, 'HUM-1', 'ch:feedback', 'abc', NOW)
    saveDraft(s, 'HUM-1', 'dm:HUM-2', 'hi', NOW)
    saveDraft(s, 'HUM-2', 'ch:feedback', 'keep', NOW)
    assert.ok(clearDrafts(s, 'HUM-1', NOW))
    assert.ok(!('HUM-1' in raw(s)))
    assert.equal(draftText(s, 'HUM-2', 'ch:feedback', NOW), 'keep')
    assert.equal(clearDrafts(s, '', NOW), false)
  })
})
