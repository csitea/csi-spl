/** lde mock tenant. No product hostname. */

const T0 = '2026-09-18T10:00:00Z'

/* The lde mock #lobby id (the welcome topic below) is MOCK_LOBBY_TASK_ID in
   mock-ids.mjs, apart so the live first screen does not load this file. */

export const MOCK_ME = { id: 'HUM-1', box: 'box-wui', display: 'HUM-1@box-wui' }

export const MOCK_CHANNELS = [
  { channel_id: 'lobby', name: 'lobby', created_by: 'HUM-1' },
  { channel_id: 'alerts', name: 'alerts', created_by: 'HUM-1' },
  { channel_id: 'feedback', name: 'feedback', created_by: 'hub' },
]

export const MOCK_ROSTER = {
  'box-a': ['CLE-07', 'GRK-03'],
  'box-b': ['CLE-07', 'AGY-02'],
  // CLE-77799: a third machine box, so the Boxes section shows more than one
  // (owner: "later on we will have more boxes than the current one box").
  'box-desk': ['CLE-11'],
  // HUM-1 is the viewer; the others are tenant members to invite.
  'box-wui': ['HUM-1', 'HUM-2', 'HUM-12', 'HUM-3'],
}

export const MOCK_ONLINE = ['CLE-07@box-a', 'GRK-03@box-a', 'CLE-11@box-desk', 'HUM-1@box-wui']

/* CLE-77794: the People section's per-member detail (view-v1 §4.1 humans[]):
   owner flag, free-text interests and last_seen. No display_name here (the card
   draws the id via HumanName) and no personal names (dist hygiene). */
export const MOCK_HUMANS = [
  { human_id: 'HUM-1', owner: true, interests: 'Go, Postgres, mountain biking', last_seen: T0 },
  { human_id: 'HUM-2', interests: 'Type systems, tea gardens' },
  { human_id: 'HUM-12' },
  { human_id: 'HUM-3', interests: 'Distributed systems, trail running' },
]

/* HUM-10 (t1 f77c9f87, d1d9bcd3): the box facts the hub serves on boxes[]
   (c-220's field names). Only box-desk reported them, so the Boxes page shows
   both a reported box and an unreported one (box-a, box-b: "not reported
   yet"). Documentation-range addresses (RFC 5737), a generic hostname. */
const MOCK_DESK_FACTS = {
  os: { name: 'Debian GNU/Linux', version: '13', pretty: 'Debian GNU/Linux 13 (trixie)', kernel: '6.12.0-cloud-amd64', arch: 'x86_64' },
  runtimes: { go: '1.24.4', node: '20.19.2', git: '2.47.2', docker: '28.3.0', claude: '2.1.0', spool: 'v8.9.5' },
  system: {
    hostname: 'desk-01', timezone: 'UTC', boot_at: '2026-09-15T08:00:00Z', cpus: 8, cpu_model: 'Example CPU @ 2.20GHz',
    load: '0.42 0.37 0.30', mem_total_mb: 32768, mem_avail_mb: 20480, swap_total_mb: 2048, swap_free_mb: 1536, state: 'running',
  },
  network: { ips: ['192.0.2.10', '198.51.100.7'], gateway: '192.0.2.1', dns: ['192.0.2.53'] },
  facts_reported_at: T0,
  agent_presence: { 'CLE-11': { state: 'online', last_seen: T0 } },
}

/* HUM-10 (owner ba10751d, "present also the current info"): box-desk's latest
   box-stats sample (GET /v1/tenant/box-stats rows), the Boxes page's "Now".
   The other boxes have none, so their "no current sample yet" shows too. */
export const MOCK_BOX_STATS = [
  { box: 'box-desk', writer_box: 'box-desk', at: T0, load1: 1.25, load5: 0.9, load15: 0.7, cpus: 8, mem_total_kb: 33554432, mem_avail_kb: 20971520, swap_used_kb: 524288, agents_live: 1,
    disks: [{ mount: '/', total_kb: 104857600, avail_kb: 52428800 }, { mount: '/var', total_kb: 209715200, avail_kb: 10485760 }] },
]
/* the hub folds rows into one per (box, UTC hour); this is that fold. The
   09:00 hour is from before the hub reported disks (rdb 0121): no `disks`. */
export const MOCK_BOX_STAT_HOURS = [
  { box: 'box-desk', hour: '2026-09-18T09:00:00Z', n: 1, cpus: 8, load1_avg: 0.5, load1_peak: 0.5, mem_used_avg_kb: 8388608, mem_used_peak_kb: 8388608, mem_avail_min_kb: 25165824, agents_avg: 1, agents_peak: 1 },
  { box: 'box-desk', hour: '2026-09-18T10:00:00Z', n: 1, cpus: 8, load1_avg: 1.25, load1_peak: 1.25, mem_used_avg_kb: 12582912, mem_used_peak_kb: 12582912, mem_avail_min_kb: 20971520, agents_avg: 1, agents_peak: 1,
    disks: [{ mount: '/', total_kb: 104857600, avail_min_kb: 52428800 }, { mount: '/var', total_kb: 209715200, avail_min_kb: 10485760 }] },
]

/* CLE-77794: the Agents section's per-box detail (view-v1 §4.1 boxes[]):
   online and last_hello_at, so the card can show a box's liveness. */
export const MOCK_BOXES = [
  { box_id: 'box-a', online: true, last_hello_at: T0, agents: ['CLE-07', 'GRK-03'] },
  { box_id: 'box-b', online: false, last_hello_at: T0, agents: ['CLE-07', 'AGY-02'] },
  { box_id: 'box-desk', online: true, last_hello_at: T0, agents: ['CLE-11'], ...MOCK_DESK_FACTS },
]

