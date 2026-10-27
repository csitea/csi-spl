// Spec 153 3.2 (build row B4, SPL-3215): Monitoring -> Lanes, the util under
// the page (src/utils/monitoring-lanes.mjs): the hub body as a view in the
// hub's order, the row's links, the 60 s poll on a fake clock (C18), the
// locale keys (C19), the mock's 403, and the page's chunk rules (C20: its own
// chunk, no :style, no page meta).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  LANES_MOCK_KEY,
  LANES_MOCK_OPERATOR_KEY,
  LANES_MOCK_TOPIC,
  LANES_POLL_MS,
  fleetLanesOf,
  laneIssuePath,
  laneName,
  laneTopicPath,
  lanesShouldFetch,
  lanesStaleLevel,
  minutesAgo,
  mockFleetLanes,
  startLanesPoll,
} from '../../src/utils/monitoring-lanes.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const store = (m) => ({ getItem: (k) => (k in m ? m[k] : null) })
const OP = { [LANES_MOCK_OPERATOR_KEY]: '1' }
const UUID = '5e7b15c9-2995-427d-8b05-659762fbb9d8'

describe('the fleet-lanes body as a view', () => {
  it('keeps the hub order and its fields; drops a row without an agent and an issue without a key', () => {
    const v = fleetLanesOf({ as_of: '2026-10-24T10:00:00Z', fleet: 'main', lanes: [
      { agent_id: 'c-002', agent_box: 'box-a', vendor: 'claude', scope: 's', topic_id: UUID, topic_title: 'T',
        issues: [{ key: 'SPL-1', status: 'wip' }, { status: 'done' }, null], updated_at: '2026-10-24T09:58:00Z', age_s: 120, last_active: '2026-10-24T09:59:00Z' },
      { agent_box: 'box-a' },
      { agent_id: 'c-001', agent_box: 'box-b', age_s: -5 },
    ] })
    assert.equal(v.asOf, '2026-10-24T10:00:00Z')
    assert.deepEqual(v.lanes.map((l) => l.agentId), ['c-002', 'c-001'], 'the hub order (newest write first), never re-sorted')
    assert.deepEqual(v.lanes[0].issues, [{ key: 'SPL-1', status: 'wip' }])
    assert.equal(v.lanes[1].ageS, 0, 'a junk age is 0, never negative')
    assert.deepEqual(v.lanes[1].issues, [])
    assert.deepEqual(fleetLanesOf(null), { asOf: '', fleet: '', lanes: [] })
  })
  it('spec 153 3.8 (C43, C44): keeps a queued ask with no agent, and every row its state and workspace', () => {
    const v = fleetLanesOf({ lanes: [
      { agent_id: 'c-002', workspace: 'w1', workspace_name: 'W one' },
      { state: 'queued', scope: 'QUEUE x', wait: '', workspace: 'w1', workspace_name: 'W one' },
      { state: 'live', scope: 'no agent, not queued' },
      { agent_id: 'c-003', workspace: 'w2' },
    ] })
    assert.deepEqual(v.lanes.map((l) => [l.agentId, l.state, l.workspaceName]),
      [['c-002', 'live', 'W one'], ['', 'queued', 'W one'], ['c-003', 'live', 'w2']], 'a row with no name shows its id')
    assert.equal(v.lanes[1].wait, '')
  })
  it('names the agent id@box', () => {
    assert.equal(laneName({ agentId: 'c-002', box: 'box-a' }), 'c-002@box-a')
    assert.equal(laneName({ agentId: 'c-002', box: '' }), 'c-002')
  })
})

