// CLE-77882: open any message in its original place (utils/open-message.mjs).
// The place rule itself is openParentSection's (tests/unit/parent-section);
// these pin what this lane adds: the deep link, resolving a bare id, the
// failure reasons, and the mark.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  OPEN_FOCUS_CLASSES, failureReason, isMessageId, markOpened, messageHref, openMessage, placeKind, placeOf, resolveMessage, rowReason,
} from '../../src/utils/open-message.mjs'

const MSG = '33333333-3333-4333-8333-333333333333'
const TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const ROOT = '22222222-2222-4222-8222-222222222222'
const http = (status) => Object.assign(new Error('x'), { status })

function fakeApi({ info, infoErr, rows = [], topicErr, size } = {}) {
  const calls = []
  return {
    calls,
    async moveInfo(id) { calls.push(['moveInfo', id]); if (infoErr) throw infoErr; return info },
    async getTopic(id, o) { calls.push(['getTopic', id, o]); if (topicErr) throw topicErr; return { messages: rows } },
    async topicSize(id) { calls.push(['topicSize', id]); if (!size) throw http(409); return size },
  }
}

function fakeRouter() {
  const log = []
  return { log, push: async (to) => { log.push(['push', to]) }, replace: async (to) => { log.push(['replace', to]) } }
}

test('messageHref: /m/<id>, through the locale path', () => {
  assert.equal(messageHref(MSG), '/m/' + MSG)
  assert.equal(messageHref(MSG, (p) => '/bg' + p), '/bg/m/' + MSG)
  assert.equal(messageHref(''), '')
})

test('isMessageId: a lower-case uuid only', () => {
  assert.equal(isMessageId(MSG), true)
  assert.equal(isMessageId(TASK.toUpperCase()), false)
  assert.equal(isMessageId('nope'), false)
  assert.equal(isMessageId(undefined), false)
})

test('failureReason: 404 (gone or not yours, the hub never says which) is not_found; 403 is no_access', () => {
  assert.equal(failureReason(http(404)), 'not_found')
  assert.equal(failureReason(http(410)), 'not_found')
  assert.equal(failureReason(http(403)), 'no_access')
  assert.equal(failureReason(http(500)), 'error')
  assert.equal(failureReason(new Error('offline')), 'error')
})

test('rowReason: a tombstone is deleted, an archived card archived, a plain row nothing', () => {
  assert.equal(rowReason({ msg_id: MSG, deleted: true }), 'deleted')
  assert.equal(rowReason({ msg_id: MSG, deleted_at: '2026-10-01T00:00:00Z' }), 'deleted')
  assert.equal(rowReason({ msg_id: MSG, archived_at: '2026-10-01T00:00:00Z' }), 'archived')
  assert.equal(rowReason({ msg_id: MSG }), '')
  assert.equal(rowReason(null), '')
})

test('placeKind: channel, DM, Issues tab; a row naming no place opens its topic page', () => {
  assert.equal(placeKind({ channel: 'lobby', task_id: TASK, msg_id: MSG }), 'channel')
  assert.equal(placeKind({ channel: null, task_id: TASK, msg_id: MSG, from: 'HUM-1', to: 'CLE-7' }, 'HUM-1'), 'dm')
  assert.equal(placeKind({ channel: 'issues', task_id: TASK }), 'issue')
  assert.equal(placeKind({ channel: null, task_id: TASK, from: 'HUM-1' }, 'HUM-1'), 'topic')
})

test('resolveMessage: a bare id becomes its full row (task from moveInfo, row from the topic)', async () => {
  const reply = { msg_id: MSG, task_id: TASK, channel: 'lobby', from: 'HUM-1' }
  const api = fakeApi({ info: { msg_id: MSG, task_id: TASK, channel: 'lobby' }, rows: [{ msg_id: ROOT, task_id: TASK }, reply] })
  const got = await resolveMessage(MSG, api)
  assert.deepEqual(got, { row: reply })
  assert.deepEqual(api.calls.map((c) => c[0]), ['moveInfo', 'getTopic', 'topicSize'])
  assert.equal(api.calls[1][1], TASK)
})

test('resolveMessage: a message past the first read still opens on its task and channel', async () => {
  const api = fakeApi({ info: { msg_id: MSG, task_id: TASK, channel: 'ops' }, rows: [] })
  assert.deepEqual(await resolveMessage(MSG, api), { row: { msg_id: MSG, task_id: TASK, channel: 'ops' } })
})

/* CLE-77909 (lane D red, dev): a cold /m/<id> to a reply in a 676-row DM
   (row 661) opened the Topics view - the oldest 200 rows held no row, and
   the stand-in had no DM ends, so no peer. */
