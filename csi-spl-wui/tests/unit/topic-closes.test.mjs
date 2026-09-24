// The right-hand topic pane follows the middle list.
//
// Changing the open DM peer (or channel) closes the pane when the open task
// is not one of that feed's messages. An empty list always closes it. A task
// that is in the new list may stay. Closing also drops ?topic= / ?in=.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { topicClosesForMessages, topicFeedRelease } from '../../src/utils/topic-open.mjs'

const TASK = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const OTHER = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const MSG = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('the topic pane closes when the middle list moved on', () => {
  it('an open task absent from the new peer messages closes the pane', () => {
    const messages = [{ msg_id: MSG, task_id: OTHER }]
    assert.equal(topicClosesForMessages(TASK, messages), true)
  })

  it('an empty message list closes the pane', () => {
    assert.equal(topicClosesForMessages(TASK, []), true)
    assert.equal(topicClosesForMessages(TASK, null), true)
    assert.equal(topicClosesForMessages(TASK, undefined), true)
  })

  it('a task that is in the new list may stay', () => {
    const messages = [
      { msg_id: MSG, task_id: TASK },
      { msg_id: OTHER, task_id: OTHER },
    ]
    assert.equal(topicClosesForMessages(TASK, messages), false)
  })

  it('a message-rooted topic may stay when that message is in the list', () => {
    assert.equal(topicClosesForMessages(MSG, [{ msg_id: MSG, task_id: OTHER }]), false)
  })

  it('a reply that names the open task may stay', () => {
    assert.equal(
      topicClosesForMessages(TASK, [{ msg_id: MSG, task_id: OTHER, parent_task_id: TASK }]),
      false,
    )
  })

  it('a different id that merely contains the task does not keep the pane', () => {
    assert.equal(topicClosesForMessages(TASK, [{ task_id: TASK + '-x', msg_id: MSG }]), true)
  })

  it('nothing open does not close a list that has discussions', () => {
    assert.equal(topicClosesForMessages('', [{ task_id: TASK }]), false)
    assert.equal(topicClosesForMessages(null, [{ task_id: TASK }]), false)
  })
})

describe('closing drops the stale deep link', () => {
  it('drops ?topic= and ?in= and keeps the rest of the query', () => {
    const plan = topicFeedRelease(TASK, [], { topic: TASK, in: OTHER, q: 'hi' })
    assert.equal(plan.close, true)
    assert.deepEqual(plan.query, { q: 'hi' })
  })

  it('a task that may stay does not rewrite the query', () => {
    const query = { topic: TASK }
    const plan = topicFeedRelease(TASK, [{ task_id: TASK, msg_id: MSG }], query)
    assert.equal(plan.close, false)
    assert.equal(plan.query, null)
  })

  it('an already-clean url still closes and does not ask for a replace', () => {
    const plan = topicFeedRelease(TASK, [], { q: 'hi' })
    assert.equal(plan.close, true)
    assert.equal(plan.query, null)
  })
})

describe('dm and channel pages apply the close after the feed loads', () => {
  const pages = [
    ['src/pages/dm/[peer].vue', 'await channel.selectDm(p)'],
    ['src/pages/channel/[name].vue', 'await channel.selectChannel(n)'],
  ]

  for (const [rel, select] of pages) {
    it(`${rel}: judges this feed's messages, then closes`, () => {
      const s = src(rel)
      assert.match(s, /useTopicFeedClose/)
      assert.match(s, /topicFeedReady\.value = false/)
      assert.match(s, /topicFeedReady\.value = true\s+releaseStaleTopic\(\)/)
      assert.ok(s.indexOf(select) < s.indexOf('topicFeedReady.value = true'), rel)
      assert.match(s, /messages: \(\) => channel\.messages/)
    })
  }

  it('the close clears the topic store and drops ?topic= / ?in=', () => {
    const s = src('src/composables/useTopicRoute.ts')
    assert.match(s, /topicFeedRelease/)
    assert.match(s, /topic\.close\(\)/)
    assert.match(s, /router\.replace\(\{ query: plan\.query \}\)/)
    assert.match(s, /flush: 'sync'/)
  })
})
