// SPL-1008: the middle card's "N >>" equals the replies the reader may read,
// after a reload and live. prd t1 #spool-hub-mobile 2026-09-27: 6576fead
// showed "2 >>" with 6 replies stored, a1d39ecc "0 >>" with a blocker reply.
// listMessages keeps the newest `limit` lines of a 20-topic page (plus each
// opener), so an older topic's middle replies are not held; the count must
// come from the hub's §4.3 row, not from the held lines.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { dropFromTotals, mergeLive, mergeTopicTotals, topicReplies } from '../../src/utils/channel-feed.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')

const TOLD = '44440000-0000-4000-8000-00000000c001'
const TNEW = '44440000-0000-4000-8000-00000000c002'

const el = (received_at, msg, extra = {}) => ({
  cursor: `c-${msg.msg_id}`,
  received_at,
  env: { from_box: 'box-desk', to_box: 'box-wui', channel: 'mobile', ...extra, msg: { v: 1, ts: received_at, ...msg }, sig: 's' },
})

/** The old topic: an owner post, then agent replies of every shape the card must count. */
function oldTopic(extra = []) {
  return [
    el('2026-09-27T10:09:19Z', { msg_id: 'o0', task_id: TOLD, from: 'HUM-10', to: 'ALL-0', kind: 'note', body: 'root' }, { from_box: 'box-wui', to_box: '' }),
    el('2026-09-27T10:09:55Z', { msg_id: 'o1', task_id: TOLD, from: 'CLE-001', to: 'HUM-10', kind: 'note', body: 'agent to a human' }),
    el('2026-09-27T10:10:04Z', { msg_id: 'o2', task_id: TOLD, from: 'CLE-2', to: 'HUM-10', kind: 'blocker', body: 'a blocker' }),
    el('2026-09-27T10:10:32Z', { msg_id: 'o3', task_id: TOLD, from: 'CLE-3', to: 'HUM-10', kind: 'note', body: 'r3' }),
    el('2026-09-27T10:30:00Z', { msg_id: 'o4', task_id: TOLD, from: 'CLE-3', to: 'HUM-10', kind: 'note', body: 'r4' }),
    el('2026-09-27T10:40:51Z', { msg_id: 'o5', task_id: TOLD, from: 'CLE-3', to: 'HUM-10', kind: 'note', body: 'r5' }),
    el('2026-09-27T10:42:13Z', { msg_id: 'o6', task_id: TOLD, from: 'CLE-2', to: 'HUM-10', kind: 'result', body: 'r6' }),
    ...extra,
  ]
}

function newTopic() {
  return [
    el('2026-09-27T17:04:29Z', { msg_id: 'n0', task_id: TNEW, from: 'HUM-10', to: 'ALL-0', kind: 'note', body: 'new root' }, { from_box: 'box-wui', to_box: '' }),
    el('2026-09-27T17:05:03Z', { msg_id: 'n1', task_id: TNEW, from: 'CLE-001', to: 'HUM-10', kind: 'note', body: 'n1' }),
  ]
}

function client(oldMsgs) {
  const routes = [
    [(u) => u.startsWith('/v1/view/topics?'), () => ({
      topics: [
        { task_id: TNEW, channel: 'mobile', first_ts: '2026-09-27T17:04:29Z', last_ts: '2026-09-27T17:05:03Z', count: 2, subject: 'new root' },
        { task_id: TOLD, channel: 'mobile', first_ts: '2026-09-27T10:09:19Z', last_ts: oldMsgs[oldMsgs.length - 1].received_at, count: oldMsgs.length, subject: 'root' },
      ],
      next: null,
    })],
    [(u) => u.startsWith(`/v1/view/topics/${TNEW}?`), () => ({ task_id: TNEW, messages: newTopic().reverse(), next: null })],
    [(u) => u.startsWith(`/v1/view/topics/${TOLD}?`), (u) => {
      const q = new URL(u, 'http://x').searchParams
      const n = Number(q.get('limit')) || 200
      const rows = q.get('order') === 'desc' ? oldMsgs.slice().reverse().slice(0, n) : oldMsgs.slice(0, n)
      return { task_id: TOLD, messages: rows, next: null }
    }],
  ]
  const fetchFn = async (url) => {
    const hit = routes.find(([p]) => p(url))
    const body = hit ? hit[1](url) : { error: 'not_found' }
    return { ok: !!hit, status: hit ? 200 : 404, headers: { get: () => 'application/json' }, json: async () => body }
  }
  return createSpoolClient({ fetchFn, mock: false })
}

