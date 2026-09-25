/**
 * Emoji on a message. The same list and the same chips for an opening
 * message (is_parent 1) and a reply (is_parent 0). The hub accepts only
 * these glyphs (internal/hub/emoji.go emojiChoices) — keep the two lists
 * the same.
 */

/** A basic set. Eight across, four rows. Not more than 33. */
export const EMOJI_CHOICES = [
  '😀', '😁', '😂', '🙂', '😉', '😊', '😍', '😎',
  '🤔', '😐', '😢', '😭', '😡', '🙄', '😴', '🤗',
  '👍', '👎', '👏', '🙏', '👋', '💪', '👀', '🔥',
  '❤️', '🎉', '✅', '❌', '⭐', '💯', '🚀', '💡',
]

const CHOICE = new Set(EMOJI_CHOICES)
const RECENT_KEY = 'spool.emoji-recent'

/** One glyph the picker offers. */
export function validEmoji(s) {
  return CHOICE.has(String(s || ''))
}

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

/** Chips for one card. `mine` is the signed-in member. */
export function reactionChips(list, me) {
  const who = String(me || '')
  return normalizeReactions(list).map((r) => ({
    emoji: r.emoji,
    count: r.actors.length,
    mine: Boolean(who) && r.actors.includes(who),
  }))
}

/** add when this member has not used the glyph, otherwise remove. */
export function reactionOp(list, emoji, me) {
  const who = String(me || '')
  const row = normalizeReactions(list).find((r) => r.emoji === emoji)
  if (row && who && row.actors.includes(who)) return 'remove'
  return 'add'
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

export function readRecent(storage) {
  const bag = storage || (typeof localStorage !== 'undefined' ? localStorage : null)
  if (!bag) return []
  try {
    const raw = JSON.parse(bag.getItem(RECENT_KEY) || '[]')
    if (!Array.isArray(raw)) return []
    return raw.filter((e) => validEmoji(e)).slice(0, 8)
  } catch {
    return []
  }
}

export function rememberEmoji(emoji, storage) {
  if (!validEmoji(emoji)) return readRecent(storage)
  const bag = storage || (typeof localStorage !== 'undefined' ? localStorage : null)
  const next = [emoji, ...readRecent(bag).filter((e) => e !== emoji)].slice(0, 8)
  if (bag) {
    try { bag.setItem(RECENT_KEY, JSON.stringify(next)) } catch { /* private mode */ }
  }
  return next
}
