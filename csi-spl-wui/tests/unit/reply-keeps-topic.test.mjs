// Owner 2026-10-05 (t1 dc6d5e3f): "reply in topic created a new topic ?!"
// HUM-10 typed `@<agent> <text>` in the reply box of an open thread (and the
// topics view); the line went out under a NEW task_id (5f0d5200 -> 86e3d656)
// instead of the thread's (ac43e7c8). SPL-996 B made a leading `@ID <task>`
// the explicit new topic even inside an open thread; that rule is retired.
//
// Each case runs the send decision exactly as a page's onSend builds it
// (startsNewTopic -> omniboxReplyTaskId -> isParentFlag), then hands it to the
// mock spool client the way channel.send does. CONTROL: on the old
// omnibox-topic.mjs every tagged case below is red (task_id a fresh uuid,
// is_parent 1).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { dockTargetHint, isParentFlag, omniboxReplyTaskId, startsNewTopic } from '../../src/utils/omnibox-topic.mjs'

const T = 'ac43e7c8-c0e1-433e-9c0c-4d217c1ce3e7'

/** what pages/channel, dm, index and t/[task_id] do in onSend */
function pageSend({ tab, selectedTaskId, paneVisible, text }) {
  const fresh = startsNewTopic(text)
  const target = omniboxReplyTaskId({ tab, selectedTaskId, namedTopicId: '', paneVisible, newTopic: fresh })
  return { target, isParent: isParentFlag({ paneVisible: paneVisible && !fresh, replyTaskId: target }) }
}

const VIEWS = [
  { name: 'the thread view (channel, pane open)', tab: 'channels', selectedTaskId: T, paneVisible: true },
  { name: 'the topics view (row selected)', tab: 'topics', selectedTaskId: T, paneVisible: false },
  { name: 'the topics view (thread open)', tab: 'topics', selectedTaskId: T, paneVisible: true },
]
const LINES = ['@a-004 please look at this', '@AGY-3499 still here?', '@c-001@sat check the run', 'plain reply', '@a-004']

describe('a reply typed in a topic keeps its task_id, mention or not (dc6d5e3f)', () => {
  for (const v of VIEWS) {
    for (const text of LINES) {
      it(`${v.name}: ${JSON.stringify(text)}`, async () => {
        const { target, isParent } = pageSend({ ...v, text })
        assert.equal(target, T, 'the send hangs off the open topic')
        assert.equal(isParent, 0, 'a reply, not a new middle card')
        const row = await createSpoolClient({ mock: true }).sendMessage({ channel: 'rel-csi-fina', text, task_id: target, is_parent: isParent })
        assert.equal(row.task_id, T)
      })
    }
  }

  it('the tagged agent is still the addressee: the tag routes, it does not re-topic', async () => {
    const { target, isParent } = pageSend({ ...VIEWS[0], text: '@a-004 please look at this' })
    const row = await createSpoolClient({ mock: true }).sendMessage({ channel: 'rel-csi-fina', text: '@a-004 please look at this', task_id: target, is_parent: isParent })
    assert.deepEqual([row.task_id, row.to], [T, 'a-004'])
  })

  it('the dock hint says "thread" for a tagged line too', () => {
    assert.equal(dockTargetHint({ reply: true, target: '#rel-csi-fina' }, '@a-004 look').mode, 'thread')
  })

  it('no topic open: a tagged line is still a new topic of its own', () => {
    const { target, isParent } = pageSend({ tab: 'channels', selectedTaskId: '', paneVisible: false, text: '@a-004 look' })
    assert.deepEqual([target, isParent], ['', 1])
  })
})
