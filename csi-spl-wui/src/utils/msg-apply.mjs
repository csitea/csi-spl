// applyEdit, split out of msg-edit.mjs so the feed stores (channel.ts, live.ts)
// can put an edited row back into their list — a live socket-frame handler — WITHOUT
// dragging the whole edit UI (msg-edit.mjs and, through it, code-blocks.mjs) into
// the initial chunk (027 perf budget). msg-edit.mjs re-exports applyEdit so its
// own importers keep working. Pure: node tests import this file directly.

/**
 * Put an edited message back into a list of rows, IN PLACE.
 *
 * Two rules, both of them somebody else's and both easy to break by reaching
 * for the merge that already exists:
 *
 *  - `mergeById()` in feed.mjs cannot do this. Measured, not assumed:
 *    `sed -n '77,95p' src/utils/feed.mjs` -> line 89 is
 *    `} else if (list[i].pending && !m.pending) {`, so it replaces a held row
 *    ONLY while that row is pending and silently drops an incoming row whose
 *    msg_id is already held as confirmed. Every screen that already has the
 *    message is exactly the set of screens an edit needs to reach.
 *  - message-edit-v1 FR-ED-009: an edit does not move the message. `ts`,
 *    `received_at` and `cursor` are unchanged by it, so this replaces at the
 *    existing index and never re-sorts. A typo fix must not jump to the
 *    bottom of the topic.
 *
 * A msg_id this list does not hold is ignored rather than appended: an edit
 * is a replacement, and inventing a row for a message the reader never had
 * would show it out of order and out of its window.
 */
export function applyEdit(rows, edited) {
  const list = rows || []
  const id = String((edited && edited.msg_id) || '')
  if (!id) return list
  const at = list.findIndex((m) => m && String(m.msg_id || '') === id)
  if (at < 0) return list
  const out = list.slice()
  /* the held row keeps every field the frame does not carry (its pending
     flag is gone by now, its deliveries and files are not on an edit frame) */
  out[at] = { ...out[at], ...edited }
  return out
}
