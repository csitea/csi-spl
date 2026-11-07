/**
 * SPL-4954: what the reader is told about a send that failed. Apart from
 * send-failure.mjs because the eager stores import that file for its send
 * helpers, which puts all of it in the entry chunk, and the initial chunk has
 * no headroom (027). Only TopBar and msg-edit read these two.
 */
import { failureToken } from './send-failure.mjs'

/** i18n key for what the reader is told. Unknown shapes get the generic line. */
export function sendFailureKey(err) {
  /* SPL-2285: the hub answered the file upload with an error (upload-fail.mjs) */
  if (/** @type {{ upload?: unknown } | null | undefined} */ (err)?.upload) return 'composer.send_failed_upload'
  switch (failureToken(err)) {
    /* SPL-2285: the upload could not reach the hub (socket down, no answer) */
    case 'hub_down': return 'composer.send_failed_hub_down'
    case 'closed': return 'composer.send_failed_closed'
    case 'timeout': return 'composer.send_failed_timeout'
    case 'empty': return 'composer.send_failed_empty'
    /* CLE-77795: an upload could not get a valid token even after a redial —
       the member session itself is gone. Tell the reader to sign in again. */
    case 'session_expired': return 'composer.send_failed_session_expired'
    /* owner 2026-10-05 (t1 dc6d5e3f): a tag of an agent that is no longer
       active is refused by the hub - a retired id with no successor, or a
       recycled one no box announces any more (unknown_agent) */
    case 'retired_id':
    case 'unknown_agent': return 'composer.send_failed_agent_inactive'
    /* SPL-1018 (spec 044 FR-OS-017): the agent's allow-list does not name you */
    case 'sender_not_allowed': return 'composer.send_failed_not_allowed'
    /* spec 025 box owner lock (B8, SPL-3015): the agent's box is locked to its owners */
    case 'box_locked': return 'composer.send_failed_box_locked'
    /* SPL-4954 (spec 041 3.1): people add nothing to an archived topic */
    case 'topic_archived': return 'composer.send_failed_archived'
    default: return 'composer.send_failed'
  }
}

/** The params of that line: the agent a sender_not_allowed refusal names, an upload's status and token. */
export function sendFailureParams(err) {
  const e = /** @type {{ agent?: unknown, status?: unknown, upload?: unknown } | null | undefined} */ (err)
  const p = { agent: typeof e?.agent === 'string' ? e.agent : '' }
  return e?.upload ? { ...p, status: String(e.status), error: failureToken(err) || '-' } : p
}
