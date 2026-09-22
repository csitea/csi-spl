// CLE-3445 row E1 — the wire half of message editing, browser side.
//
// The hub half is CLE-3443's; this is what the browser has to do to see it.
// Three of the four things pinned here are "a key that is silently dropped",
// which is the failure mode of every allow-listed normaliser: nothing throws,
// nothing logs, the marker just never renders and the row never changes.
//
//   1. view-api normalizeViewMessage() explicitly allow-lists `cursor`,
//      `received_at` and `deliveries` onto the flat row and drops every other
//      top-level key. `edited_at` / `edited_by` / `revision` sit at that top
//      level, NOT inside env.msg.
//   2. live-ws messageFromFrame() has the same shape and the same gap.
//   3. a `message_edited` frame cannot be delivered as a second `message`
//      frame. Measured on origin/master, not assumed:
//        sed -n '77,95p' src/utils/feed.mjs
//          -> } else if (list[i].pending && !m.pending) {
//      so mergeById() replaces a held row ONLY while it is pending and drops
//      an incoming row whose msg_id is already held as confirmed. This file
//      asserts that behaviour directly, so the reason for the separate frame
//      is in the suite rather than only in a commit message.
//   4. message-edit-v1 FR-ED-009: an edit does not MOVE the message. Replaced
//      at its index, never re-sorted and never appended.
//
// Run: node tests/unit/msg-edit-wire.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { FRAMES, createLiveClient, messageFromFrame } from '../../src/utils/live-ws.mjs'
import { normalizeViewMessage } from '../../src/utils/view-api.mjs'
import { mergeById } from '../../src/utils/feed.mjs'
import { applyEdit } from '../../src/utils/msg-edit.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const EDITED = { edited_at: '2026-09-22T07:40:00Z', edited_by: 'HUM-1', revision: 2 }

function fakeWs() {
  const sockets = []
  class FakeWS {
    constructor(url) { this.url = url; this.sent = []; sockets.push(this) }
    send(s) { this.sent.push(JSON.parse(s)) }
    close() { this.onclose && this.onclose() }
    open() { this.onopen && this.onopen() }
    recv(obj) { this.onmessage && this.onmessage({ data: JSON.stringify(obj) }) }
  }
  return { FakeWS, sockets }
}

/** routes: [predicate(url, opts), [status, body]] in order; first match wins. */
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

describe('the three edit keys survive the normalisers (message-edit-v1 §6)', () => {
  it('a view element carries them onto the flat row', () => {
    const row = normalizeViewMessage({
      cursor: 'c1',
      received_at: '2026-09-22T07:00:00Z',
      ...EDITED,
      env: { from_box: 'box-wui', to_box: 'box-wui', msg: { v: 1, msg_id: 'm1', body: 'the new msg' }, sig: 's' },
    })
    assert.equal(row.edited_at, EDITED.edited_at)
    assert.equal(row.edited_by, 'HUM-1')
    assert.equal(row.revision, 2)
    /* the body itself needs no client change: it is already the new one */
    assert.equal(row.body, 'the new msg')
    assert.equal(row.sig, undefined)
  })

  it('a live frame carries them too', () => {
    const m = messageFromFrame({
      type: FRAMES.edited,
      msg_id: 'm1',
      cursor: 'c1',
      ...EDITED,
      env: { from_box: 'box-wui', to_box: 'box-wui', msg: { v: 1, msg_id: 'm1', body: 'the new msg' }, sig: 's' },
    })
    assert.equal(m.edited_at, EDITED.edited_at)
    assert.equal(m.edited_by, 'HUM-1')
    assert.equal(m.revision, 2)
  })

  it('a message that has NEVER been edited grows no keys', () => {
    /* §2: the keys are OMITTED, not null. The marker tests for presence, so
       writing `out.edited_at = undefined` here would mark every message as
       edited the moment someone used `in` instead of a truth test. */
    const row = normalizeViewMessage({ cursor: 'c1', env: { from_box: 'box-a', msg: { msg_id: 'm1' }, sig: 's' } })
    assert.equal('edited_at' in row, false)
    assert.equal('edited_by' in row, false)
    assert.equal('revision' in row, false)
    const m = messageFromFrame({ type: FRAMES.message, env: { from_box: 'box-a', msg: { msg_id: 'm1' } } })
    assert.equal('edited_at' in m, false)
  })

  it('a flat element (already v:1) keeps them as well', () => {
    const row = normalizeViewMessage({ v: 1, msg_id: 'm1', body: 'b', from_box: 'box-wui', ...EDITED })
    assert.equal(row.edited_at, EDITED.edited_at)
  })
})

