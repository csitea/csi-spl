// CLE-3433 / OA-38 — `sendLive` does `task_id: parentTaskId || newId()`.
// Measured by CLE-3438 on dev (tree f76f648, n=1): 12 messages from one
// `/dm/<peer>?topic=<id>` page produced 12 distinct task ids, because the
// page passed no parent. Binding the Omnibox to the open pane stopped the
// scatter and then trapped every following send inside that pane.
//
// The line decides now. These tests keep the pane helpers honest. The pages
// must not call them — see tests/unit/topic-in.test.mjs.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { isParentFlag, omniboxParentTaskId, omniboxPlaceholderKey, omniboxReplyTaskId, sendsNewTopic } from '../../src/utils/omnibox-topic.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const PAGES = ['src/pages/dm/[peer].vue', 'src/pages/channel/[name].vue']

describe('which conversation the Omnibox writes into (CLE-3433 / OA-38)', () => {
  it('an open topic is the parent; a closed one is not', () => {
    assert.equal(omniboxParentTaskId({ open: true, parentTaskId: 'T-1' }), 'T-1')
    assert.equal(omniboxParentTaskId({ open: false, parentTaskId: 'T-1' }), '')
  })

  /* closing the pane must release the box, or a reader who opened one topic
     could never start a new message again */
  it('nothing is trapped: no topic, no parent', () => {
    assert.equal(omniboxParentTaskId({ open: true, parentTaskId: '' }), '')
    assert.equal(omniboxParentTaskId({ open: true, parentTaskId: null }), '')
    assert.equal(omniboxParentTaskId(null), '')
    assert.equal(omniboxParentTaskId(undefined), '')
    assert.equal(omniboxParentTaskId({}), '')
  })

  it('the box SAYS it is replying — a box that sends somewhere it does not name is the defect', () => {
    assert.equal(omniboxPlaceholderKey('T-1'), 'topic.reply_placeholder')
    assert.equal(omniboxPlaceholderKey(''), '')
  })

  for (const page of PAGES) {
    it(`${page}: the open topic captures the Omnibox only while Topics is the selected list`, () => {
      const s = src(page)
      assert.doesNotMatch(s, /omniboxParentTaskId/)
      assert.match(s, /omniboxReplyTaskId/)
      assert.match(s, /channel\.send\(text, topicId \|\| undefined, files, channelId, isParentFlag\(\{ paneVisible: paneOpen\(\) && !fresh, replyTaskId: topicId \|\| '' \}\)\)/)
    })
  }

  /* the key the placeholder resolves to has to exist, or the box renders the
     key itself and the fix reads as a different bug */
  it('topic.reply_placeholder exists in all 19 locales', () => {
    for (const code of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const j = JSON.parse(src(`i18n/locales/${code}.json`))
      assert.equal(typeof (j.topic && j.topic.reply_placeholder), 'string', `${code}: topic.reply_placeholder missing`)
    }
  })

  it('a closed right pane with no named topic is a new topic of one message', () => {
    assert.equal(sendsNewTopic({ paneOpen: false, namedTopicId: '' }), true)
    assert.equal(sendsNewTopic({}), true)
    assert.equal(sendsNewTopic({ paneOpen: true, namedTopicId: '' }), false)
    assert.equal(sendsNewTopic({ paneOpen: false, namedTopicId: 'T-1' }), false)
  })

  it('CONTROL: sendLive still mints a new task when there is no parent', () => {
    assert.match(src('src/stores/channel.ts'), /task_id: parentTaskId \|\| newId\(\)/)
  })

  it('an open right pane replies there; a closed pane on another tab does not', () => {
    assert.equal(omniboxReplyTaskId({ tab: 'topics', selectedTaskId: 'T-1', namedTopicId: '' }), 'T-1')
    assert.equal(omniboxReplyTaskId({ tab: 'topics', selectedTaskId: 'T-1', namedTopicId: 'T-9' }), 'T-9')
    assert.equal(omniboxReplyTaskId({ tab: 'topics', selectedTaskId: '', namedTopicId: '' }), '')
    assert.equal(omniboxReplyTaskId({ tab: 'channels', selectedTaskId: 'T-1', paneVisible: true }), 'T-1')
    assert.equal(omniboxReplyTaskId({ tab: 'channels', selectedTaskId: 'T-1', namedTopicId: '' }), '')
    assert.equal(omniboxReplyTaskId({ tab: 'dm', selectedTaskId: 'T-1' }), '')
    assert.equal(omniboxReplyTaskId({}), '')
    assert.match(src('src/pages/index.vue'), /omniboxReplyTaskId/)
    assert.match(src('src/pages/t/[task_id].vue'), /omniboxReplyTaskId/)
    assert.match(src('src/components/ChannelSidebar.vue'), /setCurrent\(id\)/)
    assert.match(src('src/components/ChannelSidebar.vue'), /req\.stay/)
    assert.doesNotMatch(src('src/components/MessageCard.vue'), /reveal\('topics'\)/)
    assert.match(src('src/components/MessageCard.vue'), /data-test="topic-replies"/)
    const card = src('src/components/MessageCard.vue')
    const repliesAt = card.indexOf('data-test="topic-replies"')
    const menuAt = card.indexOf('data-testid="msg-menu-btn"')
    const emojiAt = card.indexOf('data-testid="msg-emoji-btn"')
    assert.ok(repliesAt > 0 && repliesAt < menuAt && menuAt < emojiAt)
  })

  it('is_parent is 0 whenever the right pane is open, whichever left tab is selected', () => {
    assert.equal(isParentFlag({ paneVisible: true }), 0)
    assert.equal(isParentFlag({ paneVisible: false }), 1)
    assert.equal(isParentFlag({}), 1)
    for (const page of ['src/pages/channel/[name].vue', 'src/pages/dm/[peer].vue', 'src/pages/index.vue', 'src/pages/lobby.vue', 'src/pages/t/[task_id].vue']) {
      assert.match(src(page), /isParentFlag/, page)
    }
  })
})