/* CLE-77799: the act-as audit trail (GET /v1/audit/clones, specs/054 §7) the
   People-card Activity log reads. HUM-2 was acted-as twice (one ended, one
   live); the shape matches the hub's cloneAudit. */
export const MOCK_CLONES = [
  { clone_hum: 'HUM-2#c2', target_hum: 'HUM-2', created_by: 'HUM-1', role: 'developer', created_at: '2026-09-20T09:00:00Z', expires_at: '2026-09-20T10:00:00Z', ended_at: '2026-09-20T09:20:00Z', end_reason: 'stop' },
  { clone_hum: 'HUM-2#c1', target_hum: 'HUM-2', created_by: 'HUM-1', role: 'developer', created_at: '2026-09-18T12:00:00Z', expires_at: '2026-09-18T13:00:00Z', ended_at: null, end_reason: '' },
]

function msg(partial) {
  return {
    v: 1,
    files: [],
    channel: 'lobby',
    parent_task_id: null,
    from_box: 'box-a',
    to_box: 'box-wui',
    ...partial,
  }
}

export const MOCK_MESSAGES = [
  msg({
    msg_id: '11111111-1111-4111-8111-111111111111',
    task_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    ts: T0,
    from: 'HUM-1',
    from_box: 'box-wui',
    to: '@channel',
    kind: 'note',
    body: 'Welcome to **#lobby**. This is the lde mock feed.',
    channel: 'lobby',
  }),
  msg({
    msg_id: '22222222-2222-4222-8222-222222222222',
    task_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    ts: '2026-09-18T10:01:00Z',
    from: 'HUM-1',
    from_box: 'box-wui',
    to: 'CLE-07',
    kind: 'task',
    body: 'Review the spool WUI scaffold and keep tests green.',
    channel: 'lobby',
  }),
  msg({
    msg_id: '33333333-3333-4333-8333-333333333333',
    task_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    ts: '2026-09-18T10:02:00Z',
    from: 'CLE-07',
    to: 'HUM-1',
    kind: 'note',
    body: 'Applying patch',
    channel: 'lobby',
    parent_task_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  }),
  msg({
    msg_id: '44444444-4444-4444-8444-444444444444',
    task_id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
    ts: '2026-09-18T10:03:00Z',
    from: 'CLE-07',
    to: 'HUM-1',
    kind: 'note',
    body: '[verbose] ran `pnpm test:unit` — 2 files',
    channel: 'lobby',
    parent_task_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  }),
  msg({
    msg_id: '55555555-5555-4555-8555-555555555555',
    task_id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
    ts: '2026-09-18T10:04:00Z',
    from: 'CLE-07',
    to: 'HUM-1',
    kind: 'result',
    body: 'Scaffold is up. Tests green.',
    channel: 'lobby',
    parent_task_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
    files: [
      {
        file_id: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        name: 'wui-notes.md',
        bytes: 2048,
        sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      },
    ],
  }),
  msg({
    msg_id: '66666666-6666-4666-8666-666666666666',
    task_id: 'ffffffff-ffff-4fff-8fff-ffffffffffff',
    ts: '2026-09-18T10:05:00Z',
    from: 'GRK-03',
    to: '@channel',
    kind: 'note',
    body: 'box-b CLE-07 is online.',
    channel: 'alerts',
  }),
  msg({
    msg_id: '77777777-7777-4777-8777-777777777777',
    task_id: '99999999-9999-4999-8999-999999999999',
    ts: '2026-09-18T10:06:00Z',
    from: 'HUM-1',
    from_box: 'box-wui',
    to: 'GRK-03',
    kind: 'note',
    body: 'Direct ping — mock DM.',
    channel: null,
    to_box: 'box-a',
  }),
  /* CLE-77909: a reply in the DM's thread (rooted at the DM card above). A
     cold /m/<this id> must open the DM with the thread on it, never /t/. */
  msg({
    msg_id: '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a',
    task_id: '77777777-7777-4777-8777-777777777777',
    ts: '2026-09-18T10:06:30Z',
    from: 'GRK-03',
    from_box: 'box-a',
    to: 'HUM-1',
    kind: 'note',
    body: 'Mock DM reply, in the thread.',
    channel: null,
    to_box: 'box-wui',
    parent_task_id: '99999999-9999-4999-8999-999999999999',
  }),
  /* specs/036 FR-011: HUM-1 typed this at CLE-07's terminal; the hub verified
     it, so the lobby shows HUM-1 with a "via terminal CLE-07" badge. */
  msg({
    msg_id: '88888888-8888-4888-8888-888888888888',
    task_id: 'abababab-abab-4bab-8bab-abababababab',
    ts: '2026-09-18T10:07:00Z',
    from: 'CLE-07',
    to: '@channel',
    kind: 'note',
    body: 'Typed at the terminal: run the e2e again.',
    channel: 'lobby',
    typed_by: 'HUM-1',
  }),
]

export function cloneMock() {
  return {
    me: { ...MOCK_ME },
    channels: MOCK_CHANNELS.map((c) => ({ ...c })),
    roster: JSON.parse(JSON.stringify(MOCK_ROSTER)),
    online: MOCK_ONLINE.slice(),
    humans: MOCK_HUMANS.map((h) => ({ ...h })),
    boxes: MOCK_BOXES.map((b) => ({ ...b, agents: b.agents.slice() })),
    messages: MOCK_MESSAGES.map((m) => ({ ...m, files: (m.files || []).map((f) => ({ ...f })) })),
  }
}