describe('why the edit needs its OWN frame type', () => {
  it('mergeById DROPS a repeat of a row already held as confirmed', () => {
    /* this is the measurement the contract cites, asserted rather than
       quoted: if this ever starts passing the edit through, the separate
       frame becomes optional and someone should be told */
    const held = [{ msg_id: 'm1', body: 'the old msg' }]
    const { rows, added, confirmed } = mergeById(held, [{ msg_id: 'm1', body: 'the new msg', ...EDITED }])
    assert.equal(rows[0].body, 'the old msg', 'mergeById must NOT have applied the edit')
    assert.equal(added.length, 0)
    assert.equal(confirmed, 0)
  })

  it('it replaces a PENDING row, which is the only case it was built for', () => {
    const held = [{ msg_id: 'm1', body: 'sending', pending: true }]
    const { rows } = mergeById(held, [{ msg_id: 'm1', body: 'sent' }])
    assert.equal(rows[0].body, 'sent')
  })

  it('the frame type is message_edited', () => {
    assert.equal(FRAMES.edited, 'message_edited')
  })
})

describe('the live client routes the frame', () => {
  function connected(handlers) {
    const { FakeWS, sockets } = fakeWs()
    const c = createLiveClient({ url: 'ws://x', WebSocketImpl: FakeWS, ...handlers })
    c.connect()
    sockets[0].open()
    sockets[0].recv({ type: FRAMES.welcome, as: 'HUM-1' })
    return sockets[0]
  }

  it('sends message_edited to onEdited and NOT to onMessage', () => {
    /* feeding it to onMessage would hand it to every merge-by-append listener
       in the app, which is precisely what drops it (see the suite above) */
    const edited = []
    const messages = []
    const ws = connected({ onEdited: (m) => edited.push(m), onMessage: (m) => messages.push(m) })
    ws.recv({
      type: FRAMES.edited,
      msg_id: 'm1',
      task_id: 't1',
      ...EDITED,
      env: { from_box: 'box-wui', msg: { v: 1, msg_id: 'm1', task_id: 't1', body: 'the new msg' } },
    })
    assert.equal(messages.length, 0)
    assert.equal(edited.length, 1)
    assert.equal(edited[0].msg_id, 'm1')
    assert.equal(edited[0].body, 'the new msg')
    assert.equal(edited[0].edited_at, EDITED.edited_at)
  })

  it('keeps a plain message frame on onMessage', () => {
    const edited = []
    const messages = []
    const ws = connected({ onEdited: (m) => edited.push(m), onMessage: (m) => messages.push(m) })
    ws.recv({ type: FRAMES.message, task_id: 't1', cursor: 'c9', env: { from_box: 'box-a', msg: { msg_id: 'm2', task_id: 't1', body: 'hi' } } })
    assert.equal(edited.length, 0)
    assert.equal(messages.length, 1)
  })

  it('takes msg_id from the frame when the envelope does not repeat it', () => {
    const edited = []
    const ws = connected({ onEdited: (m) => edited.push(m) })
    ws.recv({ type: FRAMES.edited, msg_id: 'm1', task_id: 't1', ...EDITED, env: { from_box: 'box-wui', msg: { body: 'the new msg' } } })
    assert.equal(edited[0].msg_id, 'm1')
  })

  it('a client with no onEdited handler does not throw on the frame', () => {
    /* an older page kept open across a hub roll gets these frames too */
    const ws = connected({})
    assert.doesNotThrow(() => ws.recv({ type: FRAMES.edited, msg_id: 'm1', env: { msg: { body: 'x' } } }))
  })
})

