// SPL-72, channels-v1 §5.4: Delete channel in the channel's row menu, for the
// member who created it only, behind a confirm; a live channel_deleted frame
// drops the row from every open sidebar.
// Run: node tests/unit/channel-delete.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { applyChannelFrame } from '../../src/utils/channel-feed.mjs'
import { canDeleteChannel, createSpoolClient } from '../../src/utils/spool-client.mjs'
import { rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'
import { FRAMES } from '../../src/utils/live-ws.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('canDeleteChannel: its creator, nobody else', () => {
  const mine = { channel_id: 'release-notes', created_by: 'HUM-4', default: false }
  it('the creator may', () => {
    assert.equal(canDeleteChannel({ selfId: 'HUM-4', row: mine }), true)
  })
  it('another member may not, whatever their role', () => {
    assert.equal(canDeleteChannel({ selfId: 'HUM-5', row: mine }), false)
  })
  it('a default channel never, even for created_by hub', () => {
    for (const id of ['lobby', 'alerts', 'feedback', 'general']) {
      assert.equal(canDeleteChannel({ selfId: 'HUM-4', row: { channel_id: id, created_by: 'HUM-4' } }), false, id)
    }
    assert.equal(canDeleteChannel({ selfId: 'HUM-4', row: { ...mine, default: true } }), false)
  })
  it('a channel made by hub or wui has no creator to match', () => {
    assert.equal(canDeleteChannel({ selfId: 'HUM-4', row: { ...mine, created_by: 'wui' } }), false)
    assert.equal(canDeleteChannel({ selfId: 'wui', row: { ...mine, created_by: 'wui' } }), false)
  })
  it('an unknown viewer is never offered it', () => {
    assert.equal(canDeleteChannel({ selfId: '', row: mine }), false)
    assert.equal(canDeleteChannel({}), false)
  })
})

describe('row menu', () => {
  it('Delete is the last channel item, only when deletable', () => {
    const on = rowMenuItems(false, { channel: true, properties: true, deletable: true })
    assert.deepEqual(on.at(-1), { id: 'delete', icon: 'trash', labelKey: 'sidebar.row_menu.delete_channel' })
    const off = rowMenuItems(false, { channel: true, properties: true })
    assert.equal(off.some((i) => i.id === 'delete'), false)
  })
  it('a person row never gets it', () => {
    assert.equal(rowMenuItems(false, { person: true, admin: true, deletable: true }).some((i) => i.id === 'delete'), false)
  })
})

describe('applyChannelFrame', () => {
  const rows = [{ channel_id: 'lobby' }, { channel_id: 'doomed', name: 'Doomed' }]
  it('channel_deleted drops the row', () => {
    assert.deepEqual(applyChannelFrame(rows, { type: 'channel_deleted', channel: 'doomed' }).map((r) => r.channel_id), ['lobby'])
  })
  it('an unknown or empty id leaves the same array', () => {
    assert.equal(applyChannelFrame(rows, { type: 'channel_deleted', channel: 'nope' }), rows)
    assert.equal(applyChannelFrame(rows, { type: 'channel_deleted' }), rows)
  })
  it('a channel frame still adds', () => {
    const out = applyChannelFrame(rows, { type: 'channel', channel: 'fresh', name: 'Fresh' })
    assert.deepEqual(out.map((r) => r.channel_id), ['lobby', 'doomed', 'fresh'])
  })
  it('the socket routes channel_deleted to onChannel', () => {
    assert.equal(FRAMES.channelDeleted, 'channel_deleted')
    assert.match(src('src/utils/live-ws.mjs'), /case FRAMES\.channel:\s*case FRAMES\.channelDeleted:\s*onChannel\(f\)/)
  })
})

describe('client', () => {
  it('live: DELETE /v1/channels/{channel}', async () => {
    const calls = []
    const fetchFn = async (url, opts = {}) => {
      calls.push({ url, opts })
      return { ok: true, status: 204, headers: { get: () => '' }, json: async () => null, text: async () => '' }
    }
    const c = createSpoolClient({ fetchFn, mock: false })
    assert.equal(await c.deleteChannel('doomed'), null)
    assert.equal(calls.length, 1)
    assert.equal(calls[0].url, '/v1/channels/doomed')
    assert.equal(calls[0].opts.method, 'DELETE')
  })
  it('mock: the creator deletes; a default channel is 409', async () => {
    const c = createSpoolClient({ mock: true })
    await c.createChannel({ name: 'Doomed' })
    await c.deleteChannel('doomed')
    assert.equal((await c.listChannels()).some((x) => x.channel_id === 'doomed'), false)
    await assert.rejects(c.deleteChannel('lobby'), (e) => e.status === 409 && e.token === 'channel_public')
    await assert.rejects(c.deleteChannel('doomed'), (e) => e.status === 404)
  })
})

describe('ChannelSidebar wiring', () => {
  const vue = src('src/components/ChannelSidebar.vue')
  it('the channel row menu passes deletable and handles delete', () => {
    /* topic 635f8072: Flow lists messages now, so Channels is the one channel list */
    assert.equal((vue.match(/:deletable="deletableChannel\(/g) || []).length, 1)
    assert.equal((vue.match(/@delete="askDeleteChannel\(/g) || []).length, 1)
  })
  it('Delete opens a confirm; nothing is deleted from the menu itself', () => {
    assert.match(vue, /<LazyChannelDeleteDialog[\s\S]*?v-model:open="deleteOpen"/)
    assert.doesNotMatch(vue, /@delete="[^"]*channel\.deleteChannel/)
    assert.doesNotMatch(vue, /channel\.deleteChannel\(/)
    const dlg = src('src/components/ChannelDeleteDialog.vue')
    assert.match(dlg, /<UiConfirm[\s\S]*?testid="delete-channel"[\s\S]*?@confirm="confirm"/)
    assert.match(dlg, /await channel\.deleteChannel\(id\)/)
  })
  it('the confirm stays off the initial script: only the Lazy form is used', () => {
    assert.doesNotMatch(vue, /<ChannelDeleteDialog\b/)
    assert.doesNotMatch(vue, /import ChannelDeleteDialog/)
  })
})
