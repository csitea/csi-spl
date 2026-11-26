// Spec 186 row M3 (owner HUM-10, t1 032d8010, msgs 5fdfff6c and 4b3833e7):
// the select phase, shared by every bulk action on topics. The store
// (stores/topicSelect.ts) and the composable (composables/useTopicSelect.ts)
// run for real against pinia and vue; the hub's `topic_select` answer is a
// stub that records each frame, so a test sees exactly what the WUI sent and
// what it added. The components are checked on their source (the suite has
// no DOM), and the 390 px phone flow is the e2e topic-select-phone.test.mjs.
//
// Run: node --test tests/unit/topic-select.test.mjs
import { beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { nextTick, reactive } from 'vue'
import { createPinia, defineStore, setActivePinia } from 'pinia'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'
import { mockTopicSelect } from '../../src/utils/spool-client-mock.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const template = (p) => {
  const s = read(p)
  return s.slice(s.indexOf('<template>'), s.lastIndexOf('</template>'))
}

/* the hub stand-in: each topic_select frame is recorded; `answer(frame)` decides the reply */
const hub = { frames: [], answer: null }
const session = reactive({ claims: { t: 't1' } })
const mod = await importTsStubbed('src/composables/useTopicSelect.ts', {
  pinia: { defineStore },
  '~/composables/useSpoolApi': {
    useSpoolApi: () => ({
      tenant: 't1',
      topicSelect: async (frame) => {
        hub.frames.push(structuredClone(frame))
        return hub.answer(frame)
      },
    }),
  },
  '~/stores/session': { useSessionStore: () => session },
})
const { selectableCard } = await importTsStubbed('src/stores/topicSelect.ts', { pinia: { defineStore } })

const pick = (id, channel = 'alpha', title = 'Topic ' + id) => ({ task_id: id, channel, title })
const A = [pick('a1', 'alpha'), pick('a2', 'alpha'), pick('a3', 'alpha'), pick('a4', 'alpha')]
const B = [pick('b1', 'beta'), pick('b2', 'beta')]

let sel
beforeEach(() => {
  setActivePinia(createPinia())
  hub.frames = []
  hub.answer = null
  session.claims = { t: 't1' }
  sel = mod.useTopicSelect()
})

describe('ticks, as on issues (utils/issues-bulk.ts)', () => {
  it('a click ticks and unticks, in the order ticked', () => {
    sel.store.setShown(A)
    sel.store.toggle(A[2])
    sel.store.toggle(A[0])
    assert.deepEqual(sel.store.keys, ['a3', 'a1'])
    sel.store.toggle(A[2])
    assert.deepEqual(sel.store.keys, ['a1'])
  })
  it('shift-click ticks the run from the last box clicked', () => {
    sel.store.setShown(A)
    sel.store.toggle(A[0])
    sel.store.range(A[2], true)
    assert.deepEqual(sel.store.keys, ['a1', 'a2', 'a3'])
  })
  it('Esc empties the selection; Esc typed in a field does not', () => {
    sel.store.setShown(A)
    sel.store.toggle(A[1])
    sel.onKey({ key: 'Escape', defaultPrevented: false, target: { closest: () => ({}) } })
    assert.equal(sel.store.count, 1, 'a key in a field, dialog or menu is not the list\'s')
    sel.onKey({ key: 'Escape', defaultPrevented: false, target: { closest: () => null } })
    assert.equal(sel.store.count, 0)
  })
  it('a card\'s x ticks it, and a phone tap toggles instead of opening the topic while selecting', () => {
    const card = mod.useCardTopicSelect({ on: () => true, msg: () => ({ task_id: 'a1', channel: 'alpha' }), title: () => 'Topic a1', phone: () => true })
    const ev = (key) => ({ key, preventDefault() {}, target: { closest: () => null } })
    assert.equal(card.onKey(ev('x')), true)
    assert.equal(card.ticked.value, true)
    const tap = { target: { closest: () => null }, preventDefault() {}, stopPropagation() {} }
    assert.equal(card.onTap(tap), true, 'the tap is the select phase\'s')
    assert.equal(card.ticked.value, false)
    assert.equal(card.onTap(tap), false, 'nothing selected: the tap opens the topic as before')
  })
})

