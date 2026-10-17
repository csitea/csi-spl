/**
 * The first-paint half of poll-control (SPL-1637): only the cheap test and
 * the injection keys, so a body with no ```poll form never loads the parser
 * (poll.mjs) or the form (PollBody.vue / PollForm.vue).
 */

/**
 * true when the body may hold a ```poll form. CR and CRLF count as line ends:
 * splitPolls (poll.mjs) normalises them, so the gate must not hide its forms.
 */
export function mayHavePoll(body) {
  return /(^|[\r\n])`{3,}poll[ \t]*([\r\n]|$)/.test(String(body || ''))
}

/** MessageCard provides the message a form answers and how to open its topic */
export const POLL_HOST = 'spool:poll-host'
/** a topic pane provides the replies it shows: the answers a form reads */
export const POLL_ROWS = 'spool:poll-rows'
