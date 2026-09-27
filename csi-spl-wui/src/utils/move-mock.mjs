// csi-spl-wui/src/utils/move-mock.mjs
//
// SPL-1024: the lde mock tenant's move (utils/spool-client.mjs, mock: true).
// Loaded on the first mock move only, so it never weighs on a deployed
// bundle's initial JS.

/**
 * SPL-1024: the lde mock's move, with the hub's refusals (move-v1 §2/§3)
 * and the author-only gate (the mock viewer has no role), so the browser
 * e2e drives the whole path (drag, menu, undo) without a hub. A mock reply
 * is its own task with parent_task_id = the topic; a card has neither.
 */
export function mockMove(state, id, body) {
  const fail = (status, token) => Object.assign(new Error(token), { status, token })
  const norm = (c) => String(c || '').replace(/^#/, '').toLowerCase()
  const isLobby = (c) => norm(c) === 'lobby' || norm(c) === 'general'
  const isCard = (m) => m.is_parent !== 0 && !m.parent_task_id
  const row = state.messages.find((m) => m.msg_id === id)
  if (!row) throw fail(404, 'not_found')
  const at = new Date().toISOString().replace(/\.\d+Z$/, 'Z')
  const stamp = (m, moved, fromChannel) => {
    if (moved) {
      m.moved_at = at
      m.moved_by = state.me.id
      if (!m.moved_from_channel) m.moved_from_channel = fromChannel
    } else {
      delete m.moved_at
      delete m.moved_by
      delete m.moved_from_channel
      delete m.moved_from_task
    }
  }
  if (body.to_channel) {
    const to = norm(body.to_channel)
    if (!isCard(row)) throw fail(409, 'not_a_card')
    if (!row.channel) throw fail(409, 'not_in_channel')
    if (isLobby(row.channel) || isLobby(to)) throw fail(409, 'lobby')
    if (to === 'issues' || !state.channels.some((c) => c.channel_id === to)) throw fail(404, 'unknown_channel')
    const from = norm(row.channel)
    if (to === from) throw fail(409, 'same_place')
    if (row.from !== state.me.id) throw fail(403, 'not_allowed')
    const home = norm(row.moved_from_channel || from)
    const rows = state.messages.filter((m) => m.task_id === row.task_id || m.parent_task_id === row.task_id || m.task_id === row.msg_id)
    for (const m of rows) {
      const was = norm(m.channel)
      m.channel = to
      stamp(m, to !== home, was)
    }
    return { kind: 'topic', msg_id: id, task_id: row.task_id, channel: to, from_channel: from, moved: to !== home,
      moved_by: state.me.id, moved_at: at, msg_ids: rows.map((m) => m.msg_id), undo: { to_channel: from } }
  }
  const to = String(body.to_task || '')
  if (isCard(row)) throw fail(409, 'is_card')
  const fromTask = String(row.parent_task_id || row.task_id || '')
  if (to === fromTask) throw fail(409, 'same_place')
  if (to === id) throw fail(409, 'cycle')
  const inTask = state.messages.filter((m) => m.task_id === to)
  if (!inTask.length) throw fail(404, 'not_found')
  const card = inTask.find(isCard)
  if (!card) throw fail(409, 'not_a_card')
  if (!row.channel || !card.channel) throw fail(409, 'not_in_channel')
  if (isLobby(row.channel) || isLobby(card.channel)) throw fail(409, 'lobby')
  if (row.from !== state.me.id) throw fail(403, 'not_allowed')
  const fromChannel = norm(row.channel)
  const home = String(row.moved_from_task || fromTask)
  const moved = to !== home
  row.task_id = to
  row.parent_task_id = null
  row.is_parent = 0
  row.channel = card.channel
  stamp(row, moved, fromChannel)
  if (moved && !row.moved_from_task) row.moved_from_task = fromTask
  const thread = state.messages.filter((m) => m.task_id === id)
  for (const m of thread) {
    const was = norm(m.channel)
    m.channel = card.channel
    stamp(m, moved, was)
  }
  return { kind: 'message', msg_id: id, task_id: to, from_task: fromTask, channel: norm(card.channel), from_channel: fromChannel,
    moved, moved_by: state.me.id, moved_at: at, received_at: row.received_at || row.ts, msg_ids: [id, ...thread.map((m) => m.msg_id)],
    undo: { to_task: fromTask } }
}
