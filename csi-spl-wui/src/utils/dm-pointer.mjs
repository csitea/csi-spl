/**
 * DM pointers (owner, prd t1 dc6d5e3f): "if I tag the agent in a channels
 * topic, it means that this msg WILL appear also as a personal msg ... but
 * of course it should be treated as a reply in the topic and not a new
 * topic". The hub's DM view of a person and an agent carries the channel
 * lines between the two (`pointers`, view-v1 GET /v1/view/topics?dm=true&
 * peer=<agent>): the person's tag and the agent's line back. Each is the
 * stored row, with its channel and task_id; here it becomes a card of the
 * DM feed marked `pointer`, which opens the line in its topic. Pure.
 */

/**
 * The DM feed's card for one pointer row: a middle card (is_parent 1, no
 * parent) of the topic the line is in, marked `pointer`. Null for a row
 * that is not a channel line.
 */
export function dmPointerRow(m) {
  if (!m || !m.msg_id || !m.channel || !m.task_id) return null
  return { ...m, is_parent: 1, parent_task_id: null, pointer: true }
}

/** The pointer cards of the hub's `pointers` list. */
export function dmPointerRows(rows) {
  const out = []
  for (const m of Array.isArray(rows) ? rows : []) {
    const row = dmPointerRow(m)
    if (row) out.push(row)
  }
  return out
}

/**
 * The mock hub's pointers: the channel lines from `me` to the peer or from
 * the peer to `me` (the peer's box, when the label names one).
 */
export function mockDmPointers(messages, me, peer) {
  const [id, box = ''] = String(peer || '').split('@')
  const self = String(me || '')
  if (!id || !self) return []
  return dmPointerRows((messages || []).filter((m) => m && m.channel && (
    (m.from === self && m.to === id && (!box || !m.to_box || m.to_box === box || m.to_box === 'box-wui')) ||
    (m.from === id && m.to === self && (!box || !m.from_box || m.from_box === box)))))
}
