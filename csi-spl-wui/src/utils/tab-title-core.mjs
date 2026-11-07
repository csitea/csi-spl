/** The tab title's unread total: the one piece the entry chunk needs (unread-model.mjs). */

/**
 * Bug A (t1 5002067f): a background tab gave no sign of a new message. The
 * unread total leads the title, "(3) hooli.spool-hub", as a chat tab does.
 * Muted channels do not count: they are the ones the reader asked to ignore.
 * Spec 079 FR-002: only unreadModel (unread-model.mjs) calls this; a surface
 * reads the result from useUnread().title.
 *
 * @param {Record<string, number>} unread per key (`ch:<slug>` / `dm:<peer>`)
 * @param {string[]} [muted] muted channel slugs
 */
export function unreadTotal(unread, muted = []) {
  const off = new Set((muted || []).map((c) => `ch:${c}`))
  let n = 0
  for (const [k, v] of Object.entries(unread || {})) {
    if (!off.has(k)) n += Math.max(0, Number(v) || 0)
  }
  return n
}
