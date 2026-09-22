/**
 * Editing a message in place (row E1, CLE-3445) — the BROWSER half.
 *
 * The owner, 2026-09-22:
 *
 *   "once a msg in the 3rd panel is selected, if one presses the e shortcut
 *    the msg becomes once again a textbox and after once writes the new msg
 *    (the old msg should be shown there) and hits the enter the msg is sent"
 *
 * Pure, so the Node tests drive the whole state machine without a browser —
 * the same split as thread-pane.mjs and send-failure.mjs. MessageCard.vue is
 * the only thing that owns a textarea; everything that DECIDES is here.
 *
 * Three rules this file exists to keep honest:
 *
 *  1. The editor opens PRE-FILLED with the old body. That is the half of the
 *     owner's sentence most likely to be dropped, so `beginEdit` has no way to
 *     produce an empty draft and the unit test pins it.
 *  2. The displayed body is never replaced before the server has confirmed.
 *     `commitEdit` only reports what SHOULD be sent; the caller rolls back to
 *     `state.original` on a rejection. This repo already paid for the other
 *     shape once — see send-failure.mjs, which owns the failure vocabulary
 *     this one reuses rather than inventing a second.
 *  3. Enter / Shift+Enter mean here exactly what they mean in the composer.
 *     Read MessageComposer.vue: it calls `enterAction` from code-blocks.mjs
 *     with { inCode, shift, alt, mod }, which answers 'send' for a bare Enter
 *     and for Ctrl/Cmd+Enter, and 'newline' inside a ``` block or with
 *     Shift / Alt. This file calls the SAME function, so the two can never
 *     drift apart.
 *
 * OWNER-STATED, 2026-09-22 — author-only. This was recorded as OUR inference
 * until the owner stated it themselves, watching the feature live:
 *
 *   "of course msgs sent by bots should not be editable"
 *
 * so it is no longer ours to trade away. The NO-time-window half remains
 * CLE-00's ruling of the same day. A shortcut that opens an editor the hub
 * will refuse is a defect, so the gate is here and not only in the template.
 *
 * STILL INFERRED, not ordered (recorded so the next reader can tell the two
 * apart, and so the owner can overrule it):
 *  - Escape cancels and restores the original body. The owner named Enter
 *    only; both seats agreed on Escape because Slack does it and this app
 *    already uses Escape to dismiss. The owner has said NOTHING about Escape,
 *    so it did not ride along with the upgrade above.
 *
 * The wire half is CLE-3443's, published as the `message-edit-v1` contract
 * (db78443; its spec home moved out of 020 while this was being written, so
 * the path is cited ONCE, in the 005 tasks.md row, and nowhere else). Nothing
 * here invents a field name: `edited_at` / `edited_by` / `revision` and the
 * client-side author predicate are that document's, quoted where they are used.
 */
import { closeOpenFence, enterAction } from './code-blocks.mjs'
import { emptySendError, isEmptySend, sendFailureKey } from './send-failure.mjs'
import { BROWSER_BOX } from './view-api.mjs'

/** The one key that opens the editor on the focused row. */
export const EDIT_KEY = 'e'

/*
 * `BROWSER_BOX` is the box a browser-authored envelope carries
 * (message-edit-v1 §4), imported above from its one definition in
 * view-api.mjs — Nuxt auto-imports by export NAME, so a second module
 * exporting it warns at build time and silently picks one.
 *
 * A box-signed envelope cannot be edited by anyone: its Ed25519 signature
 * covers the canonical inner bytes and the hub holds no key to re-sign for
 * that box, so the hub answers 409 `not_editable`. That refuses nothing the
 * owner asked for — every row the `e` shortcut can reach was typed here.
 */

/**
 * Is this row the viewer's own, browser-authored message?
 *
 * message-edit-v1 §4 gives the client predicate that agrees EXACTLY with the
 * server's rules 4 and 5: `m.from === <my HUM-id> && m.from_box === 'box-wui'`.
 * It is quoted rather than approximated, because the whole point of a client
 * gate is that it never offers an editor the hub will refuse.
 *
 * `from_box` here is the FLAT client row's, lifted from the wire ENVELOPE by
 * view-api.mjs:108 (`from_box: e.env.from_box`) and by live-ws.mjs:94. It
 * exists at two levels and means different things at each: `env.from_box` is
 * populated, `env.msg.from_box` is not. Measured on dev 2026-09-22, n=10 rows
 * — and a from_box measurement that does not say WHICH LEVEL it read is not a
 * measurement. It cost three seats an hour on the day of CLE-3446, this one
 * included.
 */
export function isOwnMessage(msg, viewer) {
  const from = String((msg && msg.from) || '')
  const id = String((viewer && viewer.id) || '')
  if (!from || !id || from !== id) return false
  return String((msg && msg.from_box) || '') === BROWSER_BOX
}

/**
 * May the viewer edit this row? Author-only, no expiry (see the header).
 *
 * A row still in flight (`pending`: sent, not yet echoed by the hub) has no
 * confirmed identity to edit, so it is refused until the echo lands.
 */
export function canEditMessage(msg, viewer) {
  const m = msg || {}
  if (!m.msg_id) return false
  if (m.pending) return false
  return isOwnMessage(m, viewer)
}

