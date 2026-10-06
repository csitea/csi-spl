// csi-spl-wui/src/utils/move-mock.mjs
//
// SPL-1024: the lde mock tenant's move (utils/spool-client.mjs, mock: true).
// Loaded on the first mock move only, so it never weighs on a deployed
// bundle's initial JS.

import { isoSeconds } from './iso-seconds.mjs'
import { isAgentId } from './agent-id.mjs'

/**
 * SPL-1024: the lde mock's move, with the hub's refusals (move-v1 §2/§3)
 * and the author-only gate (the mock viewer has no role; an agent's reply
 * moves for anyone, as on the hub's mayReply), so the browser
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
  // Each mock op stamps its own now, so one move's rows can differ by a second.
  const at = isoSeconds()
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
  /* a DM row leaves its DM only when an agent sent it to the viewer (the hub's dmOut) */
  const dmOut = !row.channel && isAgentId(row.from) && row.to === state.me.id
  if ((!row.channel && !dmOut) || !card.channel) throw fail(409, 'not_in_channel')
  if (isLobby(row.channel) || isLobby(card.channel)) throw fail(409, 'lobby')
  if (row.from !== state.me.id && !isAgentId(row.from)) throw fail(403, 'not_allowed')
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

/**
 * 714c7028: the lde mock's topic merge and its undo, with the hub's refusals so
 * the browser e2e drives the whole path (drag, confirm, undo) without a hub. A
 * merge folds every row of the source topic into the target task, demotes the
 * opener to a reply and stamps the move columns; the undo puts them back and
 * re-seats the card.
 */
