// (SPL-15): "Open parent section" on a thread message.
// Run: node tests/unit/parent-section.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  cardScrollDelta,
  ISSUE_CHANNEL,
  isTopicStarter,
  issueKeyForTask,
  mayBeIssueTopic,
  parentChannelOf,
  parentKindOf,
  parentSection,
  parentSectionHref,
  parentTopicOf,
} from '../../src/utils/parent-section.mjs'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'
import { dmPeerOf as dmPeerOfShim } from '../../src/utils/channel-feed.mjs'
import { tabForPath } from '../../src/utils/sidebar-tabs.mjs'
import { isSelectedRow, targetFromQuery } from '../../src/utils/topic-open.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

const TOPIC = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const CHILD = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
const MSG = '11111111-1111-4111-8111-111111111111'

describe('parentSection: a channel thread message', () => {
  const reply = { msg_id: MSG, task_id: TOPIC, channel: 'dev', from: 'HUM-4', to: '@channel', is_parent: 0 }

  it('goes to the channel, keeps the topic open, and names the message as the hash', () => {
    assert.deepEqual(parentSection(reply), { path: '/channel/dev', query: { topic: TOPIC }, hash: '#' + MSG, kind: 'channel' })
  })

  it('a reply in a child task opens its parent topic', () => {
    const s = parentSection({ ...reply, task_id: CHILD, parent_task_id: TOPIC })
    assert.equal(s.query.topic, TOPIC)
  })

  it('keeps the open target as it is when it holds the message (a message-rooted topic keeps ?in=)', () => {
    const target = { taskId: MSG, mode: 'message', rootMsgId: MSG, parentTaskId: TOPIC }
    const s = parentSection({ msg_id: 'm2', task_id: MSG, parent_task_id: TOPIC, channel: 'lobby' }, { target })
    assert.deepEqual(s.query, { topic: MSG, in: TOPIC })
  })

  it('ignores an open target that does not hold the message', () => {
    const target = { taskId: CHILD, mode: 'task', rootMsgId: '', parentTaskId: '' }
    assert.equal(parentSection(reply, { target }).query.topic, TOPIC)
  })

  it('strips a leading # from the channel and encodes the path', () => {
    assert.equal(parentSection({ ...reply, channel: '#a b' }).path, '/channel/a%20b')
    assert.equal(parentChannelOf({ channel: '#dev' }), 'dev')
  })

  it('lands on the Channels tab with the parent card selected', () => {
    const s = parentSection(reply)
    assert.equal(tabForPath(s.path), 'channels')
    const target = targetFromQuery(s.query)
    assert.equal(isSelectedRow({ msg_id: 'root', task_id: TOPIC, is_parent: 1 }, target), true)
    assert.equal(isSelectedRow({ msg_id: 'other', task_id: CHILD, is_parent: 1 }, target), false)
  })
})

describe('parentSection: a DM thread message', () => {
  it('goes to the DM with the end that is not the viewer', () => {
    const mine = { msg_id: MSG, task_id: TOPIC, from: 'HUM-4', from_box: 'box-wui', to: 'CLE-07', to_box: 'box-desk' }
    const s = parentSection(mine, { self: 'HUM-4' })
    assert.deepEqual(s, { path: '/dm/' + encodeURIComponent('CLE-07@box-desk'), query: { topic: TOPIC }, hash: '#' + MSG, kind: 'dm' })
    assert.equal(tabForPath(s.path), 'dm')
    const theirs = { ...mine, from: 'CLE-07', from_box: 'box-desk', to: 'HUM-4', to_box: 'box-wui' }
    assert.equal(parentSection(theirs, { self: 'HUM-4' }).path, '/dm/' + encodeURIComponent('CLE-07@box-desk'))
  })

  it('is null for a broadcast or a row with no other end', () => {
    assert.equal(parentSection({ msg_id: MSG, task_id: TOPIC, from: 'HUM-4', to: 'ALL-0' }, { self: 'HUM-4' }), null)
    assert.equal(parentSection({}), null)
    assert.equal(parentSection(null), null)
  })
})