describe('the selection spans channels and filters (H2)', () => {
  it('a selection made on channel A\'s page is still there on channel B\'s page, "in 2 channels"', () => {
    sel.store.setShown(A)
    sel.store.toggle(A[0])
    sel.store.setShown(B) /* channel B's page mounts its feed */
    sel.store.toggle(B[1])
    assert.deepEqual(sel.store.keys, ['a1', 'b2'])
    assert.equal(sel.store.channels, 2)
    const bar = read('src/components/TopicSelectBar.vue')
    assert.match(bar, /store\.channels > 1\s*\?[\s\S]*?t\('topic_select\.in_channels', \{ n: store\.channels \}\)/)
  })
  it('a filter change keeps it (the topics shown change, the ticks stay)', () => {
    sel.store.setShown(A)
    sel.store.toggle(A[1])
    sel.store.toggle(A[3])
    sel.store.setShown([A[0]]) /* Filter New: one topic left on the page */
    assert.deepEqual(sel.store.keys, ['a2', 'a4'])
  })
  it('Clear and a workspace switch empty it', async () => {
    sel.store.setShown(A)
    sel.store.toggle(A[0])
    sel.store.clear()
    assert.equal(sel.store.count, 0)
    sel.store.toggle(A[0])
    session.claims = { t: 't2' }
    await nextTick()
    assert.equal(sel.store.count, 0)
    assert.equal(sel.store.ws, 't2')
  })
})

describe('the page box and "Select all N matching" tick what the filter matches', () => {
  it('the page box ticks exactly the topics shown, then (all were) none of them', () => {
    sel.store.setShown([A[1], A[2]])
    sel.store.toggle(B[0])
    sel.store.togglePage()
    assert.deepEqual(sel.store.keys, ['b1', 'a2', 'a3'])
    assert.equal(sel.store.page, 'all')
    sel.store.togglePage()
    assert.deepEqual(sel.store.keys, ['b1'])
  })
  it('"Select all N matching" pages the list to the end, then ticks every topic it shows', async () => {
    const pages = [[A[0], A[1]], [A[2]], [A[3]]]
    const feed = reactive({ loaded: 1 }) /* the feed's hasOlder is reactive too */
    sel.store.setShown(pages[0])
    sel.store.matcher = {
      more: () => feed.loaded < pages.length,
      load: async () => { feed.loaded++; sel.store.setShown(pages.slice(0, feed.loaded).flat()) },
    }
    sel.store.togglePage()
    assert.equal(sel.canMatchAll.value, true)
    await sel.selectAllMatching()
    assert.deepEqual(sel.store.keys, ['a1', 'a2', 'a3', 'a4'])
    assert.equal(sel.store.allMatching, true)
    assert.equal(sel.canMatchAll.value, false)
  })
})

