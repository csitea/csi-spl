// DB payload cut 1 (audit 2026-10-02): the DM seed no longer inlines 50
// messages per DM topic; the hub counts the per-peer unread and total itself
// (`?dm=true&dm_counts=true`, internal/hub/view_dm_counts.go) against the
// dm_read= cursors the WUI sends. The badge must read exactly as before, so
// the rules live in one fixture, dm-counts-parity.json, that BOTH sides must
// pass: here the WUI's inline-page rules (unreadFromDms / dmTotalsFromDms),
// and in the hub's view_dm_counts_test.go its port. A hub row's `dm` counts
// then flow through the same two functions unchanged.
// Run: node tests/unit/dm-counts-parity.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { dmReadParams, dmTotalsFromDms, unreadFromDms } from '../../src/utils/channel-feed.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const { cases } = JSON.parse(readFileSync(join(here, 'dm-counts-parity.json'), 'utf8'))

/** a fixture topic as the WUI held it with per_topic: the inline page */
const inlineRow = (t) => ({
  count: t.count,
  participants: t.participants,
  inline: { messages: t.messages.map((m) => ({ channel: null, ...m })) },
})

describe('DM counts: the fixture the hub port must also pass', () => {
  for (const c of cases) {
    it(c.name, () => {
      const rows = c.topics.map(inlineRow)
      assert.deepEqual(unreadFromDms(rows, c.cursors, c.self), c.expect.unread)
      assert.deepEqual(dmTotalsFromDms(rows, c.self), c.expect.total)
    })
  }
})

describe('DM counts: a hub row (dm_counts) reads through the same functions', () => {
  const hubRows = [
    { count: 9, participants: ['CLE-1@box-desk', 'HUM-1@box-wui'], dm: { unread: { 'CLE-1@box-desk': 2 }, total: { 'CLE-1@box-desk': 9 } } },
    { count: 3, participants: ['CLE-1@box-desk', 'HUM-1@box-wui'], dm: { unread: {}, total: { 'CLE-1@box-desk': 3 } } },
    { count: 1, participants: ['HUM-2@box-wui', 'HUM-1@box-wui'], dm: { unread: { 'HUM-2@box-wui': 1 }, total: { 'HUM-2@box-wui': 1 } } },
  ]
  it('sums per peer under dm:<peer>, and never reads an inline page beside it', () => {
    const rows = hubRows.map((r) => ({ ...r, inline: { messages: [{ msg_id: 'x', from: 'CLE-9', from_box: 'box-desk', to: 'HUM-1', to_box: 'box-wui', channel: null, received_at: 'z' }] } }))
    assert.deepEqual(unreadFromDms(rows, {}, 'HUM-1'), { 'dm:CLE-1@box-desk': 2, 'dm:HUM-2@box-wui': 1 })
    assert.deepEqual(dmTotalsFromDms(rows, 'HUM-1'), { 'dm:CLE-1@box-desk': 12, 'dm:HUM-2@box-wui': 1 })
  })
  it('CONTROL: an older hub row (no dm) still counts its inline page', () => {
    const rows = [{ count: 1, participants: [], inline: { messages: [{ msg_id: 'x', from: 'CLE-9', from_box: 'box-desk', to: 'HUM-1', to_box: 'box-wui', channel: null, received_at: 'z' }] } }]
    assert.deepEqual(unreadFromDms(rows, {}, 'HUM-1'), { 'dm:CLE-9@box-desk': 1 })
    assert.deepEqual(dmTotalsFromDms(rows, 'HUM-1'), { 'dm:CLE-9@box-desk': 1 })
  })
})

describe('dmReadParams: the dm_read= marks', () => {
  it('one <peer>~<ts>~<id> per dm: cursor with a time; channels, topics and empty cursors stay home', () => {
    const cursors = {
      'dm:CLE-1@box-desk': { ts: '2026-10-01T10:00:00.5Z', id: 'm1' },
      'dm:HUM-2@box-wui': { ts: '2026-10-01T11:00:00Z', id: '' },
      'dm:CLE-3@box-desk': { ts: '', id: '' },
      'ch:lobby': { ts: '2026-10-01T10:00:00Z', id: '', hub: 'abc' },
      't:1111': { ts: '2026-10-01T10:00:00Z', id: '', count: 3 },
    }
    assert.deepEqual(dmReadParams(cursors), ['CLE-1@box-desk~2026-10-01T10:00:00.5Z~m1', 'HUM-2@box-wui~2026-10-01T11:00:00Z~'])
    assert.deepEqual(dmReadParams(null), [])
  })
})

describe('listTopics({ dmCounts }): the DM seed read', () => {
  it('asks dm_counts=true with one dm_read per cursor, no per_topic, and keeps the row dm counts', async () => {
    const calls = []
    const dm = { unread: { 'CLE-1@box-desk': 2 }, total: { 'CLE-1@box-desk': 9 } }
    const fetchFn = async (url) => {
      calls.push(url)
      const body = { topics: [{ task_id: 't1', first_ts: '1', last_ts: '1', count: 9, subject: 's', participants: ['CLE-1@box-desk', 'HUM-1@box-wui'], dm }], next: null }
      return { ok: true, status: 200, headers: { get: () => 'application/json' }, json: async () => body }
    }
    const c = createSpoolClient({ mock: false, base: 'https://h', fetchFn })
    const page = await c.listTopics({ dm: true, limit: 50, dmCounts: true, dmRead: ['CLE-1@box-desk~2026-10-01T10:00:00.5Z~m1', 'HUM-2@box-wui~2026-10-01T11:00:00Z~'] })
    const q = new URL(calls[0]).searchParams
    assert.equal(calls.length, 1)
    assert.equal(q.get('dm'), 'true')
    assert.equal(q.get('dm_counts'), 'true')
    assert.equal(q.get('per_topic'), null)
    assert.deepEqual(q.getAll('dm_read'), ['CLE-1@box-desk~2026-10-01T10:00:00.5Z~m1', 'HUM-2@box-wui~2026-10-01T11:00:00Z~'])
    assert.deepEqual(page.topics[0].dm, dm)
    assert.deepEqual(unreadFromDms(page.topics, {}, 'HUM-1'), { 'dm:CLE-1@box-desk': 2 })
  })
  it('the channel store seeds DMs with dm_counts and no per_topic page', () => {
    const src = readFileSync(join(here, '../../src/stores/channel.ts'), 'utf8')
    const seed = src.slice(src.indexOf('async function loadDmActivity'), src.indexOf('async function loadChannels'))
    assert.match(seed, /dmCounts: true, dmRead/)
    assert.doesNotMatch(seed, /perTopic/)
  })
  it('a hub read-mark pull that moves dm: cursors refetches the seed (its counts were made against the old ones)', () => {
    const src = readFileSync(join(here, '../../src/utils/read-sync-boot.ts'), 'utf8')
    const dm = src.slice(src.indexOf("k.startsWith('dm:')"), src.indexOf("k.startsWith('ch:')"))
    assert.match(dm, /channel\.loadDmActivity\(self\)/)
    assert.doesNotMatch(dm, /applyDms\(channel\.dmSeed/)
  })
})