describe('parentSection: an issue discussion', () => {
  it('goes to the Issues tab with that issue selected', () => {
    const s = parentSection({ msg_id: MSG, task_id: TOPIC, channel: 'issues' }, { issueKey: 'SPL-15' })
    assert.deepEqual(s, { path: '/issues', query: { issue: 'SPL-15' }, hash: '', kind: 'issue' })
    assert.equal(tabForPath(s.path), 'issues')
  })

  it('only the issue channel (or the retired #tasks) may be an issue topic', () => {
    assert.equal(ISSUE_CHANNEL, 'issues')
    assert.equal(mayBeIssueTopic({ channel: 'issues' }), true)
    assert.equal(mayBeIssueTopic({ channel: '#Issues' }), true)
    assert.equal(mayBeIssueTopic({ channel: 'tasks' }), true)
    assert.equal(mayBeIssueTopic({ channel: 'dev' }), false)
    assert.equal(mayBeIssueTopic({}), false)
  })

  it('never sends anyone to /channel/issues (SPL-68: it is not a channel)', () => {
    const s = parentSection({ msg_id: MSG, task_id: TOPIC, channel: 'issues' })
    assert.deepEqual(s, { path: '/issues', query: {}, hash: '', kind: 'issue' })
    /* CONTROL: a real channel still goes to its channel page */
    assert.equal(parentSection({ msg_id: MSG, task_id: TOPIC, channel: 'dev' }).path, '/channel/dev')
  })

  it('finds the issue by its discussion task', () => {
    const list = { issues: [{ key: 'SPL-1', task_id: CHILD }, { key: 'SPL-15', task_id: TOPIC }] }
    assert.equal(issueKeyForTask(list, TOPIC), 'SPL-15')
    assert.equal(issueKeyForTask(list.issues, CHILD), 'SPL-1')
    assert.equal(issueKeyForTask(list, 'nope'), '')
    assert.equal(issueKeyForTask(null, TOPIC), '')
    assert.equal(issueKeyForTask(list, ''), '')
  })
})

describe('parentSectionHref / parentTopicOf', () => {
  it('writes one address with the locale path', () => {
    const s = parentSection({ msg_id: MSG, task_id: TOPIC, channel: 'dev' })
    assert.equal(parentSectionHref(s, (p) => '/fi' + p), `/fi/channel/dev?topic=${TOPIC}#${MSG}`)
    assert.equal(parentSectionHref({ path: '/issues', query: { issue: 'SPL-15' }, hash: '' }), '/issues?issue=SPL-15')
    assert.equal(parentSectionHref(null), '')
  })

  it('prefers the parent task over the row task', () => {
    assert.equal(parentTopicOf({ task_id: CHILD, parent_task_id: TOPIC }), TOPIC)
    assert.equal(parentTopicOf({ task_id: TOPIC }), TOPIC)
    assert.equal(parentTopicOf(null), '')
  })
})

describe('HUM-10 c15b557e: a topic message stops at the topic level (the card menu)', () => {
  const dmCard = { msg_id: MSG, task_id: TOPIC, from: 'HUM-4', from_box: 'box-wui', to: 'CLE-07', to_box: 'box-desk', parent_task_id: null }
  const chCard = { msg_id: MSG, task_id: TOPIC, channel: 'dev', is_parent: 1 }

  it('a DM topic message goes to that conversation with nothing opened and no hash', () => {
    assert.deepEqual(parentSection(dmCard, { self: 'HUM-4', topicLevel: true }), { path: '/dm/' + encodeURIComponent('CLE-07@box-desk'), query: {}, hash: '', kind: 'dm' })
  })

  it('a channel topic message goes to the channel with nothing opened, even while its topic is open', () => {
    const target = { taskId: TOPIC, mode: 'task', rootMsgId: '', parentTaskId: '' }
    assert.deepEqual(parentSection(chCard, { target, topicLevel: true }), { path: '/channel/dev', query: {}, hash: '', kind: 'channel' })
  })

  it('CONTROL: a reply still opens its topic with the reply as the hash', () => {
    assert.deepEqual(parentSection({ ...chCard, is_parent: 0 }, { topicLevel: true }), { path: '/channel/dev', query: { topic: TOPIC }, hash: '#' + MSG, kind: 'channel' })
    assert.equal(parentSection({ ...dmCard, parent_task_id: CHILD }, { self: 'HUM-4', topicLevel: true }).query.topic, CHILD)
  })

  it('CONTROL: without topicLevel (the search Original jump) a topic message keeps the topic open', () => {
    assert.deepEqual(parentSection(chCard).query, { topic: TOPIC })
    assert.equal(parentSection(chCard).hash, '#' + MSG)
  })

  it('isTopicStarter: level 1 with no parent; absent is_parent is level 1 (spec 033)', () => {
    assert.equal(isTopicStarter({ msg_id: MSG }), true)
    assert.equal(isTopicStarter({ is_parent: 1 }), true)
    assert.equal(isTopicStarter({ is_parent: 0 }), false)
    assert.equal(isTopicStarter({ parent_task_id: TOPIC }), false)
  })
})

