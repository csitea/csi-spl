/**
 * CLE-77930: the thread-cursor seeding a channel open runs. Its own module,
 * loaded on that open (stores/notification seedTopics), so it stays out of
 * the initial chunk (specs/027 perf budget).
 */
import { isViewersOwn } from './typed-by.mjs'
import { OWN_KEEP, isUnread, replyTopicsOf, topicKey, when } from './read-cursor.mjs'

/**
 * CLE-77930 (owner, t1 bf737f3f): "I see, on a specific channel, 2 new
 * messages, then I go there and there is nothing new for me." The channel
 * badge counts every line after the reader's channel cursor, and 91% of them
 * are thread replies (prd, 24 h, n=393). A thread the reader never opened had
 * no t:<id> cursor, so its card showed a plain total (topicUnread -> 0), and
 * opening the channel cleared the badge: the new lines were counted, then
 * shown nowhere.
 *
 * The one rule (hub ViewChannelStats and here): a line is new for the reader
 * when it is not their own and it is after their mark for its THREAD, or -
 * when they have no mark for that thread - after their mark for the CHANNEL.
 *
 * So, as a channel opens and before its cursor moves, every thread that has
 * replies after the frozen channel boundary and no t:<id> cursor of its own
 * gets one AT that boundary: count = total - those unseen replies, `own` = the
 * reader's own replies after it (already counted as seen, so ownReplyReadAt
 * never counts them twice). The card then reads "<new>/<total> >>" until the
 * thread is opened. A channel with no boundary (never read) seeds nothing.
 *
 * @param {Record<string, any>} cursors loadCursors()
 * @param {{ ts?: string, id?: string } | null | undefined} boundary the channel cursor frozen at open
 * @param {any[]} messages the channel feed's held rows
 * @param {(taskId: string) => number} totalOf the thread's current reply total (repliesFor)
 * @param {string} selfId the reader
 * @returns {Record<string, any>} the same object when nothing was seeded
 */
export function seedTopicCursors(cursors, boundary, messages, totalOf, selfId = '') {
  if (!boundary || !boundary.ts) return cursors
  const fresh = unseenRepliesSince(messages, boundary, selfId)
  let next = cursors
  for (const [taskId, { unseen, own }] of fresh) {
    const key = topicKey(taskId)
    if (!key || !unseen || (cursors && cursors[key])) continue
    const total = Math.max(0, Number(totalOf(taskId)) || 0)
    const c = { ts: String(boundary.ts), id: String(boundary.id || ''), count: Math.max(0, total - unseen) }
    if (next === cursors) next = { ...(cursors || {}) }
    next[key] = own.length ? { ...c, own: own.slice(-OWN_KEEP) } : c
  }
  return next
}

/**
 * Per thread, the replies after `boundary`: `unseen` counts the others' lines,
 * `own` lists the reader's own msg_ids. A thread's opening line (the earliest
 * held row of its task_id) is not a reply of that thread; a child thread's
 * opener still counts under its parent.
 *
 * @param {any[]} messages
 * @param {{ ts?: string, id?: string }} boundary
 * @param {string} selfId
 * @returns {Map<string, { unseen: number, own: string[] }>}
 */
export function unseenRepliesSince(messages, boundary, selfId = '') {
  const rows = (messages || []).filter((m) => m && m.msg_id && !m.topic_row && !m.pending)
  const opener = new Map()
  for (const m of rows) {
    if (!m.task_id) continue
    const was = opener.get(m.task_id)
    if (!was || when(m) < when(was) || (when(m) === when(was) && String(m.msg_id) < String(was.msg_id))) opener.set(m.task_id, m)
  }
  const out = new Map()
  for (const m of rows) {
    if (!isUnread(m, boundary)) continue
    const own = isViewersOwn(m, selfId)
    for (const id of replyTopicsOf(m)) {
      if (id === String(m.task_id || '') && opener.get(id) === m) continue
      const e = out.get(id) || { unseen: 0, own: [] }
      if (own) e.own.push(String(m.msg_id))
      else e.unseen++
      out.set(id, e)
    }
  }
  return out
}
