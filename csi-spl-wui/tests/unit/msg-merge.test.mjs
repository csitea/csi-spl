// merge with previous / next deletes its source, in ONE hub call.
//
// Owner (prd t1 topic 04130ea2): "once the content is merged, the actual
// source of the merged content, the source card, should self-delete". On prd
// the WUI sent PATCH and never the DELETE (Cloud Run log 2026-09-27). These
// pin the three places that make it one step: the client's single POST, the
// message_merged frame, and the card's use of it instead of edit + delete.
// Run: node tests/unit/msg-merge.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { createLiveClient, FRAMES } from '../../src/utils/live-ws.mjs'
import { mergeableSource } from '../../src/utils/msg-menu.mjs'
import { editFailureKey } from '../../src/utils/msg-edit.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

function stubFetch(routes) {
  const calls = []
  const fn = async (url, opts = {}) => {
    calls.push({ url, opts })
    const hit = routes.find(([p]) => p(url, opts))
    const [status, body] = hit ? hit[1] : [404, { error: 'not_found' }]
    return { ok: status >= 200 && status < 300, status, headers: { get: () => 'application/json' }, json: async () => body }
  }
  return { fn, calls }
}

const SRC = '22222222-2222-4222-8222-222222222222'
const KEEP = '11111111-1111-4111-8111-111111111111'

describe('spool-client mergeMessage', () => {
  it('is ONE POST /v1/messages/{source}/merge {into}, never a PATCH and a DELETE', async () => {
    const { fn, calls } = stubFetch([[(u, o) => o.method === 'POST' && u.endsWith(`/v1/messages/${SRC}/merge`), [200, {
      task_id: 'T', cursor: 'c', received_at: '2026-09-27T20:47:55Z',
      env: { from_box: 'box-wui', to_box: '', msg: { v: 1, msg_id: KEEP, task_id: 'T', body: 'a\n\nb' } },
      edited_at: '2026-09-27T20:48:59Z', edited_by: 'HUM-10', revision: 2, merged_from: SRC,
    }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const row = await c.mergeMessage(SRC, KEEP)
    assert.equal(calls.length, 1)
    assert.equal(calls[0].opts.method, 'POST')
    assert.deepEqual(JSON.parse(calls[0].opts.body), { into: KEEP })
    assert.equal(row.msg_id, KEEP)
    assert.equal(row.body, 'a\n\nb')
    assert.equal(row.merged_from, SRC)
    assert.equal(row.revision, 2)
  })

  it('carries the hub refusal token', async () => {
    const { fn } = stubFetch([[() => true, [409, { error: 'has_replies', detail: 'x' }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await assert.rejects(c.mergeMessage(SRC, KEEP), (e) => e.token === 'has_replies')
    await assert.rejects(c.mergeMessage(SRC, SRC), (e) => e.token === 'bad_json')
  })

  it('the mock folds the source into its neighbor and removes it', async () => {
    const c = createSpoolClient({ mock: true })
    const a = await c.sendMessage({ channel: 'lobby', text: 'first', task_id: 'T-merge', is_parent: 1 })
    const b = await c.sendMessage({ channel: 'lobby', text: 'second', task_id: 'T-merge', is_parent: 0 })
    const row = await c.mergeMessage(b.msg_id, a.msg_id)
    assert.equal(row.body, 'first\n\nsecond')
    assert.equal(row.merged_from, b.msg_id)
    const { messages } = await c.getTopic('T-merge')
    assert.deepEqual(messages.map((m) => m.msg_id), [a.msg_id])
  })
})

describe('message_merged frame', () => {
  it('applies as the edit of the kept row AND the delete of the source', () => {
    const sockets = []
    class FakeWS {
      constructor() { sockets.push(this) }
      send() {}
      close() {}
    }
    const edited = []
    const deleted = []
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, onEdited: (m) => edited.push(m), onDeleted: (m) => deleted.push(m) })
    c.connect()
    sockets[0].onopen()
    sockets[0].onmessage({ data: JSON.stringify({ type: 'welcome' }) })
    sockets[0].onmessage({ data: JSON.stringify({
      type: FRAMES.merged, task_id: 'T', msg_id: KEEP, merged_from: SRC,
      env: { from_box: 'box-wui', to_box: '', msg: { v: 1, msg_id: KEEP, task_id: 'T', body: 'a\n\nb' } },
      edited_at: '2026-09-27T20:48:59Z', edited_by: 'HUM-10', revision: 2,
    }) })
    assert.equal(FRAMES.merged, 'message_merged')
    assert.equal(edited.length, 1)
    assert.equal(edited[0].msg_id, KEEP)
    assert.equal(edited[0].body, 'a\n\nb')
    assert.deepEqual(deleted, [{ msg_id: SRC, task_id: 'T' }])
  })
})

describe('mergeableSource', () => {
  const card = { msg_id: 'c', task_id: 'T', is_parent: 1, received_at: '1' }
  const reply = { msg_id: 'r', task_id: 'T', is_parent: 0, received_at: '2' }
  const later = { msg_id: 'r2', task_id: 'T', is_parent: 1, received_at: '3' }
  it('a topic card is never merged away (hub 409 is_card)', () => {
    assert.equal(mergeableSource([card, reply], card), false)
  })
  it('a reply, a later is_parent row, and a lobby row may be', () => {
    assert.equal(mergeableSource([card, reply], reply), true)
    assert.equal(mergeableSource([card, reply, later], later), true)
    assert.equal(mergeableSource([{ ...card, task_id: 'L' }], { ...card, task_id: 'L' }, 'L'), true)
  })
})

describe('the card', () => {
  it('merges through mergeInto, not commit + removeMessage', () => {
    const card = src('src/components/MessageCard.vue')
    const body = card.slice(card.indexOf('async function onMerge'), card.indexOf('/* Open on a topic card opens its topic'))
    assert.match(body, /await mergeInto\(dropId, keepId\)/)
    assert.doesNotMatch(body, /removeMessage|commit\(/)
  })
  it('names every merge refusal', () => {
    for (const token of ['is_card', 'has_replies', 'not_same_thread', 'not_same_author']) {
      assert.equal(editFailureKey({ token }), 'feed.edit.failed_merge')
    }
    assert.equal(editFailureKey({ token: 'not_allowed' }), 'feed.edit.failed_not_author')
  })
})