describe('HUM-10 c15b557e: the item names its place', () => {
  it('a DM card reads Open in direct msg view; CONTROL a channel card reads Open in channels view', () => {
    assert.equal(parentKindOf({ from: 'HUM-4', to: 'CLE-07', to_box: 'box-a', task_id: TOPIC }, 'HUM-4'), 'dm')
    assert.equal(parentKindOf({ channel: '#dev', task_id: TOPIC }, 'HUM-4'), 'channel')
    assert.equal(msgMenuItems({ parent: true, parentKind: 'dm' })[1].labelKey, 'feed.msg_menu.open_in_dm')
    assert.equal(msgMenuItems({ parent: true, parentKind: 'channel' })[1].labelKey, 'feed.msg_menu.open_in_channels')
  })

  it('an issue discussion, or no kind, keeps Open parent section', () => {
    assert.equal(parentKindOf({ channel: 'issues' }), 'issue')
    assert.equal(parentKindOf({ channel: 'tasks' }), 'issue')
    assert.equal(parentKindOf({ from: 'HUM-4', to: 'ALL-0' }, 'HUM-4'), '')
    assert.equal(msgMenuItems({ parent: true, parentKind: 'issue' })[1].labelKey, 'feed.msg_menu.open_parent')
    assert.equal(msgMenuItems({ parent: true })[1].labelKey, 'feed.msg_menu.open_parent')
  })

  it('the card computes the same kind inline (it may not import parent-section.mjs)', () => {
    const card = src('src/components/MessageCard.vue')
    assert.match(card, /:parent-kind="parentKind"/)
    assert.match(card, /ch === 'issues' \|\| ch === 'tasks' \? 'issue' : 'channel'/)
    assert.match(card, /dmPeerOf\(props\.msg, viewerId\.value\) \? 'dm' : ''/)
    const inline = (m, self) => {
      const ch = String(m.channel || '').trim().replace(/^#/, '').toLowerCase()
      if (ch) return ch === 'issues' || ch === 'tasks' ? 'issue' : 'channel'
      return dmPeerOfShim(m, self) ? 'dm' : ''
    }
    for (const m of [{ channel: 'dev' }, { channel: '#Issues' }, { channel: 'tasks' }, { from: 'HUM-4', to: 'CLE-07', to_box: 'box-a' }, { from: 'HUM-4', to: 'ALL-0' }, {}]) {
      assert.equal(inline(m, 'HUM-4'), parentKindOf(m, 'HUM-4'), JSON.stringify(m))
    }
    assert.match(src('src/components/MessageMenu.vue'), /parentKind: props\.parentKind/)
  })

  it('both words exist and are translated in every locale', () => {
    const dir = join(WUI, 'i18n/locales')
    const en = JSON.parse(readFileSync(join(dir, 'en.json'), 'utf8')).feed.msg_menu
    assert.equal(en.open_in_dm, 'Open in direct msg view')
    assert.equal(en.open_in_channels, 'Open in channels view')
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const row = JSON.parse(readFileSync(join(dir, f), 'utf8')).feed.msg_menu
      for (const k of ['open_in_dm', 'open_in_channels']) {
        assert.ok(typeof row[k] === 'string' && row[k].trim() && !/[<@{}|]/.test(row[k]), f + ' ' + k)
        if (f !== 'en.json') assert.notEqual(row[k], en[k], f + ' ' + k)
      }
    }
  })
})

