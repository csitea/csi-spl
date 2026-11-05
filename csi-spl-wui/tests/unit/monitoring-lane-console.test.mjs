// Spec 153 3.20 (SPL-4810; owner HUM-10, t1 27162335): a lane's live
// console, the util under the lane dialog (src/utils/monitoring-lane-console.mjs):
// the hub body as the feed, the routes, the saved file's name and text, the
// mock's doors; and the page rules: the row opens a LAZY dialog (never in the
// Lanes page's chunk), the Console button lives only inside the dialog.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  CONSOLE_POLL_MS,
  CONSOLE_WATCH_MS,
  laneConsoleFileName,
  laneConsoleFileText,
  laneConsoleOf,
  laneConsolePath,
  laneConsoleQuery,
  mockLaneConsole,
} from '../../src/utils/monitoring-lane-console.mjs'
import { LANES_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-lanes.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const store = (o) => ({ getItem: (k) => (k in o ? o[k] : null) })

describe('lane console: the hub body as the feed', () => {
  it('a capture is live, its redactions summed over the kinds', () => {
    const f = laneConsoleOf({ state: 'live', screen: 'a\nb', lines: 2, redactions: { 'github-token': 2, 'private-key': 1 }, captured_at: '2026-11-04T18:00:00Z', age_s: 3 })
    assert.deepEqual(f, { state: 'live', screen: 'a\nb', lines: 2, redacted: 3, capturedAt: '2026-11-04T18:00:00Z', ageS: 3 })
  })
  it('no capture yet, an unknown state or junk reads as waiting with no screen', () => {
    for (const b of [null, 'x', {}, { state: 'weird', screen: 5, redactions: 'x' }]) {
      const f = laneConsoleOf(b)
      assert.equal(f.state, 'waiting')
      assert.equal(f.screen, '')
      assert.equal(f.redacted, 0)
    }
  })
  it('the poll reads every 2 s and renews the watch well inside the hub\'s 60 s', () => {
    assert.equal(CONSOLE_POLL_MS, 2000)
    assert.ok(CONSOLE_WATCH_MS <= 30000)
  })
})

describe('lane console: the routes', () => {
  it('the operator door and the workspace door, as the Lanes tab reads', () => {
    assert.equal(laneConsolePath(false), '/v1/operator/lane-console')
    assert.equal(laneConsolePath(true), '/v1/lanes/console')
    assert.equal(laneConsoleQuery('c-085', 'box-a'), '?agent_id=c-085&agent_box=box-a')
    assert.equal(laneConsoleQuery('c-085', ''), '?agent_id=c-085&agent_box=')
  })
})

describe('lane console: Save', () => {
  it('names the file <agent>@<box>-<UTC>.txt, the box left out when not given', () => {
    const at = new Date('2026-11-04T18:05:09.123Z')
    assert.equal(laneConsoleFileName('c-085', 'box-a', at), 'c-085@box-a-20261104T180509Z.txt')
    assert.equal(laneConsoleFileName('c-085', '', at), 'c-085-20261104T180509Z.txt')
    assert.equal(laneConsoleFileName('c/../x', 'b x', at), 'c_.._x@b_x-20261104T180509Z.txt')
  })
  it('the text is exactly the shown lines, one newline at the end', () => {
    assert.equal(laneConsoleFileText('a\nb'), 'a\nb\n')
    assert.equal(laneConsoleFileText('a\nb\n\n'), 'a\nb\n')
    assert.equal(laneConsoleFileText(''), '')
  })
})

describe('lane console: the mock', () => {
  it('the operator door answers the mock operator admin only, else the hub\'s 403', () => {
    assert.throws(() => mockLaneConsole({ own: false, watch: false, agentId: 'c-085', agentBox: 'box-a' }, store({})), (e) => e.status === 403)
    const b = mockLaneConsole({ own: false, watch: false, agentId: 'c-085', agentBox: 'box-a' }, store({ [LANES_MOCK_OPERATOR_KEY]: '1' }))
    assert.equal(b.state, 'live')
    assert.match(b.screen, /<redacted:github-token>/)
  })
  it('the workspace door answers a mock owner or admin only', () => {
    const me = (role) => store({ 'spool.mock.me': JSON.stringify({ role, permissions: [] }) })
    assert.throws(() => mockLaneConsole({ own: true, watch: false, agentId: 'c-085', agentBox: '' }, me('member')), (e) => e.status === 403)
    assert.equal(mockLaneConsole({ own: true, watch: false, agentId: 'c-085', agentBox: '' }, me('biz_owner')).agent_box, '')
  })
  it('the first watch of a lane waits; the reads after it are the capture', () => {
    const s = store({ [LANES_MOCK_OPERATOR_KEY]: '1' })
    const q = { own: false, agentId: 'c-777', agentBox: 'box-z' }
    assert.equal(mockLaneConsole({ ...q, watch: true }, s).state, 'waiting')
    assert.equal(mockLaneConsole({ ...q, watch: false }, s).state, 'live')
  })
})

describe('lane console: the page rules', () => {
  const page = read('src/pages/monitoring/lanes/index.vue')
  const dialog = read('src/components/monitoring/LaneDialog.vue')
  it('the row opens the dialog, loaded lazily (never a static import of it)', () => {
    assert.match(page, /data-test="lanes-open"[^>]*@click="openLane\(l\)"/)
    assert.match(page, /defineAsyncComponent\(\(\) => import\('~\/components\/monitoring\/LaneDialog\.vue'\)\)/)
    assert.doesNotMatch(page, /^import .*LaneDialog/m)
  })
  it('the Console button lives only inside the dialog', () => {
    assert.doesNotMatch(page, /lane-console-toggle/)
    assert.match(dialog, /data-test="lane-console-toggle"/)
    assert.match(dialog, /<UiDialog /)
  })
  it('every console key the dialog names is in en.json', () => {
    const en = JSON.parse(read('i18n/locales/en.json'))
    const keys = [...(dialog + page).matchAll(/t\('monitoring\.lanes\.console\.([a-z_]+)'/g)].map((m) => m[1])
    assert.ok(keys.length >= 10)
    for (const k of keys) assert.ok(en.monitoring.lanes.console[k], k)
  })
})
