// Spec 186 row M11 (owner HUM-10, t1 032d8010, msgs 5fdfff6c and 4b3833e7):
// the Multicast action. Two layers run for real:
// - the channel store (stores/channel.ts): sendMulticast is one sendLive per
//   target over a fake live socket that a test can drop, with the real
//   offline queue, so a resend after the reconnect is the store's own;
// - the flow (composables/useMulticastSend.ts) on the mock client
//   (spool-client.mjs mock + spool-client-mock.mjs), whose sends are recorded.
// The dialog is checked on its source (the suite has no DOM).
//
// Run: node --test tests/unit/multicast-send.test.mjs
import { beforeEach, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { computed, nextTick, ref, shallowRef } from 'vue'
import { createPinia, defineStore, setActivePinia } from 'pinia'
import { importTsStubbed } from './lib/load-ts-stubbed.mjs'
import { mockMulticastCheck } from '../../src/utils/spool-client-mock.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const tick = () => new Promise((r) => setTimeout(r, 0))

/* ---- the fake live socket: a hub that stores each msg_id once and acks it; `drop` closes it after N acks ---- */
const hub = { rows: [], frames: [], dropAfter: Infinity, refuse: new Map() }
const reconnected = []
const sock = {
  state: 'open',
  async send(frame) {
    hub.frames.push(structuredClone(frame))
    if (hub.rows.length >= hub.dropAfter) {
      sock.state = 'reconnecting'
      throw Object.assign(new Error('socket closed'), { token: 'closed' })
    }
    const why = hub.refuse.get(frame.task_id)
    if (why) throw Object.assign(new Error(why), { token: why, status: 404 })
    if (!hub.rows.some((r) => r.msg_id === frame.msg_id)) hub.rows.push({ ...frame })
    return { type: 'ack', msg_id: frame.msg_id, task_id: frame.task_id, received_at: new Date().toISOString() }
  },
}
const liveApi = { mock: false, configError: '' }
Object.assign(globalThis, { ref, computed, shallowRef, useNuxtApp: () => ({ $i18n: { t: (k) => k } }) })
globalThis.window ??= { addEventListener() {} }
const channelMod = await importTsStubbed('src/stores/channel.ts', {
  pinia: { defineStore },
  '~/composables/useSpoolApi': { useSpoolApi: () => liveApi },
  '~/composables/useLive': {
    useLive: () => ({ ensure: () => sock, identity: { value: 'HUM-1' }, state: { get value() { return sock.state } }, onReconnected: (fn) => reconnected.push(fn) }),
  },
  '~/composables/useMentionPoke': { useMentionPoke: () => ({ poke: async () => {} }) },
  '~/stores/notification': { useNotificationStore: () => ({ markTopicRead() {} }) },
  '~/composables/useFreshTopics': { useFreshTopics: () => ({ note() {} }) },
}, { client: true })

const T5 = ['t1', 't2', 't3', 't4', 't5'].map((id, i) => ({ task_id: id, channel: i < 3 ? 'alpha' : 'beta', msg_id: 'm-' + id }))

describe('stores/channel.ts sendMulticast: one sendLive per target', () => {
  let store
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.assign(hub, { rows: [], frames: [], dropAfter: Infinity, refuse: new Map() })
    sock.state = 'open'
    reconnected.length = 0
    store = channelMod.useChannelStore()
  })

  it('N frames: each its own msg_id, one mc_id, the check\'s task ids, a reply (is_parent 0) in its channel', async () => {
    const out = {}
    await store.sendMulticast({ text: 'hello all', files: [], mcId: 'mc-1', copies: T5, onResult: (id, r) => { out[id] = r.state } })
    assert.equal(hub.rows.length, 5)
    assert.deepEqual(hub.rows.map((r) => r.task_id).sort(), ['t1', 't2', 't3', 't4', 't5'])
    assert.deepEqual(new Set(hub.rows.map((r) => r.mc_id)), new Set(['mc-1']))
    assert.deepEqual(hub.rows.map((r) => r.msg_id).sort(), T5.map((c) => c.msg_id).sort())
    assert.ok(hub.rows.every((r) => r.is_parent === 0 && r.body === 'hello all'))
    assert.equal(hub.rows.find((r) => r.task_id === 't4').channel, 'beta')
    assert.deepEqual(Object.values(out), ['sent', 'sent', 'sent', 'sent', 'sent'])
  })

  it('the socket drops after 2 of 5 acks: 2 sent, 3 wait; the reconnect sends the 3 under their own msg_ids (5 stored, not 7)', async () => {
    hub.dropAfter = 2
    const out = {}
    await store.sendMulticast({ text: 'hello all', files: [], mcId: 'mc-2', copies: T5, onResult: (id, r) => { out[id] = r.state } })
    assert.equal(hub.rows.length, 2)
    assert.equal(Object.values(out).filter((s) => s === 'sent').length, 2)
    assert.equal(Object.values(out).filter((s) => s === 'waiting').length, 3)
    hub.dropAfter = Infinity
    sock.state = 'open'
    for (const fn of reconnected) fn()
    for (let i = 0; i < 20 && hub.rows.length < 5; i++) await tick()
    await tick()
    assert.equal(hub.rows.length, 5, 'a fresh msg_id on the resend would store 7 rows')
    assert.deepEqual(hub.rows.map((r) => r.msg_id).sort(), T5.map((c) => c.msg_id).sort())
    assert.deepEqual(new Set(hub.rows.map((r) => r.mc_id)), new Set(['mc-2']))
    assert.deepEqual(Object.values(out), ['sent', 'sent', 'sent', 'sent', 'sent'], 'the held copies report sent when they land')
  })

  it('a send-time refusal is that copy\'s alone; the others store', async () => {
    hub.refuse.set('t3', 'topic_archived')
    const out = {}
    await store.sendMulticast({ text: 'x', files: [], mcId: 'mc-3', copies: T5, onResult: (id, r) => { out[id] = r } })
    assert.equal(hub.rows.length, 4)
    assert.deepEqual(out['m-t3'], { state: 'refused', error: 'topic_archived' })
  })

  it('at most 4 copies in flight', async () => {
    let inFlight = 0
    let most = 0
    const send = sock.send
    sock.send = async (f) => { inFlight++; most = Math.max(most, inFlight); await tick(); inFlight--; return send(f) }
    try {
      const copies = Array.from({ length: 9 }, (_, i) => ({ task_id: 'k' + i, channel: 'alpha', msg_id: 'mk' + i }))
      await store.sendMulticast({ text: 'x', files: [], mcId: 'mc-4', copies, onResult() {} })
      assert.equal(hub.rows.length, 9)
      assert.equal(most, 4)
    } finally { sock.send = send }
  })

  it('the page\'s own send is not changed: no mc_id, a fresh msg_id', async () => {
    await store.send('page post', 't1', [], 'alpha', 0)
    const f = hub.frames.at(-1)
    assert.equal(f.mc_id, undefined)
    assert.ok(f.msg_id && !f.msg_id.startsWith('m-'))
  })
})

