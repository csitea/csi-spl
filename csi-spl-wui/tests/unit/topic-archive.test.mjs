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
  isLatestMessage,
  isTopicCard,
  latestMessageId,
  mayArchiveTopic,
  mayChangeTopic,
  openingCardId,
  paneArchiveOffer,
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

describe('isLatestMessage', () => {
  it('returns true if the message is the latest in the topic', () => {
    const msg = { msg_id: 'm2' }
    assert.equal(isLatestMessage(msg, 'm2'), true)
  })
  
  it('returns false if the message is not the latest in the topic', () => {
    const msg = { msg_id: 'm1' }
    assert.equal(isLatestMessage(msg, 'm2'), false)
  })
  
  it('returns false if the message has no msg_id', () => {
    const msg = {}
    assert.equal(isLatestMessage(msg, 'm2'), false)
  })
  
  it('returns false if the message is null or undefined', () => {
    assert.equal(isLatestMessage(null, 'm2'), false)
    assert.equal(isLatestMessage(undefined, 'm2'), false)
  })
  
  it('returns false if lastMsgId is null or undefined', () => {
    const msg = { msg_id: 'm2' }
    assert.equal(isLatestMessage(msg, null), false)
    assert.equal(isLatestMessage(msg, undefined), false)
  })
})

describe('HUM-10: in a topic pane only the LATEST message offers Archive topic (owner, t1 7de82b71)', () => {
  const opener = { msg_id: 'o1', task_id: 't1', from: 'HUM-1', is_parent: 1, ts: '2026-10-10T10:00:00Z' }
  const older = { msg_id: 'r1', task_id: 't1', from: 'HUM-2', is_parent: 0, ts: '2026-10-10T10:01:00Z' }
  const newest = { msg_id: 'r2', task_id: 't1', from: 'HUM-2', is_parent: 0, ts: '2026-10-10T10:02:00Z' }
  const everyone = { role: 'developer', tenantOwner: false, topicArchivePolicy: 'everyone' }
  const starter = { role: 'developer', tenantOwner: false, topicArchivePolicy: 'starter' }

  it('the latest message is the newest stored row, whatever order the pane shows', () => {
    assert.equal(latestMessageId([newest, older, opener]), 'r2')
    assert.equal(latestMessageId([opener, older, newest]), 'r2')
    assert.equal(latestMessageId([opener]), 'o1')
    assert.equal(latestMessageId([opener, { msg_id: 'p', pending: true, ts: '2026-10-10T11:00:00Z' }]), 'o1', 'a pending echo is not stored yet')
    assert.equal(latestMessageId([]), '')
  })
  it('the latest reply: yes', () => {
    assert.equal(paneArchiveOffer(newest, 'r2', opener, 'HUM-2', everyone), true)
  })
  it('an older reply: no', () => {
    assert.equal(paneArchiveOffer(older, 'r2', opener, 'HUM-2', everyone), false)
  })
  it('the opener alone (no replies): yes', () => {
    assert.equal(paneArchiveOffer(opener, latestMessageId([opener]), opener, 'HUM-1', everyone), true)
  })
  it('the opener of a topic with replies: no', () => {
    assert.equal(paneArchiveOffer(opener, 'r2', opener, 'HUM-1', everyone), false)
  })
  it('the permission is read on the opener, never on the reply', () => {
    // starter policy: HUM-2 wrote the latest reply but did not start the topic
    assert.equal(paneArchiveOffer(newest, 'r2', opener, 'HUM-2', starter), false)
    // HUM-1 started it: the latest reply (someone else's) offers it to them
    assert.equal(paneArchiveOffer(newest, 'r2', opener, 'HUM-1', starter), true)
    // no opener known: nothing is offered
    assert.equal(paneArchiveOffer(newest, 'r2', null, 'HUM-1', everyone), false)
  })
  it('never on a pending echo or with no latest id', () => {
    assert.equal(paneArchiveOffer({ ...newest, pending: true }, 'r2', opener, 'HUM-1', everyone), false)
    assert.equal(paneArchiveOffer(newest, '', opener, 'HUM-1', everyone), false)
  })
  it('MessageCard gates the menu item and the left swipe on it; the pane passes the opener', () => {
    const mc = src('src/components/MessageCard.vue')
    assert.match(mc, /paneArchiveOffer\(props\.msg, props\.lastMsgId \|\| '', props\.paneOpener/)
    assert.match(mc, /if \(props\.topicMenu \|\| inPane\.value\) return showTopicArchive\.value/)
    assert.match(src('src/components/LiveFeed.vue'), /:pane-opener="paneOpener"/)
  })
})

describe('who may Archive, per the workspace policy (CLE-77819, owner 2026-09-30)', () => {
  // card.from = HUM-1 (the starter). me carries topicArchivePolicy, as
  // normalizeMe fills from /v1/view/me.
  const me = (policy, over = {}) => ({ role: 'developer', tenantOwner: false, topicArchivePolicy: policy, ...over })
  const owner = (policy) => me(policy, { role: 'biz_owner', tenantOwner: true })
  const admin = (policy) => me(policy, { role: 'admin' })

  it("everyone (the default): any member archives any card they can see", () => {
    assert.equal(mayArchiveTopic(card, 'HUM-2', me('everyone')), true)
    assert.equal(mayArchiveTopic(card, 'HUM-1', me('everyone')), true)
    assert.equal(mayArchiveTopic(card, 'HUM-9', admin('everyone')), true)
  })
  it('admins: only the tenant owner or an admin; the starter and a member no', () => {
    assert.equal(mayArchiveTopic(card, 'HUM-8', owner('admins')), true)
    assert.equal(mayArchiveTopic(card, 'HUM-9', admin('admins')), true)
    assert.equal(mayArchiveTopic(card, 'HUM-1', me('admins')), false, 'the starter is not an admin')
    assert.equal(mayArchiveTopic(card, 'HUM-2', me('admins')), false)
  })
  it('starter: the topic starter, plus owner / admin; a plain member no', () => {
    assert.equal(mayArchiveTopic(card, 'HUM-1', me('starter')), true, 'the starter')
    assert.equal(mayArchiveTopic(card, 'HUM-9', admin('starter')), true)
    assert.equal(mayArchiveTopic(card, 'HUM-2', me('starter')), false)
  })
  it('before /v1/view/me answers (or in the mock): the author only; never on a reply', () => {
    assert.equal(mayArchiveTopic(card, 'HUM-1', null), true, 'the author, as before the setting')
    assert.equal(mayArchiveTopic(card, 'HUM-2', null), false)
    assert.equal(mayArchiveTopic({ ...card, is_parent: 0 }, 'HUM-1', me('everyone')), false, 'a reply is not a card')
  })
  it('Delete stays the three-role rule, unaffected by the policy', () => {
    assert.equal(mayChangeTopic(card, 'HUM-2', me('everyone')), false, 'a member never deletes under everyone')
    assert.equal(mayChangeTopic(card, 'HUM-1', me('everyone')), true, 'the author still deletes')
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
  it('CLE-77819: Archive and Delete are gated apart', () => {
    // The addressee: Archive, no Delete-topic, and no single-message Delete.
    assert.deepEqual(msgMenuItems({ topicArchive: true }).map((i) => i.id), ['open', 'copy', 'archive'])
    assert.deepEqual(msgMenuItems({ editable: false, topicArchive: true }).map((i) => i.id), ['open', 'copy', 'archive'])
    // Delete-topic without Archive (a defensive shape) offers only Delete-topic.
    assert.deepEqual(msgMenuItems({ topicDelete: true }).map((i) => i.id), ['open', 'copy', 'delete-topic'])
    // Both flags = the author / owner / admin card, as `topic` shorthand does.
    assert.deepEqual(msgMenuItems({ topicArchive: true, topicDelete: true }).map((i) => i.id), ['open', 'copy', 'archive', 'delete-topic'])
  })
  it('HUM-10 (t1 7de82b71): a topic pane\'s latest reply offers Archive AND keeps its message Delete', () => {
    assert.deepEqual(msgMenuItems({ editable: true, topicArchive: true, paneArchive: true }).map((i) => i.id), ['open', 'copy', 'edit', 'archive', 'delete'])
    // not the viewer's to delete: Archive alone
    assert.deepEqual(msgMenuItems({ editable: false, topicArchive: true, paneArchive: true }).map((i) => i.id), ['open', 'copy', 'archive'])
    // MessageCard passes paneArchive on a pane reply, to the menu AND the shortcuts
    const card = src('src/components/MessageCard.vue')
    assert.match(card, /:pane-archive="paneArchiveReply"/)
    assert.match(card, /paneArchive: paneArchiveReply\.value/)
    assert.match(card, /const paneArchiveReply = computed\(\(\) => inPane\.value && !props\.topicMenu && showTopicArchive\.value\)/)
    assert.match(src('src/components/MessageMenu.vue'), /paneArchive: props\.paneArchive/)
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
  it('the middle feed marks its cards, the card offers the entries, the dialog is mounted on demand', () => {
    assert.match(src('src/components/LiveFeed.vue'), /:topic-menu="topicMenuFor\(it\.msg\)"/)
    assert.match(src('src/components/LiveFeed.vue'), /if \(props\.openButton\) return true/)
    assert.match(src('src/components/LiveFeed.vue'), /!props\.topicCardMenu \|\| !isTopicCard\(m\)/)
    /* t1 ffc3b83c: only the thread's opener (its earliest card), not every level-1 row */
    assert.match(src('src/components/LiveFeed.vue'), /String\(m\.msg_id\) === openerId\.value/)
    assert.match(src('src/components/TopicPane.vue'), /\btopic-card-menu\b/)
    assert.match(src('src/components/LiveTopicPane.vue'), /\btopic-card-menu\b/)
    const cardSrc = src('src/components/MessageCard.vue')
    assert.match(cardSrc, /:topic-archive="showTopicArchive"/)
    assert.match(cardSrc, /:topic-delete="showTopicDelete"/)
    assert.match(cardSrc, /mayChangeTopic\(props\.msg, editorId\.value, access\.me\)/)
    assert.match(cardSrc, /mayArchiveTopic\(props\.msg, editorId\.value, access\.me\)/)
    /* CLE-77840: eager code (the Delete key opens it; a lazy chunk is gone on a stale tab) */
    assert.match(cardSrc, /<TopicDeleteDialog\s+v-if="topicDeleteOpen"/)
    assert.match(cardSrc, /archiveTopic\(id, true\)/)
  })
  it('the dialog names the reply count from the hub before it deletes', () => {
    const d = src('src/components/TopicDeleteDialog.vue')
    assert.match(d, /withSessionRetry\(api, \(\) => api\.topicSize\(props\.msgId\)\)/)
    /* UiConfirm disables Delete while busy; the reply count is cosmetic and
       must NOT gate it (a disabled primary leaves the focus trap, prd t1 b6a7db19) */
    const template = d.slice(0, d.indexOf('<script'))
    assert.ok(template.includes('<UiConfirm'), 'the template is read, not the script')
    assert.doesNotMatch(template, /:disabled="replies === null"/)
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
    /* t1 58b8055d: a row click opens the shell pane and stays on Archive */
    assert.match(p, /topic\.openTopic\(id\)/)
    assert.match(p, /ev\.preventDefault\(\)/)
  })
})
