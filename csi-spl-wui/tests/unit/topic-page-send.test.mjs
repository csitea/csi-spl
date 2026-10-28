// SPL-3440 (CI failures panel I13): a line sent on /t/<id> right after the
// page loads went out with no task and no channel, and the hub refused it
// (`wui send refused`, token dm_needs_to). Since 2d5ef7b2d (10-11) the page
// opens the topic only after a door-check read (getTopic limit 1) answers;
// until then topic.open is false, so onSend had no reply target. Measured on
// dev 2026-10-20T19:12:29 (wf 30 run 39480361834, tree 6ea526200, n=1): the
// limit-1 read at .603, the probe's send right after .649, the thread read
// at .859; the hub refused the send under a fresh task_id. prd shows the same
// signature from the probe member in every one of 5 refusals since 10-18,
// each inside a red wf 30 run.
//
// The page names its topic in the URL, so that is the target from the first
// frame; only the view door (a topic this session may not read) withholds it.
// CONTROL: on the old page every case marked "before the read" is red.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isParentFlag, omniboxReplyTaskId, topicPageOpen } from '../../src/utils/omnibox-topic.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const page = readFileSync(join(WUI, 'src/pages/t/[task_id].vue'), 'utf8')
const T = '687efd26-720c-47fa-b86e-48d46d695575'

/** what pages/t/[task_id].vue's onSend decides */
function send({ open, door }) {
  const visible = topicPageOpen({ open, taskId: T, door })
  const target = omniboxReplyTaskId({ selectedTaskId: T, namedTopicId: '', paneVisible: visible })
  return { target, isParent: isParentFlag({ paneVisible: visible, replyTaskId: target }) }
}

describe('/t/<id>: a line sent before the topic read answers stays in the topic (SPL-3440)', () => {
  it('before the read: the URL topic is the target, a reply (is_parent 0)', () => {
    assert.deepEqual(send({ open: false, door: null }), { target: T, isParent: 0 })
  })
  it('after the read: the same', () => {
    assert.deepEqual(send({ open: true, door: null }), { target: T, isParent: 0 })
  })
  it('the view door is up: no target (the page shows the token form, not the topic)', () => {
    assert.equal(topicPageOpen({ open: false, taskId: T, door: { detail: 'x' } }), false)
  })
  it('no task in the URL: closed', () => {
    assert.equal(topicPageOpen({ open: false, taskId: '', door: null }), false)
  })
  it('the page reads topicPageOpen for onSend and the composer target, never topic.open alone', () => {
    assert.match(page, /const visible = pageOpen\(\)/)
    assert.match(page, /paneVisible: pageOpen\(\),/)
    assert.match(page, /topicPageOpen\(\{ open: topic\.open, taskId: taskId\.value, door: door\.value \}\)/)
    assert.doesNotMatch(page, /const visible = topic\.open/)
  })
})