describe('the row links (C17, 3.3)', () => {
  it('a titled topic of this workspace links /t/<uuid>', () => {
    assert.equal(laneTopicPath({ topicId: UUID, topicTitle: 'T' }), '/t/' + UUID)
  })
  it('CONTROL: an untitled topic (another workspace), an 8-hex short id or none links nothing', () => {
    assert.equal(laneTopicPath({ topicId: UUID, topicTitle: '' }), '')
    assert.equal(laneTopicPath({ topicId: '5e7b15c9', topicTitle: 'T' }), '')
    assert.equal(laneTopicPath({ topicId: '', topicTitle: '' }), '')
  })
  it('an issue with a status links /issues?issue=<KEY>; one without (a foreign key) does not', () => {
    assert.equal(laneIssuePath({ key: 'SPL-3215', status: 'wip' }), '/issues?issue=SPL-3215')
    assert.equal(laneIssuePath({ key: 'ACME-7', status: '' }), '')
    assert.equal(laneIssuePath({ key: 'spl 1', status: 'wip' }), '')
  })
  it('minutes ago against the answer time; none is null', () => {
    assert.equal(minutesAgo('2026-10-24T09:55:30Z', '2026-10-24T10:00:00Z'), 4)
    assert.equal(minutesAgo('', '2026-10-24T10:00:00Z'), null)
    assert.equal(minutesAgo('2026-10-24T09:55:30Z', ''), null)
  })
  it('the stale marks: amber after 90 s, red after 180 s (1.5x and 3x the minute)', () => {
    assert.equal(lanesStaleLevel(0), 'ok')
    assert.equal(lanesStaleLevel(90), 'ok')
    assert.equal(lanesStaleLevel(91), 'amber')
    assert.equal(lanesStaleLevel(181), 'red')
    assert.equal(lanesStaleLevel(NaN), 'red')
  })
})

describe('the poll (C18, decision P4)', () => {
  /** a fake clock and timer: advance(ms) fires the interval at each multiple of its period */
  function fake() {
    let t = 1_000_000
    let timer = null
    const c = {
      vis: 'visible',
      calls: [],
      now: () => t,
      setTimer: (fn, ms) => { timer = { fn, ms, next: t + ms }; return timer },
      clearTimer: () => { timer = null },
      advance(ms) {
        const end = t + ms
        while (timer && timer.next <= end) { t = timer.next; timer.next += timer.ms; timer.fn() }
        t = end
      },
    }
    c.start = () => startLanesPoll({ load: () => c.calls.push(t), visibility: () => c.vis, now: c.now, setTimer: c.setTimer, clearTimer: c.clearTimer })
    c.at = () => c.calls.map((x) => (x - 1_000_000) / 1000)
    return c
  }
  it('the minute is 60 s', () => assert.equal(LANES_POLL_MS, 60000))
  it('fetches at 0 s and 60 s, not at 30 s', () => {
    const c = fake()
    c.start()
    c.advance(30_000)
    assert.deepEqual(c.at(), [0], 'nothing at 30 s')
    c.advance(30_000)
    assert.deepEqual(c.at(), [0, 60])
    c.advance(60_000)
    assert.deepEqual(c.at(), [0, 60, 120])
  })
  it('none while hidden; shown again it catches up at once', () => {
    const c = fake()
    const p = c.start()
    c.vis = 'hidden'
    c.advance(180_000)
    assert.deepEqual(c.at(), [0], 'no call while the browser tab is hidden')
    c.advance(10_000)
    c.vis = 'visible'
    p.wake()
    assert.deepEqual(c.at(), [0, 190], 'the visibility hook catches up')
    p.wake()
    assert.deepEqual(c.at(), [0, 190], 'a second wake within the minute makes no call')
    c.advance(60_000)
    assert.deepEqual(c.at(), [0, 190, 250], 'the minute restarts at the catch-up')
  })
  it('CONTROL: a hidden tab at mount makes no call at all', () => {
    const c = fake()
    c.vis = 'hidden'
    c.start()
    c.advance(120_000)
    assert.deepEqual(c.at(), [])
  })
  it('Refresh fetches now and the minute counts from there; stop ends it', () => {
    const c = fake()
    const p = c.start()
    c.advance(20_000)
    p.refresh()
    c.advance(40_000)
    assert.deepEqual(c.at(), [0, 20], 'no call at 60 s: the minute counts from the refresh')
    c.advance(20_000)
    assert.deepEqual(c.at(), [0, 20, 80])
    p.stop()
    c.advance(300_000)
    assert.deepEqual(c.at(), [0, 20, 80])
  })
  it('never after a 403', () => {
    assert.equal(lanesShouldFetch({ visibilityState: 'visible', lastAt: 0, now: 1, forbidden: true }), false)
    assert.equal(lanesShouldFetch({ visibilityState: 'visible', lastAt: 0, now: 1 }), true)
  })
})

