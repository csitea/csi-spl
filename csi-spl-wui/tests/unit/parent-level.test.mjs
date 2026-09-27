// Level 1 / level 2 (owner order 2026-09-25), end to end at unit level.
//
//   level 1  the opening message of a topic, is_parent 1, the middle card
//   level 2  written while the right topic pane is open, is_parent 0, drawn
//            only inside that topic on the right
//
// Each block is one leg a level-2 line travels: the send (flag + target),
// the wire (optimistic row, ack, live echo, view read), the middle list, the
// right pane, the topics home list, and the reload read. The live proof is
// tests/e2e/parent-level-live.proof.mjs.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { normalizeViewMessage } from '../../src/utils/view-api.mjs'
import { channelView as channelViewOf, mergeLive, rowFromAck, rowsForRightPane } from '../../src/utils/channel-feed.mjs'
import { pendingRow } from '../../src/utils/feed.mjs'
import { messageFromFrame } from '../../src/utils/live-ws.mjs'
import { bumpTopic } from '../../src/utils/topic-list.mjs'
import { isParentFlag, omniboxReplyTaskId, startsNewTopic } from '../../src/utils/omnibox-topic.mjs'
import { KEY_NAV_MS, eventChoosesPane, isKeyNav, onScrollbar, paneOfTarget, paneTakesLine } from '../../src/utils/pane-focus.mjs'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/* channelView answers { rows, hasOlder }; these checks read the rows. */
const channelView = (messages) => channelViewOf(messages).rows

const T = '44440000-0000-4000-8000-00000000c001'
const U = '44440000-0000-4000-8000-00000000c002'

const L1 = { msg_id: 'l1', task_id: T, ts: '2026-09-25T10:00:00Z', from: 'HUM-4', kind: 'note', body: 'opening line', channel: 'tasks', parent_task_id: null, is_parent: 1 }
const L2 = { msg_id: 'l2', task_id: T, ts: '2026-09-25T10:05:00Z', from: 'HUM-4', kind: 'note', body: 'second line', channel: 'tasks', parent_task_id: null, is_parent: 0 }

describe('the send: flag and target', () => {
  for (const tab of ['channels', 'dm', 'topics', 'flow']) {
    it(`pane open on ${tab}: is_parent 0 into the open topic`, () => {
      assert.equal(isParentFlag({ paneVisible: true }), 0)
      assert.equal(omniboxReplyTaskId({ tab, selectedTaskId: T, paneVisible: true }), T)
    })
  }
  for (const tab of ['channels', 'dm', 'flow']) {
    it(`pane closed on ${tab}: is_parent 1 and a new task`, () => {
      assert.equal(isParentFlag({ paneVisible: false }), 1)
      assert.equal(omniboxReplyTaskId({ tab, selectedTaskId: T, paneVisible: false }), '')
    })
  }
  it('`in: <title>` still names the topic, pane open or not', () => {
    assert.equal(omniboxReplyTaskId({ tab: 'channels', selectedTaskId: T, namedTopicId: U, paneVisible: true }), U)
    assert.equal(omniboxReplyTaskId({ tab: 'channels', namedTopicId: U, paneVisible: false }), U)
  })
})

describe('the wire keeps is_parent 0 on every leg', () => {
  it('optimistic row', () => {
    assert.equal(pendingRow({ msg_id: 'p', task_id: T, body: 'x', is_parent: 0 }).is_parent, 0)
  })
  it('row built from the ack', () => {
    const row = rowFromAck({ msg_id: 'a', task_id: T, received_at: '2026-09-25T10:05:00Z' }, { task_id: T, body: 'x', is_parent: 0 })
    assert.equal(row.is_parent, 0)
    assert.equal(row.task_id, T)
  })
  it('live echo frame', () => {
    const m = messageFromFrame({ type: 'message', task_id: T, is_parent: 0, env: { from_box: 'box-wui', to_box: 'box-wui', channel: 'tasks', msg: { v: 1, msg_id: 'e', task_id: T, body: 'x' } } })
    assert.equal(m.is_parent, 0)
  })
  it('view read element (the reload path)', () => {
    const m = normalizeViewMessage({ cursor: 'c', received_at: '2026-09-25T10:05:00Z', is_parent: 0, env: { from_box: 'box-wui', to_box: 'box-wui', msg: { v: 1, msg_id: 'v', task_id: T } } })
    assert.equal(m.is_parent, 0)
  })
})

