// perf-fixture.mjs — the seeded large tenant the WUI perf runner measures
// (perf round 6 row 12, SPL-2051).
//
// WHY: the mock tenant (utils/mock-data.mjs) has 1 issue, 3 channels and 1-3
// messages per feed, so a change that only pays off on a real-sized tenant
// (windowed issue rows, feed transitions, a long channel list) measures 0 on
// it. This module builds a bigger tenant on top of the mock one, the same
// way on every run, and never edits mock-data.mjs (round 13 row 08 owns it):
//
//   • ISSUES    the mock's own hook `spool.mock.issues-seed` (utils/issues.mjs)
//               adds SPL-2 .., so /issues lists PERF_FIXTURE.issues rows (the
//               mock's own SPL-1 is an epic, which the list shows no row for)
//   • MESSAGES  the mock's own hook `spool.mock.extra-messages`
//               (utils/spool-client.mjs) adds PERF_FIXTURE.messages feed rows
//   • CHANNELS  the mock has no channel hook, so the runner rewrites the one
//               mock-data chunk in flight (patchMockChannels): the minified
//               MOCK_CHANNELS literal gains PERF_FIXTURE.channels rows. The
//               anchor is checked; a bundle without it fails loudly instead of
//               measuring the small tenant under the large tenant's name.
//
// Deterministic: no clock, no random. The same counts give byte-equal output.

export const PERF_FIXTURE = Object.freeze({ issues: 300, messages: 30, channels: 20 })

const T0 = Date.parse('2026-09-18T11:00:00Z')
const SENDERS = [
  { from: 'CLE-07', from_box: 'box-a' },
  { from: 'GRK-03', from_box: 'box-a' },
  { from: 'HUM-2', from_box: 'box-wui' },
  { from: 'AGY-02', from_box: 'box-b' },
]
const KINDS = ['note', 'task', 'result', 'note', 'msg']
const BODIES = [
  (k) => `Fixture line ${k}: the build on box-a is green.`,
  (k) => `Fixture task ${k}: **review** the change and keep \`pnpm test:unit\` green.`,
  (k) => `Fixture result ${k}:\n\n- step one done\n- step two done\n- step three done`,
  (k) => `Fixture note ${k} with a longer body so the card wraps over more than one line at the phone width, the way a real report does.`,
]

/* the minified MOCK_CHANNELS literal ends with this row (mock-data.mjs) */
export const MOCK_CHANNELS_ANCHOR = '{channel_id:"feedback",name:"feedback",created_by:"hub"}'

const pad = (n, w) => String(n).padStart(w, '0')
/** a v4-shaped uuid from a 1-digit lane and a counter */
const fixtureId = (lane, k) => `f${lane}${pad(k, 6)}-0000-4000-8000-${pad(k, 12)}`

/** The fixture's channel rows: perf-01 .. perf-<n>. */
export function perfChannels(n = PERF_FIXTURE.channels) {
  return Array.from({ length: n }, (_, i) => ({ channel_id: `perf-${pad(i + 1, 2)}`, name: `perf-${pad(i + 1, 2)}`, created_by: 'HUM-1' }))
}

/**
 * The fixture's feed rows: half in #lobby, half in #alerts (the routes the
 * runner opens), one root each, a fixed minute apart after the mock's lines.
 */
export function perfMessages(n = PERF_FIXTURE.messages) {
  return Array.from({ length: n }, (_, i) => {
    const k = i + 1
    return {
      v: 1,
      msg_id: fixtureId(0, k),
      task_id: fixtureId(1, k),
      ts: new Date(T0 + k * 60000).toISOString(),
      ...SENDERS[i % SENDERS.length],
      to: '@channel',
      to_box: 'box-wui',
      kind: KINDS[i % KINDS.length],
      body: BODIES[i % BODIES.length](k),
      files: [],
      channel: i % 2 ? 'alerts' : 'lobby',
      parent_task_id: null,
    }
  })
}

/** localStorage the page must hold before it boots, as { key: string }. */
export function perfStorage(fx = PERF_FIXTURE) {
  return {
    'spool.mock.issues-seed': String(fx.issues),
    'spool.mock.extra-messages': JSON.stringify(perfMessages(fx.messages)),
  }
}

/** True when `source` is the mock-data chunk this fixture can extend. */
export function isMockChannelsChunk(source) {
  return String(source).includes(MOCK_CHANNELS_ANCHOR)
}

/** The mock-data chunk with the fixture's channels appended to MOCK_CHANNELS; throws unless the anchor is there once. */
export function patchMockChannels(source, n = PERF_FIXTURE.channels) {
  const text = String(source)
  const at = text.indexOf(MOCK_CHANNELS_ANCHOR)
  if (at < 0 || text.indexOf(MOCK_CHANNELS_ANCHOR, at + 1) >= 0) {
    throw new Error(`perf fixture: MOCK_CHANNELS anchor found ${at < 0 ? '0 times' : 'more than once'}; did mock-data.mjs change?`)
  }
  const rows = perfChannels(n).map((c) => `{channel_id:${JSON.stringify(c.channel_id)},name:${JSON.stringify(c.name)},created_by:"HUM-1"}`)
  const end = at + MOCK_CHANNELS_ANCHOR.length
  return `${text.slice(0, end)},${rows.join(',')}${text.slice(end)}`
}
