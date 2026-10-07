// Topic-row kind changes (topics view). A row's `kinds` map counts every
// message; only the opener's kind is settable, through the same rule as a
// card (canSetKind). The opener is openingCardId's row.

import { canSetKind } from './msg-kind.mjs'
import { openingCardId } from './topic-archive.mjs'

/** The kind a row shows for a message. A post with none is a note. */
export function messageKind(msg) {
  const k = String((msg && msg.kind) || '')
  return k || 'note'
}

/**
 * The opener among a getTopic page (oldest first), or null when the page
 * has no card. `fallbackId` is openingCardId's fallback.
 * @param {unknown} messages
 * @param {string} [fallbackId]
 */
export function openerMessage(messages, fallbackId = '') {
  const rows = Array.isArray(messages) ? messages : []
  const id = openingCardId(rows, fallbackId)
  if (!id) return null
  return rows.find((m) => m && String(m.msg_id || '') === String(id)) || null
}

/**
 * The aggregate key that is the opener's badge, or '' when this row has
 * no such key. Other keys stay display-only.
 * @param {Record<string, number> | null | undefined} kinds
 * @param {{ msg_id?: string, kind?: string, pending?: boolean } | null | undefined} msg
 */
export function openerKindKey(kinds, msg) {
  if (!msg || !msg.msg_id || msg.pending) return ''
  const k = messageKind(msg)
  const map = kinds && typeof kinds === 'object' ? kinds : {}
  return Object.prototype.hasOwnProperty.call(map, k) ? k : ''
}

/**
 * The kind key the topics-view menu and badge may set, or '' when the
 * viewer may not set this opener. `role` is the viewer's tenant role.
 * @param {unknown} msg
 * @param {string} viewerId
 * @param {string | null | undefined} role
 * @param {Record<string, number> | null | undefined} kinds
 */
export function topicRowKind(msg, viewerId, role, kinds) {
  if (!canSetKind(msg, viewerId, role)) return ''
  return openerKindKey(kinds, msg)
}

/**
 * Move one count from `from` to `to`. A count that hits zero leaves the
 * map, so the row drops that badge. The same call with the kinds swapped
 * is the rollback. `from === to` returns a copy unchanged.
 * @param {Record<string, number> | null | undefined} kinds
 * @param {string} from
 * @param {string} to
 * @returns {Record<string, number>}
 */
export function retargetKinds(kinds, from, to) {
  const src = kinds && typeof kinds === 'object' ? kinds : {}
  const next = { ...src }
  const f = String(from || '')
  const t = String(to || '')
  if (!f || !t || f === t) return next
  const left = (Number(next[f]) || 0) - 1
  if (left > 0) next[f] = left
  else delete next[f]
  next[t] = (Number(next[t]) || 0) + 1
  return next
}

/**
 * The topics view's copy of a message with the kind last set on it from
 * anywhere (a row badge, a card in the pane, the keyboard). `kindSet` maps
 * msg_id to that kind. Without it a row holding its opener from before the
 * change reads the old kind, and the badge the row now shows is not the
 * opener's, so it stops being a button.
 * @template T
 * @param {T} msg
 * @param {Record<string, string> | null | undefined} kindSet
 * @returns {T}
 */
export function withSetKind(msg, kindSet) {
  const m = /** @type {{ msg_id?: string, kind?: string } | null | undefined} */ (msg)
  const k = m && m.msg_id && kindSet ? kindSet[String(m.msg_id)] : ''
  return m && k && k !== m.kind ? /** @type {T} */ ({ ...m, kind: k }) : msg
}

/**
 * The topics list after one message of `taskId` changed kind: that row's
 * counts move one from `from` to `to` (retargetKinds). Every other row, and
 * a list without that topic, comes back as it was (the same array).
 * @template {{ task_id: string, kinds: Record<string, number> }} R
 * @param {R[]} topics
 * @param {string} taskId
 * @param {string} from
 * @param {string} to
 * @returns {R[]}
 */
export function topicsWithKind(topics, taskId, from, to) {
  const task = String(taskId || '')
  const f = messageKind({ kind: from })
  const t = messageKind({ kind: to })
  if (!task || f === t || !topics.some((r) => r.task_id === task)) return topics
  return topics.map((r) => (r.task_id !== task ? r : { ...r, kinds: retargetKinds(r.kinds, f, t) }))
}