describe('the middle: one card per topic, and it is the opening line', () => {
  it('a newer level-2 line bumps the card but is never the card', () => {
    const v = channelView([L1, L2])
    assert.deepEqual(v.map((r) => r.msg_id), ['l1'])
    assert.equal(v[0].body, 'opening line')
    assert.equal(v[0].last_ts, L2.ts)
  })
  it('the echo of a level-2 line merged into the feed adds no card', () => {
    const rows = mergeLive([L1], { ...L2, msg_id: 'echo' })
    assert.deepEqual(channelView(rows).map((r) => r.msg_id), ['l1'])
  })
  it('a level-2 line that arrives before its opening line is loaded is not a card', () => {
    assert.deepEqual(channelView([L2]), [])
  })
  it('a level-1 send is its own new card', () => {
    const other = { ...L1, msg_id: 'l1b', task_id: U, ts: '2026-09-25T10:06:00Z', body: 'another topic' }
    assert.deepEqual(channelView([L1, L2, other]).map((r) => r.msg_id), ['l1b', 'l1'])
  })
})

describe('the right pane: the open topic keeps its level-2 lines', () => {
  it('a confirmed level-2 line held by the feed joins the topic read', () => {
    const rows = rowsForRightPane([L1], [L1, { ...L2, pending: false }], T)
    assert.deepEqual(rows.map((r) => r.msg_id).sort(), ['l1', 'l2'])
  })
  it('another topic\'s level-2 line does not', () => {
    const rows = rowsForRightPane([L1], [{ ...L2, task_id: U, msg_id: 'x' }], T)
    assert.deepEqual(rows.map((r) => r.msg_id), ['l1'])
  })
})

describe('the topics home list', () => {
  const home = [{ task_id: T, subject: 'opening line', last_ts: L1.ts, count: 1, kinds: { note: 1 }, participants: [] }]
  it('a level-2 line bumps its topic and keeps the subject', () => {
    const next = bumpTopic(home, { ...L2, received_at: L2.ts })
    assert.equal(next.length, 1)
    assert.equal(next[0].subject, 'opening line')
    assert.equal(next[0].count, 2)
  })
  it('a level-2 line of an unknown topic starts no row', () => {
    assert.deepEqual(bumpTopic(home, { ...L2, task_id: U, msg_id: 'u', received_at: L2.ts }), home)
  })
})

/* The reload read: listMessages reads each topic newest first with a limit.
   A topic with more level-2 lines than the limit must still bring back its
   opening line, or every row loaded is is_parent 0 and the topic has no
   middle card at all after a reload. */
