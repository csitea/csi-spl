// rdb 0092: Archive channel in the channel's row menu (its creator only, behind
// a confirm) hides the channel and reserves its name; Unarchive brings it back.
// A create against an archived name is refused with channel_archived and offers
// to unarchive it.
// Run: node tests/unit/channel-archive.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { rowMenuItems } from '../../src/utils/sidebar-row-menu.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('row menu', () => {
  it('Archive channel appears only when archivable, before Delete', () => {
    const on = rowMenuItems(false, { channel: true, properties: true, archivable: true, deletable: true })
    const ids = on.map((i) => i.id)
    assert.ok(ids.includes('archive-channel'), 'has archive-channel')
    assert.ok(ids.indexOf('archive-channel') < ids.indexOf('delete'), 'archive before delete')
    assert.deepEqual(
      on.find((i) => i.id === 'archive-channel'),
      { id: 'archive-channel', icon: 'archive', labelKey: 'sidebar.row_menu.archive_channel' },
    )
    const off = rowMenuItems(false, { channel: true, properties: true })
    assert.equal(off.some((i) => i.id === 'archive-channel'), false)
  })
  it('a person row never gets it', () => {
    assert.equal(rowMenuItems(false, { person: true, admin: true, archivable: true }).some((i) => i.id === 'archive-channel'), false)
  })
})

describe('client (live)', () => {
  const jsonHeaders = { get: (k) => (String(k).toLowerCase() === 'content-type' ? 'application/json' : '') }
  const reply = (status, body) => ({
    ok: status < 400, status, headers: jsonHeaders,
    json: async () => body, text: async () => JSON.stringify(body),
    arrayBuffer: async () => new TextEncoder().encode(JSON.stringify(body)).buffer,
  })
  it('PUT /v1/channels/{c}/archive', async () => {
    const calls = []
    const c = createSpoolClient({ mock: false, fetchFn: async (url, opts = {}) => { calls.push({ url, opts }); return { ...reply(204, null), status: 204, headers: { get: () => '' } } } })
    assert.equal(await c.archiveChannel('keepme'), null)
    assert.equal(calls[0].url, '/v1/channels/keepme/archive')
    assert.equal(calls[0].opts.method, 'PUT')
  })
  it('PUT /v1/channels/{c}/unarchive returns the row', async () => {
    const calls = []
    const c = createSpoolClient({ mock: false, fetchFn: async (url, opts = {}) => { calls.push({ url, opts }); return reply(200, { channel: 'keepme', name: 'Keep Me' }) } })
    const row = await c.unarchiveChannel('keepme')
    assert.equal(calls[0].url, '/v1/channels/keepme/unarchive')
    assert.equal(calls[0].opts.method, 'PUT')
    assert.equal(row.channel_id, 'keepme')
  })
})

describe('client (mock)', () => {
  it('archive drops the row, reserves the name, unarchive restores it', async () => {
    const c = createSpoolClient({ mock: true })
    await c.createChannel({ name: 'Keep Me' })
    await c.archiveChannel('keep-me')
    assert.equal((await c.listChannels()).some((x) => x.channel_id === 'keep-me'), false)
    // the name is reserved by the archived channel
    await assert.rejects(c.createChannel({ name: 'Keep Me' }), (e) => e.status === 409 && e.token === 'channel_archived')
    // unarchive brings it back
    await c.unarchiveChannel('keep-me')
    assert.equal((await c.listChannels()).some((x) => x.channel_id === 'keep-me'), true)
  })
  it('a default channel cannot be archived', async () => {
    const c = createSpoolClient({ mock: true })
    await assert.rejects(c.archiveChannel('lobby'), (e) => e.status === 409 && e.token === 'channel_public')
  })
  it('after a hard delete the name is FREE (no channel_archived)', async () => {
    const c = createSpoolClient({ mock: true })
    await c.createChannel({ name: 'Doomed' })
    await c.deleteChannel('doomed')
    // re-create succeeds - delete freed the name
    const row = await c.createChannel({ name: 'Doomed' })
    assert.equal(row.channel_id, 'doomed')
  })
})

describe('ChannelSidebar wiring', () => {
  const vue = src('src/components/ChannelSidebar.vue')
  it('the channel row menu passes archivable and handles archive-channel', () => {
    /* topic 635f8072: Flow lists messages now, so Channels is the one channel list */
    assert.equal((vue.match(/:archivable="deletableChannel\(/g) || []).length, 1)
    assert.equal((vue.match(/@archive-channel="askArchiveChannel\(/g) || []).length, 1)
  })
  it('Archive opens the lazy confirm; nothing is archived from the menu itself', () => {
    assert.match(vue, /<LazyChannelConfirmDialog[\s\S]*?v-model:open="archiveOpen"[\s\S]*?action="archive"/)
    assert.doesNotMatch(vue, /channel\.archiveChannel\(/)
    const dlg = src('src/components/ChannelConfirmDialog.vue')
    assert.match(dlg, /<UiConfirm[\s\S]*?testid="`\$\{action\}-channel`"[\s\S]*?@confirm="confirm"/)
    assert.match(dlg, /channel\.archiveChannel\(id\)/)
  })
  it('the create dialog offers Unarchive on a channel_archived conflict', () => {
    assert.match(vue, /data-testid="create-channel-unarchive"/)
    assert.match(vue, /if \(tok === 'channel_archived'\) archivedSlug\.value = slug\.value/)
    assert.match(vue, /await channel\.unarchiveChannel\(id\)/)
  })
})

describe('store + row menu emit', () => {
  it('the channel store exposes archiveChannel and unarchiveChannel', () => {
    const store = src('src/stores/channel.ts')
    assert.match(store, /async function archiveChannel\(/)
    assert.match(store, /async function unarchiveChannel\(/)
    assert.match(store, /api\.archiveChannel\(id\)/)
    assert.match(store, /api\.unarchiveChannel\(id\)/)
  })
  it('SidebarRowMenu emits archiveChannel for the archive-channel item', () => {
    const menu = src('src/components/SidebarRowMenu.vue')
    assert.match(menu, /id === 'archive-channel'[\s\S]*?emit\('archiveChannel'\)/)
    assert.match(menu, /archivable\?: boolean/)
  })
})
