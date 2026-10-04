// HUM-10 (t1 f77c9f87): the Boxes page's resources (middle pane) and their
// statistics (right pane). The WUI shows only what the hub serves: OS and
// run-times from the roster's boxes[] once the BOX-0 hello carries them, the
// load / memory / disk history from GET /v1/tenant/box-stats - and a plain
// "not reported" / "no history yet" otherwise, never made-up numbers.
//
// Run: node tests/unit/box-resources.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import {
  BOX_RESOURCES, ageOf, agentCounts, agentStatRows, boxDisksOf, boxNetworkOf, boxOsOf, boxResourceOf, boxRuntimesOf,
  boxStatsOf, boxSystemOf, currentOf, factsReportedAt, formatKB, formatLoad, formatMB, hardwareSummary, isBoxStatsForbidden,
  isNoBoxStats, latestBoxStat, osLine,
} from '../../src/utils/box-resources.mjs'

describe('boxResourceOf', () => {
  it('keeps a known resource, drops anything else', () => {
    assert.deepEqual(BOX_RESOURCES, ['agents', 'hardware', 'system', 'os', 'runtimes', 'network'])
    for (const r of BOX_RESOURCES) assert.equal(boxResourceOf(r), r)
    assert.equal(boxResourceOf(['hardware', 'os']), 'hardware')
    assert.equal(boxResourceOf('people'), '')
    assert.equal(boxResourceOf(undefined), '')
  })
})

describe('box-stats read', () => {
  it('404 / 501 are "no history", 403 is "no permission", others neither', () => {
    assert.equal(isNoBoxStats({ status: 404 }), true)
    assert.equal(isNoBoxStats({ status: 501 }), true)
    assert.equal(isNoBoxStats({ status: 500 }), false)
    assert.equal(isNoBoxStats(null), false)
    assert.equal(isBoxStatsForbidden({ status: 403 }), true)
    assert.equal(isBoxStatsForbidden({ status: 404 }), false)
  })
  it('an absent or partial body reads as empty lists', () => {
    assert.deepEqual(boxStatsOf(null), { rows: [], hours: [] })
    assert.deepEqual(boxStatsOf({ rows: [{ box: 'box-a' }] }).hours, [])
  })
  it('the newest sample of the box wins, other boxes ignored', () => {
    const rows = [
      { box: 'box-a', at: '2026-10-04T10:00:00Z', cpus: 4 },
      { box: 'box-b', at: '2026-10-04T12:00:00Z', cpus: 8 },
      { box: 'box-a', at: '2026-10-04T11:00:00Z', cpus: 6 },
    ]
    assert.equal(latestBoxStat(rows, 'box-a').cpus, 6)
    assert.equal(latestBoxStat(rows, 'box-c'), null)
    assert.equal(latestBoxStat([], 'box-a'), null)
  })
  it('disks: absent until rdb 0118 (read as []), sorted by mount when served', () => {
    assert.deepEqual(boxDisksOf({ box: 'box-a' }), [])
    assert.deepEqual(boxDisksOf(null), [])
    assert.deepEqual(
      boxDisksOf({ disks: [{ mount: '/var', total_kb: 2048, avail_kb: 1024 }, { mount: '/', total_kb: 4096, avail_kb: 100 }, { total_kb: 1 }] }),
      [{ mount: '/', totalKB: 4096, availKB: 100 }, { mount: '/var', totalKB: 2048, availKB: 1024 }],
    )
  })
  it('the hardware summary is sample-weighted; none without hours', () => {
    assert.equal(hardwareSummary([]), null)
    const s = hardwareSummary([
      { n: 1, load1_avg: 1, load1_peak: 2, mem_used_peak_kb: 100, mem_avail_min_kb: 50 },
      { n: 3, load1_avg: 3, load1_peak: 5, mem_used_peak_kb: 300, mem_avail_min_kb: 20 },
    ])
    assert.deepEqual(s, { samples: 4, load1Avg: 2.5, load1Peak: 5, memUsedPeakKB: 300, memAvailMinKB: 20 })
  })
})

describe('the current state (latest sample)', () => {
  it('none without a sample', () => assert.equal(currentOf(null), null))
  it('load vs cpus, memory used / free, swap, live agents, its time', () => {
    assert.deepEqual(currentOf({ at: '2026-10-04T12:00:00Z', load1: 1.5, cpus: 8, mem_total_kb: 1000, mem_avail_kb: 400, swap_used_kb: 10, agents_live: 3 }),
      { at: '2026-10-04T12:00:00Z', load1: 1.5, cpus: 8, memUsedKB: 600, memAvailKB: 400, swapUsedKB: 10, agentsLive: 3 })
  })
})