function longDmApi({ newest = [] } = {}) {
  const old = Array.from({ length: 200 }, (_, i) => ({ msg_id: `0000${String(i).padStart(4, '0')}-0000-4000-8000-000000000000`, task_id: TASK, channel: null, from: 'CLE-1', to: 'HUM-4' }))
  const calls = []
  return {
    calls,
    async moveInfo(id) { calls.push(['moveInfo', id]); return { msg_id: id, task_id: TASK, channel: null } },
    async getTopic(id, o) { calls.push(['getTopic', id, o]); return o && o.order === 'desc' ? { messages: newest, next: null } : { messages: old, next: old[199].msg_id } },
    async topicSize() { throw http(409) },
  }
}

test('resolveMessage: a DM reply past the oldest page is found on the newest page', async () => {
  const reply = { msg_id: MSG, task_id: TASK, channel: null, from: 'CLE-1', to: 'HUM-4' }
  const api = longDmApi({ newest: [reply] })
  assert.deepEqual(await resolveMessage(MSG, api), { row: reply })
  assert.deepEqual(api.calls.filter((c) => c[0] === 'getTopic').map((c) => c[2].order || 'asc'), ['asc', 'desc'])
  assert.equal(placeKind(reply, 'HUM-4'), 'dm')
})

test('resolveMessage: a DM row on neither page keeps the DM ends of its topic, so it opens the DM', async () => {
  const got = await resolveMessage(MSG, longDmApi())
  assert.deepEqual(got, { row: { msg_id: MSG, task_id: TASK, channel: null, from: 'CLE-1', to: 'HUM-4' } })
  assert.equal(placeKind(got.row, 'HUM-4'), 'dm')
})

test('resolveMessage: a short topic is read once', async () => {
  const api = fakeApi({ info: { msg_id: MSG, task_id: TASK, channel: null }, rows: [{ msg_id: ROOT, task_id: TASK, channel: null, from: 'CLE-1', to: 'HUM-4' }] })
  const got = await resolveMessage(MSG, api)
  assert.equal(api.calls.filter((c) => c[0] === 'getTopic').length, 1)
  assert.equal(placeKind(got.row, 'HUM-4'), 'dm')
})

test('resolveMessage: a DM thread reply whose thread read is empty takes the DM ends of the parent topic', async () => {
  const calls = []
  const api = {
    async moveInfo(id) { return { msg_id: id, task_id: ROOT, channel: null, parent_task_id: TASK } },
    async getTopic(id, o) { calls.push([id, o]); return { messages: id === TASK ? [{ msg_id: ROOT, task_id: TASK, channel: null, from: 'HUM-1', to: 'GRK-03', to_box: 'box-a' }] : [] } },
    async topicSize() { throw http(409) },
  }
  const got = await resolveMessage(MSG, api)
  assert.deepEqual(got, { row: { msg_id: MSG, task_id: ROOT, channel: null, from: 'HUM-1', to: 'GRK-03', to_box: 'box-a', parent_task_id: TASK } })
  assert.deepEqual(calls.map((c) => c[0]), [ROOT, TASK])
  assert.equal(placeKind(got.row, 'HUM-1'), 'dm')
})

test('placeOf: the channel wins; a DM takes the ends of the topic row; nothing known is a bare row', () => {
  assert.deepEqual(placeOf({ channel: 'lobby', from: 'X' }, { channel: null }), { channel: 'lobby' })
  assert.deepEqual(placeOf({ from: 'X' }, { channel: 'ops' }), { channel: 'ops' })
  assert.deepEqual(placeOf({ channel: null, from: 'CLE-1', from_box: 'b1', to: 'HUM-4' }, {}), { channel: null, from: 'CLE-1', from_box: 'b1', to: 'HUM-4' })
  assert.deepEqual(placeOf(undefined, undefined), { channel: null })
})

test('openMessage: a cold id of a DM reply past the oldest page opens the DM (kind dm), never its topic page', async () => {
  const router = fakeRouter()
  const sections = []
  const out = await openMessage(MSG, {
    self: 'HUM-4', api: longDmApi(), router, localePath: (p) => p, mark: () => {},
    openSection: async (row) => { sections.push(row); return true },
  })
  assert.deepEqual(out, { ok: true, kind: 'dm', msgId: MSG })
  assert.equal(sections[0].to, 'HUM-4')
  assert.equal(router.log.length, 0)
})

