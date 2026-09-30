// csi-spl-wui/src/utils/topic-archive.mjs
//
// SPL-983 (specs/041): Archive and Delete on a topic card. The hub decides
// every write (topic-archive-v1 §1); this file only decides what to OFFER and
// what a live frame drops from the screen.
//
// The owner, 2026-09-26: the card's author, the tenant owner and an admin may
// archive or delete; nobody else, and never an agent. An agent never runs a
// browser, so "never an agent" is the hub's; here the rule is the three roles.

/** Roles, besides the author, that may archive or delete any topic. */
export const TOPIC_ADMIN_ROLES = Object.freeze(['biz_owner', 'admin'])

/**
 * A card the menu may offer Archive / Delete on: a level-1 message that is
 * stored (not a pending echo). An absent is_parent is level 1 (spec 033:
 * the hub's default), so an old row still counts.
 */
export function isTopicCard(msg) {
  if (!msg || typeof msg !== 'object') return false
  if (msg.pending || !msg.msg_id) return false
  return msg.is_parent !== 0
}

/**
 * The topic's opening card among `messages` (a getTopic page, oldest first):
 * the earliest level-1 row, the row the hub treats as the opener (spec 041 §2
 * / resolveCard). A LATER is_parent 1 line - an agent's level-1 line in a
 * topic whose opener is gone - is not the opener and the hub refuses it
 * (409 not_a_card), so the card menu resolves to this id before it archives or
 * deletes, and acting on any card of a topic clears the topic. Falls back to
 * fallbackId when no row is a card.
 * @param {Array<{msg_id?: string, is_parent?: number}>} messages
 * @param {string} [fallbackId]
 * @returns {string}
 */
export function openingCardId(messages, fallbackId = '') {
  const rows = Array.isArray(messages) ? messages : []
  for (const m of rows) {
    if (m && m.msg_id && m.is_parent !== 0) return String(m.msg_id)
  }
  return String(fallbackId || '')
}

/**
 * The viewer may archive / delete this card: its author, the tenant owner or
 * an admin. `me` is utils/access.mjs normalizeMe (null = not loaded yet: then
 * only the author test answers, so a menu never offers what the hub refuses).
 */
export function mayChangeTopic(msg, viewerId, me) {
  if (!isTopicCard(msg)) return false
  const id = String(viewerId || '')
  if (id && String(msg.from || '') === id) return true
  if (!me || typeof me !== 'object') return false
  return me.tenantOwner === true || TOPIC_ADMIN_ROLES.includes(String(me.role || ''))
}

/**
 * The msg ids a live frame removes from the feeds on screen.
 * - topic_deleted: every row it names.
 * - topic_archived (archived: true): the card. Its replies stay held but the
 *   middle pane never draws a level-2 row, so the topic is gone from view.
 * - unarchive: nothing (the card comes back on the next read).
 */
export function topicFrameDrops(frame) {
  const f = frame && typeof frame === 'object' ? frame : {}
  if (f.type === 'topic_deleted') {
    const ids = Array.isArray(f.msg_ids) ? f.msg_ids.map(String).filter(Boolean) : []
    if (f.msg_id && !ids.includes(String(f.msg_id))) ids.unshift(String(f.msg_id))
    return ids
  }
  if (f.type === 'topic_archived' && f.archived === true && f.msg_id) return [String(f.msg_id)]
  return []
}

/**
 * The tasks a topic_deleted frame ends: an open pane on one of them has
 * nothing left to show. The lobby task is never one (spec §2).
 */
export function topicFrameTasks(frame, lobbyTaskId = '') {
  const f = frame && typeof frame === 'object' ? frame : {}
  const lobby = String(lobbyTaskId || '')
  // 714c7028: a merge empties the source topic (from_task) - a pane open on it
  // has nothing left to show; the target keeps its own pane.
  if (f.type === 'topic_merged') {
    const from = String(f.from_task || '')
    return from && from !== lobby ? [from] : []
  }
  if (f.type !== 'topic_deleted') return []
  const ids = Array.isArray(f.task_ids) ? f.task_ids.map(String) : []
  return ids.filter((id) => id && id !== lobby)
}

/** The catalogue key for a refused or failed archive / delete. */
export function topicErrorKey(e, scope = 'feed.topic_delete') {
  const tok = e && typeof e === 'object' && 'token' in e ? String(e.token || '') : ''
  if (tok === 'not_allowed' || tok === 'forbidden') return `${scope}.error_forbidden`
  // 409 not_a_card: the caller acted on a level-1 line that is not the topic's
  // opening card (spec 041 §2). Retrying will never pass, so name the reason
  // rather than the generic "try again" - point them at the opening card.
  if (tok === 'not_a_card') return `${scope}.error_not_card`
  return `${scope}.error`
}

/**
 * An archived card of GET /v1/view/archived as the Archive page draws it:
 * newest archived first (the hub's order), one line of body.
 */
