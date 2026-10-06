// csi-spl-wui/src/utils/move.mjs
//
// SPL-1024 (specs/045): move a topic to another channel, a reply to another
// topic. The hub decides every move (move-v1 §1); this file only decides what
// to OFFER (which card may be dragged, which rows may take the drop,
// which menu entries show) and how a move answer / live frame changes the
// rows already on screen. Pure: the Node tests import it.

import { isTopicCard, TOPIC_ADMIN_ROLES } from './topic-archive.mjs'
import { isAgentId } from './agent-id.mjs'

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
 * An AGENT's reply moves for anyone who sees it (owner, t1 ffc3b83c: "the
 * humans should be able to move the bots msgs to a desired topic"); a
 * person's reply keeps the author / owner / admin rule. A DM row (no channel)
 * moves only when an agent sent it to this viewer: out of the DM, into a
 * channel topic (t1 ffc3b83c was such a DM). `openerId` is the card the pane was opened on (never movable: spec 3.2
 * `is_card`); `channel` is the pane's channel when the row carries none.
 */
export function mayMoveMessage(msg, viewerId, me, { openerId = '', lobbyTaskId = '', channel = '' } = {}) {
  const m = msg && typeof msg === 'object' ? msg : null
  if (!m || m.pending || !m.msg_id || m.topic_row) return false
  if (m.is_parent === 1) return false
  if (openerId && String(m.msg_id) === String(openerId)) return false
  const lobby = String(lobbyTaskId || '')
  if (lobby && (String(m.task_id || '') === lobby || String(m.parent_task_id || '') === lobby)) return false
  if (!moveChan(m.channel || channel)) return isDmOut(m, viewerId)
  if (moveBlocked(m.channel || channel)) return false
  return isAgentId(m.from) || mayChange(m, viewerId, me)
}

/** A DM row an agent sent to this viewer: the one DM row that may leave its DM. */
function isDmOut(m, viewerId) {
  const id = String(viewerId || '')
  return Boolean(id) && isAgentId(m.from) && String(m.to || '') === id
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
 * The viewer may PROMOTE this reply into a new topic of its own (8f588edd) /
 * is offered "Make it a topic". The same gate as Move to topic: a reply (never
 * a card, never the opener) an agent wrote, or the viewer authored, owns or
 * admins, in a real channel (not a DM, not the lobby).
 */
export function mayPromoteMessage(msg, viewerId, me, opts = {}) {
  const m = msg && typeof msg === 'object' ? msg : {}
  return Boolean(moveChan(m.channel || opts.channel)) && mayMoveMessage(msg, viewerId, me, opts)
}

/**
 * The topics-list background lights up (and takes the drop) for a reply being
 * dragged = a PROMOTE (8f588edd). The reply keeps its own channel, so the drop
 * only needs a reply drag; the hub decides the rest.
 */
export function isPromoteDropTarget(drag) {
  const d = drag && typeof drag === 'object' ? drag : null
  /* a DM row (no channel) only ever goes to a channel topic, never a new one */
  return Boolean(d && d.kind === 'message' && (d.channel === undefined || moveChan(d.channel)))
}

/**
 * The "moved from ..." note on a row, or null: a card names its home channel
 * (a topic move) or, when it opens a topic promoted out of another (8f588edd),
 * its home topic; a reply names its home topic (a message move).
 */
export function movedNote(msg) {
  const m = msg && typeof msg === 'object' ? msg : {}
  if (!m.moved_at) return null
  // A moved reply, or a card promoted out of another topic, names its home topic.
  if (m.moved_from_task) return { kind: 'topic', task: String(m.moved_from_task) }
  const from = moveChan(m.moved_from_channel)
  if (from && m.is_parent !== 0 && from !== moveChan(m.channel)) return { kind: 'channel', channel: from }
  return null
}