describe('Select by title: the hub resolves, the WUI adds its answer', () => {
  it('sends the lines verbatim in one topic_select and adds exactly the answer\'s task ids, deduplicated', async () => {
    sel.store.toggle(pick('t2', 'beta', 'Ops'))
    /* the answer holds titles no JS reading of these lines would keep: only the hub decides */
    hub.answer = (f) => ({ type: 'topic_selected', req_id: f.req_id, ok: true, topics: [pick('t1', 'alpha', 'zzz'), pick('t2', 'beta', 'Ops'), pick('t1', 'alpha', 'zzz'), pick('t3', 'gamma', 'pre-release')] })
    /* no empty line inside: an empty JS RegExp matches every title, which would hide a JS reader */
    const text = '  ^rel  \n(?i)Ops\n*\n\n'
    const out = await sel.selectByTitle(text)
    assert.equal(hub.frames.length, 1)
    const f = hub.frames[0]
    assert.equal(f.action, 'multicast', 'no action registered yet: Multicast (7.1.6)')
    assert.deepEqual(f.task_ids, [])
    assert.deepEqual(f.patterns, ['  ^rel  ', '(?i)Ops', '*'], 'as typed; only the trailing empty lines go')
    assert.deepEqual(sel.store.keys, ['t2', 't1', 't3'])
    assert.equal(out.added, 2)
    assert.deepEqual(sel.store.picks.find((p) => p.task_id === 't3'), pick('t3', 'gamma', 'pre-release'))
  })
  it('the frame names the first registered action', async () => {
    sel.registerAction({ id: 'priority', icon: 'tag', labelKey: 'x', run: () => true })
    hub.answer = (f) => ({ req_id: f.req_id, ok: true, topics: [] })
    const out = await sel.selectByTitle('x')
    assert.equal(hub.frames[0].action, 'priority')
    assert.equal(out.none, true, '"No topic matches"')
  })
  it('a bad-pattern answer adds nothing and names the line', async () => {
    hub.answer = (f) => ({ req_id: f.req_id, ok: false, error: 'topic_select_bad_pattern', detail: 'line 2: ^(: missing closing )', topics: [pick('t9')] })
    const out = await sel.selectByTitle('ok\n^(')
    assert.equal(sel.store.count, 0)
    assert.deepEqual(out.bad, { line: '2', reason: '^(: missing closing )' })
    assert.match(read('src/components/TopicSelectPatterns.vue'), /t\('topic_select\.bad_pattern', \{ line: o\.bad\.line, reason: o\.bad\.reason \}\)/)
  })
  it('an answer to an older req_id is dropped', async () => {
    const held = []
    hub.answer = (f) => new Promise((resolve) => held.push(() => resolve({ req_id: f.req_id, ok: true, topics: [pick(f.patterns[0])] })))
    const first = sel.selectByTitle('old')
    const second = sel.selectByTitle('new')
    held[1]()
    held[0]()
    assert.equal(await first, null)
    assert.equal((await second).added, 1)
    assert.deepEqual(sel.store.keys, ['new'])
    assert.notEqual(hub.frames[0].req_id, hub.frames[1].req_id)
  })
  it('the mock hub resolves the frame in its own code (trim, *, case-insensitive, bad line)', () => {
    const state = { messages: [
      { msg_id: 'm1', task_id: 'r1', channel: 'alpha', body: 'Release 2.0', ts: '2026-11-01T00:00:01Z' },
      { msg_id: 'm2', task_id: 'r2', channel: 'beta', body: 'pre-release notes', ts: '2026-11-01T00:00:02Z' },
      { msg_id: 'm3', task_id: 'r3', channel: 'issues', body: 'release issue', ts: '2026-11-01T00:00:03Z' },
      { msg_id: 'm4', task_id: 'r4', channel: null, body: 'release dm', ts: '2026-11-01T00:00:04Z' },
    ] }
    const ids = (a) => a.topics.map((t) => t.task_id).sort()
    assert.deepEqual(ids(mockTopicSelect(state, { req_id: 'q', action: 'multicast', patterns: ['^rel'] })), ['r1'])
    assert.deepEqual(ids(mockTopicSelect(state, { req_id: 'q', action: 'multicast', patterns: [' * '] })), ['r1', 'r2'])
    const bad = mockTopicSelect(state, { req_id: 'q', action: 'multicast', patterns: ['ok', '^('] })
    assert.equal(bad.ok, false)
    assert.equal(bad.error, 'topic_select_bad_pattern')
    assert.match(bad.detail, /^line 2: \^\(: /)
  })
})

describe('where boxes show', () => {
  it('a channel topic card (the lobby and general too) may be ticked; a DM card, an issues card or a reply may not', () => {
    assert.equal(selectableCard({ task_id: 't', channel: 'alpha' }, true), true)
    assert.equal(selectableCard({ task_id: 't', channel: 'lobby' }, true), true)
    assert.equal(selectableCard({ task_id: 't', channel: 'general' }, true), true)
    assert.equal(selectableCard({ task_id: 't', channel: null }, true), false, 'a DM card')
    assert.equal(selectableCard({ task_id: 't', channel: 'issues' }, true), false, 'an issues card')
    assert.equal(selectableCard({ task_id: 't', channel: 'alpha', is_parent: 0 }, true), false, 'a reply')
    assert.equal(selectableCard({ task_id: 't', channel: 'alpha' }, false), false, 'a thread pane\'s card')
  })
  it('LiveFeed asks selectableCard per card; the card draws its box only then', () => {
    assert.match(template('src/components/LiveFeed.vue'), /:topic-select="selectableOf\(it\.msg\)"/)
    assert.match(read('src/components/LiveFeed.vue'), /return selectableCard\(m, Boolean\(props\.openButton\)\)/)
    assert.match(template('src/components/MessageCard.vue'), /v-if="topicSelect && \(!mobile \|\| sel\.selecting\.value\)"[\s\S]*?data-test="topic-select-box"/)
  })
  it('Monitoring -> Topics: only this workspace\'s rows carry a box, another\'s row says why', () => {
    const page = read('src/pages/monitoring/topics/index.vue')
    assert.match(page, /const ownRow = \(r: TopicRow\) => Boolean\(r\.topicId\) && String\(r\.workspace \|\| ''\) === pageTenant\.value/)
    assert.match(page, /const selectableRow = \(r: TopicRow\) => ownRow\(r\) && selectableCard\(/)
    assert.match(template('src/pages/monitoring/topics/index.vue'), /<input\s+v-if="selectableRow\(r\)"[\s\S]*?data-test="topic-select-box"/)
    assert.match(template('src/pages/monitoring/topics/index.vue'), /:title="otherWorkspace\(r\) \? t\('topic_select\.other_workspace'\) : undefined"/)
  })
})

describe('the bar and its actions', () => {
  it('lists the actions registered with it, in order; a finished action empties the selection', async () => {
    const seen = []
    sel.registerAction({ id: 'test-act', icon: 'tag', labelKey: 'topic_select.select', run: (s) => { seen.push(s.map((p) => p.task_id)); return true } })
    assert.deepEqual(sel.store.actions.map((a) => a.id), ['test-act'])
    assert.match(template('src/components/TopicSelectBar.vue'), /v-for="a in store\.actions"[\s\S]*?:data-test="'topic-select-act-' \+ a\.id"[\s\S]*?@click="runAction\(a\)"/)
    sel.store.toggle(A[0])
    await sel.runAction(sel.store.actions[0])
    assert.deepEqual(seen, [['a1']])
    assert.equal(sel.store.count, 0)
  })
  it('a cancelled action keeps the selection; runEach fills the result line, naming what failed', async () => {
    sel.store.toggle(A[0])
    sel.store.toggle(A[1])
    await sel.runAction({ id: 'c', icon: 'tag', labelKey: 'x', run: () => false })
    assert.equal(sel.store.count, 2)
    await sel.runEach(async (p) => { if (p.task_id === 'a2') throw new Error('no') })
    assert.deepEqual(sel.store.result, { done: 1, total: 2, failed: ['Topic a2'] })
  })
  it('the header gives its place to the bar on a channel or the lobby, never on a DM page', () => {
    const t = template('src/components/FeedHeader.vue')
    assert.match(t, /<LazyTopicSelectBar v-if="selectOn && topicSelect\.active" :phone="phone" \/>\s*<header v-else class="feed-header feed-header--pane"/)
    assert.match(read('src/components/FeedHeader.vue'), /const selectOn = computed\(\(\) => \/\\\/\(\?:channel\\\/\[\^\/\]\+\|lobby\)\\\/\?\$\/\.test\(route\.path\)\)/)
  })
})

describe('the card menu and the gestures while selecting (4.6, H4)', () => {
  it('"Select" heads the desktop menu and follows Archive on the phone sheet', () => {
    const menu = read('src/components/MessageMenu.vue')
    assert.match(menu, /if \(!sheet\.value\) return \[SELECT_ITEM, \.\.\.list\]/)
    assert.match(menu, /list\.findIndex\(\(it\) => it\.id === 'archive'\)/)
    assert.match(menu, /else if \(id === 'topic-select'\) emit\('topic-select'\)/)
    assert.match(template('src/components/MessageCard.vue'), /@topic-select="sel\.toggle\(null, true\)"/)
  })
  it('the swipes and the move handle rest while the selection is not empty', () => {
    const card = read('src/components/MessageCard.vue')
    assert.match(card, /if \(swipeOn\.value && !removing\.value && !sel\.selecting\.value\) swipe\.down\(ev\)/)
    assert.match(template('src/components/MessageCard.vue'), /v-if="movable && !sel\.selecting\.value"\s+class="msg-move-handle"/)
    assert.match(card, /function onCardClick\(ev: MouseEvent\) \{\s+if \(!sel\.onTap\(ev\)\) onClick\(ev\)/)
  })
})

describe('Select by title shows only where topic_select can be sent (R7 W1)', () => {
  it('a live client offers it only once the socket request half is set; the mock always', () => {
    const live = createSpoolClient({ fetchFn: async () => { throw new Error('no fetch') }, mock: false })
    assert.equal(live.canTopicSelect(), false)
    live.setRequester(async () => ({ ok: true, topics: [] }))
    assert.equal(live.canTopicSelect(), true)
    live.setRequester(null)
    assert.equal(live.canTopicSelect(), false)
    assert.equal(createSpoolClient({ mock: true }).canTopicSelect(), true)
  })
  it('the title field is gated on it, on a channel page only (SPL-6613)', () => {
    const choice = read('src/composables/useTopicListChoice.ts')
    assert.match(choice, /const titleOn = computed\(\(\) => canTopicSelect && \/\\\/channel\\\/\[\^\/\]\+\\\/\?\$\/\.test\(route\.path\)\)/)
    assert.match(choice, /const titleIds = computed\(\(\) => \(titleOn\.value \? topicSelect\.titleIds : null\)\)/, 'a DM or the lobby is never narrowed')
    assert.match(template('src/components/TopicListControl.vue'), /<div v-if="g\.id === 'filter' && titleOn" class="tl-ctl__title">/)
    assert.equal(sel.byTitleOn, false, 'the stub api has no canTopicSelect: nothing offered')
  })
})

// SPL-6613 (owner HUM-10, t1 f7b53cf8, msg 5b8f9db2: "make the search by
// title part of the filter and the select the one which actually selects
// either all , but the already listed / filtered"). Red on origin/master
// a464b5399: filterByTitle, store.titleMatch and matchTotal do not exist,
// the header and the bar still carry Select by title.
describe('SPL-6613 the title search is a filter; the tick selects the topics listed', () => {
  it('the title field sends one topic_select as typed; its answer narrows the list, never the selection', async () => {
    hub.answer = (f) => ({ req_id: f.req_id, ok: true, topics: [pick('a2', 'alpha', 'zzz'), pick('b1', 'beta', 'yyy'), pick('a2', 'alpha', 'zzz')] })
    const out = await sel.filterByTitle('  ^rel ')
    assert.equal(hub.frames.length, 1)
    assert.deepEqual(hub.frames[0].patterns, ['  ^rel '], 'as typed: the hub trims and matches (4.2)')
    assert.deepEqual(hub.frames[0].task_ids, [])
    assert.equal(sel.store.count, 0, 'nothing selected')
    assert.deepEqual([...sel.store.titleIds], ['a2', 'b1'])
    assert.equal(out.added, 2)
  })
  it('an empty field ends the filter without a frame; a bad pattern ends it and names the line', async () => {
    hub.answer = (f) => ({ req_id: f.req_id, ok: true, topics: [pick('a1')] })
    await sel.filterByTitle('x')
    assert.ok(sel.store.titleIds)
    assert.equal(await sel.filterByTitle('   '), null)
    assert.equal(sel.store.titleIds, null)
    assert.equal(hub.frames.length, 1)
    hub.answer = (f) => ({ req_id: f.req_id, ok: false, error: 'topic_select_bad_pattern', detail: 'line 1: ^(: missing closing )', topics: [] })
    const out = await sel.filterByTitle('^(')
    assert.equal(sel.store.titleIds, null)
    assert.deepEqual(out.bad, { line: '1', reason: '^(: missing closing )' })
  })
  it('an answer to an older title frame is dropped', async () => {
    const held = []
    hub.answer = (f) => new Promise((resolve) => held.push(() => resolve({ req_id: f.req_id, ok: true, topics: [pick(f.patterns[0])] })))
    const first = sel.filterByTitle('old')
    const second = sel.filterByTitle('new')
    held[1]()
    held[0]()
    assert.equal(await first, null)
    await second
    assert.deepEqual([...sel.store.titleIds], ['new'])
  })
  it('the tick selects exactly the topics listed: all unfiltered, only the filtered ones under the filter', async () => {
    sel.store.setShown(A)
    sel.store.togglePage()
    assert.deepEqual(sel.store.keys, ['a1', 'a2', 'a3', 'a4'], 'no filter: every topic listed')
    sel.store.clear()
    hub.answer = (f) => ({ req_id: f.req_id, ok: true, topics: [A[1], A[3], B[0]] })
    await sel.filterByTitle('2|4')
    /* the feed lists what the filter keeps (MessageFeed -> topicListView only) and LiveFeed hands it to setShown */
    sel.store.setShown(A.filter((p) => sel.store.titleIds.has(p.task_id)))
    sel.store.togglePage()
    assert.deepEqual(sel.store.keys, ['a2', 'a4'], 'filtered: only the listed ones')
    assert.equal(sel.canMatchAll.value, false, 'every match of this channel is listed and ticked')
  })
  it('"Select all N matching" under a title filter adds the hub\'s matches in this channel, N exact, no paging', async () => {
    let loads = 0
    sel.store.matcher = { more: () => true, load: async () => { loads++ } }
    hub.answer = (f) => ({ req_id: f.req_id, ok: true, topics: [A[0], A[1], A[2], B[0]] })
    await sel.filterByTitle('a')
    sel.store.setShown([A[0], A[1]])
    sel.store.togglePage()
    assert.equal(sel.canMatchAll.value, true)
    assert.equal(sel.matchTotal.value, '3', 'the 3 matches in alpha, not beta\'s')
    await sel.selectAllMatching()
    assert.deepEqual(sel.store.keys, ['a1', 'a2', 'a3'])
    assert.equal(loads, 0)
    assert.equal(sel.store.allMatching, true)
  })
  it('the header and the bar carry no Select by title; the header\'s tick ticks the listed topics', () => {
    const head = template('src/components/FeedHeader.vue')
    assert.doesNotMatch(head, /topic-select-by-title|TopicSelectPatterns/)
    assert.match(head, /data-test="topic-select-listed"/)
    assert.match(head, /@click\.prevent="topicSelect\.togglePage\(\)"/)
    const bar = template('src/components/TopicSelectBar.vue')
    assert.doesNotMatch(bar, /topic-select-by-title|TopicSelectPatterns/)
    assert.match(bar, /t\('topic_select\.select_matching', \{ total: matchTotal \}\)/)
    assert.match(bar, /<span v-if="channelPage" class="topic-select__list"><LazyTopicListControl \/><\/span>/, 'the filter stays usable while topics are ticked (holder GO dc0fa0cb)')
    assert.match(read('src/components/MessageFeed.vue'), /only: choice\.titleIds\.value,/)
  })
})