describe('OS and run-times from the hello', () => {
  it('none until the hub serves them', () => {
    assert.equal(boxOsOf({ online: true }), null)
    assert.equal(boxOsOf(null), null)
    assert.equal(boxOsOf({ os: {} }), null)
    assert.deepEqual(boxRuntimesOf({ online: true }), [])
    assert.deepEqual(boxRuntimesOf({ runtimes: ['go'] }), [])
  })
  it('as served: os fields, run-times sorted by name', () => {
    assert.deepEqual(boxOsOf({ os: { name: 'Debian', version: '13', kernel: '6.12', arch: 'amd64' } }),
      { name: 'Debian', version: '13', pretty: '', kernel: '6.12', arch: 'amd64' })
    assert.equal(osLine(boxOsOf({ os: { name: 'Debian', version: '13', pretty: 'Debian 13 (trixie)' } })), 'Debian 13 (trixie)')
    assert.equal(osLine(boxOsOf({ os: { name: 'Debian', version: '13' } })), 'Debian 13')
    assert.equal(osLine(boxOsOf({ os: { kernel: '6.12' } })), '6.12')
    assert.equal(osLine(null), '')
    assert.deepEqual(boxRuntimesOf({ runtimes: { node: '20.19', go: '1.24', docker: '' } }),
      [{ name: 'docker', version: '' }, { name: 'go', version: '1.24' }, { name: 'node', version: '20.19' }])
  })
})

describe('system and network snapshot (c-220 field names)', () => {
  it('none until reported', () => {
    assert.equal(boxSystemOf({}), null)
    assert.equal(boxNetworkOf({ network: 'x' }), null)
    assert.equal(factsReportedAt({}), '')
  })
  it('as served; a missing number stays null, not 0', () => {
    const s = boxSystemOf({ system: { hostname: 'h1', cpus: 8, mem_total_mb: 1024, state: 'degraded' } })
    assert.equal(s.hostname, 'h1')
    assert.equal(s.cpus, 8)
    assert.equal(s.memTotalMB, 1024)
    assert.equal(s.memAvailMB, null)
    assert.equal(s.state, 'degraded')
    assert.deepEqual(boxNetworkOf({ network: { ips: ['192.0.2.1', ''], dns: ['192.0.2.53'] } }), { ips: ['192.0.2.1'], gateway: '', dns: ['192.0.2.53'] })
    assert.equal(factsReportedAt({ facts_reported_at: '2026-10-04T00:00:00Z' }), '2026-10-04T00:00:00Z')
  })
})

describe('agents statistics', () => {
  const agents = [
    { id: 'GRK-03', label: 'GRK-03@box-a', online: false },
    { id: 'CLE-07', label: 'CLE-07@box-a', online: true },
    { id: 'AGY-02', label: 'AGY-02@box-a', online: true },
  ]
  it('online first then by id, with seated_at and the box hello', () => {
    const rows = agentStatRows(agents, { last_hello_at: '2026-10-04T10:00:00Z', seated_at: { 'CLE-07': '2026-10-01T00:00:00Z' } })
    assert.deepEqual(rows.map((r) => r.id), ['AGY-02', 'CLE-07', 'GRK-03'])
    assert.equal(rows[1].seatedAt, '2026-10-01T00:00:00Z')
    assert.equal(rows[0].seatedAt, '')
    assert.equal(rows[2].lastHello, '2026-10-04T10:00:00Z')
    assert.deepEqual(agentCounts(rows), { total: 3, online: 2, offline: 1 })
  })
  it('agent_presence (live) wins over the roster dot and the box hello', () => {
    const rows = agentStatRows(agents, {
      last_hello_at: '2026-10-04T10:00:00Z',
      agent_presence: { 'GRK-03': { state: 'online', last_seen: '2026-10-04T11:00:00Z' }, 'CLE-07': { state: 'offline', last_seen: null } },
    })
    const by = Object.fromEntries(rows.map((r) => [r.id, r]))
    assert.equal(by['GRK-03'].online, true)
    assert.equal(by['GRK-03'].lastHello, '2026-10-04T11:00:00Z')
    assert.equal(by['CLE-07'].online, false)
    assert.equal(by['CLE-07'].lastHello, '')
    assert.equal(by['AGY-02'].lastHello, '2026-10-04T10:00:00Z')
  })
  it('no detail: still one row per agent', () => {
    assert.equal(agentStatRows(agents, null).length, 3)
    assert.deepEqual(agentCounts([]), { total: 0, online: 0, offline: 0 })
  })
})

describe('formatting', () => {
  it('sizes, loads and ages', () => {
    assert.equal(formatKB(512), '512 KiB')
    assert.equal(formatKB(16384), '16 MiB')
    assert.equal(formatKB(1536), '1.5 MiB')
    assert.equal(formatKB(33554432), '32 GiB')
    assert.equal(formatKB(-1), '')
    assert.equal(formatMB(32768), '32 GiB')
    assert.equal(formatMB(null), '')
    assert.equal(formatLoad(1.234), '1.23')
    assert.equal(formatLoad(undefined), '')
    const now = Date.parse('2026-10-04T12:00:00Z')
    assert.equal(ageOf('2026-10-04T11:59:15Z', now), '45s')
    assert.equal(ageOf('2026-10-04T11:48:00Z', now), '12m')
    assert.equal(ageOf('2026-10-04T09:00:00Z', now), '3h')
    assert.equal(ageOf('2026-09-29T12:00:00Z', now), '5d')
    assert.equal(ageOf('', now), '')
  })
})