describe('SPL-1008 reply counts', () => {
  it('an older topic cut to its opener and last lines still counts every reply (blocker, agent to HUM-x)', async () => {
    const page = await client(oldTopic()).listMessages({ channel: 'mobile', limit: 4 })
    const held = page.messages.filter((m) => m.task_id === TOLD).length
    assert.ok(held < 7, `the cut must drop middle replies for this shape to mean anything (held ${held})`)
    /* the pre-fix count: what is held, minus the opener - the photo's "2 >>" */
    assert.equal(topicReplies(page.messages, TOLD), held - 1)
    assert.equal(topicReplies(page.messages, TOLD, page.totals[TOLD]), 6)
    assert.equal(topicReplies(page.messages, TNEW, page.totals[TNEW]), 1)
  })

  it('a reply that arrived while the tab was closed is counted after the reload', async () => {
    const late = el('2026-09-27T18:00:00Z', { msg_id: 'o7', task_id: TOLD, from: 'CLE-4', to: 'HUM-10', kind: 'note', body: 'while closed' }, { from_box: 'box-other' })
    const page = await client(oldTopic([late])).listMessages({ channel: 'mobile', limit: 4 })
    assert.equal(topicReplies(page.messages, TOLD, page.totals[TOLD]), 7)
  })

  it('a live reply after the read adds one, and a re-read of the same topic does not double it', async () => {
    const page = await client(oldTopic()).listMessages({ channel: 'mobile', limit: 4 })
    const live = { msg_id: 'o7', task_id: TOLD, from: 'CLE-4', to: 'HUM-10', kind: 'blocker', ts: '2026-09-27T18:00:00Z', received_at: '2026-09-27T18:00:00.123Z' }
    const rows = mergeLive(page.messages, live)
    assert.equal(topicReplies(rows, TOLD, page.totals[TOLD]), 7)
    /* catch-up re-reads the topic list: its row now counts the live line */
    const totals = mergeTopicTotals(page.totals, { [TOLD]: { count: 8, last_ts: live.received_at } })
    assert.equal(topicReplies(rows, TOLD, totals[TOLD]), 7)
    /* an older read never replaces a newer one */
    assert.deepEqual(mergeTopicTotals(totals, page.totals)[TOLD], totals[TOLD])
  })

  it('an own pending send counts at once, whatever its clock says', async () => {
    const page = await client(oldTopic()).listMessages({ channel: 'mobile', limit: 4 })
    const rows = [...page.messages, { msg_id: 'p1', task_id: TOLD, ts: '2020-01-01T00:00:00Z', pending: true }]
    assert.equal(topicReplies(rows, TOLD, page.totals[TOLD]), 7)
  })

  it('a deleted held reply lowers the count', async () => {
    const page = await client(oldTopic()).listMessages({ channel: 'mobile', limit: 4 })
    const gone = page.messages.find((m) => m.msg_id === 'o6')
    const totals = dropFromTotals(page.totals, gone)
    const rows = page.messages.filter((m) => m.msg_id !== 'o6')
    assert.equal(topicReplies(rows, TOLD, totals[TOLD]), 5)
  })

  it('no total (mock) falls back to the held lines', () => {
    const rows = [{ msg_id: 'a', task_id: 't' }, { msg_id: 'b', task_id: 't' }]
    assert.equal(topicReplies(rows, 't'), 1)
    assert.equal(topicReplies(rows, 't', null), 1)
  })

  it('the channel store feeds the hub totals to the card count', () => {
    const src = readFileSync(join(SRC, 'stores/channel.ts'), 'utf8')
    assert.match(src, /topicReplies\(messages\.value, taskId, totals\.value\[taskId\]\)/)
    assert.equal((src.match(/mergeTopicTotals\(totals\.value, page\.totals\)/g) || []).length, 2, 'loadOlder and catchUp merge the page totals')
    assert.match(src, /totals\.value = page\.totals \|\| \{\}/)
  })
})