/* ---- the flow on the mock client ---- */
function mockClient() {
  const api = createSpoolClient({ mock: true })
  return api
}

const sel = [
  { task_id: 'a', channel: 'alpha', title: 'Topic A' },
  { task_id: 'b', channel: 'alpha', title: 'Topic B' },
  { task_id: 'c', channel: 'beta', title: 'Topic C' },
]
const mcMod = await importTsStubbed('src/composables/useMulticastSend.ts', {
  '~/stores/channel': { useChannelStore: () => { throw new Error('the tests inject the store') } },
  '~/composables/useSpoolApi': { useSpoolApi: () => ({}) },
  '~/composables/useTopicSelect': { useTopicSelect: () => ({ registerAction() {} }) },
})

describe('useMulticastSend: the dialog\'s check, send and results', () => {
  let checks, sends, uploads, mc, answer, pageSends
  const state = { messages: [
    { msg_id: 'r1', task_id: 'a', channel: 'alpha', body: 'Topic A', ts: '2026-11-01T00:00:01Z', kind: 'note', from: 'HUM-1' },
    { msg_id: 'r2', task_id: 'b', channel: 'alpha', body: 'Topic B', ts: '2026-11-01T00:00:02Z', kind: 'note', from: 'HUM-1' },
    { msg_id: 'r3', task_id: 'c', channel: 'beta', body: 'Topic C', ts: '2026-11-01T00:00:03Z', kind: 'note', from: 'HUM-1' },
    { msg_id: 'r4', task_id: 'dm', channel: null, body: 'a DM', ts: '2026-11-01T00:00:04Z', kind: 'note', from: 'HUM-1', to: 'HUM-2' },
  ] }
  let n = 0
  beforeEach(() => {
    checks = []
    sends = []
    uploads = []
    pageSends = []
    answer = (f, refuse) => mockMulticastCheck(state, f, refuse)
    let refuse = {}
    const api = {
      setRefuse(r) { refuse = r },
      multicastCheck: async (f) => { checks.push(structuredClone(f)); return answer(f, refuse) },
    }
    const store = {
      uploadFiles: async (files) => { uploads.push(files); return (files || []).map((f) => ({ mode: 'blob', file_id: 'sha-' + f.name, name: f.name })) },
      sendMulticast: async (a) => {
        sends.push({ ...a, copies: a.copies.map((c) => ({ ...c })) })
        for (const c of a.copies) a.onResult(c.msg_id, store.outcome(c))
      },
      outcome: () => ({ state: 'sent' }),
      send: async (...args) => { pageSends.push(args) },
    }
    mc = mcMod.createMulticast({ api, store, debounceMs: 0, newId: () => 'id-' + (++n) })
    mc.api = api
    mc.store = store
  })

  it('opens with a check naming exactly the selection\'s task ids, no pattern; Send waits for every ok', async () => {
    const closed = mc.start(sel)
    assert.equal(mc.open.value, true)
    assert.equal(mc.canSend.value, false, 'no verdict yet')
    await tick()
    assert.equal(checks.length, 1)
    assert.deepEqual(checks[0].task_ids, ['a', 'b', 'c'])
    assert.equal('patterns' in checks[0], false)
    assert.equal(mc.canSend.value, true)
    mc.close()
    assert.equal(await closed, false, 'closed without sending: the selection stays')
  })

  it('a refused target keeps Send disabled; removing it re-runs the check and enables Send', async () => {
    mc.api.setRefuse({ b: 'topic_archived' })
    mc.start(sel)
    await tick()
    assert.equal(mc.canSend.value, false)
    assert.deepEqual(mc.lines.value.map((l) => [l.task_id, l.ok, l.error]), [['a', true, ''], ['b', false, 'topic_archived'], ['c', true, '']])
    await mc.send('hi', [])
    assert.equal(sends.length, 0, 'Send is held while any target refuses')
    await mc.remove('b')
    assert.deepEqual(checks.at(-1).task_ids, ['a', 'c'])
    assert.equal(mc.canSend.value, true)
  })

  it('files uploaded once; N copies with one mc_id and N msg_ids, exactly the check\'s task ids; all acked: closes, finished', async () => {
    const closed = mc.start(sel)
    await tick()
    const files = [{ name: 'a.txt' }]
    await mc.send('hello', files)
    assert.equal(uploads.length, 1)
    assert.equal(sends.length, 1)
    const [s] = sends
    assert.deepEqual(s.files, [{ mode: 'blob', file_id: 'sha-a.txt', name: 'a.txt' }])
    assert.equal(s.text, 'hello')
    assert.ok(s.mcId)
    assert.deepEqual(s.copies.map((c) => c.task_id), ['a', 'b', 'c'])
    assert.equal(new Set(s.copies.map((c) => c.msg_id)).size, 3)
    assert.equal(checks.at(-1).body, 'hello', 'the last check read the real text')
    assert.deepEqual(checks.at(-1).files, s.files, 'and the uploaded refs')
    assert.equal(mc.open.value, false)
    assert.equal(await closed, true, 'finished: the bar empties the selection')
  })

  it('copies waiting for the network keep the dialog and the text until they land', async () => {
    mc.store.outcome = (c) => ({ state: c.task_id === 'a' ? 'sent' : 'waiting' })
    let onResult
    const orig = mc.store.sendMulticast
    mc.store.sendMulticast = async (a) => { onResult = a.onResult; return orig(a) }
    const closed = mc.start(sel)
    await tick()
    await mc.send('keep me', [])
    assert.equal(mc.open.value, true)
    assert.equal(mc.phase.value, 'sending')
    assert.equal(mc.sentText.value, 'keep me')
    assert.deepEqual(mc.lines.value.map((l) => l.state), ['sent', 'waiting', 'waiting'])
    for (const l of mc.lines.value.slice(1)) onResult(l.msg_id, { state: 'sent' })
    assert.equal(mc.open.value, false)
    assert.equal(await closed, true)
  })

  it('a send-time refusal lists that target with Retry under the same msg_id and mc_id', async () => {
    mc.store.outcome = (c) => (c.task_id === 'b' && sends.length === 1 ? { state: 'refused', error: 'quota' } : { state: 'sent' })
    const closed = mc.start(sel)
    await tick()
    await mc.send('hi', [])
    assert.equal(mc.phase.value, 'failed')
    assert.equal(mc.open.value, true)
    const b = mc.lines.value.find((l) => l.task_id === 'b')
    assert.deepEqual([b.state, b.error], ['failed', 'quota'])
    await mc.retry()
    assert.equal(sends.length, 2)
    assert.deepEqual(sends[1].copies, [{ task_id: 'b', channel: 'alpha', msg_id: b.msg_id }])
    assert.equal(sends[1].mcId, sends[0].mcId)
    assert.equal(uploads.length, 1, 'Retry does not upload again')
    assert.equal(await closed, true)
  })

  it('a Send the final check refused goes back to compose; the next Send uploads its own files (review N2)', async () => {
    mc.start(sel)
    await tick()
    assert.equal(mc.canSend.value, true)
    mc.api.setRefuse({ b: 'topic_archived' })
    await mc.send('hi', [])
    assert.equal(mc.phase.value, 'compose', 'the check refused: back to compose')
    assert.equal(sends.length, 0)
    mc.api.setRefuse({})
    await mc.check()
    await mc.send('hi', [{ name: 'late.txt' }])
    assert.equal(uploads.length, 2, 'the second Send uploads again')
    assert.equal(sends.length, 1)
    assert.deepEqual(sends[0].files, [{ mode: 'blob', file_id: 'sha-late.txt', name: 'late.txt' }], 'the file attached after the refusal goes out')
    assert.deepEqual(checks.at(-1).files, sends[0].files)
  })

  it('an answer to an older req_id is dropped', async () => {
    const pending = []
    mc.api.multicastCheck = (f) => { checks.push(f); return new Promise((r) => pending.push(() => r(mockMulticastCheck(state, f, f.task_ids.length === 3 ? {} : { a: 'forbidden' })))) }
    mc.start(sel)
    const second = mc.remove('c')
    pending[1]()
    await second
    assert.equal(mc.lines.value.find((l) => l.task_id === 'a').ok, false)
    pending[0]()
    await tick()
    assert.equal(mc.lines.value.find((l) => l.task_id === 'a').ok, false, 'the older all-ok answer did not overwrite the newer one')
  })

  it('the text change re-checks with the text (debounced), and the page composer\'s store send is never used', async () => {
    mc.start(sel)
    await tick()
    mc.setBody('@c-001 do it')
    await tick()
    assert.equal(checks.at(-1).body, '@c-001 do it')
    await mc.send('@c-001 do it', [])
    assert.equal(pageSends.length, 0)
  })

  it('spec 186 4.9 sendNow (the Omnibox, 2+ ticked): no compose step; one check with the text, then one copy per selected topic; all acked: closes, finished', async () => {
    const closed = mc.sendNow(sel, 'to all three', [{ name: 'f.txt' }])
    assert.equal(mc.open.value, true)
    assert.equal(mc.via.value, 'omnibox')
    assert.equal(await closed, true)
    assert.equal(uploads.length, 1)
    assert.equal(checks.length, 1)
    assert.equal(checks[0].body, 'to all three')
    assert.deepEqual(checks[0].task_ids, ['a', 'b', 'c'])
    assert.equal(sends.length, 1)
    assert.equal(sends[0].text, 'to all three')
    assert.deepEqual(sends[0].copies.map((c) => c.task_id), ['a', 'b', 'c'])
    assert.equal(mc.open.value, false)
  })

  it('spec 186 4.9 sendNow: a refused check sends nothing and leaves the dialog in compose with the text', async () => {
    mc.api.setRefuse({ b: 'topic_archived' })
    const closed = mc.sendNow(sel, 'keep me', [])
    await tick()
    await tick()
    assert.equal(sends.length, 0)
    assert.equal(mc.open.value, true)
    assert.equal(mc.phase.value, 'compose')
    assert.equal(mc.body.value, 'keep me')
    assert.equal(mc.lines.value.find((l) => l.task_id === 'b').error, 'topic_archived')
    mc.close()
    assert.equal(await closed, false, 'closed unsent: the selection stays')
  })

  it('the mock check: an empty selection is multicast_none; a DM topic is multicast_no_topic', () => {
    assert.equal(mockMulticastCheck(state, { req_id: 'q', task_ids: [] }, {}).error, 'multicast_none')
    const r = mockMulticastCheck(state, { req_id: 'q', task_ids: ['a', 'dm'] }, {})
    assert.equal(r.ok, false)
    assert.deepEqual(r.targets.map((t) => [t.task_id, t.ok, t.error || '']), [['a', true, ''], ['dm', false, 'multicast_no_topic']])
  })
})

