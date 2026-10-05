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
import { chipLabel, isParentFlag, PHONE_CHIP_MAX, phoneChipLabel, omniboxParentTaskId, omniboxPlaceholderKey, omniboxReplyTaskId, sendsNewTopic, startsNewTopic } from '../../src/utils/omnibox-topic.mjs'

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

/* 080 FR-006 / FR-007 (AC6): the chip names the target send uses. Each case
   of the target table above is built the way a page builds its omnibox
   target (dock() and place() from one replyTarget()), then the chip and the
   send are compared: a reply chip opens the very topic the send hangs off,
   and a send that starts a topic never wears a reply chip. */
describe('080 the target chip and the send read one target (AC6)', () => {
  const TABLE = [
    { tab: 'topics', selectedTaskId: 'T-1' },
    { tab: 'topics', selectedTaskId: 'T-1', namedTopicId: 'T-9' },
    { tab: 'topics', selectedTaskId: '' },
    { tab: 'channels', selectedTaskId: 'T-1', paneVisible: true },
    { tab: 'channels', selectedTaskId: 'T-1' },
    { tab: 'dm', selectedTaskId: 'T-1' },
    {},
  ]
  const LINES = ['hello', '@CLE-07 do the thing', '@test', '@CLE-07']
  const PAGES = [
    { name: 'channel', dock: (r) => ({ reply: Boolean(r), target: '#feedback' }), place: (r) => (r ? `t:${r}` : 'ch:feedback'), plain: '#feedback' },
    { name: 'lobby', dock: (r) => ({ reply: Boolean(r), target: '#lobby' }), place: (r) => (r ? `t:${r}` : 'ch:lobby'), plain: '#lobby' },
    { name: 'dm', dock: (r) => ({ reply: Boolean(r), target: 'HUM-3', dm: true }), place: (r) => (r ? `t:${r}` : 'dm:HUM-3'), plain: '@HUM-3' },
  ]
  for (const page of PAGES) {
    for (const row of TABLE) {
      for (const text of LINES) {
        it(`${page.name} ${JSON.stringify(row)} ${JSON.stringify(text)}`, () => {
          const reply = omniboxReplyTaskId(row)
          const c = chipLabel({ dock: page.dock(reply), place: page.place(reply), text, title: 'The title' })
          assert.ok(c, 'a box with text and a send target has a chip')
          const intoTopic = Boolean(reply) && !startsNewTopic(text)
          if (intoTopic) {
            assert.equal(c.key, 'composer.chip_reply')
            assert.equal(c.params.title, 'The title')
            assert.equal(c.open, `t:${reply}`)
          } else if (reply) {
            assert.equal(c.key, 'composer.chip_new_topic')
            assert.equal(c.params.target, page.plain)
          } else {
            assert.equal(c.key, '')
            assert.equal(c.text, page.plain)
            assert.equal(c.open, page.place(''))
          }
        })
      }
    }
  }

  it('no chip: an empty box, a /search line, no send target', () => {
    const dock = { reply: false, target: '#lobby' }
    assert.equal(chipLabel({ dock, place: 'ch:lobby', text: '' }), null)
    assert.equal(chipLabel({ dock, place: 'ch:lobby', text: '   ' }), null)
    assert.equal(chipLabel({ dock, place: 'ch:lobby', text: '/search x' }), null)
    assert.equal(chipLabel({ dock: null, place: '', text: 'x' }), null)
    assert.equal(chipLabel(), null)
  })

  it('an `in: <title>` the line names wins, as it does in send', () => {
    const c = chipLabel({ dock: { reply: false, target: '#lobby' }, place: 'ch:lobby', text: 'in: Other x', named: { taskId: 'T-9', title: 'Other' } })
    assert.deepEqual([c && c.key, c && c.params.title, c && c.open], ['composer.chip_reply', 'Other', 't:T-9'])
  })

  it('a reply with no known title names the topic id; an issue comment names the issue', () => {
    assert.equal(chipLabel({ dock: { reply: true, target: 'x' }, place: 't:T-1', text: 'a' })?.params.title, 'T-1')
    const c = chipLabel({ dock: { reply: true, target: 'SPL-12', comment: true }, place: '', text: 'a' })
    assert.deepEqual([c && c.key, c && c.params.title, c && c.open], ['composer.chip_reply', 'SPL-12', ''])
  })

  it('composer.chip_reply and composer.chip_new_topic exist in all 19 locales', () => {
    for (const code of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const c = JSON.parse(src(`i18n/locales/${code}.json`)).composer || {}
      assert.match(String(c.chip_reply), /\{title\}/, `${code}: composer.chip_reply`)
      assert.match(String(c.chip_new_topic), /\{target\}/, `${code}: composer.chip_new_topic`)
    }
  })

  it('the composer renders the chip from chipLabel, and the bottom-only line is gone', () => {
    const vue = src('src/components/MessageComposer.vue')
    assert.match(vue, /const opts = \{ dock: props\.dockTarget, place, text: text\.value, named, title \}/)
    assert.match(vue, /const c = chipLabel\(opts\)/)
    assert.match(vue, /data-test="composer-target-chip"/)
    assert.doesNotMatch(vue, /data-test="dock-target"/)
  })
})

