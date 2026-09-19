import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  topLevel,
  threadOf,
  replyCount,
  parseMention,
  formatBytes,
  initials,
  channelSlug,
  retentionLabel,
  feedRow,
  belongsTo,
  mergeLive,
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

  it('formats bytes and initials', () => {
    assert.equal(formatBytes(2048), '2.0 KiB')
    assert.equal(initials('CLE-07'), 'CL')
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
