// SPL-983 (specs/041): Archive / Delete a topic card - who is offered it,
// what the menu shows, what a live frame drops, and that the pieces are wired.
// Run: node tests/unit/topic-archive.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  archivedRow,
  isTopicCard,
  mayChangeTopic,
  openingCardId,
  topicErrorKey,
  topicFrameDrops,
  topicFrameTasks,
  withoutCards,
} from '../../src/utils/topic-archive.mjs'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

const card = { msg_id: 'm1', task_id: 't1', from: 'HUM-1', is_parent: 1 }

describe('who is offered Archive / Delete (owner rule, 2026-09-26)', () => {
  it('the author of the card', () => {
    assert.equal(mayChangeTopic(card, 'HUM-1', { role: 'developer', tenantOwner: false }), true)
  })
  it('the tenant owner and an admin, on anyone\'s card, an agent\'s too', () => {
    assert.equal(mayChangeTopic(card, 'HUM-8', { role: 'biz_owner', tenantOwner: true }), true)
    assert.equal(mayChangeTopic(card, 'HUM-9', { role: 'admin', tenantOwner: false }), true)
    assert.equal(mayChangeTopic({ ...card, from: 'CLE-07' }, 'HUM-9', { role: 'admin' }), true)
  })
  it('never any other member, and nobody before /v1/view/me answered unless it is their card', () => {
    assert.equal(mayChangeTopic(card, 'HUM-2', { role: 'developer', tenantOwner: false }), false)
    assert.equal(mayChangeTopic(card, 'HUM-2', { role: 'tester' }), false)
    assert.equal(mayChangeTopic(card, 'HUM-2', null), false)
    assert.equal(mayChangeTopic({ ...card, from: 'CLE-07' }, 'HUM-2', { role: 'developer' }), false)
    assert.equal(mayChangeTopic(card, '', null), false)
  })
  it('only on a stored level-1 card: never a reply or a pending echo', () => {
    assert.equal(isTopicCard(card), true)
    assert.equal(isTopicCard({ msg_id: 'x' }), true, 'no is_parent = level 1 (spec 033)')
    assert.equal(isTopicCard({ ...card, is_parent: 0 }), false)
    assert.equal(isTopicCard({ ...card, pending: true }), false)
    assert.equal(mayChangeTopic({ ...card, is_parent: 0 }, 'HUM-1', { role: 'admin' }), false)
  })
})

describe('the card menu', () => {
  it('ends with Archive then Delete on a card the viewer may change, the single-message Delete gone', () => {
    const items = msgMenuItems({ editable: true, topic: true })
    assert.deepEqual(items.map((i) => i.id), ['open', 'copy', 'edit', 'archive', 'delete-topic'])
    assert.deepEqual(items.slice(-2).map((i) => i.icon), ['archive', 'delete'])
    assert.deepEqual(items.slice(-2).map((i) => i.labelKey), ['feed.msg_menu.archive', 'feed.msg_menu.delete'])
    assert.deepEqual(msgMenuItems({ editable: false, topic: true }).map((i) => i.id), ['open', 'copy', 'archive', 'delete-topic'])
  })
  it('is unchanged without the topic flag', () => {
    assert.deepEqual(msgMenuItems({ editable: true }).map((i) => i.id), ['open', 'copy', 'edit', 'delete'])
  })
  it('draws the Gmail-style archive glyph (tray + arrow in), unarchive (arrow out) and a Material delete can', () => {
    const icons = src('src/utils/uiIcons.ts')
    const glyph = (name) => (icons.match(new RegExp(`\\n  ${name}: \\[([\\s\\S]*?)\\n  \\]`)) || [])[1] || ''
    for (const name of ['archive', 'unarchive', 'delete']) assert.ok(glyph(name), name)
    assert.ok(glyph('archive').includes('m9 14 3 3 3-3'), 'archive arrow points in (down)')
    assert.ok(glyph('unarchive').includes('m9 14 3-3 3 3'), 'unarchive arrow points out (up)')
  })
})

describe('live frames', () => {
  it('topic_archived drops the card; unarchive drops nothing', () => {
    assert.deepEqual(topicFrameDrops({ type: 'topic_archived', msg_id: 'm1', archived: true }), ['m1'])
    assert.deepEqual(topicFrameDrops({ type: 'topic_archived', msg_id: 'm1', archived: false }), [])
  })
  it('topic_deleted drops every row, the card first', () => {
    assert.deepEqual(topicFrameDrops({ type: 'topic_deleted', msg_id: 'm1', msg_ids: ['m2', 'm3'] }), ['m1', 'm2', 'm3'])
    assert.deepEqual(topicFrameDrops({ type: 'topic_deleted', msg_id: 'm1', msg_ids: ['m1', 'm2'] }), ['m1', 'm2'])
  })
  it('topic_deleted ends its tasks, never the lobby', () => {
    assert.deepEqual(topicFrameTasks({ type: 'topic_deleted', task_ids: ['m1', 'L', 't1'] }, 'L'), ['m1', 't1'])
    assert.deepEqual(topicFrameTasks({ type: 'topic_archived', task_ids: ['t1'] }, 'L'), [])
  })
  it('anything else drops nothing', () => {
    assert.deepEqual(topicFrameDrops(null), [])
    assert.deepEqual(topicFrameDrops({ type: 'message_deleted', msg_id: 'm1' }), [])
  })
})

