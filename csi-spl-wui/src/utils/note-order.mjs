// Spec 155 2.6 (B6, SPL-4186): the person's own order of their notes. Pinned
// notes come first; each group (Pinned, the rest, Archived) keeps its own
// order by `position`, a number the hub stores (PATCH position). Moving a
// note writes one new position between its new neighbours, so no other note
// is rewritten. Pure: the page and the unit test call the same functions.
//
// A priority (spec 155 2.9, SPL-4652) orders a group before `position` does.
// D8 (owner HUM-10, msg 63fe839e, SPL-4701): a drag or Move onto a note of
// another priority moves the note there and gives it that note's priority;
// both go in one PATCH. Groups still never mix.

/** A note nobody set, as the hub reads it (rdb 0254); issues keep 5 too. */
export const NOTE_PRIORITY_DEFAULT = 5

/** 1..5; anything else (a hub that does not send it yet) is the default. */
export function notePriority(n) {
  const p = Number(n?.priority)
  return Number.isInteger(p) && p >= 1 && p <= 5 ? p : NOTE_PRIORITY_DEFAULT
}

/** The drawn order: pinned first, then priority (1 first), position, the newest first. */
export function compareNotes(a, b) {
  return Number(b.pinned) - Number(a.pinned)
    || notePriority(a) - notePriority(b)
    || a.position - b.position
    || String(b.updated_at).localeCompare(String(a.updated_at))
}

/** The group a note is drawn in: 'archived', 'pinned' or 'rest'. */
export function noteGroup(n) {
  if (n.archived) return 'archived'
  return n.pinned ? 'pinned' : 'rest'
}

/** The person's own order inside one run: position, then the last changed first. */
const ownOrder = (a, b) => a.position - b.position || String(b.updated_at).localeCompare(String(a.updated_at))

/** The position that puts a note at index `k` of `others` (the run without it). */
export function positionAt(others, k) {
  if (!others.length) return 0
  if (k <= 0) return others[0].position - 1
  if (k >= others.length) return others[others.length - 1].position + 1
  return (others[k - 1].position + others[k].position) / 2
}

/** True when `id` is drawn above `targetId`: a drag from there goes down. */
export function drawnAbove(list, id, targetId) {
  const a = list.find((n) => n.id === id)
  const b = list.find((n) => n.id === targetId)
  return Boolean(a && b) && compareNotes(a, b) < 0
}

/**
 * A drag: where `id` lands dropped on `targetId` (before it, or after it
 * when `after`), as { position, priority }: the target's priority, so a drop
 * on another priority also changes it (D8). null when the target is in
 * another group, is the note itself, or nothing would change.
 */
export function dropPlacement(list, id, targetId, after = false) {
  const me = list.find((n) => n.id === id)
  const target = list.find((n) => n.id === targetId)
  if (!me || !target || id === targetId || noteGroup(me) !== noteGroup(target)) return null
  const priority = notePriority(target)
  const run = list.filter((n) => noteGroup(n) === noteGroup(me) && notePriority(n) === priority).sort(ownOrder)
  const others = run.filter((n) => n.id !== id)
  const k = others.indexOf(target) + (after ? 1 : 0)
  if (k === run.indexOf(me)) return null
  return { position: positionAt(others, k), priority }
}

/**
 * Alt+Up / Alt+Down, or Move up / Move down: `id` one step `dir` (-1 up,
 * +1 down) inside its group, past its neighbour; a neighbour of another
 * priority gives it that priority (D8). null at the group's edge.
 */
export function movePlacement(list, id, dir) {
  const me = list.find((n) => n.id === id)
  if (!me || !dir) return null
  const rows = list.filter((n) => noteGroup(n) === noteGroup(me)).sort(compareNotes)
  const next = rows[rows.indexOf(me) + Math.sign(dir)]
  return next ? dropPlacement(list, id, next.id, dir > 0) : null
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