describe('HUM-10 c15b557e: the card lands at the reader\'s edge', () => {
  const scroller = { top: 100, bottom: 700 }
  it('newest first (prepend): the card\'s top meets the list\'s top', () => {
    assert.equal(cardScrollDelta({ top: 400, bottom: 480 }, scroller, false), 300)
    assert.equal(cardScrollDelta({ top: 40, bottom: 120 }, scroller, false), -60)
  })
  it('newest last (append): the card\'s bottom meets the list\'s bottom, above the docked Omnibox', () => {
    assert.equal(cardScrollDelta({ top: 400, bottom: 480 }, scroller, true), -220)
    assert.equal(cardScrollDelta({ top: 400, bottom: 480 }, scroller, true, 120), -100)
    assert.equal(cardScrollDelta({ top: 900, bottom: 980 }, scroller, true), 280)
  })
  it('the menu jump reads the person\'s order and selects a topic message without opening it', () => {
    const nav = src('src/utils/parent-section-open.mjs')
    assert.match(nav, /cardScrollDelta\(/)
    assert.match(nav, /topicLevel: Boolean\(deps\.topicLevel\)/)
    assert.match(nav, /if \(!target\) card\.focus\(\{ preventScroll: true, focusVisible: true \}\)/)
    assert.match(src('src/components/MessageCard.vue'), /newestLast: newestLast\.value, topicLevel: true/)
  })
})

describe('the menu item', () => {
  it('sits right after Open on a thread line', () => {
    assert.deepEqual(msgMenuItems({ parent: true }).map((i) => i.id), ['open', 'parent', 'copy'])
    assert.deepEqual(msgMenuItems({ parent: true, editable: true }).map((i) => i.id), ['open', 'parent', 'copy', 'edit', 'delete'])
    assert.equal(msgMenuItems({ parent: true })[1].labelKey, 'feed.msg_menu.open_parent')
    assert.equal(msgMenuItems({ parent: true })[1].icon, 'parent')
  })

  it('is not offered unless asked for', () => {
    assert.equal(msgMenuItems().some((i) => i.id === 'parent'), false)
  })

  it('has its glyph and its words in every locale', () => {
    assert.match(src('src/utils/uiIcons.ts'), /\n {2}parent: \[/)
    const dir = join(WUI, 'i18n/locales')
    const files = readdirSync(dir).filter((f) => f.endsWith('.json'))
    assert.equal(files.length, 19)
    for (const f of files) {
      const j = JSON.parse(readFileSync(join(dir, f), 'utf8'))
      const text = j.feed && j.feed.msg_menu && j.feed.msg_menu.open_parent
      assert.equal(typeof text, 'string', f)
      assert.ok(text.trim() && !/[<@{}|]/.test(text), f)
    }
  })
})

describe('wiring', () => {
  it('a thread line (not a middle card) offers it and loads what it does on choice', () => {
    const card = src('src/components/MessageCard.vue')
    assert.match(card, /:parent="showParent"/)
    assert.match(card, /@parent="onMenuParent"/)
    assert.match(card, /showParent = computed\(\(\) => !props\.clickable/)
    assert.match(card, /import\('~\/utils\/parent-section-open\.mjs'\)/)
    const menu = src('src/components/MessageMenu.vue')
    assert.match(menu, /else if \(id === 'parent'\) emit\('parent'\)/)
  })

  it('none of it is in the initial chunk: no static import of either module anywhere', () => {
    const files = ['src/components/MessageCard.vue', 'src/components/MessageMenu.vue', 'src/components/LiveFeed.vue']
    for (const rel of files) assert.doesNotMatch(src(rel), /from '~\/utils\/parent-section(-open)?\.mjs'/, rel)
    assert.doesNotMatch(src('src/components/LiveFeed.vue'), /reveal/)
  })

  it('pages back for the parent card and re-opens the thread the page released', () => {
    const nav = src('src/utils/parent-section-open.mjs')
    assert.match(nav, /REVEAL_PAGES/)
    assert.match(nav, /data-testid="load-more"/)
    assert.match(nav, /topic\.openTarget\(target, topic\.rootMsg\)/)
  })

  it('the card test agrees with parentSection on who has a parent', () => {
    const cases = [
      { channel: 'dev', task_id: TOPIC },
      { channel: '#dev', task_id: TOPIC },
      { from: 'HUM-4', to: 'CLE-07', to_box: 'box-a', task_id: TOPIC },
      { from: 'HUM-4', to: 'ALL-0', task_id: TOPIC },
      {},
    ]
    assert.match(src('src/components/MessageCard.vue'), /String\(props\.msg\.channel \|\| ''\)\.trim\(\)\.replace\(\/\^#\/, ''\) \|\| dmPeerOf\(props\.msg, viewerId\.value\)/)
    for (const m of cases) {
      const card = Boolean(String(m.channel || '').trim().replace(/^#/, '') || dmPeerOfShim(m, 'HUM-4'))
      assert.equal(card, Boolean(parentSection(m, { self: 'HUM-4' })), JSON.stringify(m))
    }
  })
})