/**
 * Does this keydown mean "edit the focused row"?
 *
 * Same guard the row's existing Enter / Space handler uses: only the row
 * itself. An `e` typed inside a child control — the reply composer, a link,
 * the editor this very function opens — belongs to that control.
 */
export function wantsEdit(ev, { editable = false } = {}) {
  if (!editable || !ev) return false
  if (ev.isComposing) return false
  if (ev.ctrlKey || ev.metaKey || ev.altKey || ev.shiftKey) return false
  if (String(ev.key) !== EDIT_KEY) return false
  return ev.target === ev.currentTarget
}

/**
 * Open the editor on a message: the draft STARTS as the stored body.
 *
 * `original` is kept beside the draft for the whole life of the edit — it is
 * what Escape restores and what a rejected commit rolls back to, and it is
 * read from the message once, here, so a live frame arriving mid-edit cannot
 * move the thing we promised to put back.
 */
export function beginEdit(msg) {
  const m = msg || {}
  const msgId = String(m.msg_id || '')
  if (!msgId) return null
  const original = String(m.body == null ? '' : m.body)
  return { msgId, original, draft: original }
}

/** The same edit with a new draft (the textarea's value). */
export function withDraft(state, draft) {
  if (!state) return null
  return { ...state, draft: String(draft == null ? '' : draft) }
}

/** What the wire would carry for a draft: an open ``` closed, then trimmed. */
export function editWireBody(draft) {
  return closeOpenFence(String(draft == null ? '' : draft)).trim()
}

/** Has the human actually changed anything yet? */
export function editIsDirty(state) {
  return Boolean(state) && editWireBody(state.draft) !== editWireBody(state.original)
}

/**
 * What a key pressed INSIDE the editor means.
 *
 * '' = not ours, let the textarea have it. The caller passes the fence state
 * at the caret exactly as MessageComposer does, so a ``` block in an edit
 * takes newlines the way it does in the composer.
 */
export function editKeyAction(ev, { inCode = false } = {}) {
  if (!ev || ev.isComposing) return ''
  if (String(ev.key) === 'Escape') return 'cancel'
  if (String(ev.key) !== 'Enter') return ''
  const act = enterAction({ inCode, shift: ev.shiftKey, alt: ev.altKey, mod: ev.ctrlKey || ev.metaKey })
  return act === 'send' ? 'commit' : 'newline'
}

/**
 * What Enter should do with the current draft.
 *
 *  - 'empty'     nothing left to send. An edit carries no files, so the
 *                composer's "files alone are a message" case cannot apply:
 *                emptying the box is a delete, and nobody has asked for one.
 *                Refused, and `error` carries the 'empty' token so the caller
 *                reports it through the one failure vocabulary we have.
 *  - 'unchanged' the draft says what the stored body already says. The editor
 *                closes and NOTHING is sent — writing a revision that records
 *                no change would put noise in the register the owner asked for
 *                ("both the old and the new msg should be stored").
 *  - 'commit'    send `body`.
 */
export function commitEdit(state) {
  if (!state) return { action: 'empty', body: '', error: emptySendError() }
  const body = editWireBody(state.draft)
  if (isEmptySend(body, null)) return { action: 'empty', body: '', error: emptySendError() }
  if (body === editWireBody(state.original)) return { action: 'unchanged', body }
  return { action: 'commit', body }
}

/** Escape / a rejected commit: the body that goes back on screen. */
export function cancelEdit(state) {
  return state ? String(state.original) : ''
}

/**
 * Has this message been edited? message-edit-v1 §2: `edited_at` is an RFC3339
 * UTC string and the key is OMITTED while the message has never been edited,
 * so the test is its presence — not a boolean and not `revision > 1`.
 */
export function isEdited(msg) {
  return Boolean(msg && typeof msg.edited_at === 'string' && msg.edited_at)
}

/** How many bodies the register holds, original included (2 after one edit); 1 when unedited. */
export function revisionOf(msg) {
  const n = msg && Number(msg.revision)
  return Number.isFinite(n) && n >= 2 ? n : 1
}

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
 *    bottom of the thread.
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

/**
 * The i18n key for an edit that did not land.
 *
 * Two vocabularies meet here and both are somebody else's. A hub refusal
 * carries one of message-edit-v1 §5's tokens; a transport failure carries
 * live-ws's ('closed' / 'timeout' / 'empty'), which send-failure.mjs already
 * names. The hub tokens the reader can act on get their own line; everything
 * else falls through to the composer's family rather than minting a second
 * set of strings that say the same thing.
 */
export function editFailureKey(err) {
  const token = err && typeof err === 'object' ? String(err.token || '') : ''
  switch (token) {
    /* §5: whitespace-only. The hub's own mirror of the 'empty' send token. */
    case 'empty_body': return 'composer.send_failed_empty'
    case 'not_author': return 'feed.edit.failed_not_author'
    case 'not_editable': return 'feed.edit.failed_not_editable'
    case 'not_found': return 'feed.edit.failed_not_found'
    case 'too_large': return 'feed.edit.failed_too_large'
    default: return sendFailureKey(err)
  }
}