export function archivedRow(card) {
  const c = card && typeof card === 'object' ? card : {}
  const m = c.message && typeof c.message === 'object' ? c.message : {}
  const body = String(m.body || '')
  const line = body.split('\n').map((l) => l.trim()).find(Boolean) || ''
  return {
    msg_id: String(c.msg_id || m.msg_id || ''),
    task_id: String(c.task_id || m.task_id || ''),
    channel: c.channel ? String(c.channel) : '',
    from: String(m.from || ''),
    from_box: String(m.from_box || ''),
    title: line.length > 140 ? `${line.slice(0, 139)}…` : line,
    archived_at: String(c.archived_at || ''),
    archived_by: String(c.archived_by || ''),
    replies: Math.max(0, Number(c.replies) || 0),
    can_delete: c.can_delete === true,
  }
}

/** `rows` without the cards a frame or an action removed. */
export function withoutCards(rows, ids) {
  const gone = new Set((ids || []).map(String))
  return (Array.isArray(rows) ? rows : []).filter((r) => !gone.has(String(r && r.msg_id)))
}

/*
 * SPL-986 (specs/041 §3.5): the same Archive / Delete on a topic ROW of a
 * list (the left-rail Topics section, Flow, the Topics home). A row is a task,
 * not a message; the hub acts on the card. The row's card is found lazily,
 * when its menu opens, and the hub is asked (GET /v1/view/messages/{id}/topic)
 * before anything is offered, so a row never offers what the hub refuses.
 */

/**
 * The msg ids that may be this row's card, in the order to ask the hub:
 * the task's first message (a channel / DM / sub-task opener), then the task
 * id itself (a lobby card's message-rooted thread: task_id = the card's
 * msg_id). The lobby task itself is never a topic (spec §2): no candidates.
 * @param {string} taskId
 * @param {{ msg_id?: string } | null | undefined} first the task's oldest readable message
 * @param {string} [lobbyTaskId]
 * @returns {string[]}
 */
export function rowCardCandidates(taskId, first, lobbyTaskId = '') {
  const task = String(taskId || '')
  if (!task || task === String(lobbyTaskId || '')) return []
  const out = []
  const firstId = first && typeof first === 'object' ? String(first.msg_id || '') : ''
  if (firstId) out.push(firstId)
  if (!out.includes(task)) out.push(task)
  return out
}

/**
 * Whether the hub's topic answer (topic-archive-v1 §3) for `msgId` is THIS
 * row's topic: the card opens the row's task, or it is a lobby card whose
 * thread is the row. A thread on a line of some other topic is part of that
 * topic, whose own row carries the menu, so it gets none here.
 * @param {{ msg_id?: string, task_id?: string } | null | undefined} size
 * @param {string} taskId the row
 * @param {string} msgId the candidate asked
 * @param {string} [lobbyTaskId]
 */
export function isRowTopic(size, taskId, msgId, lobbyTaskId = '') {
  const s = size && typeof size === 'object' ? size : {}
  const task = String(taskId || '')
  const cardTask = String(s.task_id || '')
  if (!task || !cardTask) return false
  if (cardTask === task) return true
  const lobby = String(lobbyTaskId || '')
  return Boolean(lobby) && cardTask === lobby && String(msgId || '') === task
}

/**
 * The menu state of a row once the hub answered: which of Archive / Delete
 * to offer. `size` null = no card for this row (nothing offered).
 * @param {{ msg_id?: string, replies?: number, can_archive?: boolean, can_delete?: boolean } | null} size
 * @param {string} msgId
 */
export function rowTopicState(size, msgId) {
  if (!size || typeof size !== 'object') return { state: 'none', msgId: '', canArchive: false, canDelete: false, replies: 0 }
  return {
    state: 'ready',
    msgId: String(size.msg_id || msgId || ''),
    canArchive: size.can_archive === true,
    canDelete: size.can_delete === true,
    replies: Math.max(0, Number(size.replies) || 0),
  }
}

/**
 * The topic-list rows (task ids) a live frame removes: an archived card's
 * task and its message-rooted thread, every task a delete named. The lobby
 * task is never removed (a lobby card is one row of it).
 */
export function topicFrameRows(frame, lobbyTaskId = '') {
  const f = frame && typeof frame === 'object' ? frame : {}
  const lobby = String(lobbyTaskId || '')
  let ids = []
  if (f.type === 'topic_deleted') ids = [f.task_id, f.msg_id, ...(Array.isArray(f.task_ids) ? f.task_ids : [])]
  else if (f.type === 'topic_archived' && f.archived === true) ids = [f.task_id, f.msg_id]
  // 714c7028: the merged-away source topic leaves the Topics / Flow lists (its
  // opener is now a reply in the target); the move-apply re-read fills the rest.
  else if (f.type === 'topic_merged') ids = [f.from_task]
  const out = []
  for (const raw of ids) {
    const id = String(raw || '')
    if (id && id !== lobby && !out.includes(id)) out.push(id)
  }
  return out
}

/** `rows` (topic-list rows) without the tasks named. */
export function withoutTopics(rows, taskIds) {
  const gone = new Set((taskIds || []).map(String))
  return (Array.isArray(rows) ? rows : []).filter((r) => !gone.has(String(r && r.task_id)))
}
