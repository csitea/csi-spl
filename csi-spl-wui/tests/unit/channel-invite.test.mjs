// channels-v1 §7.4: invite posts one human id. The picker offers only
// tenant humans who are not already in the channel.
//
// Run: node tests/unit/channel-invite.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  channelInviteCandidates,
  createSpoolClient,
  inviteErrorToken,
  isPublicChannel,
} from '../../src/utils/spool-client.mjs'

function stubFetch(routes) {
  const calls = []
  const fn = async (url, opts = {}) => {
    calls.push({ url, opts })
    const hit = routes.find(([p]) => p(url, opts))
    const [status, body] = hit ? hit[1] : [404, { error: 'not_found' }]
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: { get: () => 'application/json' },
      json: async () => body,
    }
  }
  return { fn, calls }
}

describe('POST /v1/channels/{channel}/members', () => {
  it('sends {human_id} to /v1/channels/releases/members with session credentials', async () => {
    const { fn, calls } = stubFetch([
      [(u, o) => u === '/v1/channels/releases/members' && o.method === 'POST', [201, { channel: 'releases', human_id: 'HUM-9', added_by: 'HUM-1' }]],
    ])
    const c = createSpoolClient({ fetchFn: fn, mock: false, door: 'session' })
    const out = await c.addChannelMember('releases', 'HUM-9')
    assert.equal(calls.length, 1)
    assert.equal(calls[0].url, '/v1/channels/releases/members')
    assert.equal(calls[0].opts.method, 'POST')
    assert.equal(calls[0].opts.credentials, 'include')
    assert.equal(calls[0].opts.headers['content-type'], 'application/json')
    assert.deepEqual(JSON.parse(calls[0].opts.body), { human_id: 'HUM-9' })
    assert.equal(out.human_id, 'HUM-9')
  })

  it('keeps the hub error token', async () => {
    const cases = [
      [409, 'channel_public'],
      [404, 'not_a_member'],
      [404, 'unknown_channel'],
      [403, 'forbidden'],
    ]
    for (const [status, token] of cases) {
      const { fn } = stubFetch([[() => true, [status, { error: token }]]])
      const c = createSpoolClient({ fetchFn: fn, mock: false, door: 'session' })
      await assert.rejects(
        c.addChannelMember('releases', 'HUM-9'),
        (e) => e.status === status && e.token === token && inviteErrorToken(e) === token,
      )
    }
  })
})

describe('PATCH members_open_invite', () => {
  it('sends {members_open_invite:true} with session credentials and keeps the returned flag', async () => {
    const { fn, calls } = stubFetch([
      [(u, o) => u === '/v1/channels/releases' && o.method === 'PATCH', [200, { channel: 'releases', members_open_invite: true }]],
    ])
    const c = createSpoolClient({ fetchFn: fn, mock: false, door: 'session' })
    const out = await c.setMembersOpenInvite('releases', true)
    assert.equal(calls[0].url, '/v1/channels/releases')
    assert.equal(calls[0].opts.credentials, 'include')
    assert.equal(calls[0].opts.headers['content-type'], 'application/json')
    assert.deepEqual(JSON.parse(calls[0].opts.body), { members_open_invite: true })
    assert.equal(out.members_open_invite, true)
  })

  it('treats a missing members_open_invite as false and keeps agents', async () => {
    const { fn } = stubFetch([
      [() => true, [200, { channel: 'releases', members: ['HUM-1'], agents: [{ id: 'CLE-07', box: 'box-a' }] }]],
    ])
    const c = createSpoolClient({ fetchFn: fn, mock: false, door: 'session' })
    const body = await c.listChannelMembers('releases')
    assert.equal(body.members_open_invite, false)
    assert.deepEqual(body.agents, [{ id: 'CLE-07', box: 'box-a' }])
  })
})

describe('invite picker', () => {
  it('hides humans already in the channel and humans who are not HUM-*', () => {
    const ids = channelInviteCandidates(
      ['HUM-1', 'HUM-2', 'CLE-07', 'GRK-03', 'AGY-02', 'GST-1', 'HUM-2', 'not-a-human', 'HUM-'],
      ['HUM-1'],
    )
    assert.deepEqual(ids, ['HUM-2'])
  })
})

