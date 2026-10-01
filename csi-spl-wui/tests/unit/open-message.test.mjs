// CLE-77882: open any message in its original place (utils/open-message.mjs).
// The place rule itself is openParentSection's (tests/unit/parent-section);
// these pin what this lane adds: the deep link, resolving a bare id, the
// failure reasons, and the mark.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  OPEN_FOCUS_CLASSES, failureReason, isMessageId, markOpened, messageHref, openMessage, placeKind, resolveMessage, rowReason,
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

test('markOpened: every copy on screen gets open-focus + search-focus, cleared after the hold', async () => {
  globalThis.CSS = globalThis.CSS || { escape: (s) => s }
  const mk = () => {
    const set = new Set()
    return { set, classList: { add: (c) => set.add(c), remove: (c) => set.delete(c) } }
  }
  const els = [mk(), mk()]
  const doc = { querySelectorAll: (sel) => (sel.includes(MSG) ? els : []) }
  markOpened(MSG, { doc, hold: 20 })
  for (const el of els) assert.deepEqual([...el.set].sort(), [...OPEN_FOCUS_CLASSES].sort())
  await new Promise((r) => setTimeout(r, 40))
  for (const el of els) assert.equal(el.set.size, 0)
})

test('markOpened: a copy that renders during the hold (the phone thread pane) is marked too', async () => {
  globalThis.CSS = globalThis.CSS || { escape: (s) => s }
  const mk = () => {
    const set = new Set()
    return { set, classList: { add: (c) => set.add(c), remove: (c) => set.delete(c) } }
  }
  const early = mk()
  const late = mk()
  const els = [early]
  const doc = { querySelectorAll: () => els }
  markOpened(MSG, { doc, hold: 60, every: 5 })
  await new Promise((r) => setTimeout(r, 15))
  els.push(late)
  await new Promise((r) => setTimeout(r, 15))
  assert.equal(late.set.has('open-focus'), true)
  await new Promise((r) => setTimeout(r, 80))
  assert.equal(early.set.size + late.set.size, 0)
})
