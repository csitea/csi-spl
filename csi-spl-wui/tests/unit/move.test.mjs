// SPL-1024 (specs/045): move a topic to a channel, a reply to a topic - the
// view override, who may drag / is offered the menu entry, which rows light
// up as drop targets, how a move answer / frame changes the rows on screen,
// the old-URL redirect and the wiring of the pieces.
// Run: node tests/unit/move.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  isCardDropTarget,
  isChannelDropTarget,
  isMovableTopic,
  isPromoteDropTarget,
  mayMoveMessage,
  mayMoveTopic,
  mayPromoteMessage,
  movedNote,
} from '../../src/utils/move.mjs'
import {
  applyMoveRows,
  applyMoveToStores,
  moveChannelTargets,
  moveErrorKey,
  moveFrame,
  moveFrameFromAnswer,
  moveJoinsTask,
  moveLeavesTask,
  moveTopicChoices,
  movedChannelFor,
  queryTasks,
} from '../../src/utils/move-apply.mjs'
import { normalizeViewMessage } from '../../src/utils/view-api.mjs'
import { messageFromFrame } from '../../src/utils/live-ws.mjs'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

const LOBBY = 'L0'
const card = { msg_id: 'c1', task_id: 't1', from: 'HUM-1', channel: 'devel', is_parent: 1 }
const reply = { msg_id: 'r1', task_id: 't1', from: 'HUM-1', channel: 'devel', is_parent: 0 }
const member = { role: 'developer', tenantOwner: false }
const channels = [{ channel_id: 'lobby' }, { channel_id: 'devel' }, { channel_id: 'ops', name: 'Ops' }, { channel_id: 'issues' }, { channel_id: 'alerts' }]

describe('view override (move-v1 §5)', () => {
  const el = {
    cursor: 'k', env: { from_box: 'box-wui', channel: 'devel', parent_task_id: 'P', msg: { v: 1, msg_id: 'r1', task_id: 'old', body: 'x' } },
    channel: 'ops', task_id: 'new', parent_task_id: '', moved_at: '2026-09-28T10:00:00Z', moved_by: 'HUM-1',
    moved_from_channel: 'devel', moved_from_task: 'old',
  }
  it('the top-level place wins over the envelope; "" parent is none; the moved fields are copied', () => {
    const m = normalizeViewMessage(el)
    assert.equal(m.channel, 'ops')
    assert.equal(m.task_id, 'new')
    assert.equal(m.parent_task_id, null)
    assert.equal(m.moved_at, '2026-09-28T10:00:00Z')
    assert.equal(m.moved_by, 'HUM-1')
    assert.equal(m.moved_from_channel, 'devel')
    assert.equal(m.moved_from_task, 'old')
  })
  it('a row at home keeps its envelope and carries no moved key (control)', () => {
    const m = normalizeViewMessage({ env: el.env, cursor: 'k' })
    assert.equal(m.channel, 'devel')
    assert.equal(m.task_id, 'old')
    assert.equal(m.parent_task_id, 'P')
    for (const k of ['moved_at', 'moved_by', 'moved_from_channel', 'moved_from_task']) assert.equal(k in m, false, k)
  })
  it('a live message frame takes the same override', () => {
    const m = messageFromFrame({ type: 'message', ...el })
    assert.equal(m.channel, 'ops')
    assert.equal(m.task_id, 'new')
    assert.equal(m.moved_from_channel, 'devel')
  })
})

