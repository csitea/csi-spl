/** lde mock tenant. No product hostname. */

const T0 = '2026-09-18T10:00:00Z'

export const MOCK_ME = { id: 'HUM-1', box: 'box-wui', display: 'HUM-1@box-wui' }

export const MOCK_CHANNELS = [
  { channel_id: 'general', name: 'general', created_by: 'HUM-1' },
  { channel_id: 'tasks', name: 'tasks', created_by: 'HUM-1' },
  { channel_id: 'alerts', name: 'alerts', created_by: 'HUM-1' },
]

export const MOCK_ROSTER = {
  'box-a': ['CLE-07', 'GRK-03'],
  'box-b': ['CLE-07', 'AGY-02'],
  'box-wui': ['HUM-1'],
}

export const MOCK_ONLINE = ['CLE-07@box-a', 'GRK-03@box-a', 'HUM-1@box-wui']

function msg(partial) {
  return {
    v: 1,
    files: [],
    channel: 'general',
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
    body: 'Welcome to **#general**. This is the lde mock feed.',
    channel: 'general',
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
    channel: 'tasks',
  }),
  msg({
    msg_id: '33333333-3333-4333-8333-333333333333',
    task_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
    ts: '2026-09-18T10:02:00Z',
    from: 'CLE-07',
    to: 'HUM-1',
    kind: 'note',
    body: 'Applying patch',
    channel: 'tasks',
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
    channel: 'tasks',
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
    channel: 'tasks',
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
]

export function cloneMock() {
  return {
    me: { ...MOCK_ME },
    channels: MOCK_CHANNELS.map((c) => ({ ...c })),
    roster: JSON.parse(JSON.stringify(MOCK_ROSTER)),
    online: MOCK_ONLINE.slice(),
    messages: MOCK_MESSAGES.map((m) => ({ ...m, files: (m.files || []).map((f) => ({ ...f })) })),
  }
}
