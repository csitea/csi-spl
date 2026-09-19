import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

describe('spool-client mock', () => {
  it('lists default channels and catch-up of 50', async () => {
    const c = createSpoolClient({ mock: true })
    const channels = await c.listChannels()
    assert.deepEqual(channels.map((x) => x.channel_id), ['lobby', 'tasks', 'alerts'])
    const feed = await c.listMessages({ channel: 'lobby', limit: 50 })
    assert.ok(feed.length >= 1)
    assert.equal(feed.every((m) => m.channel === 'lobby'), true)
  })

  it('sends an @mention as kind=task and appends it', async () => {
    const c = createSpoolClient({ mock: true })
    const sent = await c.sendMessage({ channel: 'dev', text: '@GRK-03 ship it' })
    assert.equal(sent.kind, 'task')
    assert.equal(sent.to, 'GRK-03')
    assert.equal(sent.channel, 'dev')
    const feed = await c.listMessages({ channel: 'dev' })
    assert.equal(feed.some((m) => m.msg_id === sent.msg_id), true)
  })

  it('creates a channel slug and lists it', async () => {
    const c = createSpoolClient({ mock: true })
    const row = await c.createChannel({ name: 'Feature Auth' })
    assert.equal(row.channel_id, 'feature-auth')
    const channels = await c.listChannels()
    assert.equal(channels.some((x) => x.channel_id === 'feature-auth'), true)
  })

  it('DM list is channel-null messages for that peer', async () => {
    const c = createSpoolClient({ mock: true })
    const dms = await c.listMessages({ peer: 'GRK-03@box-a' })
    assert.ok(dms.length >= 1)
    assert.equal(dms.every((m) => !m.channel), true)
  })
})