describe('who may move (spec 3.4)', () => {
  it('the author, the tenant owner and an admin move a channel topic', () => {
    assert.equal(mayMoveTopic(card, 'HUM-1', member, LOBBY), true)
    assert.equal(mayMoveTopic({ ...card, from: 'CLE-07' }, 'HUM-9', { role: 'admin' }, LOBBY), true)
    assert.equal(mayMoveTopic({ ...card, from: 'CLE-07' }, 'HUM-8', { role: 'biz_owner', tenantOwner: true }, LOBBY), true)
  })
  it('never another member, nor anyone before /v1/view/me answered unless it is their card', () => {
    assert.equal(mayMoveTopic(card, 'HUM-2', member, LOBBY), false)
    assert.equal(mayMoveTopic(card, 'HUM-2', null, LOBBY), false)
    assert.equal(mayMoveTopic(card, '', null, LOBBY), false)
  })
  it('never the lobby, a DM, an issue discussion, a reply, a pending echo or a topic-list stand-in', () => {
    assert.equal(isMovableTopic(card, LOBBY), true)
    assert.equal(isMovableTopic({ ...card, channel: 'lobby' }, LOBBY), false)
    assert.equal(isMovableTopic({ ...card, task_id: LOBBY }, LOBBY), false)
    assert.equal(isMovableTopic({ ...card, channel: null }, LOBBY), false)
    assert.equal(isMovableTopic({ ...card, channel: 'issues' }, LOBBY), false)
    assert.equal(isMovableTopic({ ...card, is_parent: 0 }, LOBBY), false)
    assert.equal(isMovableTopic({ ...card, pending: true }, LOBBY), false)
    assert.equal(isMovableTopic({ ...card, topic_row: true }, LOBBY), false)
  })
  it('a reply: author / owner / admin, never the pane opener, a card, the lobby or a DM', () => {
    const ctx = { openerId: 'c1', lobbyTaskId: LOBBY, channel: 'devel' }
    assert.equal(mayMoveMessage(reply, 'HUM-1', member, ctx), true)
    assert.equal(mayMoveMessage({ ...reply, from: 'CLE-07' }, 'HUM-9', { role: 'admin' }, ctx), true)
    assert.equal(mayMoveMessage(reply, 'HUM-2', member, ctx), false)
    assert.equal(mayMoveMessage({ ...reply, msg_id: 'c1' }, 'HUM-1', member, ctx), false, 'the opener')
    assert.equal(mayMoveMessage({ ...reply, is_parent: 1 }, 'HUM-1', member, ctx), false, 'a card (is_card)')
    assert.equal(mayMoveMessage({ ...reply, task_id: LOBBY, channel: 'lobby' }, 'HUM-1', member, ctx), false)
    assert.equal(mayMoveMessage({ ...reply, channel: null }, 'HUM-1', member, { ...ctx, channel: '' }), false, 'a DM')
    assert.equal(mayMoveMessage({ ...reply, channel: null }, 'HUM-1', member, ctx), true, 'no tag: the pane channel')
    assert.equal(mayMoveMessage({ ...reply, pending: true }, 'HUM-1', member, ctx), false)
  })

  it('an agent reply moves for any member; a person\'s reply does not (t1 ffc3b83c)', () => {
    const ctx = { openerId: 'c1', lobbyTaskId: LOBBY, channel: 'devel' }
    assert.equal(mayMoveTopic({ ...card, from: 'c-004' }, 'HUM-2', member, LOBBY), false, 'an agent topic keeps 041')
    assert.equal(mayMoveMessage({ ...reply, from: 'c-004' }, 'HUM-2', member, ctx), true, 'new-form agent')
    assert.equal(mayMoveMessage({ ...reply, from: 'CLE-07' }, 'HUM-2', null, ctx), true, 'legacy agent, no me loaded')
    assert.equal(mayMoveMessage({ ...reply, from: 'HUM-3' }, 'HUM-2', member, ctx), false, 'another person')
    assert.equal(mayMoveMessage({ ...reply, from: 'GST-3' }, 'HUM-2', member, ctx), false, 'a guest is a person')
    assert.equal(mayMoveMessage({ ...reply, from: 'c-004', is_parent: 1 }, 'HUM-2', member, ctx), false, 'still never a card')
    assert.equal(mayMoveMessage({ ...reply, from: 'c-004', task_id: LOBBY, channel: 'lobby' }, 'HUM-2', member, ctx), false, 'still never the lobby')
    assert.equal(mayMoveMessage({ ...reply, from: 'c-004', channel: null, to: 'HUM-1' }, 'HUM-2', member, { ...ctx, channel: '' }), false, 'a DM row to someone else')
  })

  it('a DM row moves out only when an agent sent it to the viewer, and never becomes a topic', () => {
    const dm = { openerId: 'c1', lobbyTaskId: LOBBY, channel: '' }
    const bot = { ...reply, from: 'c-002', to: 'HUM-10', channel: null }
    assert.equal(mayMoveMessage(bot, 'HUM-10', member, dm), true, 'the agent wrote to the viewer')
    assert.equal(mayMoveMessage(bot, 'HUM-10', null, dm), true, 'no me loaded: still the viewer\'s DM')
    assert.equal(mayMoveMessage(bot, 'HUM-2', { role: 'admin' }, dm), false, 'an admin who is not the DM\'s human')
    assert.equal(mayMoveMessage({ ...bot, from: 'HUM-10', to: 'c-002' }, 'HUM-10', member, dm), false, 'a person\'s DM row stays')
    assert.equal(mayMoveMessage({ ...bot, is_parent: 1 }, 'HUM-10', member, dm), false, 'never the DM\'s card')
    assert.equal(mayPromoteMessage(bot, 'HUM-10', member, dm), false, 'a DM row is never promoted')
    assert.equal(isPromoteDropTarget({ kind: 'message', msgId: 'r1', channel: '' }), false, 'nor dropped on the topics list')
    assert.equal(isPromoteDropTarget({ kind: 'message', msgId: 'r1', channel: 'devel' }), true)
  })
})