describe('putting the edit back into a list (FR-ED-009: it does not move)', () => {
  const rows = () => [
    { msg_id: 'm1', body: 'first', ts: 't1', cursor: 'c1' },
    { msg_id: 'm2', body: 'the old msg', ts: 't2', cursor: 'c2', files: [{ file_id: 'f1' }] },
    { msg_id: 'm3', body: 'third', ts: 't3', cursor: 'c3' },
  ]

  it('replaces IN PLACE — same index, same order', () => {
    const out = applyEdit(rows(), { msg_id: 'm2', body: 'the new msg', ...EDITED })
    assert.deepEqual(out.map((m) => m.msg_id), ['m1', 'm2', 'm3'])
    assert.equal(out[1].body, 'the new msg')
    assert.equal(out[1].edited_at, EDITED.edited_at)
    assert.equal(out.length, 3)
  })

  it('leaves ts and cursor alone — a typo fix must not jump down the thread', () => {
    const out = applyEdit(rows(), { msg_id: 'm2', body: 'the new msg', ...EDITED })
    assert.equal(out[1].ts, 't2')
    assert.equal(out[1].cursor, 'c2')
  })

  it('keeps fields the edit frame does not carry', () => {
    const out = applyEdit(rows(), { msg_id: 'm2', body: 'the new msg', ...EDITED })
    assert.deepEqual(out[1].files, [{ file_id: 'f1' }])
  })

  it('ignores a message this list does not hold, rather than appending it', () => {
    /* an edit is a replacement; inventing a row for a message the reader
       never had would show it out of order and outside its window */
    const before = rows()
    const out = applyEdit(before, { msg_id: 'zz', body: 'not here', ...EDITED })
    assert.equal(out.length, 3)
    assert.equal(out, before, 'the same array is returned when nothing matched')
  })

  it('does not mutate the array it was given', () => {
    const before = rows()
    applyEdit(before, { msg_id: 'm2', body: 'the new msg', ...EDITED })
    assert.equal(before[1].body, 'the old msg')
  })

  it('survives an empty list and a frame with no msg_id', () => {
    assert.deepEqual(applyEdit([], { msg_id: 'm1' }), [])
    assert.deepEqual(applyEdit(rows(), {}).length, 3)
    assert.deepEqual(applyEdit(null, { msg_id: 'm1' }), [])
  })
})

