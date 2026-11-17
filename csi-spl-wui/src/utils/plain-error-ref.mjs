// csi-spl-wui/src/utils/plain-error-ref.mjs
//
// The reference id a PlainErrorNotice quotes, and whether it journals the
// failure itself (spec 162, owner HUM-10, t1 955ab0bd: "check all of the
// events and fix them").
//
// SPL-5750 / SPL-5760 (F4): one failure, one journal row. The api layer
// already journals a transport failure ("Failed to fetch") and stamps its
// reference on the rejection; a notice handed only the message minted a
// second record for it. A notice handed the rejection (`error`) quotes the
// stamped reference and journals nothing.
//
// SPL-5744 / SPL-5753 (F6): not a member is a state, not an error. On a
// tenant host whose workspace the session is not a member of
// (tenant-host-boot.mjs step 3) every read answers 403 not_member, and the
// not-member card says so; the notice journals none of them.
//
// Relative imports: the unit suite executes this under bare `node`.
import { extractErrorId, newClientErrorId, noteError } from '../composables/errorJournal.mjs'
import { plainErrorStatus } from './plain-error.mjs'

/**
 * A 403 not_member answer (the spool client's err.token, else its message).
 * @param {unknown} message
 * @param {unknown} [error]
 * @returns {boolean}
 */
export function isNotMember(message, error) {
  if (plainErrorStatus(message, error) !== 403) return false
  const token = /** @type {{ token?: unknown } | null | undefined} */ (error)?.token
  return token === 'not_member' || /\bnot_member\b/.test(String(message || ''))
}

/**
 * The notice's reference: the caller's id or the one stamped on the
 * rejection (nothing journaled); '' for no failure, a compact row or a 403
 * not_member while the session is known not a member (nothing journaled);
 * else a new id, journaled `inline`.
 * @param {{ message?: string, error?: unknown, errorId?: string, compact?: boolean, source?: string }} p
 * @param {{ notMember?: boolean, journal?: { isClient?: boolean, now?: number } }} [o]
 *   `notMember`: the not-member card is up; `journal`: noteError's opts (tests)
 * @returns {string}
 */
export function noticeRef(p, o = {}) {
  const known = p.errorId || extractErrorId(p.error)
  if (known || p.compact) return known
  if (!p.message && p.error == null) return ''
  if (o.notMember && isNotMember(p.message, p.error)) return ''
  const id = newClientErrorId()
  noteError({ source: p.source, message: p.message, error: p.error, errorId: id, inline: true }, o.journal)
  return id
}
