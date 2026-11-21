// Spec 189 row B2 (owner HUM-10, t1 a48d75d6, answers OWN and RLD): the fresh
// set, the topics the viewer created in this tab, per channel
// (src/utils/topic-list-order.mjs; the tab's copy: composables/useFreshTopics.ts).
// Red control (spec row B2): make `freshNote` add on a reply (drop the
// `ev.parentTaskId` test) and the reply case below fails.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { freshEmpty, freshEndsOnRoute, freshIdsFor, freshNote } from '../../src/utils/topic-list-order.mjs'

const run = (events, from = freshEmpty()) => events.reduce(freshNote, from)
const opened = (name) => ({ type: 'channel', channel: name })
const send = (taskId, extra = {}) => ({ type: 'send', channel: 'alerts', taskId, ...extra })

describe('spec 189 B2 D1 / C5 whose', () => {
  it('my own send with no parent task adds its task id', () => {
    assert.deepEqual(freshIdsFor(run([opened('alerts'), send('t-1')]), 'alerts'), ['t-1'])
  })
  it('a reply adds none (red: a reply fills the set)', () => {
    assert.deepEqual(freshIdsFor(run([opened('alerts'), send('t-1', { parentTaskId: 't-0' })]), 'alerts'), [])
  })
  it('a DM send adds none', () => {
    assert.deepEqual(run([opened(''), send('t-1', { channel: '', peer: 'CLE-07' })]).ids, [])
    assert.deepEqual(run([opened('alerts'), send('t-1', { peer: 'CLE-07' })]).ids, [])
  })
  it('a live topic root from another sender adds none: only a send event adds, and a live row is no send', () => {
    const s = run([opened('alerts'), send('t-1')])
    const live = { type: 'live', channel: 'alerts', taskId: 't-9', from: 'CLE-07' }
    assert.equal(freshNote(s, /** @type {any} */ (live)), s)
    assert.deepEqual(freshIdsFor(freshNote(s, /** @type {any} */ (live)), 'alerts'), ['t-1'])
  })
  it('several sends stay in send order; one sent twice keeps one place, the newest', () => {
    assert.deepEqual(freshIdsFor(run([opened('alerts'), send('a'), send('b'), send('a')]), 'alerts'), ['b', 'a'])
  })
  it('an empty task id or channel adds none', () => {
    assert.deepEqual(run([opened('alerts'), send('')]).ids, [])
    assert.deepEqual(run([opened('alerts'), send('x', { channel: '' })]).ids, [])
  })
})

describe('spec 189 B2 D2 / C6 how long', () => {
  it('switching to another channel empties it', () => {
    const s = run([opened('alerts'), send('t-1'), opened('ops')])
    assert.deepEqual(freshIdsFor(s, 'alerts'), [])
    assert.deepEqual(freshIdsFor(s, 'ops'), [])
  })
  it('opening a DM empties it', () => {
    assert.deepEqual(run([opened('alerts'), send('t-1'), opened('')]).ids, [])
  })
  it('re-opening the same channel (a refresh of it) keeps it', () => {
    assert.deepEqual(freshIdsFor(run([opened('alerts'), send('t-1'), opened('alerts')]), 'alerts'), ['t-1'])
  })
  it('leaving the channel empties it', () => {
    assert.deepEqual(run([opened('alerts'), send('t-1'), { type: 'leave' }]).ids, [])
  })
  it('a topic open, a sort or a filter change are no event: the set is kept as it was', () => {
    const s = run([opened('alerts'), send('t-1')])
    for (const ev of [{ type: 'open-topic' }, { type: 'sort' }, { type: 'filter' }, null, undefined]) {
      assert.equal(freshNote(s, /** @type {any} */ (ev)), s)
    }
  })
  it('the ids are for their own channel only', () => {
    const s = run([opened('alerts'), send('t-1')])
    assert.deepEqual(freshIdsFor(s, 'ops'), [])
    assert.deepEqual(freshIdsFor(s, ''), [])
    assert.deepEqual(freshIdsFor(s, null), [])
  })
  it('a route ends it unless it is this channel\'s feed (any query) or a topic page', () => {
    assert.equal(freshEndsOnRoute('/channel/alerts', 'alerts'), false)
    assert.equal(freshEndsOnRoute('/channel/alerts/', 'alerts'), false)
    assert.equal(freshEndsOnRoute('/channel/alerts?topic=t-2', 'alerts'), false)
    assert.equal(freshEndsOnRoute('/t/t-2', 'alerts'), false)
    assert.equal(freshEndsOnRoute('/channel/ops', 'alerts'), true)
    assert.equal(freshEndsOnRoute('/issues', 'alerts'), true)
    assert.equal(freshEndsOnRoute('/dm/CLE-07', 'alerts'), true)
    assert.equal(freshEndsOnRoute('/channel/alerts', ''), true)
    // a malformed escape (a bare %) ends the pin rather than throwing in the route guard
    assert.equal(freshEndsOnRoute('/channel/al%erts', 'alerts'), true)
    assert.equal(freshEndsOnRoute('/channel/%E0%A4%A', 'alerts'), true)
  })
})