describe('drop targets (FR-MV-009)', () => {
  const topicDrag = { kind: 'topic', msgId: 'c1', taskId: 't1', topicTask: 't1', channel: 'devel' }
  const msgDrag = { kind: 'message', msgId: 'r1', taskId: 't1', topicTask: 't1', channel: 'devel' }
  it('a topic lights up the listed channels, never its own, the lobby or issues', () => {
    assert.equal(isChannelDropTarget(topicDrag, 'ops', channels), true)
    assert.equal(isChannelDropTarget(topicDrag, 'devel', channels), false)
    assert.equal(isChannelDropTarget(topicDrag, 'lobby', channels), false)
    assert.equal(isChannelDropTarget(topicDrag, 'issues', channels), false)
    assert.equal(isChannelDropTarget(topicDrag, 'secret', channels), false, 'not listed for the viewer')
    assert.equal(isChannelDropTarget(msgDrag, 'ops', channels), false, 'a reply never drops on a channel')
    assert.equal(isChannelDropTarget(null, 'ops', channels), false, 'no drag, no target')
  })
  it('a reply lights up other channel topic cards, never its own topic, its own thread or the lobby', () => {
    const other = { msg_id: 'c2', task_id: 't2', channel: 'devel', is_parent: 1 }
    assert.equal(isCardDropTarget(msgDrag, other, LOBBY), true)
    assert.equal(isCardDropTarget(msgDrag, card, LOBBY), false)
    assert.equal(isCardDropTarget(msgDrag, { ...other, task_id: 'r1' }, LOBBY), false, 'cycle')
    assert.equal(isCardDropTarget(msgDrag, { ...other, channel: 'lobby' }, LOBBY), false)
    assert.equal(isCardDropTarget(msgDrag, { ...other, channel: null }, LOBBY), false, 'a DM')
    assert.equal(isCardDropTarget(topicDrag, other, LOBBY), false, 'a card never drops on a card')
  })
  it('the channel picker lists the same set, current one left out', () => {
    assert.deepEqual(moveChannelTargets(channels, 'devel').map((c) => c.channel_id), ['ops', 'alerts'])
    assert.equal(moveChannelTargets(channels, 'devel')[0].name, 'Ops')
  })
})

