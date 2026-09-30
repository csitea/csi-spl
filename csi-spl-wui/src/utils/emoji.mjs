/**
 * Emoji on a message. The same list and the same chips for an opening
 * message (is_parent 1) and a reply (is_parent 0). The hub accepts only
 * these glyphs (internal/hub/emoji.go emojiChoices); emoji_test.go and
 * tests/unit/emoji.test.mjs fail when the two lists differ.
 */

/**
 * Eight across, six full rows: 48 glyphs, each once (SPL-1002, owner: "the
 * angry emoji is displayed twice ... 2 empty emoji places"). 48 also divides
 * by the 6, 12 and 16 columns of the phone sheet, so no grid ends in a hole.
 * No variation selector (U+FE0F) except where the glyph needs it to draw as
 * an emoji (the heart); canonicalEmoji maps the other spelling onto it.
 *
 * Order (owner, prd t1 da0c0e98): the two reactions people reach for most lead
 * the grid - ✅ in the top-left cell, 🔥 next to its right - and everything
 * else keeps the order it had. The hub copy (internal/hub/emoji.go) is kept
 * in lock-step; TestEmojiChoicesMatchWUI compares the two lists in order.
 */
export const EMOJI_CHOICES = [
  '✅', '🔥', '😀', '😁', '😂', '🤣', '😆', '😅',
  '🙂', '😉', '😊', '😇', '😍', '😎', '😜', '🥳',
  '🤗', '🤔', '😐', '😕', '😬', '🙄', '😴', '😢',
  '😭', '😱', '😡', '🤯', '👍', '👎', '👏', '🙌',
  '🙏', '👋', '💪', '👌', '🤝', '👀', '❤️', '🎉',
  '✨', '❌', '⭐', '💯', '🚀', '💡', '🎯', '🐛',
]

const CHOICE = new Set(EMOJI_CHOICES)
const VS16 = '\uFE0F'

/**
 * The one spelling the picker (and the hub) uses for a glyph: a choice
 * written with or without U+FE0F maps onto the listed form. '' when it is
 * not a choice at all.
 */
export function canonicalEmoji(s) {
  const raw = String(s || '')
  if (CHOICE.has(raw)) return raw
  const bare = raw.split(VS16).join('')
  if (CHOICE.has(bare)) return bare
  if (CHOICE.has(bare + VS16)) return bare + VS16
  return ''
}

/** One glyph the picker offers. */
export function validEmoji(s) {
  return CHOICE.has(String(s || ''))
}

/**
 * A short, plain name for each picker glyph, keyed by a stable slug; the i18n
 * key `feed.emoji.name.<slug>` carries the localized word (owner, prd t1
 * da0c0e98: "add on hover what each emoji represents ... some kind of simple
 * text"). Every EMOJI_CHOICES glyph has one, so the picker and the reaction
 * chips can name what a reaction means on hover and to a screen reader.
 * emoji-name-map.tst pins that the two lists stay in lock-step.
 */
export const EMOJI_NAME_SLUG = {
  '✅': 'check', '🔥': 'fire', '😀': 'grin', '😁': 'beam', '😂': 'joy',
  '🤣': 'rofl', '😆': 'laugh', '😅': 'phew', '🙂': 'smile', '😉': 'wink',
  '😊': 'blush', '😇': 'angel', '😍': 'hearteyes', '😎': 'cool', '😜': 'cheeky',
  '🥳': 'party', '🤗': 'hug', '🤔': 'thinking', '😐': 'neutral', '😕': 'confused',
  '😬': 'grimace', '🙄': 'eyeroll', '😴': 'sleepy', '😢': 'sad', '😭': 'crying',
  '😱': 'shock', '😡': 'angry', '🤯': 'mindblown', '👍': 'like', '👎': 'dislike',
  '👏': 'applause', '🙌': 'praise', '🙏': 'thanks', '👋': 'wave', '💪': 'strong',
  '👌': 'ok', '🤝': 'deal', '👀': 'eyes', '❤️': 'heart', '🎉': 'celebrate',
  '✨': 'sparkle', '❌': 'no', '⭐': 'star', '💯': 'hundred', '🚀': 'ship',
  '💡': 'idea', '🎯': 'target', '🐛': 'bug',
}

/** The i18n key that names a glyph, or '' when it is not a picker glyph. */
export function emojiNameKey(emoji) {
  const slug = EMOJI_NAME_SLUG[canonicalEmoji(emoji)]
  return slug ? `feed.emoji.name.${slug}` : ''
}

/**
 * The localized short name of a glyph, for a tooltip / aria-label, via a
 * translate function `t`. Falls back to the glyph itself when it is not a
 * known choice (naming an unknown glyph would be a guess) or when no `t` is
 * given.
 */
export function emojiName(emoji, t) {
  const key = emojiNameKey(emoji)
  return key && typeof t === 'function' ? String(t(key)) : String(emoji || '')
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

/**
 * Chips for one card. `mine` is the signed-in member. `actors` names who
 * reacted (the chip's tooltip); `showCount` is true from 2 people on
 * (SPL-982, owner: "if there are multiple persons with the same reaction add
 * a number"), so one person's chip is the emoji alone.
 */
export function reactionChips(list, me) {
  const who = String(me || '')
  return normalizeReactions(list).map((r) => ({
    emoji: r.emoji,
    count: r.actors.length,
    showCount: r.actors.length >= 2,
    actors: r.actors.slice(),
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