describe('mock membership', () => {
  it('a created channel gains the human id in memory', async () => {
    const c = createSpoolClient({ mock: true })
    await c.createChannel({ name: 'releases' })
    const before = await c.listChannelMembers('releases')
    assert.equal(before.default, false)
    assert.equal(before.members_open_invite, false)
    assert.deepEqual(before.members, ['HUM-1'])
    const { roster } = await c.listRoster()
    roster['box-wui'].push('HUM-2')
    const added = await c.addChannelMember('releases', 'HUM-2')
    assert.equal(added.human_id, 'HUM-2')
    assert.deepEqual((await c.listChannelMembers('releases')).members, ['HUM-1', 'HUM-2'])
  })

  it('a member who is not the owner cannot add until the flag is on, and only the owner can set it', async () => {
    const c = createSpoolClient({ mock: true })
    await c.createChannel({ name: 'releases' })
    const { roster, me } = await c.listRoster()
    roster['box-wui'].push('HUM-2', 'HUM-3')
    await c.addChannelMember('releases', 'HUM-2')
    me.id = 'HUM-2'
    await assert.rejects(c.addChannelMember('releases', 'HUM-3'), (e) => e.status === 403 && e.token === 'forbidden')
    await assert.rejects(c.setMembersOpenInvite('releases', true), (e) => e.token === 'forbidden')
    me.id = 'HUM-1'
    const saved = await c.setMembersOpenInvite('releases', true)
    assert.equal(saved.members_open_invite, true)
    me.id = 'HUM-2'
    await c.addChannelMember('releases', 'HUM-3')
    const after = await c.listChannelMembers('releases')
    assert.equal(after.members_open_invite, true)
    assert.deepEqual(after.members, ['HUM-1', 'HUM-2', 'HUM-3'])
  })

  it('a default channel has no invite list and refuses the write', async () => {
    const c = createSpoolClient({ mock: true })
    for (const name of ['lobby', 'tasks', 'alerts', 'feedback', 'general']) {
      assert.equal(isPublicChannel(name), true)
    }
    const lobby = await c.listChannelMembers('lobby')
    assert.equal(lobby.default, true)
    assert.deepEqual(lobby.members, [])
    await assert.rejects(c.addChannelMember('lobby', 'HUM-1'), (e) => e.token === 'channel_public')
    await assert.rejects(c.setMembersOpenInvite('lobby', true), (e) => e.token === 'channel_public')
    await assert.rejects(c.addChannelMember('releases', 'HUM-2'), (e) => e.token === 'unknown_channel')
  })

  it('a default channel starts with no agents; a member adds and removes one (2026-09-25)', async () => {
    const c = createSpoolClient({ mock: true })
    for (const name of ['lobby', 'tasks', 'alerts', 'feedback']) {
      const row = await c.listChannelMembers(name)
      assert.equal(row.default, true)
      assert.deepEqual(row.agents, [], `#${name} has no agent until someone adds one`)
    }
    await c.addChannelAgent('lobby', 'GRK-03', 'box-a')
    assert.deepEqual((await c.listChannelMembers('lobby')).agents, [{ id: 'GRK-03', box: 'box-a' }])
    assert.deepEqual((await c.listChannelMembers('tasks')).agents, [], 'a lobby pick does not leak into #tasks')
    await c.removeChannelAgent('lobby', 'GRK-03', 'box-a')
    assert.deepEqual((await c.listChannelMembers('lobby')).agents, [])
    await assert.rejects(c.addChannelAgent('lobby', 'CLE-99', 'box-a'), (e) => e.token === 'not_a_member')
  })

  it('refuses a human who is not in the tenant', async () => {
    const c = createSpoolClient({ mock: true })
    await c.createChannel({ name: 'releases' })
    await assert.rejects(c.addChannelMember('releases', 'HUM-9'), (e) => e.status === 404 && e.token === 'not_a_member')
    await assert.rejects(c.addChannelMember('releases', 'CLE-07'), (e) => e.token === 'not_a_member')
  })
})