describe('reload: the opening line is loaded even behind the page limit', () => {
  const el = (id, at, isParent, body) => ({
    cursor: 'c-' + id, received_at: at, is_parent: isParent,
    env: { from_box: 'box-wui', to_box: 'box-wui', channel: 'tasks', msg: { v: 1, msg_id: id, task_id: T, ts: at, body, kind: 'note' }, sig: 's' },
  })
  const replies = Array.from({ length: 3 }, (_, i) => el('r' + i, `2026-09-25T10:1${i}:00Z`, 0, 'reply ' + i))
  const opener = el('l1', '2026-09-25T10:00:00Z', 1, 'opening line')

  function stub() {
    const calls = []
    const fn = async (url) => {
      calls.push(url)
      const q = new URL(url, 'http://x').searchParams
      let body = { error: 'not_found' }
      let status = 404
      if (url.startsWith('/v1/view/topics?')) {
        status = 200
        body = { topics: [{ task_id: T, channel: 'tasks', first_ts: opener.received_at, last_ts: replies[2].received_at, count: 4, subject: 'opening line' }], next: null }
      } else if (url.startsWith(`/v1/view/topics/${T}?`)) {
        status = 200
        const lim = Number(q.get('limit')) || 200
        const all = q.get('order') === 'desc' ? [...replies].reverse().concat(opener) : [opener, ...replies]
        body = { task_id: T, messages: all.slice(0, lim), next: null }
      }
      return { ok: status === 200, status, headers: { get: () => 'application/json' }, json: async () => body }
    }
    return { fn, calls }
  }

  it('a topic whose newest page is all level-2 still has its card', async () => {
    const { fn } = stub()
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const page = await c.listMessages({ channel: 'tasks', limit: 3 })
    const v = channelView(page.messages)
    assert.deepEqual(v.map((r) => r.msg_id), ['l1'])
    assert.equal(v[0].body, 'opening line')
  })
  it('a topic whose page already holds its opening line costs no extra read', async () => {
    const { fn, calls } = stub()
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await c.listMessages({ channel: 'tasks', limit: 50 })
    assert.equal(calls.filter((u) => u.startsWith(`/v1/view/topics/${T}?`)).length, 1)
  })
})

/* Owner, 2026-09-25 (test-02 / test-03): the pane selected LAST decides.
   Right pane visible and selected last -> is_parent 0 into that topic.
   Middle selected last -> is_parent 1, a new topic, even with the pane open. */