export function mockMergeTopic(state, id, body) {
  const fail = (status, token) => Object.assign(new Error(token), { status, token })
  const norm = (c) => String(c || '').replace(/^#/, '').toLowerCase()
  const isLobby = (c) => norm(c) === 'lobby' || norm(c) === 'general'
  const isCard = (m) => m.is_parent !== 0 && !m.parent_task_id
  // Each mock op stamps its own now, so one move's rows can differ by a second.
  const at = isoSeconds()
  const row = state.messages.find((m) => m.msg_id === id)
  if (!row) throw fail(404, 'not_found')

  if (body.undo) {
    const ids = new Set((body.undo.msg_ids || []).map(String))
    const from = String(body.undo.from_task || '')
    for (const m of state.messages) {
      if (!ids.has(String(m.msg_id))) continue
      if (m.moved_from_task) { m.task_id = m.moved_from_task; m.parent_task_id = m.moved_from_parent || null }
      if (m.moved_from_channel) m.channel = m.moved_from_channel
      delete m.moved_at; delete m.moved_by; delete m.moved_from_channel
      delete m.moved_from_task; delete m.moved_from_parent
    }
    row.is_parent = 1
    return { kind: 'unmerge', msg_id: id, task_id: from, from_task: String(row.task_id || ''),
      channel: norm(row.channel), unmerged: ids.size, moved_by: state.me.id, msg_ids: [...ids] }
  }

  const to = String(body.to_task || '')
  const srcTask = String(row.task_id || '')
  if (!isCard(row)) throw fail(409, 'not_a_card')
  if (!row.channel) throw fail(409, 'not_in_channel')
  if (isLobby(row.channel)) throw fail(409, 'lobby')
  if (to === srcTask) throw fail(409, 'same_place')
  const inTask = state.messages.filter((m) => m.task_id === to)
  if (!inTask.length) throw fail(404, 'not_found')
  const card = inTask.find(isCard)
  if (!card) throw fail(409, 'not_a_card')
  if (!card.channel) throw fail(409, 'not_in_channel')
  if (isLobby(card.channel)) throw fail(409, 'lobby')
  if (row.from !== state.me.id) throw fail(403, 'not_allowed')
  const rows = state.messages.filter((m) => m.task_id === srcTask || m.parent_task_id === srcTask || m.task_id === id)
  if (rows.some((m) => m.task_id === to)) throw fail(409, 'cycle')
  const fromChannel = norm(row.channel)
  for (const m of rows) {
    if (!m.moved_from_task) { m.moved_from_task = String(m.task_id || ''); m.moved_from_parent = m.parent_task_id || null }
    if (!m.moved_from_channel) m.moved_from_channel = norm(m.channel)
    if (m.task_id === srcTask) { m.task_id = to; m.parent_task_id = null; m.is_parent = 0 }
    else if (m.parent_task_id === srcTask) m.parent_task_id = to
    m.channel = norm(card.channel)
    m.moved_at = at
    m.moved_by = state.me.id
  }
  return { kind: 'merge', msg_id: id, task_id: to, from_task: srcTask, channel: norm(card.channel), from_channel: fromChannel,
    merged: rows.length, moved_by: state.me.id, moved_at: at, msg_ids: rows.map((m) => m.msg_id),
    undo: { from_task: srcTask, msg_ids: rows.map((m) => m.msg_id) } }
}

/**
 * 8f588edd: the lde mock's promote and its undo, with the hub's refusals so the
 * browser e2e drives the whole path (drag into the topics list, menu, undo)
 * without a hub. A promote makes a reply the opening card of a NEW topic (a
 * fresh task id, in the reply's own channel), its sub-thread moving with it;
 * the undo re-seats it as a reply. The mock mints the task id the hub mints.
 */
export function mockPromoteTopic(state, id, body) {
  const fail = (status, token) => Object.assign(new Error(token), { status, token })
  const norm = (c) => String(c || '').replace(/^#/, '').toLowerCase()
  const isLobby = (c) => norm(c) === 'lobby' || norm(c) === 'general'
  const isCard = (m) => m.is_parent !== 0 && !m.parent_task_id
  // Each mock op stamps its own now, so one move's rows can differ by a second.
  const at = isoSeconds()
  const mint = () => (typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : 'mock-' + Math.abs(Date.parse(at)).toString(16) + '-' + id.slice(0, 8))
  const row = state.messages.find((m) => m.msg_id === id)
  if (!row) throw fail(404, 'not_found')

  if (body.undo) {
    const ids = new Set((body.undo.msg_ids || []).map(String))
    const home = String(row.moved_from_task || '')
    for (const m of state.messages) {
      if (!ids.has(String(m.msg_id))) continue
      if (m.moved_from_task) { m.task_id = m.moved_from_task; m.parent_task_id = m.moved_from_parent || null }
      if (m.moved_at && m.moved_from_channel) m.channel = m.moved_from_channel
      delete m.moved_at; delete m.moved_by; delete m.moved_from_channel
      delete m.moved_from_task; delete m.moved_from_parent
    }
    row.is_parent = 0
    return { kind: 'demote', msg_id: id, task_id: home, from_task: String(body.undo.from_task || ''),
      channel: norm(row.channel), from_channel: norm(row.channel), msg_ids: [...ids] }
  }

  const srcTask = String(row.parent_task_id || row.task_id || '')
  if (isCard(row)) throw fail(409, 'is_card')
  if (!row.channel) throw fail(409, 'not_in_channel')
  if (isLobby(row.channel)) throw fail(409, 'lobby')
  if (row.from !== state.me.id && !isAgentId(row.from)) throw fail(403, 'not_allowed')
  const newTask = mint()
  const fromChannel = norm(row.channel)
  const thread = state.messages.filter((m) => m.task_id === id && m.parent_task_id === srcTask)
  for (const m of [row, ...thread]) {
    if (!m.moved_from_task) { m.moved_from_task = String(m.task_id || ''); m.moved_from_parent = m.parent_task_id || null }
  }
  if (!row.moved_from_channel) row.moved_from_channel = fromChannel
  row.task_id = newTask
  row.parent_task_id = null
  row.is_parent = 1
  row.moved_at = at
  row.moved_by = state.me.id
  for (const m of thread) m.parent_task_id = newTask
  return { kind: 'promote', msg_id: id, task_id: newTask, from_task: srcTask, channel: fromChannel, from_channel: fromChannel,
    moved_by: state.me.id, moved_at: at, received_at: row.received_at || row.ts, msg_ids: [id, ...thread.map((m) => m.msg_id)],
    undo: { from_task: newTask, msg_ids: [id, ...thread.map((m) => m.msg_id)] } }
}