test('resolveMessage: unknown / deleted / not yours -> not_found; no topics.read -> no_access', async () => {
  assert.deepEqual(await resolveMessage(MSG, fakeApi({ infoErr: http(404) })), { reason: 'not_found' })
  assert.deepEqual(await resolveMessage(MSG, fakeApi({ infoErr: http(403) })), { reason: 'no_access' })
  assert.deepEqual(await resolveMessage('not-a-uuid', fakeApi({})), { reason: 'not_found' })
})

test('resolveMessage: a message in an archived topic -> archived', async () => {
  const api = fakeApi({ info: { task_id: TASK, channel: 'lobby' }, rows: [{ msg_id: ROOT, task_id: TASK }, { msg_id: MSG, task_id: TASK }], size: { archived: true } })
  assert.deepEqual(await resolveMessage(MSG, api), { reason: 'archived' })
})

test('openMessage with the row: no hub lookup, the place opened, the message marked', async () => {
  const api = fakeApi({})
  const router = fakeRouter()
  const seen = []
  const marked = []
  const row = { msg_id: MSG, task_id: TASK, channel: 'lobby', from: 'HUM-1' }
  const out = await openMessage(row, {
    self: 'HUM-1', api, router, localePath: (p) => p,
    openSection: async (msg, deps) => { seen.push([msg, deps.self]); return true },
    mark: (id) => marked.push(id),
  })
  assert.deepEqual(out, { ok: true, kind: 'channel', msgId: MSG })
  assert.equal(api.calls.length, 0)
  assert.deepEqual(seen, [[row, 'HUM-1']])
  assert.deepEqual(marked, [MSG])
})

test('openMessage with a bare id: resolves first, then opens', async () => {
  const reply = { msg_id: MSG, task_id: TASK, channel: 'lobby' }
  const api = fakeApi({ info: { task_id: TASK, channel: 'lobby' }, rows: [reply] })
  let opened = null
  const out = await openMessage(MSG, {
    self: '', api, router: fakeRouter(), localePath: (p) => p,
    openSection: async (msg) => { opened = msg; return true }, mark: () => {},
  })
  assert.equal(out.ok, true)
  assert.deepEqual(opened, reply)
})

test('openMessage replace: the deep link page replaces itself, it is not left in history', async () => {
  const router = fakeRouter()
  await openMessage({ msg_id: MSG, task_id: TASK, channel: 'lobby' }, {
    self: '', api: fakeApi({}), router, localePath: (p) => p, replace: true,
    openSection: async (msg, deps) => { await deps.router.push({ path: '/channel/lobby' }); return true }, mark: () => {},
  })
  assert.deepEqual(router.log, [['replace', { path: '/channel/lobby' }]])
})

test('openMessage: a row that names no place opens its topic page at the message', async () => {
  const router = fakeRouter()
  const out = await openMessage({ msg_id: MSG, task_id: TASK, channel: null, from: 'HUM-1' }, {
    self: 'HUM-1', api: fakeApi({}), router, localePath: (p) => '/bg' + p,
    openSection: async () => false, mark: () => {},
  })
  assert.deepEqual(out, { ok: true, kind: 'topic', msgId: MSG })
  assert.deepEqual(router.log, [['push', { path: '/bg/t/' + TASK, hash: '#' + MSG }]])
})

test('openMessage failures navigate nowhere and say why', async () => {
  const router = fakeRouter()
  const deps = { self: '', router, localePath: (p) => p, openSection: async () => { throw new Error('must not open') }, mark: () => { throw new Error('must not mark') } }
  assert.deepEqual(await openMessage(MSG, { ...deps, api: fakeApi({ infoErr: http(404) }) }), { ok: false, reason: 'not_found', msgId: MSG })
  assert.deepEqual(await openMessage(MSG, { ...deps, api: fakeApi({ infoErr: http(403) }) }), { ok: false, reason: 'no_access', msgId: MSG })
  assert.deepEqual(await openMessage({ msg_id: MSG, task_id: TASK, deleted: true }, { ...deps, api: fakeApi({}) }), { ok: false, reason: 'deleted', msgId: MSG })
  assert.deepEqual(await openMessage('', { ...deps, api: fakeApi({}) }), { ok: false, reason: 'not_found', msgId: '' })
  assert.deepEqual(router.log, [])
})

/* A manual clock + timer for markOpened: `advance(ms)` moves the clock and
   fires each timer that falls due, in order, so the hold is measured without
   sleeping in real time. */
function manualTime() {
  let t = 0
  let timers = []
  return {
    now: () => t,
    setTimer: (fn, ms) => { timers.push({ at: t + ms, fn }) },
    pending: () => timers.length,
    advance(ms) {
      const end = t + ms
      for (;;) {
        timers.sort((a, b) => a.at - b.at)
        const next = timers[0]
        if (!next || next.at > end) break
        timers = timers.slice(1)
        t = next.at
        next.fn()
      }
      t = end
    },
  }
}