describe('the last selected pane decides the level', () => {
  const el = (inside) => ({ closest: (sel) => (sel === inside ? {} : null) })

  it('a target in the right pane is the right pane, in the middle the middle', () => {
    assert.equal(paneOfTarget(el('aside.live-pane')), 'right')
    assert.equal(paneOfTarget(el('.spool-main')), 'middle')
  })
  it('the sidebar, the top bar and a pane divider choose nothing', () => {
    assert.equal(paneOfTarget(el('.sidebar')), '')
    assert.equal(paneOfTarget({ closest: (s) => (s === '.pane-divider' || s === '.spool-main' ? {} : null) }), '')
    assert.equal(paneOfTarget(null), '')
  })
  it('test-03: pane visible and selected last -> level 2 into the open topic', () => {
    const paneVisible = paneTakesLine({ paneOpen: true, lastPane: 'right' })
    assert.equal(isParentFlag({ paneVisible }), 0)
    assert.equal(omniboxReplyTaskId({ tab: 'dm', selectedTaskId: T, paneVisible, lastPane: 'right' }), T)
  })
  /* SPL-996, owner answer B (topic e0b12a2c, 2026-09-27) replaced test-02:
     a click in the middle no longer makes the next line a new topic */
  for (const tab of ['channels', 'dm', 'topics', 'flow']) {
    it(`SPL-996 B on ${tab}: pane open, the middle clicked last -> still level 2 into the open topic`, () => {
      const paneVisible = paneTakesLine({ paneOpen: true, lastPane: 'middle' })
      assert.equal(paneVisible, true)
      assert.equal(isParentFlag({ paneVisible, lastPane: 'middle' }), 0)
      assert.equal(omniboxReplyTaskId({ tab, selectedTaskId: T, paneVisible, lastPane: 'middle' }), T)
    })
  }
  it('SPL-996 B: `@someone` first is the explicit new topic, pane open or not', () => {
    assert.equal(startsNewTopic('@CLE-001 please look'), true)
    assert.equal(startsNewTopic('  @HUM-10 hi'), true)
    assert.equal(startsNewTopic('ask @CLE-001 later'), false)
    assert.equal(startsNewTopic('@ alone'), false)
    assert.equal(omniboxReplyTaskId({ tab: 'channels', selectedTaskId: T, paneVisible: true, newTopic: true }), '')
    assert.equal(isParentFlag({ paneVisible: true && !startsNewTopic('@CLE-001 x') }), 1)
    assert.equal(omniboxReplyTaskId({ tab: 'channels', selectedTaskId: T, namedTopicId: U, paneVisible: true, newTopic: true }), U)
  })
  it('`in: <title>` still names the topic when the middle was selected last', () => {
    assert.equal(omniboxReplyTaskId({ tab: 'channels', selectedTaskId: T, namedTopicId: U, lastPane: 'middle' }), U)
  })
  it('an unknown last pane with the pane open (a ?topic= URL) keeps the pane', () => {
    assert.equal(paneTakesLine({ paneOpen: true, lastPane: '' }), true)
    assert.equal(paneTakesLine({ paneOpen: false, lastPane: 'right' }), false)
  })

  const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
  const read = (p) => readFileSync(join(SRC, p), 'utf8')
  it('the shell records the pane on pointerdown and focus', () => {
    const layout = read('layouts/default.vue')
    assert.match(layout, /@pointerdown\.capture="paneFocus\.noteEvent"/)
    assert.match(layout, /@focusin="paneFocus\.noteEvent"/)
  })
  it('opening a topic puts the reader on the right (channel/DM pane and live pane)', () => {
    assert.match(read('stores/topic.ts'), /function openTarget[\s\S]*?usePaneFocus\(\)\.openedTopic\(\)/)
    assert.match(read('stores/live.ts'), /async function open\([\s\S]*?if \(key === 'pane'\) usePaneFocus\(\)\.openedTopic\(\)/)
  })
  for (const [page, fn] of [['pages/channel/[name].vue', 'paneOpen'], ['pages/dm/[peer].vue', 'paneOpen'], ['pages/index.vue', 'paneOpen'], ['pages/lobby.vue', 'lobbyPaneOpen']]) {
    it(`${page} gates the pane on the last selected pane`, () => {
      const s = read(page)
      assert.match(s, new RegExp(`function ${fn}\\(\\) \\{\\s*return paneTakesLine\\(\\{ paneOpen: [^,]+, lastPane: paneFocus\\.last \\}\\)`))
      assert.doesNotMatch(s, /omniboxReplyTaskId\(\{(?:(?!lastPane)[^}])*\}\)/, 'every reply-target call passes lastPane')
    })
  }
})

/* Another reader's new lobby topic is a new task in channel lobby; the main
   lobby store merged only the room task's frames, so it reached nobody else
   live (dev 5b16c0f, a second tab, n=1). */