describe('frames and answers (move-v1 §6)', () => {
  const rows = [
    { msg_id: 'c1', task_id: 't1', channel: 'devel', is_parent: 1 },
    { msg_id: 'r1', task_id: 't1', channel: 'devel', is_parent: 0 },
    { msg_id: 'x1', task_id: 'r1', channel: 'devel', parent_task_id: 't1' },
    { msg_id: 'z9', task_id: 't9', channel: 'devel' },
  ]
  const topicMoved = { type: 'topic_moved', msg_id: 'c1', task_id: 't1', channel: 'ops', from_channel: 'devel', moved: true, moved_by: 'HUM-1', moved_at: 'T', msg_ids: ['r1'] }
  const msgMoved = { type: 'message_moved', msg_id: 'r1', task_id: 't2', from_task: 't1', channel: 'devel', from_channel: 'devel', moved: true, moved_by: 'HUM-1', moved_at: 'T', msg_ids: ['r1', 'x1'] }
  it('topic_moved re-channels every named row (the card included) and stamps its home', () => {
    const out = applyMoveRows(rows, topicMoved)
    assert.deepEqual(out.map((r) => r.channel), ['ops', 'ops', 'devel', 'devel'])
    assert.equal(out[0].moved_from_channel, 'devel')
    assert.equal(out[3], rows[3], 'an untouched row is the same object')
  })
  it('message_moved re-homes the reply as a reply of the target and re-points its thread', () => {
    const out = applyMoveRows(rows, msgMoved)
    assert.equal(out[1].task_id, 't2')
    assert.equal(out[1].is_parent, 0)
    assert.equal(out[1].parent_task_id, null)
    assert.equal(out[1].moved_from_task, 't1')
    assert.equal(out[2].parent_task_id, 't2')
    assert.equal(out[0], rows[0])
  })
  it('is idempotent, keeps the first home, and a move home clears the stamp', () => {
    const once = applyMoveRows(rows, topicMoved)
    const twice = applyMoveRows(once, topicMoved)
    assert.deepEqual(twice, once)
    const again = applyMoveRows(once, { ...topicMoved, channel: 'alerts', from_channel: 'ops' })
    assert.equal(again[0].moved_from_channel, 'devel', 'the note always names the home')
    const home = applyMoveRows(once, { ...topicMoved, channel: 'devel', from_channel: 'ops', moved: false })
    assert.equal(home[0].channel, 'devel')
    assert.equal('moved_at' in home[0], false)
    assert.equal('moved_from_channel' in home[0], false)
  })
  it('a pane on the old topic drops the reply; one on the new topic re-reads', () => {
    assert.deepEqual(moveLeavesTask(msgMoved, 't1'), ['r1'])
    assert.deepEqual(moveLeavesTask(msgMoved, 't2'), [])
    assert.equal(moveJoinsTask(msgMoved, 't2'), true)
    assert.equal(moveJoinsTask(msgMoved, 't1'), false)
    assert.equal(moveJoinsTask(topicMoved, 't1'), false)
  })
  it('a frame of another type is nothing; an answer stands for its frame', () => {
    assert.equal(moveFrame({ type: 'topic_archived', msg_id: 'c1' }), null)
    assert.equal(applyMoveRows(rows, { type: 'message_deleted', msg_id: 'r1' }), rows)
    const f = moveFrameFromAnswer({ kind: 'message', msg_id: 'r1', task_id: 't2', from_task: 't1', channel: 'devel', moved: true, msg_ids: ['x1'] })
    assert.equal(f.type, 'message_moved')
    assert.deepEqual(f.msg_ids, ['r1', 'x1'])
    assert.equal(moveFrameFromAnswer({ kind: 'topic', msg_id: 'c1' }).type, 'topic_moved')
  })
})

