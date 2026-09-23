import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  topLevel,
  threadOf,
  replyCount,
  parseMention,
  formatBytes,
  initials,
  channelSlug,
  retentionLabel,
  retentionDays,
  formatTs,
  formatAbsTs,
  formatElapsed,
  formatThreadTs,
  feedRow,
  belongsTo,
  mergeLive,
  connectionHealth,
  rootsByTask,
  threadReplies,
  followPlan,
  rowFromAck,
  channelFollow,
  channelView,
  formatIsoTs,
  recipientOf,
} from '../../src/utils/channel-feed.mjs'
import { applyVerbosity } from '../../src/utils/verbosity.mjs'
import { MOCK_MESSAGES } from '../../src/utils/mock-data.mjs'

describe('channel-feed', () => {
  it('splits top-level from thread replies', () => {
    const top = topLevel(MOCK_MESSAGES)
    assert.equal(top.every((m) => !m.parent_task_id), true)
    const task = MOCK_MESSAGES.find((m) => m.kind === 'task')
    const thread = threadOf(MOCK_MESSAGES, task.task_id)
    assert.ok(thread.length >= 3)
    assert.equal(replyCount(MOCK_MESSAGES, task.task_id), thread.length - 1)
  })

  it('verbosity shows task/result/reject at minimal and notes at normal', () => {
    const taskId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    const thread = threadOf(MOCK_MESSAGES, taskId)
    const min = applyVerbosity(thread, 'minimal')
    const norm = applyVerbosity(thread, 'normal')
    const verb = applyVerbosity(thread, 'verbose')
    assert.equal(min.some((m) => m.kind === 'result'), true)
    assert.equal(min.some((m) => m.kind === 'task'), true)
    assert.equal(min.some((m) => m.kind === 'note'), false)
    assert.equal(norm.some((m) => m.body === 'Applying patch'), true)
    assert.equal(norm.some((m) => String(m.body).startsWith('[verbose]')), true)
    assert.equal(verb.length, thread.length)
  })

  it('parses @mention into a task', () => {
    const hit = parseMention('@CLE-07 review patch.zip')
    assert.deepEqual(hit, { to: 'CLE-07', kind: 'task', body: 'review patch.zip' })
    const note = parseMention('hello channel')
    assert.equal(note.kind, 'note')
    assert.equal(note.to, '@channel')
  })

  it('a leading id@box routes on the bare id and drops the box from the body', () => {
    assert.deepEqual(parseMention('@GRK-3492@box-desk please'), { to: 'GRK-3492', kind: 'task', body: 'please' })
    assert.deepEqual(parseMention('@GRK-3492@box-desk'), { to: 'GRK-3492', kind: 'task', body: '' })
    assert.deepEqual(parseMention('@GRK-3492 please'), { to: 'GRK-3492', kind: 'task', body: 'please' })
    assert.deepEqual(parseMention('@CLE-07please'), { to: '@channel', kind: 'note', body: '@CLE-07please' })
  })

  it('formats bytes and initials', () => {
    assert.equal(formatBytes(2048), '2.0 KiB')
    assert.equal(initials('CLE-07'), 'CL')
  })

  it('formats times and sizes in the active UI locale when given one (spec 021)', () => {
    const ts = '2026-09-19T14:05:00Z'
    assert.equal(formatTs(ts), '14:05')
    assert.equal(formatTs(ts, 'fi'), '14.05')
    assert.equal(formatTs(ts, 'en'), new Intl.DateTimeFormat('en', { hour: '2-digit', minute: '2-digit', timeZone: 'UTC' }).format(new Date(ts)))
    assert.equal(formatTs('not a date', 'fi'), 'not a date')
    assert.equal(formatAbsTs(ts), '2026-09-19 14:05:00')
    assert.equal(formatElapsed(0), '0s')
    assert.equal(formatElapsed(7), '7s')
    assert.equal(formatElapsed(59), '59s')
    assert.equal(formatElapsed(60), '1m')
    assert.equal(formatElapsed(72), '1m')
    assert.equal(formatElapsed(3600), '1h')
    assert.equal(formatElapsed(7383), '2h 3m')
    assert.equal(formatThreadTs(ts, Date.parse('2026-09-19T14:05:07Z')), '2026-09-19 14:05:00 sent 7s')
    assert.equal(formatThreadTs(ts, Date.parse('2026-09-19T14:05:59Z')), '2026-09-19 14:05:00 sent 59s')
    assert.equal(formatThreadTs(ts, Date.parse('2026-09-19T14:06:00Z')), '2026-09-19 14:05:00 sent 1m')
    assert.equal(formatThreadTs(ts, Date.parse('2026-09-19T14:08:00Z')), '2026-09-19 14:05:00 sent 3m')
    assert.equal(formatThreadTs(ts, Date.parse('2026-09-19T16:08:12Z')), '2026-09-19 14:05:00 sent 2h 3m')
    assert.equal(formatThreadTs(ts, Date.parse('2026-09-19T14:04:00Z')), '2026-09-19 14:05:00 sent 0s')
    assert.equal(formatThreadTs('not a date', 1), 'not a date')
    assert.equal(formatBytes(2048, 'fi'), '2,0 KiB')
    assert.equal(formatBytes(2048, 'en'), '2.0 KiB')
    assert.equal(retentionDays({ channel_id: 'alerts' }), 7)
    assert.equal(retentionDays({ channel_id: 'alerts', retention_days: 3 }), 3)
    assert.equal(retentionDays({ channel_id: 'lobby', retention_days: 30 }), 0)
  })
})

