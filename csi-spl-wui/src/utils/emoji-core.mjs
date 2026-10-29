/**
 * The EAGER core of utils/emoji.mjs: the reaction list shape the channel
 * store and the view reads apply before first paint. The initial JS chunk is
 * at its 027 budget (ci_initial_gzip_kb 155), so the glyph grid, the names
 * and the chips stay in emoji.mjs, which re-exports this file.
 */

/**
 * The wire shape: [{ emoji, actors: [id, ...] }], emoji order kept, empty
 * actors dropped. Anything else becomes [].
 */
export function normalizeReactions(list) {
  if (!Array.isArray(list)) return []
  const out = []
  for (const r of list) {
    if (!r || typeof r.emoji !== 'string' || !r.emoji) continue
    const actors = []
    const seen = new Set()
    for (const a of (Array.isArray(r.actors) ? r.actors : [])) {
      const id = String(a || '')
      if (!id || seen.has(id)) continue
      seen.add(id)
      actors.push(id)
    }
    if (!actors.length) continue
    out.push({ emoji: r.emoji, actors })
  }
  return out
}

/**
 * Replace `reactions` on the one row whose msg_id matches. A list that does
 * not hold the message is returned as-is, so telling every store is cheap.
 */
export function applyReactions(list, update) {
  const id = String((update && update.msg_id) || '')
  if (!id || !Array.isArray(list)) return list
  const reactions = normalizeReactions(update && update.reactions)
  let hit = false
  const next = list.map((m) => {
    if (!m || String(m.msg_id || '') !== id) return m
    hit = true
    return { ...m, reactions }
  })
  return hit ? next : list
}