describe('the mock', () => {
  it('403 operator.workspaces unless the operator admin opted in', () => {
    assert.throws(() => mockFleetLanes(store({})), (e) => e.status === 403 && e.permission === 'operator.workspaces')
  })
  it('three lanes: a linked topic with issues, a foreign topic, none; then one queued ask', () => {
    const v = fleetLanesOf(mockFleetLanes(store(OP), new Date('2026-10-24T10:00:00Z')))
    assert.equal(v.lanes.length, 4)
    assert.deepEqual(v.lanes.map((l) => l.state), ['live', 'live', 'live', 'queued'])
    assert.ok(v.lanes.every((l) => l.workspaceName), 'every mock row names its workspace')
    assert.equal(laneTopicPath(v.lanes[0]), '/t/' + LANES_MOCK_TOPIC)
    assert.equal(laneTopicPath(v.lanes[1]), '')
    assert.equal(v.lanes[2].topicId, '')
    assert.deepEqual(fleetLanesOf(mockFleetLanes(store({ ...OP, [LANES_MOCK_KEY]: 'empty' }))).lanes, [])
  })
})

describe('locale keys (C19) and the chunk rules (C20)', () => {
  const page = read('src/pages/monitoring/lanes/index.vue')
  it('every key the page renders is in all 19 locales', () => {
    const keys = [...new Set([...page.matchAll(/\bt\('([a-z_.]+)'/g)].map((m) => m[1]))]
    assert.ok(keys.includes('monitoring.lanes.empty') && keys.length >= 10, keys.join(','))
    const locales = ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']
    for (const loc of locales) {
      const cat = JSON.parse(read('i18n/locales/' + loc + '.json'))
      const get = (key) => key.split('.').reduce((o, k) => (o == null ? o : o[k]), cat)
      for (const key of [...keys, 'monitoring.tab.lanes']) assert.equal(typeof get(key), 'string', loc + ': ' + key)
      /* 3.2: the tab reuses the locale's Reporting word; "updated" is Tokens' own key */
      assert.equal(get('monitoring.tab.lanes'), get('reporting.tab.lanes'), loc)
      assert.match(get('monitoring.lanes.min_ago'), /\{n\}/, loc)
    }
  })
  it('the page binds no :style (CSP), sets no page meta, and polls through the visibility-guarded helper', () => {
    assert.doesNotMatch(page, /:style=|v-bind:style/)
    assert.doesNotMatch(page, /useHead|useSeoMeta|definePageMeta/)
    assert.match(page, /startLanesPoll\(/)
    assert.match(page, /visibilitychange/)
  })
  it('the client call is lazy: the mock and the live route', () => {
    const lazy = read('src/utils/spool-client-lazy.mjs')
    assert.match(lazy, /live\('\/v1\/operator\/fleet-lanes'\)/)
    assert.match(lazy, /import\('\.\/monitoring-lanes\.mjs'\)\)\.mockFleetLanes\(\)/)
    assert.match(read('src/utils/spool-client.mjs'), /'getFleetLanes',/, 'the initial client carries the stub name only')
    /* nothing on the first screen imports the lanes util */
    for (const f of ['src/pages/monitoring.vue', 'src/utils/monitoring-tabs.mjs', 'src/utils/spool-client.mjs']) {
      assert.doesNotMatch(read(f), /monitoring-lanes/, f)
    }
  })
})