describe('channel-feed live rows (gap A2)', () => {
  const row = {
    task_id: 't1', first_ts: '2026-09-19T05:00:00Z', last_ts: '2026-09-19T06:00:00Z',
    count: 3, kinds: { note: 2, task: 1 }, participants: ['HUM-1@wui', 'CLE-2@box1'],
    subject: 'hello', channel: 'alerts',
  }

  it('maps a view-v1 thread row onto a root card', () => {
    const f = feedRow(row)
    assert.equal(f.msg_id, 't1')
    assert.equal(f.task_id, 't1')
    assert.equal(f.from, 'HUM-1')
    assert.equal(f.from_box, 'wui')
    assert.equal(f.body, 'hello')
    assert.equal(f.kind, 'note')
    assert.equal(f.channel, 'alerts')
    assert.equal(f.count, 2)
    assert.equal(f.parent_task_id, null)
    const flat = { msg_id: 'm1', body: 'x' }
    assert.equal(feedRow(flat), flat)
  })

  it('routes a live message to its channel or DM only', () => {
    assert.equal(belongsTo({ channel: 'alerts' }, { channel: 'alerts' }), true)
    assert.equal(belongsTo({ channel: 'tasks' }, { channel: 'alerts' }), false)
    assert.equal(belongsTo({ channel: 'general' }, { channel: 'lobby' }), true)
    assert.equal(belongsTo({ channel: null, from: 'CLE-2', from_box: 'b1' }, { peer: 'CLE-2@b1' }), true)
    assert.equal(belongsTo({ channel: null, to: 'CLE-2' }, { peer: 'CLE-2' }), true)
    assert.equal(belongsTo({ channel: null, from: 'CLE-2', from_box: 'b2' }, { peer: 'CLE-2@b1' }), false)
    assert.equal(belongsTo({ channel: 'lobby', from: 'CLE-2' }, { peer: 'CLE-2' }), false)
    assert.equal(belongsTo({ channel: 'lobby' }, {}), false)
  })

  it('merges live frames: dedupe, bump the thread row, append a new root', () => {
    const rows = [feedRow(row)]
    const reply = { msg_id: 'm9', task_id: 't1', ts: '2026-09-19T07:00:00Z', channel: 'alerts' }
    const bumped = mergeLive(rows, reply)
    assert.equal(bumped.length, 1)
    assert.equal(bumped[0].count, 3)
    assert.equal(bumped[0].last_ts, '2026-09-19T07:00:00Z')
    assert.equal(rows[0].count, 2, 'input not mutated')
    const fresh = { msg_id: 'm10', task_id: 't2', ts: '2026-09-19T08:00:00Z', channel: 'alerts' }
    const appended = mergeLive(bumped, fresh)
    assert.equal(appended.length, 2)
    assert.equal(mergeLive(appended, fresh), appended)
  })

  it('slugs a channel name and labels only #alerts retention', () => {
    assert.equal(channelSlug('#Release Notes!'), 'release-notes')
    assert.equal(channelSlug('  '), '')
    assert.equal(retentionLabel({ channel_id: 'alerts', retention_days: 7 }), '7 d')
    assert.equal(retentionLabel({ channel: 'alerts' }), '7 d')
    assert.equal(retentionLabel({ channel_id: 'alerts', retention_days: 3 }), '3 d')
    assert.equal(retentionLabel({ channel_id: 'lobby', retention_days: 30 }), '')
  })
})