describe('a move applied to the stores on screen', () => {
  const frame = { type: 'message_moved', msg_id: 'r1', task_id: 't2', from_task: 't1', channel: 'devel', from_channel: 'devel', moved: true, moved_by: 'HUM-1', moved_at: 'T', msg_ids: [] }
  it('the channel feed re-reads a channel the rows left or joined; the old pane drops the reply; the new pane re-reads', async () => {
    let caught = 0
    const channel = { active: 'devel', messages: [{ msg_id: 'r1', task_id: 't1', channel: 'devel' }], catchUp: () => { caught++ } }
    const dropped = []
    const admitted = []
    const old = { taskId: 't1', messages: [{ msg_id: 'r1', task_id: 't1' }], drop: (id) => dropped.push(id), admit: () => {} }
    const next = { taskId: 't2', messages: [], drop: () => {}, admit: (rows) => admitted.push(...rows) }
    const f = applyMoveToStores(frame, { channel, main: old, pane: next, getTopic: async () => ({ messages: [{ msg_id: 'r1' }] }) })
    await new Promise((r) => setTimeout(r, 0))
    assert.equal(f.type, 'message_moved')
    assert.equal(channel.messages[0].task_id, 't2')
    assert.equal(caught, 1)
    assert.deepEqual(dropped, ['r1'])
    assert.deepEqual(admitted.map((r) => r.msg_id), ['r1'])
  })
  it('a topic that left the open channel leaves its feed; the topic list row names the new channel', () => {
    const channel = { active: 'devel', messages: [{ msg_id: 'c1', task_id: 't1', channel: 'devel' }, { msg_id: 'z', task_id: 'tz', channel: 'devel' }], catchUp: () => {} }
    const viewer = { topics: [{ task_id: 't1', channel: 'devel' }] }
    applyMoveToStores({ type: 'topic_moved', msg_id: 'c1', task_id: 't1', channel: 'ops', from_channel: 'devel', msg_ids: [] }, { channel, viewer })
    assert.deepEqual(channel.messages.map((m) => m.msg_id), ['z'])
    assert.equal(viewer.topics[0].channel, 'ops')
    assert.equal(applyMoveToStores({ type: 'topic_archived', msg_id: 'c1' }, { channel }), null, 'control: another frame changes nothing')
  })
})

describe('notes, errors, redirect, picker rows', () => {
  it('a moved card names its home channel, a moved reply its home topic; at home nothing', () => {
    assert.deepEqual(movedNote({ moved_at: 'T', moved_from_channel: 'devel', channel: 'ops', is_parent: 1 }), { kind: 'channel', channel: 'devel' })
    assert.deepEqual(movedNote({ moved_at: 'T', moved_from_task: 't1', moved_from_channel: 'devel', channel: 'devel', is_parent: 0 }), { kind: 'topic', task: 't1' })
    assert.equal(movedNote({ moved_at: 'T', moved_from_channel: 'devel', channel: 'ops', is_parent: 0 }), null, 'a reply of a moved topic: the card says it')
    assert.equal(movedNote({ channel: 'ops' }), null)
  })
  it('each hub refusal has its own sentence', () => {
    assert.equal(moveErrorKey({ token: 'not_allowed' }), 'feed.move.error_forbidden')
    assert.equal(moveErrorKey({ token: 'lobby' }), 'feed.move.error_lobby')
    assert.equal(moveErrorKey({ token: 'unknown_channel' }), 'feed.move.error_unknown_channel')
    assert.equal(moveErrorKey(new Error('x')), 'feed.move.error')
  })
  it('an old channel link goes to the channel a MOVED topic is in now; a never-moved one does not', () => {
    assert.deepEqual(queryTasks({ topic: 'a', in: 'b', q: 'x' }), ['a', 'b'])
    assert.deepEqual(queryTasks({ thread: ['c'] }), ['c'])
    assert.equal(movedChannelFor([{ channel: 'ops', moved_at: 'T' }], 'devel'), 'ops')
    assert.equal(movedChannelFor([{ channel: 'ops', moved_at: 'T' }], 'ops'), '')
    assert.equal(movedChannelFor([{ channel: 'ops' }], 'devel'), '', 'control: not moved')
    assert.equal(movedChannelFor([], 'devel'), '')
  })
  it('the topic picker: listed channels only, not the own topic, filtered, newest first', () => {
    const topics = [
      { task_id: 'a', channel: 'ops', subject: 'Deploy notes', last_ts: '2026-09-01' },
      { task_id: 'b', channel: 'alerts', subject: 'Disk full', last_ts: '2026-09-03' },
      { task_id: 't1', channel: 'devel', subject: 'own topic', last_ts: '2026-09-04' },
      { task_id: 'd', channel: null, subject: 'a DM', last_ts: '2026-09-05' },
      { task_id: 'e', channel: 'secret', subject: 'not listed', last_ts: '2026-09-06' },
      { task_id: 'L0', channel: 'lobby', subject: 'lobby', last_ts: '2026-09-07' },
    ]
    const rows = moveTopicChoices(topics, { channels, exclude: ['t1'], lobbyTaskId: LOBBY })
    assert.deepEqual(rows.map((r) => r.task_id), ['b', 'a'])
    assert.deepEqual(moveTopicChoices(topics, { channels, exclude: ['t1'], query: 'deploy' }).map((r) => r.task_id), ['a'])
    assert.deepEqual(moveTopicChoices(topics, { channels, query: '#alerts' }).map((r) => r.task_id), ['b'])
  })
})

