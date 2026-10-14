// csi-spl-wui/src/utils/archived-card.mjs
//
// SPL-1763 (owner HUM-10, t1 0bb05176 msg 5cd1ce7b): "whenever one clicks on
// the "Archived" label, that label is a button which will unarchive the
// topic". ArchivedBadge imports this file lazily (the badge sits in the
// shell's first chunks), so the probe costs nothing until an archived topic
// renders.
//
// The badge knows a topic by its task; the hub archives a CARD. The card is
// found the way a topic row finds it (topic-archive.mjs rowCardCandidates /
// isRowTopic): the task's first message, then the task id itself (a lobby
// card's thread), each asked of GET /v1/view/messages/{id}/topic. That
// answer's can_archive is the hub's own rule (the workspace setting "Who can
// archive topics"), the same one it checks on the unarchive write: only a
// viewer it says yes to gets the button.
import { isRowTopic, rowCardCandidates } from './topic-archive.mjs'

/**
 * The archived card of topic `taskId` and whether this viewer may unarchive
 * it; null when no candidate is this topic's archived card (a live topic, a
 * refused read).
 * @param {{ getTopic: Function, topicSize: Function }} api
 * @param {string} taskId
 * @param {string} [lobbyTaskId]
 * @param {string} [firstId] the topic's opening msg id, when the caller holds it
 * @returns {Promise<{ msgId: string, canUnarchive: boolean } | null>}
 */
export async function archivedCardOf(api, taskId, lobbyTaskId = '', firstId = '') {
  const task = String(taskId || '')
  if (!task) return null
  let first = firstId ? { msg_id: String(firstId) } : null
  if (!first) {
    // No opener held: a limit-1 read answers the topic's oldest message; a failed read leaves the task id alone.
    const data = await api.getTopic(task, { limit: 1 }).catch(() => null)
    first = (data && Array.isArray(data.messages) && data.messages[0]) || null
  }
  for (const id of rowCardCandidates(task, first, lobbyTaskId)) {
    // A refused or failed answer means "not this candidate"; the label stays a label.
    const size = await api.topicSize(id).catch(() => null)
    if (size && size.archived === true && isRowTopic(size, task, id, lobbyTaskId)) {
      return { msgId: String(size.msg_id || id), canUnarchive: size.can_archive === true }
    }
  }
  return null
}

/**
 * Whether a `spool:topic-archived` event (spool-client-lazy archiveTopicAndTell)
 * unarchived topic `taskId`: the card's own task, or a lobby card whose
 * thread is the topic (task id = the card's msg id).
 * @param {{ msgId?: string, taskId?: string, archived?: boolean } | null | undefined} detail
 * @param {string} taskId
 */
export function unarchivedTopic(detail, taskId) {
  const task = String(taskId || '')
  if (!task || !detail || detail.archived !== false) return false
  return String(detail.taskId || '') === task || String(detail.msgId || '') === task
}