describe('sidebar connection health (gap A2)', () => {
  it('maps the live socket state onto ok / warn / down', () => {
    assert.equal(connectionHealth('open'), 'ok')
    assert.equal(connectionHealth('mock'), 'ok')
    assert.equal(connectionHealth('connecting'), 'warn')
    assert.equal(connectionHealth('reconnecting'), 'warn')
    assert.equal(connectionHealth('closed'), 'down')
    assert.equal(connectionHealth('no_base'), 'down')
    assert.equal(connectionHealth(''), 'down')
  })
})

describe('live channel / DM wiring (gap A2)', () => {
  const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
  const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

  it('polls only the mock tenant; live mode merges WS frames and catches up on reconnect', () => {
    const ev = src('src/composables/useSpoolEvents.ts')
    assert.match(ev, /if \(api\.mock\) \{\s+timer = setInterval/)
    assert.equal(ev.includes('channel.ingestLive(m)'), true)
    assert.equal(ev.includes('live.onReconnected('), true)
  })

  it('offers channel creation in live mode and names the hub errors', () => {
    const sb = src('src/components/ChannelSidebar.vue')
    assert.equal(sb.includes('v-if="api.mock"'), false)
    assert.equal(sb.includes('channel_exists'), true)
    assert.equal(sb.includes('bad_channel'), true)
    assert.equal(sb.includes('retentionLabel(c)'), true)
    assert.equal(sb.includes('connection-health'), true)
    assert.equal(sb.includes("notes.mentions['ch:' + c.channel_id]"), true)
  })

  it('the store maps hub rows to feed rows and sends read= cursors', () => {
    const st = src('src/stores/channel.ts')
    assert.equal(st.includes('.map(feedRow)'), true)
    assert.equal(st.includes('readMap(loadCursors())'), true)
  })
})

describe('live flat feed (A1 listMessages shape, gap A2)', () => {
  const flat = [
    { msg_id: 'a', task_id: 't1', ts: '1' },
    { msg_id: 'b', task_id: 't2', ts: '2' },
    { msg_id: 'c', task_id: 't1', ts: '3' },
    { msg_id: 'd', task_id: 't1', ts: '4' },
    { msg_id: 'e', task_id: 't9', parent_task_id: 't2', ts: '5' },
  ]
  it('shows one card per thread and counts its replies', () => {
    assert.deepEqual(rootsByTask(topLevel(flat)).map((m) => m.msg_id), ['a', 'b'])
    assert.equal(threadReplies(flat, 't1'), 2)
    assert.equal(threadReplies(flat, 't2'), 1)
    assert.equal(threadReplies([feedRow({ task_id: 't5', count: 4 })], 't5'), 3)
  })
  it('matches mock replyCount for mock threads', () => {
    const task = MOCK_MESSAGES.find((m) => m.kind === 'task')
    assert.equal(threadReplies(MOCK_MESSAGES, task.task_id), replyCount(MOCK_MESSAGES, task.task_id))
  })
})

describe('live subscriptions + own send (hub fans out per subscribed task, gap A2)', () => {
  it('adds new threads, drops gone ones, never drops the lobby task', () => {
    assert.deepEqual(followPlan(['t1', 't2', 'LOBBY'], ['t2', 't3'], 'LOBBY'), { add: ['t3'], drop: ['t1'] })
    assert.deepEqual(followPlan([], ['t1', '', 't1']), { add: ['t1'], drop: [] })
  })
  it('builds our card from the ack so the echo frame dedupes on msg_id', () => {
    const ack = { type: 'ack', msg_id: 'm1', task_id: 't1', cursor: 'C', received_at: '2026-09-19T09:00:00Z' }
    const row = rowFromAck(ack, { task_id: 't1', kind: 'note', body: 'hi' }, { from: 'HUM-2', channel: 'a2' })
    assert.equal(row.msg_id, 'm1')
    assert.equal(row.cursor, 'C')
    assert.equal(row.channel, 'a2')
    assert.equal(row.from, 'HUM-2')
    assert.equal(mergeLive([row], { ...row }).length, 1)
  })
})

describe('channelFollow (H4, wui-live-ws 0.4 channel subscription)', () => {
  it('follows the open channel, switches on navigation, drops it for a DM', () => {
    assert.deepEqual(channelFollow('', { channel: '#Lobby' }), { sub: 'lobby', unsub: '', next: 'lobby' })
    assert.deepEqual(channelFollow('lobby', { channel: 'lobby' }), { sub: '', unsub: '', next: 'lobby' })
    assert.deepEqual(channelFollow('lobby', { channel: 'tasks' }), { sub: 'tasks', unsub: 'lobby', next: 'tasks' })
    assert.deepEqual(channelFollow('tasks', { channel: null, peer: 'HUM-2@box-wui' }), { sub: '', unsub: 'tasks', next: '' })
    assert.deepEqual(channelFollow('', {}), { sub: '', unsub: '', next: '' })
  })
})


/*
 * CLE-3446 — symptom A. The owner, 2026-09-22:
 *
 *   "basically three is some kind of mix between the who sends the msg and
 *    the avatar"
 *
 * There was no data defect. `threadCards` spread the FIRST message of a task
 * and thereafter updated only `last_ts` and `count`, so a card kept the ROOT's
 * `from` / `from_box` / `body` beside the NEWEST message's clock. In a
 * two-party conversation the root is always the human, so every row rendered
 * the human's identicon and the agent's reply was folded away entirely.
 * `MessageCard` renders SpoolAvatar and AgentBadge from the same `msg.from`,
 * which is why the name was wrong too.
 *
 * The owner then settled the format (relayed by CLE-3444, 2026-09-22):
 *
 *   [identicon] HUM-17@box-wui   ->  [robot] CLE-3444@box-desk   note   <iso>
 *   [robot] CLE-3444@box-desk    ->  [identicon] HUM-17@box-wui  note   <iso>
 *
 * per message, sender -> recipient, the arrow flipping per row, kind badge
 * kept, and a REAL ISO 8601 stamp with the T and the Z.
 *
 * CONTROL — and this one was a NATURAL red, not a planted one: with
 * `channelView` still folding (`threadCards(topLevel(...))`), the first case
 * below reads ['t1-1'] for a two-message conversation and fails with the
 * ROOT's sender on the reply's row. That is the owner's bug, reproduced in
 * the suite that runs in a second.
 */
describe('CLE-3446 — a channel row is ONE MESSAGE, and carries its own sender', () => {
  const at = (n) => `2026-09-22T11:${String(n).padStart(2, '0')}:03Z`
  /* a two-party conversation in ONE task: the human opens it, the agent replies */
  const CONV = [
    { msg_id: 'm1', task_id: 'tA', ts: at(58), from: 'HUM-17', from_box: 'box-wui', to: 'CLE-3444', to_box: 'box-desk', kind: 'note', body: 'ping', parent_task_id: null },
    { msg_id: 'm2', task_id: 'tA', ts: at(59), from: 'CLE-3444', from_box: 'box-desk', to: 'HUM-17', to_box: 'box-wui', kind: 'note', body: 'pong', parent_task_id: null },
  ]

  it('both sides of a two-party thread are rows, each with its OWN sender', () => {
    const rows = channelView(CONV).rows
    assert.deepEqual(rows.map((m) => m.msg_id), ['m2', 'm1'], 'the agent reply is a row, newest first')
    assert.equal(rows[0].from, 'CLE-3444', "the reply's row is the AGENT")
    assert.equal(rows[0].from_box, 'box-desk')
    assert.equal(rows[1].from, 'HUM-17', "the opener's row is the HUMAN")
    assert.equal(rows[1].from_box, 'box-wui')
  })

  it('the avatar cannot disagree with the sender, because both read msg.from', () => {
    /* the mechanism, pinned: MessageCard feeds SpoolAvatar and AgentBadge from
       the SAME field, so a row that carries the right `from` cannot show the
       wrong face. The defect was upstream, in what the row carried. */
    const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
    assert.match(vue, /<SpoolAvatar class="avatar" :id="String\(msg\.from \|\| ''\)"/)
    assert.match(vue, /<AgentBadge :id="String\(msg\.from\)"/)
  })

  it('the arrow flips per row: the recipient is read from THAT message', () => {
    const rows = channelView(CONV).rows
    assert.deepEqual(recipientOf(rows[0]), { id: 'HUM-17', box: 'box-wui' })
    assert.deepEqual(recipientOf(rows[1]), { id: 'CLE-3444', box: 'box-desk' })
  })

  it('a broadcast has no recipient — BOTH "everyone" sentinels, not just the hub one', () => {
    /* ALL-0 is the hub's and is on every row off the wire. `@channel` is the
       CLIENT's -- parseMention, rowFromAck and the optimistic row in
       stores/channel.ts all default to it, and spool-client strips it before
       the frame goes out. Excluding only ALL-0 puts an arrow, an id and a
       generated ROBOT avatar for a participant called "@channel" beside every
       ordinary channel message the viewer sends. */
    assert.equal(recipientOf({ to: 'ALL-0', to_box: 'box-wui' }), null)
    assert.equal(recipientOf({ to: '@channel' }), null)
    assert.equal(recipientOf({ to: '' }), null)
    assert.equal(recipientOf(null), null)
    /* and a real participant still is one */
    assert.deepEqual(recipientOf({ to: 'CLE-07', to_box: 'box-a' }), { id: 'CLE-07', box: 'box-a' })
  })

  it('MessageCard renders the recipient beside the sender', () => {
    const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
    assert.match(vue, /v-if="recipient"/, 'no recipient half in the row')
    assert.match(vue, /class="avatar--to" :id="recipient\.id" :box="recipient\.box"/, 'the right-hand avatar is not the recipient')
    assert.doesNotMatch(vue, /class="avatar avatar--to"/, 'CONTROL: the inline mark must not take the 36px row-gutter rule')
    assert.match(vue, /recipientOf\(props\.msg\)/, 'the recipient is not read from THIS message')
  })

  it('stamps REAL ISO 8601 — with the T and the Z, and without bending formatAbsTs', () => {
    assert.equal(formatIsoTs('2026-09-22T11:58:03Z'), '2026-09-22T11:58:03Z')
    /* the hub sends fractional seconds on some rows; the owner's format has none */
    assert.equal(formatIsoTs('2026-09-22T09:07:33.67515Z'), '2026-09-22T09:07:33Z')
    assert.equal(formatIsoTs('not a date'), 'not a date')
    /* CONTROL: the old formatter is still the old formatter, untouched */
    assert.equal(formatAbsTs('2026-09-22T11:58:03Z'), '2026-09-22 11:58:03')
    assert.notEqual(formatIsoTs('2026-09-22T11:58:03Z'), formatAbsTs('2026-09-22T11:58:03Z'))
  })
})
