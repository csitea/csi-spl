// Spec 155 2.6 (B6, SPL-4186): the person's own order of their notes. Pinned
// notes come first; each group (Pinned, the rest, Archived) keeps its own
// order by `position`, a number the hub stores (PATCH position). Moving a
// note writes one new position between its new neighbours, so no other note
// is rewritten. Pure: the page and the unit test call the same functions.

/** The group a note is drawn in: 'archived', 'pinned' or 'rest'. */
export function noteGroup(n) {
  if (n.archived) return 'archived'
  return n.pinned ? 'pinned' : 'rest'
}

/** The notes of `id`'s group, in drawn order (position, then the newest first). */
function groupOf(list, id) {
  const me = list.find((n) => n.id === id)
  if (!me) return null
  const g = noteGroup(me)
  const rows = list
    .filter((n) => noteGroup(n) === g)
    .sort((a, b) => a.position - b.position || String(b.updated_at).localeCompare(String(a.updated_at)))
  return { me, rows }
}

/** The position that puts a note at index `k` of `others` (the group without it). */
export function positionAt(others, k) {
  if (!others.length) return 0
  if (k <= 0) return others[0].position - 1
  if (k >= others.length) return others[others.length - 1].position + 1
  return (others[k - 1].position + others[k].position) / 2
}

/**
 * Alt+Up / Alt+Down, or Move up / Move down: the new position of `id` one
 * step `dir` (-1 up, +1 down) inside its group; null at the group's edge.
 */
export function movePosition(list, id, dir) {
  const g = groupOf(list, id)
  if (!g) return null
  const i = g.rows.findIndex((n) => n.id === id)
  const k = i + Math.sign(dir)
  if (!dir || k < 0 || k >= g.rows.length) return null
  return positionAt(g.rows.filter((n) => n.id !== id), k)
}

/**
 * A drag: the new position of `id` dropped on `targetId` (before it, or
 * after it when `after`); null when the target is in another group or it
 * would not move.
 */
export function dropPosition(list, id, targetId, after = false) {
  const g = groupOf(list, id)
  if (!g || id === targetId) return null
  const others = g.rows.filter((n) => n.id !== id)
  const t = others.findIndex((n) => n.id === targetId)
  if (t < 0) return null
  const k = after ? t + 1 : t
  if (k === g.rows.indexOf(g.me)) return null
  return positionAt(others, k)
}

/** A checklist line moved one step `dir`; the new array, or null at an edge. */
export function moveChecklistLine(items, index, dir) {
  const k = index + Math.sign(dir)
  if (!dir || index < 0 || index >= items.length || k < 0 || k >= items.length) return null
  const out = [...items]
  const [it] = out.splice(index, 1)
  out.splice(k, 0, it)
  return out
}
