// csi-spl-wui/src/utils/move.mjs
//
// SPL-1024 (specs/045): move a topic to another channel, a reply to another
// topic. The hub decides every move (move-v1 §1); this file only decides what
// to OFFER (which card may be dragged, which rows may take the drop,
// which menu entries show) and how a move answer / live frame changes the
// rows already on screen. Pure: the Node tests import it.

import { isTopicCard, TOPIC_ADMIN_ROLES } from './topic-archive.mjs'

/** Channels a topic can never move into or out of (spec 3.1): the shared lobby and the issues channel. */
export const MOVE_BLOCKED_CHANNELS = Object.freeze(['lobby', 'general', 'issues'])

export function moveChan(v) {
  return String(v || '').trim().replace(/^#/, '').toLowerCase()
}

export function moveBlocked(channel) {
  const c = moveChan(channel)
  return !c || MOVE_BLOCKED_CHANNELS.includes(c)
}

/** The author, the tenant owner or an admin (spec 3.4, the 041 shape). */
function mayChange(msg, viewerId, me) {
  const id = String(viewerId || '')
  if (id && String((msg && msg.from) || '') === id) return true
  if (!me || typeof me !== 'object') return false
  return me.tenantOwner === true || TOPIC_ADMIN_ROLES.includes(String(me.role || ''))
}

/**
 * A card that can move to another channel at all: a stored level-1 card of a
 * channel topic that is not the lobby, not a DM (no channel) and not an
 * issue's discussion. A topic-list row stand-in (topic_row) is not a message.
 */
export function isMovableTopic(msg, lobbyTaskId = '') {
  if (!isTopicCard(msg) || msg.topic_row) return false
  if (moveBlocked(msg.channel)) return false
  const lobby = String(lobbyTaskId || '')
  return !lobby || String(msg.task_id || '') !== lobby
}

/** The viewer may drag this card to a channel / is offered Move to channel. */
export function mayMoveTopic(msg, viewerId, me, lobbyTaskId = '') {
  return isMovableTopic(msg, lobbyTaskId) && mayChange(msg, viewerId, me)
}

/**
 * The viewer may drag this reply to another topic / is offered Move to topic.
 * `openerId` is the card the pane was opened on (never movable: spec 3.2
 * `is_card`); `channel` is the pane's channel when the row carries none.
 */
export function mayMoveMessage(msg, viewerId, me, { openerId = '', lobbyTaskId = '', channel = '' } = {}) {
  const m = msg && typeof msg === 'object' ? msg : null
  if (!m || m.pending || !m.msg_id || m.topic_row) return false
  if (m.is_parent === 1) return false
  if (openerId && String(m.msg_id) === String(openerId)) return false
  const lobby = String(lobbyTaskId || '')
  if (lobby && (String(m.task_id || '') === lobby || String(m.parent_task_id || '') === lobby)) return false
  if (moveBlocked(m.channel || channel)) return false
  return mayChange(m, viewerId, me)
}

/** A left-rail channel row lights up (and takes the drop) for this drag. */
export function isChannelDropTarget(drag, channelId, listed = null) {
  const d = drag && typeof drag === 'object' ? drag : null
  if (!d || d.kind !== 'topic') return false
  const id = moveChan(channelId)
  if (!id || moveBlocked(id) || id === moveChan(d.channel)) return false
  if (Array.isArray(listed) && !listed.some((c) => moveChan(c && (c.channel_id || c.channel)) === id)) return false
  return true
}

/**
 * A middle-list card lights up (and takes the drop) for a reply being
 * dragged: another channel topic's card, not the reply's own topic, not a
 * topic inside the reply's own thread (spec 3.2 `cycle`), not the lobby.
 */
export function isCardDropTarget(drag, card, lobbyTaskId = '') {
  const d = drag && typeof drag === 'object' ? drag : null
  if (!d || d.kind !== 'message') return false
  if (!isMovableTopic(card, lobbyTaskId)) return false
  const task = String(card.task_id || '')
  if (!task) return false
  if (task === String(d.taskId || '') || task === String(d.topicTask || '') || task === String(d.msgId || '')) return false
  if (String(card.msg_id || '') === String(d.msgId || '')) return false
  return true
}

/**
 * A middle-list card lights up (and takes the drop) for a TOPIC card being
 * dragged onto it = a MERGE (714c7028): another channel topic's card, not the
 * dragged topic itself, not a topic inside it, not the lobby. The hub decides
 * the rest (permissions, cycle); this only offers the drop.
 */
export function isMergeCardDropTarget(drag, card, lobbyTaskId = '') {
  const d = drag && typeof drag === 'object' ? drag : null
  if (!d || d.kind !== 'topic') return false
  if (!isMovableTopic(card, lobbyTaskId)) return false
  const task = String(card.task_id || '')
  if (!task) return false
  if (task === String(d.taskId || '') || task === String(d.topicTask || '') || task === String(d.msgId || '')) return false
  if (String(card.msg_id || '') === String(d.msgId || '')) return false
  return true
}

/**
 * The "moved from ..." note on a row, or null: a card names its home channel
 * (a topic move), a reply its home topic (a message move).
 */
export function movedNote(msg) {
  const m = msg && typeof msg === 'object' ? msg : {}
  if (!m.moved_at) return null
  if (m.moved_from_task && m.is_parent !== 1) return { kind: 'topic', task: String(m.moved_from_task) }
  const from = moveChan(m.moved_from_channel)
  if (from && m.is_parent !== 0 && from !== moveChan(m.channel)) return { kind: 'channel', channel: from }
  return null
}
