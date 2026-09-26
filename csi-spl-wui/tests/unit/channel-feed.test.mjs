import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  topLevel,
  topicOf,
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
  formatTopicTs,
  feedRow,
  belongsTo,
  mergeLive,
  connectionHealth,
  rootsByTask,
  topicReplies,
  followPlan,
  rowFromAck,
  channelFollow,
  channelView,
  formatIsoTs,
  formatMsgListTs,
  recipientOf,
} from '../../src/utils/channel-feed.mjs'
import { applyVerbosity } from '../../src/utils/verbosity.mjs'
import { MOCK_MESSAGES } from '../../src/utils/mock-data.mjs'
import { mentionDisplay, namedLine, peopleLabels, personTitle, shownPerson } from '../../src/utils/channel-feed.mjs'

describe('channel-feed', () => {
  it('splits top-level from topic replies', () => {
    const top = topLevel(MOCK_MESSAGES)
    assert.equal(top.every((m) => !m.parent_task_id), true)
    const task = MOCK_MESSAGES.find((m) => m.kind === 'task')
    const topic = topicOf(MOCK_MESSAGES, task.task_id)
    assert.ok(topic.length >= 3)
    assert.equal(replyCount(MOCK_MESSAGES, task.task_id), topic.length - 1)
  })

  it('verbosity shows task/result/reject at minimal and notes at normal', () => {
    const taskId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    const topic = topicOf(MOCK_MESSAGES, taskId)
    const min = applyVerbosity(topic, 'minimal')
    const norm = applyVerbosity(topic, 'normal')
    const verb = applyVerbosity(topic, 'verbose')
    assert.equal(min.some((m) => m.kind === 'result'), true)
    assert.equal(min.some((m) => m.kind === 'task'), true)
    assert.equal(min.some((m) => m.kind === 'note'), false)
    assert.equal(norm.some((m) => m.body === 'Applying patch'), true)
    assert.equal(norm.some((m) => String(m.body).startsWith('[verbose]')), true)
    assert.equal(verb.length, topic.length)
  })

  it('parses @mention into a task', () => {
    const hit = parseMention('@CLE-07 review patch.zip')
    assert.deepEqual(hit, { to: 'CLE-07', kind: 'task', body: 'review patch.zip' })
    const note = parseMention('hello channel')
    assert.equal(note.kind, 'note')
    assert.equal(note.to, '@channel')
  })

  it('formats bytes and initials', () => {
    assert.equal(formatBytes(2048), '2.0 KiB')
    assert.equal(initials('CLE-07'), 'CL')
  })

  it('formats times and sizes in the active UI locale when given one (spec 021)', () => {
    const ts = '2026-09-19T14:05:00Z'
    assert.equal(formatTs(ts), '14:05')
    assert.equal(formatTs(ts, 'fi'), '14:05')
    assert.equal(formatTs(ts, 'en'), '14:05')
    assert.equal(formatTs('not a date', 'fi'), 'not a date')
    assert.equal(formatAbsTs(ts), '2026-09-19 14:05:00')
    assert.equal(formatElapsed(0), '0s')
    assert.equal(formatElapsed(7), '7s')
    assert.equal(formatElapsed(59), '59s')
    assert.equal(formatElapsed(60), '1m')
    assert.equal(formatElapsed(72), '1m')
    assert.equal(formatElapsed(3600), '1h')
    assert.equal(formatElapsed(7383), '2h 3m')
    assert.equal(formatTopicTs(ts, Date.parse('2026-09-19T14:05:07Z')), '2026-09-19 14:05:00 sent 7s')
    assert.equal(formatTopicTs(ts, Date.parse('2026-09-19T14:05:59Z')), '2026-09-19 14:05:00 sent 59s')
    assert.equal(formatTopicTs(ts, Date.parse('2026-09-19T14:06:00Z')), '2026-09-19 14:05:00 sent 1m')
    assert.equal(formatTopicTs(ts, Date.parse('2026-09-19T14:08:00Z')), '2026-09-19 14:05:00 sent 3m')
    assert.equal(formatTopicTs(ts, Date.parse('2026-09-19T16:08:12Z')), '2026-09-19 14:05:00 sent 2h 3m')
    assert.equal(formatTopicTs(ts, Date.parse('2026-09-19T14:04:00Z')), '2026-09-19 14:05:00 sent 0s')
    assert.equal(formatTopicTs('not a date', 1), 'not a date')
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

  it('maps a view-v1 topic row onto a root card', () => {
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

  it('merges live frames: dedupe, bump the topic row, append a new root', () => {
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
  it('shows one card per topic and counts its replies', () => {
    assert.deepEqual(rootsByTask(topLevel(flat)).map((m) => m.msg_id), ['a', 'b'])
    assert.equal(topicReplies(flat, 't1'), 2)
    assert.equal(topicReplies(flat, 't2'), 1)
    assert.equal(topicReplies([feedRow({ task_id: 't5', count: 4 })], 't5'), 3)
  })
  it('matches mock replyCount for mock topics', () => {
    const task = MOCK_MESSAGES.find((m) => m.kind === 'task')
    assert.equal(topicReplies(MOCK_MESSAGES, task.task_id), replyCount(MOCK_MESSAGES, task.task_id))
  })
})

describe('live subscriptions + own send (hub fans out per subscribed task, gap A2)', () => {
  it('adds new topics, drops gone ones, never drops the lobby task', () => {
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
 * CLE-3446 kept sender -> recipient on the row that is shown (avatar and name
 * from the same `from`). Owner, 2026-09-23: pane 2 shows only the starter, so
 * that format is the starter's. A reply body must not sit beside the starter
 * avatar — the card is the starter, full stop.
 */
describe('pane 2 row is the starter and carries the starter sender', () => {
  const at = (n) => `2026-09-22T11:${String(n).padStart(2, '0')}:03Z`
  /* a two-party conversation in ONE task: the human opens it, the agent replies */
  const CONV = [
    { msg_id: 'm1', task_id: 'tA', ts: at(58), from: 'HUM-17', from_box: 'box-wui', to: 'CLE-3444', to_box: 'box-desk', kind: 'note', body: 'ping', parent_task_id: null },
    { msg_id: 'm2', task_id: 'tA', ts: at(59), from: 'CLE-3444', from_box: 'box-desk', to: 'HUM-17', to_box: 'box-wui', kind: 'note', body: 'pong', parent_task_id: null },
  ]

  it('pane 2 keeps the starter, not the reply beside the starter avatar', () => {
    const rows = channelView(CONV).rows
    assert.deepEqual(rows.map((m) => m.msg_id), ['m1'])
    assert.equal(rows[0].from, 'HUM-17')
    assert.equal(rows[0].from_box, 'box-wui')
    assert.equal(rows[0].body, 'ping')
  })

  it('the avatar cannot disagree with the sender, because both read the same author', () => {
    /* the mechanism, pinned: MessageCard feeds SpoolAvatar and AgentBadge from
       the SAME field, so a row that carries the right `from` cannot show the
       wrong face. The defect was upstream, in what the row carried. Since
       specs/036 FR-011 that field is `author` = typedByAuthor(msg): msg.from,
       or the verified typed_by of a line typed at the agent's terminal. */
    const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
    assert.match(vue, /<SpoolAvatar class="avatar" :id="author\.id" :box="author\.box"/)
    assert.match(vue, /<AgentBadge :id="author\.id"/)
    assert.match(vue, /const author = computed\(\(\) => typedByAuthor\(props\.msg\)\)/)
  })

  it('the pane-2 arrow is the starter recipient; the reply keeps its own', () => {
    const rows = channelView(CONV).rows
    assert.deepEqual(recipientOf(rows[0]), { id: 'CLE-3444', box: 'box-desk' })
    assert.deepEqual(recipientOf(CONV[1]), { id: 'HUM-17', box: 'box-wui' })
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
    assert.equal(formatMsgListTs('not a date'), 'not a date')
    /* CONTROL: the old formatter is still the old formatter, untouched */
    assert.equal(formatAbsTs('2026-09-22T11:58:03Z'), '2026-09-22 11:58:03')
    assert.notEqual(formatIsoTs('2026-09-22T11:58:03Z'), formatAbsTs('2026-09-22T11:58:03Z'))
  })

  it('the list clock is local yyyy-mm-dd HH:MM and the card hover keeps full ISO UTC', () => {
    const local = (raw) => {
      const d = new Date(raw)
      const p = (n) => String(n).padStart(2, '0')
      return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
    }
    for (const raw of ['2026-09-22T11:58:35Z', '2026-09-22T09:07:33.67515Z']) {
      const got = formatMsgListTs(raw)
      assert.equal(got, local(raw))
      assert.match(got, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/)
      assert.equal(got.includes('T') || got.includes('Z'), false)
    }
    const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/components/MessageCard.vue'), 'utf8')
    assert.match(vue, /:title="sinceMs == null \? formatIsoTs\(at\) : undefined"/)
    assert.match(vue, /:data-ts="at \|\| undefined"/)
    assert.match(vue, /formatMsgListTs\(at\.value/)
  })
})

/*
 * Pane 2 is topic starters only, including #lobby. One task_id is one topic:
 * the earliest message by ts is the row, and a later message is a reply even
 * with no parent_task_id. Replies stay available to pane 3.
 */
describe('pane 2 lists only the topic starter (owner 2026-09-23)', () => {
  const starter = {
    msg_id: 's', task_id: 't', ts: '2026-09-23T10:00:00Z', from: 'HUM-1', body: 'start', parent_task_id: null,
  }
  const replyA = {
    msg_id: 'r1', task_id: 't', ts: '2026-09-23T10:05:00Z', from: 'CLE-07', body: 'first reply', parent_task_id: null,
  }
  const replyB = {
    msg_id: 'r2', task_id: 't', ts: '2026-09-23T10:09:00Z', from: 'CLE-07', body: 'second reply', parent_task_id: 't',
  }

  it('one starter and two replies are one pane-2 row, and that row is the starter', () => {
    /* newest first in the array, so a first-seen fold would pick a reply */
    const all = [replyB, starter, replyA]
    const rows = channelView(all).rows
    assert.equal(rows.length, 1)
    assert.equal(rows[0].msg_id, 's')
    assert.equal(rows[0].body, 'start')
    assert.equal(rows[0].from, 'HUM-1')
    assert.equal(rows[0].count, 2)
    const topic = topicOf(all, 't')
    assert.deepEqual(topic.map((m) => m.msg_id), ['s', 'r1', 'r2'])
  })

  it('a parent_task_id on a different task_id is still not a pane-2 row', () => {
    const child = {
      msg_id: 'c', task_id: 'child', ts: '2026-09-23T10:08:00Z', from: 'CLE-07', body: 'child', parent_task_id: 't',
    }
    const rows = channelView([child, starter]).rows
    assert.deepEqual(rows.map((m) => m.msg_id), ['s'])
    assert.equal(rows[0].body, 'start')
  })

  it('a lobby task keeps its starter and drops later messages, parent or not', () => {
    const task = 'lobby-task'
    const a = { msg_id: 'a', task_id: task, ts: '2026-09-23T10:00:00Z', body: 'one', parent_task_id: null }
    const b = { msg_id: 'b', task_id: task, ts: '2026-09-23T10:02:00Z', body: 'two', parent_task_id: null }
    const reply = { msg_id: 'c', task_id: task, ts: '2026-09-23T10:03:00Z', body: 'reply', parent_task_id: task }
    const rows = channelView([a, b, reply], { lobby: true }).rows
    assert.equal(rows.length, 1)
    assert.equal(rows[0].msg_id, 'a')
    assert.equal(rows[0].body, 'one')
    assert.ok(String(rows[0].last_ts) >= '2026-09-23T10:03:00Z')
  })

  it('a follow-up on its own task_id whose parent is the starter is not a pane-2 row', () => {
    const task = 'lobby-task'
    const a = { msg_id: 'a', task_id: task, ts: '2026-09-23T10:00:00Z', body: 'one', parent_task_id: null }
    const b = { msg_id: 'b', task_id: task, ts: '2026-09-23T10:02:00Z', body: 'two', parent_task_id: null }
    const reply = { msg_id: 'c', task_id: 'child', ts: '2026-09-23T10:09:00Z', body: 'reply', parent_task_id: task }
    const rows = channelView([a, b, reply]).rows
    assert.deepEqual(rows.map((m) => m.msg_id), ['a'])
    assert.equal(rows[0].body, 'one')
  })

  it('rowFromAck keeps parent_task_id from the send frame', () => {
    const row = rowFromAck(
      { msg_id: 'm', task_id: 'child', received_at: '2026-09-23T10:00:00Z' },
      { task_id: 'child', body: 'reply', parent_task_id: 'lobby-task' },
      { from: 'HUM-1' },
    )
    assert.equal(row.parent_task_id, 'lobby-task')
    assert.equal(row.body, 'reply')
    const bare = rowFromAck({ msg_id: 'm2', task_id: 't' }, { task_id: 't', body: 'hi' })
    assert.equal(bare.parent_task_id, null)
  })

  it('the lobby page passes the starter list into pane 2', () => {
    const vue = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../src/pages/lobby.vue'), 'utf8')
    assert.match(vue, /:rows="store\.lobbyRows"/)
    assert.match(vue, /store\.loadOlder\('lobby'\)/)
    assert.doesNotMatch(vue, /:rows="store\.newestFirst"/)
  })
})

// owner, 2026-09-26: humans by their display name everywhere, the id on hover.
describe('display names for humans', () => {
  const names = { 'HUM-10': 'Pat Owner' }
  it('mentionDisplay: a named human reads as @name, the tag kept as the title', () => {
    assert.deepEqual(mentionDisplay('@HUM-10', names), { text: '@Pat Owner', title: '@HUM-10' })
    assert.deepEqual(mentionDisplay('@HUM-10@box-wui', names), { text: '@Pat Owner', title: '@HUM-10@box-wui' })
  })
  it('CONTROL: agents and nameless humans keep the tag as typed', () => {
    assert.deepEqual(mentionDisplay('@CLE-7', names), { text: '@CLE-7', title: '' })
    assert.deepEqual(mentionDisplay('@HUM-3', names), { text: '@HUM-3', title: '' })
    assert.deepEqual(mentionDisplay('@HUM-10', null), { text: '@HUM-10', title: '' })
  })
  it('peopleLabels: humans by name, agents unchanged', () => {
    assert.equal(peopleLabels(['HUM-10', 'CLE-7@box-a', 'HUM-3'], names), 'Pat Owner, CLE-7@box-a, HUM-3')
    assert.equal(peopleLabels([], names), '')
    assert.equal(peopleLabels(undefined, names), '')
  })
  it('shownPerson is the name, else the bare HUM id; an agent stays id@box', () => {
    assert.equal(shownPerson('HUM-10', 'box-wui', names), 'Pat Owner')
    assert.equal(shownPerson('HUM-3', 'box-wui', names), 'HUM-3')
    assert.equal(shownPerson('HUM-3', undefined, names), 'HUM-3')
    assert.equal(shownPerson('CLE-7', 'box-a', names), 'CLE-7@box-a')
  })
  it('personTitle is the full name and the id; a nameless human is the bare id', () => {
    assert.equal(personTitle('HUM-10', 'box-wui', names), 'Pat Owner · HUM-10')
    assert.equal(personTitle('HUM-3', 'box-wui', names), 'HUM-3')
    assert.equal(personTitle('CLE-7', 'box-a', names), 'CLE-7@box-a')
  })
  it('namedLine renames a peer list and leaves a subject alone', () => {
    assert.deepEqual(namedLine('HUM-10@box-wui, CLE-7@box-a', names), {
      text: 'Pat Owner, CLE-7@box-a',
      title: 'Pat Owner, CLE-7@box-a · HUM-10@box-wui, CLE-7@box-a',
    })
    assert.deepEqual(namedLine('ship the relay', names), { text: 'ship the relay', title: 'ship the relay' })
    assert.deepEqual(namedLine('', names), { text: '', title: '' })
  })
})