describe('the mock client moves (the e2e harness)', () => {
  it('a topic with its replies, the refusals, and back home', async () => {
    const api = createSpoolClient({ mock: true })
    await api.createChannel({ channel_id: 'ops', name: 'ops' })
    await api.createChannel({ channel_id: 'devel', name: 'devel' })
    const c = await api.sendMessage({ channel: 'devel', text: 'topic', is_parent: 1 })
    const r = await api.sendMessage({ channel: 'devel', text: 'a reply', parent_task_id: c.task_id, is_parent: 0 })
    await assert.rejects(api.moveTopic(c.msg_id, 'devel'), (e) => e.token === 'same_place')
    await assert.rejects(api.moveTopic(c.msg_id, 'lobby'), (e) => e.token === 'lobby')
    await assert.rejects(api.moveTopic(c.msg_id, 'issues'), (e) => e.token === 'unknown_channel')
    await assert.rejects(api.moveTopic(r.msg_id, 'ops'), (e) => e.token === 'not_a_card')
    await assert.rejects(api.moveTopic('66666666-6666-4666-8666-666666666666', 'ops'), (e) => e.token === 'not_allowed', 'another author')
    const a = await api.moveTopic(c.msg_id, 'ops')
    assert.equal(a.moved, true)
    assert.deepEqual(a.undo, { to_channel: 'devel' })
    assert.deepEqual(new Set(a.msg_ids), new Set([c.msg_id, r.msg_id]))
    const inOps = (await api.listMessages({ channel: 'ops' })).messages.map((m) => m.msg_id)
    assert.ok(inOps.includes(c.msg_id) && inOps.includes(r.msg_id))
    const back = await api.moveTopic(c.msg_id, a.undo.to_channel)
    assert.equal(back.moved, false)
    const row = (await api.listMessages({ channel: 'devel' })).messages.find((m) => m.msg_id === c.msg_id)
    assert.equal(row.moved_at, undefined)
  })
  it('a reply into another topic, the refusals, and the undo', async () => {
    const api = createSpoolClient({ mock: true })
    await api.createChannel({ channel_id: 'devel', name: 'devel' })
    const c1 = await api.sendMessage({ channel: 'devel', text: 'one', is_parent: 1 })
    const c2 = await api.sendMessage({ channel: 'devel', text: 'two', is_parent: 1 })
    const r = await api.sendMessage({ channel: 'devel', text: 'reply', parent_task_id: c1.task_id, is_parent: 0 })
    await assert.rejects(api.moveMessage(c1.msg_id, c2.task_id), (e) => e.token === 'is_card')
    await assert.rejects(api.moveMessage(r.msg_id, c1.task_id), (e) => e.token === 'same_place')
    await assert.rejects(api.moveMessage(r.msg_id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), (e) => e.token === 'lobby')
    const a = await api.moveMessage(r.msg_id, c2.task_id)
    assert.equal(a.task_id, c2.task_id)
    assert.deepEqual(a.undo, { to_task: c1.task_id })
    assert.ok((await api.getTopic(c2.task_id)).messages.some((m) => m.msg_id === r.msg_id))
    assert.ok(!(await api.getTopic(c1.task_id)).messages.some((m) => m.msg_id === r.msg_id))
    const back = await api.moveMessage(r.msg_id, a.undo.to_task)
    assert.equal(back.moved, false)
    assert.ok((await api.getTopic(c1.task_id)).messages.some((m) => m.msg_id === r.msg_id))
  })
})

