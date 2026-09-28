/**
 * a send that does not land must SAY SO.
 *
 * On 2026-09-21 the owner wrote a message in a DM and it vanished: the hub's
 * `messages` table has nothing from them after 12:39:03Z (CLE-3434 read it
 * straight out of the dev DB), while the WUI cleared the box, showed no row
 * and showed no error. Three things had to line up for the text to be lost
 * without a trace, and all three were true:
 *
 *   1. MessageComposer cleared `text` on the same tick it emitted `send` —
 *      the emit is fire-and-forget, so the box was empty before anyone knew
 *      whether the frame had landed;
 *   2. channel.sendLive rolled its own optimistic row back on failure, so the
 *      screen lost the only remaining copy;
 *   3. nothing awaited the emit's handler, so the rejection became an
 *      unhandled promise rejection and was swallowed.
 *
 * The transport itself is sound: live-ws queues a frame while the socket is
 * not open and flushes it on welcome, rejects everything pending on close
 * with token 'closed', and rejects after `ackTimeoutMs` with token 'timeout'.
 * A caller-supplied `msg_id` makes a resend idempotent, which is what lets a
 * 'closed' rejection be retried rather than reported.
 */

/** The rejection's token, when the thrower set one ('closed', 'timeout', …). */
export function failureToken(err) {
  if (!err || typeof err !== 'object') return ''
  const t = /** @type {{ token?: unknown }} */ (err).token
  return typeof t === 'string' ? t : ''
}

/**
 * Retry ONCE, automatically, only where a retry cannot double-post and the
 * first attempt provably did not reach the hub.
 *
 * 'closed': the socket went away with the frame still pending. live-ws will
 * have reconnected by the time we try again, and the frame carries the same
 * msg_id, so the hub de-dupes even in the race where the first copy did get
 * through. Worth retrying.
 *
 * 'timeout': the hub may simply be slow and may still be writing the row.
 * Resending is idempotent by msg_id, but it is also a second write against a
 * hub that is already not answering in 10s, so this reports instead. The
 * human keeps their text and a Retry button.
 */
export function shouldAutoResend(err) {
  return failureToken(err) === 'closed'
}

/**
 * SPL-964: the one resend, shared by every store that sends a frame. The
 * frame is the caller's, built once, so the retry carries the same msg_id.
 * channel.sendLive had this since CLE-3433; stores/live.ts (the Topics page,
 * /t/<id> and #lobby) did not, and a reply pending when the socket dropped
 * was lost there.
 * @template T
 * @param {() => Promise<T>} send
 * @returns {Promise<T>}
 */
export async function sendWithResend(send) {
  try {
    return await send()
  } catch (first) {
    if (!shouldAutoResend(first)) throw first
    return send()
  }
}

/** i18n key for what the reader is told. Unknown shapes get the generic line. */
export function sendFailureKey(err) {
  switch (failureToken(err)) {
    case 'closed': return 'composer.send_failed_closed'
    case 'timeout': return 'composer.send_failed_timeout'
    case 'empty': return 'composer.send_failed_empty'
    default: return 'composer.send_failed'
  }
}

/**
 * CLE-3433, found by CLE-3434 in the dev hub's own store: a row written at
 * 12:45:42Z with `body = ""`. The composer refuses an empty box, but it
 * measures the text the human typed - and the live send path then runs
 * parseMention() over it, which strips a leading `@CLE-07` and can leave
 * NOTHING behind. Type `@CLE-00` and press Enter and a task frame with an
 * empty body reaches the hub.
 *
 * To the next reader an empty row is indistinguishable from the lost one
 * this whole lane is about, so it is refused at the last point that knows
 * the real payload: after the mention is parsed, before the frame is sent.
 * Files alone are a legitimate message, so they satisfy it.
 */
export function isEmptySend(body, files) {
  const hasText = String(body == null ? '' : body).trim().length > 0
  const hasFiles = Array.isArray(files) && files.length > 0
  return !hasText && !hasFiles
}

/** The rejection isEmptySend() earns; carries a token like every other one. */
export function emptySendError() {
  return Object.assign(new Error('nothing to send'), { token: 'empty' })
}
