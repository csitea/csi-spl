/*
 * A topic card's counts, apart from read-cursor.mjs: only the lazy cards read
 * them, so they stay off the initial script (ci_initial_gzip_kb, spec 027).
 */

/**
 * SPL-2422: a topic card's "<new>/<total>": total = the opening message plus
 * its replies, new = the unread replies (capped at the replies) plus 1 when
 * the opening message is unseen (openerUnseen).
 *
 * SPL-2506 (owner, t1 d8fa6f9c): new is never less than the hub's `t:` key
 * for the topic. The channel badge is the hub's `ch:` key, the sum of its
 * topics' `t:` keys; the local count is 0 for a topic never opened on this
 * device, so a reply could count in the badge and on no card. The larger of
 * the two wins: a `ch:` mark can zero the hub key (062 FR-006), never the card.
 *
 * @param {number} replies the topic's reply total
 * @param {number} unreadReplies the unread replies (topicUnread)
 * @param {boolean} openerNew openerUnseen for its opening message
 * @param {number} [hubUnread] the hub's Flow key `t:<task_id>` (0 if none)
 * @returns {{ total: number, unseen: number }}
 */
export function topicCounts(replies, unreadReplies, openerNew = false, hubUnread = 0) {
  const n = Math.max(0, Number(replies) || 0)
  const unread = Math.max(0, Math.min(n, Number(unreadReplies) || 0))
  const hub = Math.max(0, Math.min(n + 1, Math.floor(Number(hubUnread)) || 0))
  return { total: n + 1, unseen: Math.max(unread + (openerNew ? 1 : 0), hub) }
}