describe('menu and wiring', () => {
  it('Move to channel… / Move to topic… sit before Archive / Delete', () => {
    assert.deepEqual(msgMenuItems({ topic: true, moveChannel: true }).map((i) => i.id), ['open', 'copy', 'move-channel', 'archive', 'delete-topic'])
    assert.deepEqual(msgMenuItems({ editable: true, moveTopic: true }).map((i) => i.id), ['open', 'copy', 'edit', 'move-topic', 'delete'])
    assert.deepEqual(msgMenuItems({ editable: true }).map((i) => i.id), ['open', 'copy', 'edit', 'delete'], 'control: nothing without the flag')
    assert.equal(msgMenuItems({ moveTopic: true }).find((i) => i.id === 'move-topic').icon, 'move')
  })
  it('the card drags only from its handle, gates on the role rule, and mounts the picker lazily', () => {
    const card = src('src/components/MessageCard.vue')
    /* the eager card imports only the small half; the rest loads on a move */
    assert.doesNotMatch(card, /move-apply\.mjs/)
    assert.match(card, /mayMoveTopic\(props\.msg, editorId\.value, access\.me, lobbyTask\.value\)/)
    assert.match(card, /<LazyMovePickerDialog\s+v-if="movePicker"/)
    /* SPL-1134: no HTML5 drag left on the row: the handle's pointer stream is the only start */
    assert.doesNotMatch(card, /draggable=|@dragstart|dataTransfer/)
    assert.match(card, /class="msg-move-handle"[\s\S]*?@pointerdown\.stop="onHandleDown"/)
    assert.match(card, /\.msg-move-handle \{[^}]*width: 12px;[^}]*cursor: grab;[^}]*touch-action: none;/)
  })
  it('the rail rows name themselves as drop rows; the shell routes the frames; the toast is eager (CLE-77840)', () => {
    const side = src('src/components/ChannelSidebar.vue')
    assert.match(side, /data-move-drop="channel"\s+data-move-scope="channels"\s+:data-move-id="c\.channel_id"/)
    assert.doesNotMatch(side, /@drop=|dataTransfer/)
    assert.match(side, /isChannelDropTarget\(mover\.drag\.value, id, channel\.channels\)/)
    const layout = src('src/layouts/default.vue')
    assert.match(layout, /move\.dispatch\(f\)/)
    /* CLE-77840: eager - a lazy chunk is gone on a tab older than the last deploy */
    assert.match(layout, /<MoveUndoToast v-if="move\.toast\.value" \/>/)
    const ws = src('src/utils/live-ws.mjs')
    assert.match(ws, /topicMoved: 'topic_moved'/)
    assert.match(ws, /messageMoved: 'message_moved'/)
    assert.match(src('src/pages/channel/[name].vue'), /await redirectMoved\(n\)/)
  })
  it('no new request header (a CORS preflight would break sign-in)', () => {
    const client = src('src/utils/spool-client-lazy.mjs') /* P3-30: the move calls live there */
    const from = client.indexOf('async function moveTopic(')
    const to = client.indexOf('async function moveInfo(')
    assert.ok(from > 0 && to > from, 'control: both move calls are in the lazy client')
    const block = client.slice(from, to)
    assert.doesNotMatch(block, /headers: \{[^}]*(x-|authorization)/i)
  })
  it('every locale has the move strings with the same placeholders', () => {
    const dir = join(WUI, 'i18n/locales')
    const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).feed.move
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const m = JSON.parse(readFileSync(join(dir, f), 'utf8')).feed.move
      assert.deepEqual(Object.keys(m).sort(), Object.keys(en).sort(), f)
      for (const [k, v] of Object.entries(en)) {
        const ph = (s) => (String(s).match(/\{[a-z_]+\}/g) || []).sort().join()
        assert.equal(ph(m[k]), ph(v), `${f} ${k}`)
        assert.doesNotMatch(m[k], /[|@<]/, `${f} ${k}`)
      }
    }
  })
})