/* 085 FR-002 (AC3): on a phone the chip is chipLabel(target), its words cut
   to 12 characters with an ellipsis after, for every row of 080 AC6's target
   table; the uncut words stay in `full` (title, aria-label). Spec Q3: a
   focused empty box already names the target a plain line would go to. */
describe('085 the phone chip is chipLabel cut to 12 characters (AC3)', () => {
  const TABLE = [
    { tab: 'topics', selectedTaskId: 'T-1' },
    { tab: 'topics', selectedTaskId: 'T-1', namedTopicId: 'T-9' },
    { tab: 'topics', selectedTaskId: '' },
    { tab: 'channels', selectedTaskId: 'T-1', paneVisible: true },
    { tab: 'channels', selectedTaskId: 'T-1' },
    { tab: 'dm', selectedTaskId: 'T-1' },
    {},
  ]
  const LINES = ['hello', '@CLE-07 do the thing', '@test', '@CLE-07']
  const PAGES = [
    { name: 'channel', dock: (r) => ({ reply: Boolean(r), target: '#feedback' }), place: (r) => (r ? `t:${r}` : 'ch:feedback') },
    { name: 'lobby', dock: (r) => ({ reply: Boolean(r), target: '#lobby' }), place: (r) => (r ? `t:${r}` : 'ch:lobby') },
    { name: 'dm', dock: (r) => ({ reply: Boolean(r), target: 'HUM-3', dm: true }), place: (r) => (r ? `t:${r}` : 'dm:HUM-3') },
  ]
  const WORDS = { 'composer.chip_reply': 'Reply · {title}', 'composer.chip_new_topic': 'New topic · {target}' }
  const render = (c) => (c.key ? WORDS[c.key].replace(/\{(\w+)\}/g, (_, k) => c.params[k]) : c.text)
  const cut = (s) => (Array.from(s).length > 12 ? Array.from(s).slice(0, 12).join('') + '…' : s)
  for (const page of PAGES) {
    for (const row of TABLE) {
      for (const text of LINES) {
        it(`${page.name} ${JSON.stringify(row)} ${JSON.stringify(text)}`, () => {
          const reply = omniboxReplyTaskId(row)
          const opts = { dock: page.dock(reply), place: page.place(reply), text, title: 'A long topic title' }
          const c = phoneChipLabel(opts, { render })
          const base = chipLabel(opts)
          assert.ok(c && base)
          assert.equal(c.full, render(base))
          assert.equal(c.short, cut(render(base)))
          assert.ok(Array.from(c.short.replace(/…$/, '')).length <= PHONE_CHIP_MAX)
          assert.deepEqual([c.key, c.open], [base.key, base.open])
        })
      }
    }
  }

  it('short labels stay whole; a long one is cut to 12 + an ellipsis', () => {
    assert.equal(PHONE_CHIP_MAX, 12)
    assert.equal(phoneChipLabel({ dock: { reply: false, target: '#alerts' }, place: 'ch:alerts', text: 'x' })?.short, '#alerts')
    assert.equal(phoneChipLabel({ dock: { reply: false, target: 'GRK-03', dm: true }, place: 'dm:GRK-03', text: 'x' })?.short, '@GRK-03')
    const long = phoneChipLabel({ dock: { reply: false, target: '#a' }, place: 'ch:spool-hub-mobile', text: 'x' })
    assert.deepEqual([long?.short, long?.full], ['#spool-hub-m…', '#spool-hub-mobile'])
  })

  it('spec Q3: a focused empty box names the target; unfocused, or in /search, no chip', () => {
    const opts = { dock: { reply: false, target: '#alerts' }, place: 'ch:alerts', text: '' }
    assert.equal(phoneChipLabel(opts, { focused: true })?.short, '#alerts')
    assert.equal(phoneChipLabel(opts), null)
    assert.equal(phoneChipLabel({ ...opts, text: '/search x' }, { focused: true }), null)
    assert.equal(phoneChipLabel({ dock: null, place: '', text: '' }, { focused: true }), null)
    const reply = phoneChipLabel({ dock: { reply: true, target: '#alerts' }, place: 't:T-1', text: '', title: 'Deploy notes' }, { focused: true, render })
    assert.deepEqual([reply?.key, reply?.short, reply?.full], ['composer.chip_reply', 'Reply · Depl…', 'Reply · Deploy notes'])
  })

  it('the phone dock renders the chip from phoneChipLabel, the full words in title and aria-label, indenting line 1 only', () => {
    const vue = src('src/components/MessageComposer.vue')
    assert.match(vue, /if \(docked\.value\) return phoneChipLabel\(opts, \{ focused: chipFocused\.value, render: chipWords \}\)/)
    assert.match(vue, /:title="chipFull"/)
    assert.match(vue, /:aria-label="docked \? chipFull : undefined"/)
    assert.match(vue, /\.composer\.composer--dock\.composer--dock \.has-target-chip textarea \{\s*padding-inline-start: 0;\s*text-indent: calc\(var\(--chip-w, 0px\) \+ 6px\);/)
    assert.match(vue, /\.composer--dock\.composer--dock \.composer-target-chip \{[^}]*font-size: 0.875rem;/)
  })
})
