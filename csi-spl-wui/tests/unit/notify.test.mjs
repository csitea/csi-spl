import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  shouldEscalate,
  escalateReason,
  mentionedIds,
  channelKey,
  normalizeChannel,
  notifyCopy,
  notifyCopyKey,
  loadChime,
  saveChime,
  previewUnread,
  CHIME_KEY,
} from '../../src/utils/notify.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

function msg(partial) {
  return {
    v: 1,
    msg_id: 'm1',
    task_id: 't1',
    ts: '2026-09-19T05:00:00Z',
    from: 'CLE-07',
    to: '@channel',
    kind: 'note',
    body: 'hello',
    channel: 'lobby',
    ...partial,
  }
}

describe('notify escalation', () => {
  it('escalates a mention of the signed-in HUM-* in a channel', () => {
    const m = msg({ body: 'hey @HUM-1 please look', channel: 'lobby' })
    assert.equal(escalateReason(m, { selfId: 'HUM-1' }), 'mention')
    assert.equal(shouldEscalate(m, { selfId: 'HUM-1' }), true)
    assert.equal(shouldEscalate(m, { selfId: 'HUM-2' }), false)
  })

  it('escalates to=HUM-* as a mention', () => {
    const m = msg({ to: 'HUM-1', body: 'review this', channel: 'tasks' })
    assert.equal(escalateReason(m, { selfId: 'HUM-1' }), 'mention')
  })

  it('escalates a DM (channel null) and a ctx.isDm pane', () => {
    const dm = msg({ channel: null, to: 'HUM-1', body: 'ping' })
    assert.equal(escalateReason(dm, { selfId: 'HUM-1' }), 'dm')
    const onDm = msg({ channel: undefined, body: 'hi' })
    assert.equal(escalateReason(onDm, { selfId: 'HUM-1', isDm: true, peer: 'CLE-07@box-a' }), 'dm')
    assert.equal(channelKey(dm, { selfId: 'HUM-1' }), 'dm:CLE-07')
  })

  it('escalates any #alerts message and not a plain #tasks note', () => {
    const alerts = msg({ channel: 'alerts', body: 'box-b offline' })
    assert.equal(escalateReason(alerts, { selfId: 'HUM-1' }), 'alerts')
    assert.equal(shouldEscalate(msg({ channel: '#alerts' }), { selfId: 'HUM-1' }), true)
    assert.equal(shouldEscalate(msg({ channel: 'tasks', body: 'Applying patch' }), { selfId: 'HUM-1' }), false)
    assert.equal(shouldEscalate(msg({ channel: 'lobby', body: 'hello' }), { selfId: 'HUM-1' }), false)
  })

  it('never escalates own messages, even in #alerts or with a self mention', () => {
    assert.equal(shouldEscalate(msg({ from: 'HUM-1', channel: 'alerts' }), { selfId: 'HUM-1' }), false)
    assert.equal(shouldEscalate(msg({ from: 'HUM-1', body: '@HUM-1 note' }), { selfId: 'HUM-1' }), false)
  })

  it('parses mention ids and copies', () => {
    assert.deepEqual(mentionedIds('cc @CLE-07 and @HUM-1 please'), ['CLE-07', 'HUM-1'])
    assert.deepEqual(mentionedIds('email me@example.com'), [])
    const copy = notifyCopy(msg({ from: 'GRK-03', body: 'up' }), 'alerts')
    assert.equal(copy.title.startsWith('#alerts'), true)
  })

  it('notifyCopyKey names the same title as a catalogue key (spec 021)', () => {
    const m = msg({ from: 'GRK-03', body: 'up' })
    for (const [reason, key] of [['alerts', 'notify.title_alerts'], ['dm', 'notify.title_dm'], ['mention', 'notify.title_mention'], [null, 'notify.title_other']]) {
      const k = notifyCopyKey(m, reason)
      assert.equal(k.titleKey, key)
      assert.deepEqual(k.params, { from: 'GRK-03' })
      assert.equal(k.body, notifyCopy(m, reason).body)
    }
  })

  it('normalizes general to lobby and builds ch:/dm: keys', () => {
    assert.equal(normalizeChannel('#General'), 'lobby')
    assert.equal(channelKey(msg({ channel: 'tasks' })), 'ch:tasks')
    assert.equal(channelKey(msg({ channel: 'general' })), 'ch:lobby')
    assert.equal(channelKey(msg({}), { channel: 'lobby' }), 'ch:lobby')
  })

  it('chime is opt-in (default off) and survives storage throws', () => {
    const store = memoryStore()
    assert.equal(loadChime(store), false)
    saveChime(true, store)
    assert.equal(store.getItem(CHIME_KEY), '1')
    assert.equal(loadChime(store), true)
    const boom = { getItem() { throw new Error('x') }, setItem() { throw new Error('x') } }
    assert.equal(loadChime(boom), false)
    assert.equal(previewUnread(0), '')
    assert.equal(previewUnread(3), '3')
    assert.equal(previewUnread(100), '99+')
  })

  it('NotificationCenter and the notification store do not import mock-data', () => {
    const center = readFileSync(join(WUI, 'src/components/NotificationCenter.vue'), 'utf8')
    const store = readFileSync(join(WUI, 'src/stores/notification.ts'), 'utf8')
    assert.equal(center.includes('mock-data'), false)
    assert.equal(store.includes('mock-data'), false)
    assert.equal(center.includes('useNotificationStore'), true)
    assert.equal(center.includes('chime'), true)
    assert.equal(center.includes('requestPush'), true)
  })
})

describe('live #alerts / DM escalation wiring (gap A2)', () => {
  const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

  it('a live #alerts frame keys and escalates as alerts even while a DM is open', () => {
    const frame = { msg_id: 'x', from: 'CLE-2', from_box: 'b1', channel: 'alerts', body: 'disk full' }
    const page = { selfId: 'HUM-1', activeKey: 'dm:CLE-3@b2' }
    assert.equal(channelKey(frame, page), 'ch:alerts')
    assert.equal(escalateReason(frame, page), 'alerts')
    const dm = { msg_id: 'y', from: 'CLE-3', from_box: 'b2', channel: null, body: 'hi' }
    assert.equal(channelKey(dm, page), 'dm:CLE-3@b2')
    assert.equal(escalateReason(dm, page), 'dm')
  })

  it('the plugin ingests live frames with the page identity only, not its peer', () => {
    const plugin = src('src/plugins/notify.client.ts')
    assert.match(plugin, /notes\.ingest\(\[m\], \{ selfId: page\.selfId, activeKey: page\.activeKey \}/)
    assert.equal(plugin.includes('applyChannels'), true)
  })

  it('the store derives unread from stored cursors and counts mentions', () => {
    const store = src('src/stores/notification.ts')
    assert.equal(store.includes('isUnread(m, cursors[key])'), true)
    assert.equal(store.includes('mentions'), true)
  })
})
