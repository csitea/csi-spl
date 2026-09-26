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
  if (f.type !== 'topic_deleted') return []
  const lobby = String(lobbyTaskId || '')
  const ids = Array.isArray(f.task_ids) ? f.task_ids.map(String) : []
  return ids.filter((id) => id && id !== lobby)
}

/** The catalogue key for a refused or failed archive / delete. */
export function topicErrorKey(e, scope = 'feed.topic_delete') {
  const tok = e && typeof e === 'object' && 'token' in e ? String(e.token || '') : ''
  if (tok === 'not_allowed' || tok === 'forbidden') return `${scope}.error_forbidden`
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