describe('the client call (message-edit-v1 §1)', () => {
  const M1 = '11111111-1111-4111-8111-111111111111'

  it('PATCHes /v1/messages/{msg_id} with { body } and no new header', async () => {
    const { fn, calls } = stubFetch([
      [(u, o) => u === `/v1/messages/${M1}` && o.method === 'PATCH',
        [200, { cursor: 'c1', ...EDITED, env: { from_box: 'box-wui', msg: { v: 1, msg_id: M1, body: 'the new msg' } } }]],
    ])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const row = await c.editMessage(M1, 'the new msg')
    assert.equal(calls.length, 1)
    /* §1: the prefix is /v1/, not /api/v1/ — the latter is the auth mount */
    assert.equal(calls[0].url, `/v1/messages/${M1}`)
    assert.equal(calls[0].opts.method, 'PATCH')
    assert.deepEqual(JSON.parse(calls[0].opts.body), { body: 'the new msg' })
    /* content-type is the only one, and the channels POST already sends it:
       a NEW request header is a new CORS preflight, which has broken sign-in
       in this repo before */
    assert.deepEqual(Object.keys(calls[0].opts.headers).map((k) => k.toLowerCase()).sort(), ['accept', 'content-type'])
    /* and the answer is normalised like any other view element */
    assert.equal(row.body, 'the new msg')
    assert.equal(row.edited_at, EDITED.edited_at)
  })

  it('never puts the tenant in the body — it rides the session (spec 026)', async () => {
    const { fn, calls } = stubFetch([[() => true, [200, { env: { msg: { msg_id: M1, body: 'x' } } }]]])
    await createSpoolClient({ fetchFn: fn, mock: false, tenant: 't1' }).editMessage(M1, 'x')
    assert.deepEqual(Object.keys(JSON.parse(calls[0].opts.body)), ['body'])
  })

  it("lifts the hub's refusal token onto the error, which is what the UI reports on", async () => {
    for (const [status, token] of [[403, 'not_author'], [404, 'not_found'], [400, 'empty_body'], [409, 'not_editable'], [413, 'too_large']]) {
      const { fn } = stubFetch([[() => true, [status, { error: token, detail: 'nope' }]]])
      const c = createSpoolClient({ fetchFn: fn, mock: false })
      await assert.rejects(() => c.editMessage(M1, 'x'), (e) => {
        assert.equal(e.status, status)
        assert.equal(e.token, token)
        return true
      }, token)
    }
  })

  it('refuses an empty msg_id before it reaches the network', async () => {
    const { fn, calls } = stubFetch([[() => true, [200, {}]]])
    await assert.rejects(() => createSpoolClient({ fetchFn: fn, mock: false }).editMessage('', 'x'))
    assert.equal(calls.length, 0)
  })
})

describe('the lde mock edits for real, including the refusals', () => {
  const own = async (c) => (await c.listMessages({ channel: 'lobby' })).messages.find((m) => m.from === 'HUM-1')

  it('edits the stored row and stamps the three fields', async () => {
    const c = createSpoolClient({ mock: true })
    const row = await own(c)
    const out = await c.editMessage(row.msg_id, 'the new msg')
    assert.equal(out.body, 'the new msg')
    assert.equal(out.edited_by, 'HUM-1')
    assert.equal(out.revision, 2)
    assert.match(out.edited_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
    /* and it is the STORE that changed, not just the answer */
    const again = (await c.listMessages({ channel: 'lobby' })).messages.find((m) => m.msg_id === row.msg_id)
    assert.equal(again.body, 'the new msg')
  })

  it('does not move the row it edited (FR-ED-009)', async () => {
    const c = createSpoolClient({ mock: true })
    const before = (await c.listMessages({ channel: 'lobby' })).messages.map((m) => m.msg_id)
    const row = await own(c)
    await c.editMessage(row.msg_id, 'the new msg')
    const after = (await c.listMessages({ channel: 'lobby' })).messages.map((m) => m.msg_id)
    assert.deepEqual(after, before)
  })

  it('counts revisions up from the original', async () => {
    const c = createSpoolClient({ mock: true })
    const row = await own(c)
    assert.equal((await c.editMessage(row.msg_id, 'one')).revision, 2)
    assert.equal((await c.editMessage(row.msg_id, 'two')).revision, 3)
  })

  it("refuses somebody else's message with the hub's own token", async () => {
    const c = createSpoolClient({ mock: true })
    const theirs = (await c.listMessages({ channel: 'tasks' })).messages.find((m) => m.from !== 'HUM-1')
    await assert.rejects(() => c.editMessage(theirs.msg_id, 'x'), (e) => e.status === 403 && e.token === 'not_author')
  })

  it('refuses an empty body and an unknown id', async () => {
    const c = createSpoolClient({ mock: true })
    const row = await own(c)
    await assert.rejects(() => c.editMessage(row.msg_id, '   '), (e) => e.status === 400 && e.token === 'empty_body')
    await assert.rejects(() => c.editMessage('nope', 'x'), (e) => e.status === 404 && e.token === 'not_found')
  })
})