describe('the client and the dialog', () => {
  it('the mock client: multicastCheck answers multicast_checked; sendMessage carries mc_id into an existing channel topic only', async () => {
    const api = mockClient()
    assert.equal(api.canMulticastCheck(), true)
    const live = createSpoolClient({ fetchFn: async () => { throw new Error('no fetch') }, mock: false })
    assert.equal(live.canMulticastCheck(), false, 'live without the request half: no Multicast button')
    await assert.rejects(api.sendMessage({ channel: 'alpha', task_id: 'no-such-topic', text: 'x', is_parent: 0, msg_id: 'mm1', mc_id: 'mc' }), (e) => e.token === 'multicast_no_topic')
  })

  it('the live send frame carries mc_id (live-ws send)', () => {
    assert.match(read('src/utils/live-ws.mjs'), /if \(mc_id\) frame\.mc_id = String\(mc_id\)/)
  })

  it('the dialog has its own composer (H5): no global or omnibox box, so no page draft; Send held by busy until all ok', () => {
    const d = read('src/components/MulticastDialog.vue')
    const tag = /<MessageComposer[^>]*\/>/.exec(d)?.[0] || ''
    assert.ok(tag, 'a MessageComposer instance')
    assert.doesNotMatch(tag, /\b(global|omnibox)\b/)
    assert.match(tag, /:busy="!canSend"/)
    assert.match(tag, /@send="onSend"/)
    assert.doesNotMatch(d, /useChannelStore|saveDraft|drafts/)
  })

  it('the bar registers Multicast through the select phase\'s action list', () => {
    const bar = read('src/components/TopicSelectBar.vue')
    assert.match(bar, /useMulticastAction\(\)/)
    assert.match(bar, /<LazyMulticastDialog v-if="multicast\.open\.value && multicast\.via\.value === 'bar'" \/>/)
    assert.match(read('src/composables/useMulticastSend.ts'), /registerAction\(\{ id: 'multicast', icon: 'go', labelKey: 'multicast\.action'/)
  })

  it('spec 186 4.9: TopBar routes the Omnibox send to sendNow with 2+ ticked, an in: topic excepted; the GO words say n topics', () => {
    const top = read('src/components/TopBar.vue')
    assert.match(top, /topicSelect\.count >= 2 \? topicSelect\.count : 0/)
    assert.match(top, /if \(multicastN\.value && !parent\) return sendMulticast\(text, files \|\| \[\]\)/)
    assert.match(top, /mc\.sendNow\(\[\.\.\.topicSelect\.picks\], text, files\)\) topicSelect\.clear\(\)/)
    assert.match(top, /:multicast="multicastN"/)
    assert.doesNotMatch(top, /^import .*useMulticastSend/m, 'the flow loads on the first multicast (027)')
    assert.match(read('src/composables/useComposerTarget.ts'), /mcN\.value \? 'multicast\.send' : composerSendKey/)
    assert.match(read('src/components/MessageComposer.vue'), /t\(sendKey, sendParams\)/)
  })
})