test('markOpened: every copy on screen gets open-focus + search-focus, cleared after the hold', () => {
  globalThis.CSS = globalThis.CSS || { escape: (s) => s }
  const mk = () => {
    const set = new Set()
    return { set, classList: { add: (c) => set.add(c), remove: (c) => set.delete(c) } }
  }
  const els = [mk(), mk()]
  const doc = { querySelectorAll: (sel) => (sel.includes(MSG) ? els : []) }
  const time = manualTime()
  markOpened(MSG, { doc, hold: 20, now: time.now, setTimer: time.setTimer })
  for (const el of els) assert.deepEqual([...el.set].sort(), [...OPEN_FOCUS_CLASSES].sort())
  time.advance(19)
  for (const el of els) assert.equal(el.set.size, 2, 'still marked inside the hold')
  time.advance(1)
  for (const el of els) assert.equal(el.set.size, 0)
  assert.equal(time.pending(), 0, 'the timer chain stopped itself after the hold')
})

test('markOpened: a copy that renders during the hold (the phone thread pane) is marked too', () => {
  globalThis.CSS = globalThis.CSS || { escape: (s) => s }
  const mk = () => {
    const set = new Set()
    return { set, classList: { add: (c) => set.add(c), remove: (c) => set.delete(c) } }
  }
  const early = mk()
  const late = mk()
  const els = [early]
  const doc = { querySelectorAll: () => els }
  const time = manualTime()
  markOpened(MSG, { doc, hold: 60, every: 5, now: time.now, setTimer: time.setTimer })
  time.advance(15)
  els.push(late)
  time.advance(15)
  assert.equal(late.set.has('open-focus'), true)
  time.advance(30)
  assert.equal(early.set.size + late.set.size, 0)
  assert.equal(time.pending(), 0)
})

test('markOpened: a hidden copy is never marked; the visible one is, when it shows (phone root)', () => {
  globalThis.CSS = globalThis.CSS || { escape: (s) => s }
  const mk = (w) => {
    const set = new Set()
    return { set, rect: { width: w, height: w }, getBoundingClientRect() { return this.rect }, classList: { add: (c) => set.add(c), remove: (c) => set.delete(c) } }
  }
  const hidden = mk(0)
  const shown = mk(10)
  const els = [hidden]
  const time = manualTime()
  markOpened(MSG, { doc: { querySelectorAll: () => els }, hold: 30, every: 5, now: time.now, setTimer: time.setTimer })
  time.advance(60)
  assert.equal(hidden.set.size, 0, 'the hidden middle card is not marked')
  els.push(shown)
  time.advance(15)
  assert.equal(shown.set.has('open-focus'), true)
  assert.equal(hidden.set.size, 0)
  time.advance(60)
  assert.equal(shown.set.size, 0, 'cleared after the hold')
  assert.equal(time.pending(), 0)
})

/* CLE-77909 (live dev): the DM opened, but the reply sat ~37 rows deep in a
   700-row topic and the pane reads the newest 30 - nothing to mark. The pane
   pages back toward a #<msg_id> hash, bounded. */
test('TopicPane: a #<msg_id> older than the first page is paged to (at most HASH_PAGES), live only', async () => {
  const { readFileSync } = await import('node:fs')
  const src = readFileSync(new URL('../../src/components/TopicPane.vue', import.meta.url), 'utf8')
  const fn = src.slice(src.indexOf('async function reachHash'), src.indexOf("watch(() => route.hash"))
  assert.match(src, /const HASH_PAGES = 10\n/)
  assert.match(fn, /if \(api\.mock \|\| !id \|\| !want\) return/)
  assert.match(fn, /i < HASH_PAGES && olderCursor\.value && topic\.parentTaskId === id/)
  assert.match(fn, /liveRows\.value\.some\(\(r\) => String\(r\.msg_id\) === want\)\) return/)
  assert.match(fn, /await loadOlder\(\)/)
  /* declared before the immediate topic watch that calls it (no TDZ), and called after the first page */
  assert.ok(src.indexOf('async function reachHash') < src.indexOf('watch(() => [topic.open, topic.parentTaskId]'))
  const first = src.slice(src.indexOf('watch(() => [topic.open, topic.parentTaskId]'), src.indexOf('async function loadOlder'))
  assert.match(first, /loading\.value = false\n  \}\n  void reachHash\(\)\n\}, \{ immediate: true \}\)/)
})