describe('errors and the Archive rows', () => {
  it('a refusal reads as the role sentence, anything else as the retry one', () => {
    assert.equal(topicErrorKey({ token: 'not_allowed' }), 'feed.topic_delete.error_forbidden')
    assert.equal(topicErrorKey({ token: 'forbidden' }, 'archive'), 'archive.error_forbidden')
    assert.equal(topicErrorKey({ token: 'not_a_card' }), 'feed.topic_delete.error_not_card')
    assert.equal(topicErrorKey({ token: 'not_a_card' }, 'archive'), 'archive.error_not_card')
    assert.equal(topicErrorKey(new Error('x'), 'archive'), 'archive.error')
  })
  it('opening card is the earliest is_parent 1 row, not a later one', () => {
    // The e802196b shape: the oldest row is a channel reply, then agent cards.
    const msgs = [
      { msg_id: 'r0', is_parent: 0 },
      { msg_id: 'card1', is_parent: 1 },
      { msg_id: 'r1', is_parent: 0 },
      { msg_id: 'card2', is_parent: 1 },
    ]
    assert.equal(openingCardId(msgs, 'card2'), 'card1')
    // A normal topic: the opener is first.
    assert.equal(openingCardId([{ msg_id: 'a', is_parent: 1 }, { msg_id: 'b', is_parent: 0 }], 'a'), 'a')
    // No card at all -> the fallback (the clicked id).
    assert.equal(openingCardId([{ msg_id: 'r0', is_parent: 0 }], 'r0'), 'r0')
    assert.equal(openingCardId([], 'x'), 'x')
    assert.equal(openingCardId(null, 'y'), 'y')
  })
  it('an archived card is one line of its body, its reply count and whether it may be deleted', () => {
    const r = archivedRow({ msg_id: 'm1', task_id: 't1', channel: 'dev', replies: 3, can_delete: true, archived_at: '2026-09-26T20:00:00Z',
      message: { body: '\n  first line  \nsecond', from: 'HUM-1', from_box: 'box-wui' } })
    assert.equal(r.title, 'first line')
    assert.equal(r.replies, 3)
    assert.equal(r.can_delete, true)
    assert.equal(r.channel, 'dev')
    assert.equal(archivedRow({}).can_delete, false)
    assert.deepEqual(withoutCards([{ msg_id: 'a' }, { msg_id: 'b' }], ['a']), [{ msg_id: 'b' }])
  })
})

describe('wiring', () => {
  it('the middle feed marks its cards, the card offers the entries, the dialog is lazy', () => {
    assert.match(src('src/components/LiveFeed.vue'), /:topic-menu="openButton"/)
    const cardSrc = src('src/components/MessageCard.vue')
    assert.match(cardSrc, /:topic="showTopicActions"/)
    assert.match(cardSrc, /mayChangeTopic\(props\.msg, editorId\.value, access\.me\)/)
    assert.match(cardSrc, /<LazyTopicDeleteDialog\s+v-if="topicDeleteOpen"/)
    assert.match(cardSrc, /archiveTopic\(id, true\)/)
  })
  it('the dialog names the reply count from the hub before it deletes', () => {
    const d = src('src/components/TopicDeleteDialog.vue')
    assert.match(d, /withSessionRetry\(api, \(\) => api\.topicSize\(props\.msgId\)\)/)
    /* UiConfirm disables Delete while busy; the count gates it too (SPL-1001) */
    assert.match(d, /:disabled="replies === null"/)
    assert.match(d, /api\.deleteTopic\(props\.msgId\)/)
  })
  it('the shell drops rows on topic frames and the live client routes both types', () => {
    assert.match(src('src/layouts/default.vue'), /live\.onTopic\(/)
    const ws = src('src/utils/live-ws.mjs')
    assert.match(ws, /topicArchived: 'topic_archived'/)
    assert.match(ws, /topicDeleted: 'topic_deleted'/)
  })
  it('the Archive page lists, unarchives and deletes', () => {
    const p = src('src/pages/archive.vue')
    /* a fresh page's first read can beat the session door (a 401): measured live on dev, 2026-09-26 */
    assert.match(p, /withSessionRetry\(api, \(\) => api\.listArchived\(/)
    assert.match(p, /api\.archiveTopic\(id, false\)/)
    assert.match(p, /LazyTopicDeleteDialog/)
  })
})
