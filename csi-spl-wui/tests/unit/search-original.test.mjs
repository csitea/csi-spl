// 022 §10 (CLE-35063): the right menu of a search row and where its
// "Open original" goes. Pure helpers of utils/search-results.mjs.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { isPlacedRow, originalHref, searchRowMenuItems, topicPageOf } from '../../src/utils/search-results.mjs'

const ids = (row) => searchRowMenuItems(row).map((i) => i.id)
const loc = (p) => '/bg' + p

test('FR-050: a posted hit offers Open original, Show here, Copy link - in that order', () => {
  for (const type of ['messages', 'topics', 'files']) {
    assert.deepEqual(ids({ type, task_id: 't1', msg_id: 'm1' }), ['original', 'here', 'copy'], type)
  }
})

test('FR-050: an entity row has no preview; a tenant row has no link', () => {
  assert.deepEqual(ids({ type: 'channels', channel: 'dev' }), ['original', 'copy'])
  assert.deepEqual(ids({ type: 'users', id: 'HUM-2' }), ['original', 'copy'])
  assert.deepEqual(ids({ type: 'boxes', box_id: 'box-a' }), ['original', 'copy'])
  assert.deepEqual(ids({ type: 'tenants', tenant_id: 'e2e' }), ['original'])
})

test('FR-050 CONTROL: a row that goes nowhere has no menu', () => {
  assert.deepEqual(ids({ type: 'messages' }), [])
  assert.deepEqual(ids({ type: 'nope', id: 'x' }), [])
  assert.deepEqual(ids(null), [])
})

test('isPlacedRow: only messages, topics, files', () => {
  assert.equal(isPlacedRow({ type: 'messages' }), true)
  assert.equal(isPlacedRow({ type: 'files' }), true)
  assert.equal(isPlacedRow({ type: 'topics' }), true)
  assert.equal(isPlacedRow({ type: 'channels' }), false)
  assert.equal(isPlacedRow(undefined), false)
})

test('FR-051: a channel message opens its channel, the topic open, the hit as the hash', () => {
  const row = { type: 'messages', channel: 'dev', task_id: 'T-reply', parent_task_id: 'T-root', msg_id: 'M9', from: 'HUM-1', to: 'ALL-0' }
  assert.equal(originalHref(row, { self: 'HUM-1', pathFor: loc }), '/bg/channel/dev?topic=T-root#M9')
})

test('FR-051: a DM message opens the DM with the OTHER end, whichever end the reader is', () => {
  const row = { type: 'messages', channel: null, task_id: 'T1', msg_id: 'M1', from: 'HUM-1', to: 'CLE-7', to_box: 'box-a' }
  assert.equal(originalHref(row, { self: 'HUM-1' }), '/dm/CLE-7%40box-a?topic=T1#M1')
  assert.equal(originalHref({ ...row, from: 'CLE-7', from_box: 'box-a', to: 'HUM-1', to_box: '' }, { self: 'HUM-1' }), '/dm/CLE-7%40box-a?topic=T1#M1')
})

test('FR-051: a topic opens its channel with the topic, no hash', () => {
  assert.equal(originalHref({ type: 'topics', channel: 'ops', task_id: 'T5' }), '/channel/ops?topic=T5')
})

test('FR-051: a DM topic (no peer on the row) falls back to the topic page', () => {
  assert.equal(originalHref({ type: 'topics', channel: null, task_id: 'T5' }, { pathFor: loc }), '/bg/t/T5')
})

test('FR-051: a file the reader sent in a DM names only the reader: the topic page at the message', () => {
  const row = { type: 'files', channel: null, task_id: 'T2', msg_id: 'M2', from: 'HUM-1' }
  assert.equal(originalHref(row, { self: 'HUM-1' }), '/t/T2#M2')
})

test('FR-051: an issue discussion copies the topic page, not the bare Issues tab', () => {
  const row = { type: 'messages', channel: 'issues', task_id: 'T3', msg_id: 'M3', from: 'HUM-1', to: 'ALL-0' }
  assert.equal(originalHref(row, { self: 'HUM-1' }), '/t/T3#M3')
})

test('FR-051: entity rows keep their FR-023 page', () => {
  assert.equal(originalHref({ type: 'channels', channel: '#dev' }, { pathFor: loc }), '/bg/channel/dev')
  assert.equal(originalHref({ type: 'users', id: 'HUM-2' }), '/dm/HUM-2')
  assert.equal(originalHref({ type: 'events', event_id: 7 }, { pathFor: loc }), '/bg/events#7')
  assert.equal(originalHref({ type: 'boxes', box_id: 'box-a' }), '/search?q=box%3Abox-a')
  assert.equal(originalHref({ type: 'tenants', tenant_id: 'e2e' }), '')
})

test('topicPageOf: the parent topic, the message id as hash; CONTROLS', () => {
  assert.equal(topicPageOf({ type: 'messages', task_id: 'a', parent_task_id: 'b', msg_id: 'm' }), '/t/b#m')
  assert.equal(topicPageOf({ type: 'topics', task_id: 'a', msg_id: 'm' }), '/t/a')
  assert.equal(topicPageOf({ type: 'messages' }), '')
  assert.equal(topicPageOf({ type: 'messages', task_id: 'a/../x', msg_id: 'm' }), '/t/a%2F..%2Fx#m')
})
