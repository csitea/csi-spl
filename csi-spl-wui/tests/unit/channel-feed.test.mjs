import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  topLevel,
  threadOf,
  replyCount,
  parseMention,
  formatBytes,
  initials,
} from '../../utils/channel-feed.mjs'
import { applyVerbosity } from '../../utils/verbosity.mjs'
import { MOCK_MESSAGES } from '../../utils/mock-data.mjs'

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
