// Topic-row kind counts (the viewer store's topic list). A row's `kinds`
// map counts every message; a kind set on a message moves one count.

/** The kind a row shows for a message. A post with none is a note. */
export function messageKind(msg) {
  const k = String((msg && msg.kind) || '')
  return k || 'note'
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