describe('#lobby follows its channel live', () => {
  const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
  const lobby = readFileSync(join(SRC, 'pages/lobby.vue'), 'utf8')
  it('subscribes to the lobby channel once the socket is up', () => {
    assert.match(lobby, /startHubSocket\(live\)\s*\n\s*followLobbyChannel\(\)/)
    assert.match(lobby, /client\.subscribeChannel\('lobby'\)/)
  })
  it('admits a lobby-channel frame of another task, and drops its listener on leave', () => {
    assert.match(lobby, /m\.channel === 'lobby' && m\.task_id !== store\.taskId\) store\.admit\(/)
    assert.match(lobby, /onBeforeUnmount\(\(\) => \{\s*if \(offLobbyChannel\) offLobbyChannel\(\)/)
  })
  it('the follow is declared before the immediate watch that calls it (TDZ crash on dev 57a7d4a)', () => {
    const decl = lobby.indexOf('let offLobbyChannel')
    const watchAt = lobby.indexOf('watch([lobbyId')
    assert.ok(decl > 0 && watchAt > 0 && decl < watchAt, `let at ${decl}, watch at ${watchAt}`)
  })
  it('a level-2 frame admitted that way is still not a middle card', () => {
    assert.deepEqual(channelView([L1, { ...L2, channel: 'lobby' }]).map((r) => r.msg_id), ['l1'])
  })
})

/* SPL-996 (prd t1 #spool-hub-mobile, 2026-09-27, n=4): follow-ups typed while
   a topic was open became new topics. Only the reader's own move picks the
   middle, and a send into an existing topic is never an opening. */
describe('SPL-996: a post made while a topic is open goes into it', () => {
  it('a reply target is always is_parent 0, pane open or closed', () => {
    assert.equal(isParentFlag({ paneVisible: false, replyTaskId: T }), 0)
    assert.equal(isParentFlag({ paneVisible: false, lastPane: 'middle', replyTaskId: T }), 0)
    assert.equal(isParentFlag({ paneVisible: false, replyTaskId: '' }), 1)
  })
  it('a pointerdown chooses, unless it is on a scrollbar', () => {
    assert.equal(eventChoosesPane({ type: 'pointerdown' }), true)
    assert.equal(eventChoosesPane({ type: 'pointerdown', onScrollbar: true }), false)
  })
  it('a focusin the app made is not a choice; one right after a nav key is', () => {
    assert.equal(eventChoosesPane({ type: 'focusin', keyNavAt: 0, now: 5000 }), false)
    assert.equal(eventChoosesPane({ type: 'focusin', keyNavAt: 5000, now: 5000 + KEY_NAV_MS + 1 }), false)
    assert.equal(eventChoosesPane({ type: 'focusin', keyNavAt: 5000, now: 5020 }), true)
    assert.equal(eventChoosesPane({ type: 'scroll' }), false)
  })
  it('typing and Enter in the composer are not navigation; Tab and arrows on a row are', () => {
    const field = { closest: (s) => (s.includes('textarea') ? {} : null) }
    const row = { closest: () => null }
    assert.equal(isKeyNav({ key: 'Enter', target: field }), false)
    assert.equal(isKeyNav({ key: 'a', target: field }), false)
    assert.equal(isKeyNav({ key: 'ArrowDown', target: field }), false)
    assert.equal(isKeyNav({ key: 'Tab', target: field }), true)
    assert.equal(isKeyNav({ key: 'ArrowDown', target: row }), true)
    assert.equal(isKeyNav({ key: 'Escape', target: row }), false)
  })
  it('the scrollbar is past the client box of a scrolling element', () => {
    const el = { clientWidth: 300, clientHeight: 500, scrollWidth: 300, scrollHeight: 2000 }
    assert.equal(onScrollbar({ target: el, offsetX: 305, offsetY: 10 }), true)
    assert.equal(onScrollbar({ target: el, offsetX: 120, offsetY: 10 }), false)
    assert.equal(onScrollbar({ target: { ...el, scrollHeight: 500 }, offsetX: 305, offsetY: 10 }), false)
    assert.equal(onScrollbar({ target: null }), false)
  })
  const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
  const read = (p) => readFileSync(join(SRC, p), 'utf8')
  it('the shell records navigation keys, and the store gates pointerdown / focusin', () => {
    assert.match(read('layouts/default.vue'), /document\.addEventListener\('keydown', noteKey, true\)/)
    assert.match(read('stores/pane-focus.ts'), /if \(chooses\) set\(paneOfTarget\(ev\.target\)\)/)
  })
  it('every page passes the reply target to isParentFlag', () => {
    assert.match(read('pages/channel/[name].vue'), /replyTaskId: topicId \|\| ''/)
    assert.match(read('pages/dm/[peer].vue'), /replyTaskId: topicId \|\| ''/)
    assert.match(read('pages/index.vue'), /replyTaskId: target \}\)\)/)
    assert.match(read('pages/lobby.vue'), /parentBit\(topicId\)/)
    assert.match(read('pages/lobby.vue'), /parentBit\('', fresh\)/)
    assert.match(read('pages/lobby.vue'), /parentBit\(replyHere\)/)
  })
})
