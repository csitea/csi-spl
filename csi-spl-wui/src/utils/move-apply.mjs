// csi-spl-wui/src/utils/move-apply.mjs
//
// SPL-1024 (specs/045): the half of the move logic needed only once a move
// happens (a drop, the picker, a live frame, an old channel link). Loaded
// with `await import()`, so it stays out of the initial JS (specs/027
// budget); the half every card needs at first paint (who may drag, what
// lights up) is utils/move.mjs.

import { moveBlocked as blocked, moveChan as chan } from './move.mjs'

/**
 * The channels a topic may be moved into, in the order given: those listed
 * for the viewer (the hub lists only channels they may read), minus the
 * current one, the lobby and `issues`.
 */
export function moveChannelTargets(channels, current = '') {
  const here = chan(current)
  const out = []
  for (const c of Array.isArray(channels) ? channels : []) {
    const id = chan(c && (c.channel_id || c.channel))
    if (!id || id === here || blocked(id) || out.some((o) => o.channel_id === id)) continue
    out.push({ channel_id: id, name: String((c && c.name) || id) })
  }
  return out
}

/**
 * A topic_moved / message_moved frame (move-v1 §6), normalized; null for
 * anything else. `msg_ids` always includes `msg_id`.
 */
export function moveFrame(frame) {
  const f = frame && typeof frame === 'object' ? frame : null
  if (!f || (f.type !== 'topic_moved' && f.type !== 'message_moved')) return null
  const msgId = String(f.msg_id || '')
  const ids = Array.isArray(f.msg_ids) ? f.msg_ids.map(String).filter(Boolean) : []
  if (msgId && !ids.includes(msgId)) ids.unshift(msgId)
  return {
    type: f.type,
    msg_id: msgId,
    task_id: String(f.task_id || ''),
    from_task: String(f.from_task || ''),
    channel: chan(f.channel),
    from_channel: chan(f.from_channel),
    moved: f.moved !== false,
    moved_by: String(f.moved_by || ''),
    moved_at: String(f.moved_at || ''),
    msg_ids: ids,
  }
}

/** The frame a successful POST .../move answer stands for (applied at once, before the socket's copy). */
export function moveFrameFromAnswer(answer) {
  const a = answer && typeof answer === 'object' ? answer : {}
  return moveFrame({ ...a, type: a.kind === 'message' ? 'message_moved' : 'topic_moved' })
}

/**
 * The rows on screen after a move: every row the frame names takes the new
 * channel and the stamp (cleared on a move home); the moved reply takes the
 * target task and becomes a reply there; a row of its thread that pointed at
 * the old topic points at the new one. Idempotent; same array when nothing
 * it holds changed.
 */
export function applyMoveRows(rows, frame) {
  const f = moveFrame(frame)
  const list = Array.isArray(rows) ? rows : []
  if (!f) return list
  const ids = new Set(f.msg_ids)
  let changed = false
  const out = list.map((r) => {
    if (!r || !ids.has(String(r.msg_id || ''))) return r
    changed = true
    const next = { ...r }
    if (f.channel) next.channel = f.channel
    if (f.moved) {
      next.moved_at = f.moved_at
      next.moved_by = f.moved_by
      if (!next.moved_from_channel && f.from_channel) next.moved_from_channel = f.from_channel
    } else {
      delete next.moved_at
      delete next.moved_by
      delete next.moved_from_channel
      delete next.moved_from_task
    }
    if (f.type === 'message_moved') {
      if (String(r.msg_id) === f.msg_id) {
        next.task_id = f.task_id
        next.parent_task_id = null
        next.is_parent = 0
        if (f.moved && !next.moved_from_task && f.from_task) next.moved_from_task = f.from_task
      } else if (f.from_task && String(r.parent_task_id || '') === f.from_task) {
        next.parent_task_id = f.task_id
      }
    }
    return next
  })
  return changed ? out : list
}

/** The rows' msg_ids a move took OUT of a pane showing `taskId` (message_moved from it). */
export function moveLeavesTask(frame, taskId) {
  const f = moveFrame(frame)
  const id = String(taskId || '')
  if (!f || !id || f.type !== 'message_moved' || f.from_task !== id || f.task_id === id) return []
  return [f.msg_id]
}

/** Whether a pane showing `taskId` gained rows by this move (it re-reads). */
export function moveJoinsTask(frame, taskId) {
  const f = moveFrame(frame)
  const id = String(taskId || '')
  return Boolean(f && id && f.type === 'message_moved' && f.task_id === id && f.from_task !== id)
}

/**
 * A topic_merged / topic_unmerged frame (714c7028), normalized; null for
 * anything else. `msg_ids` always includes `msg_id` (the source opener).
 */
export function mergeFrame(frame) {
  const f = frame && typeof frame === 'object' ? frame : null
  if (!f || (f.type !== 'topic_merged' && f.type !== 'topic_unmerged')) return null
  const msgId = String(f.msg_id || '')
  const ids = Array.isArray(f.msg_ids) ? f.msg_ids.map(String).filter(Boolean) : []
  if (msgId && !ids.includes(msgId)) ids.unshift(msgId)
  return {
    type: f.type,
    msg_id: msgId,
    task_id: String(f.task_id || ''),
    from_task: String(f.from_task || ''),
    channel: chan(f.channel),
    from_channel: chan(f.from_channel),
    msg_ids: ids,
  }
}

/** The frame a successful merge answer stands for (applied at once, before the socket copy). */
export function mergeFrameFromAnswer(answer) {
  const a = answer && typeof answer === 'object' ? answer : {}
  return mergeFrame({ ...a, type: a.kind === 'unmerge' ? 'topic_unmerged' : 'topic_merged' })
}

/**
 * A merge (or its undo) applied to every store that can hold its rows. A merge
 * folds the whole source topic into the target, so - unlike a move - the
 * source topic disappears; the safe, idempotent way to reflect that on screen
 * is to drop the source card and re-READ the affected topics/channel from the
 * hub (the authoritative state), not to reshuffle rows by hand. Returns the
 * normalized frame, or null for anything that is not a merge.
 */
export function applyMergeToStores(frame, { channel, main, pane, viewer, getTopic } = {}) {
  const f = mergeFrame(frame)
  if (!f) return null
  const ids = new Set(f.msg_ids)
  if (viewer && Array.isArray(viewer.topics) && f.type === 'topic_merged' && f.from_task) {
    const next = viewer.topics.filter((r) => String((r && r.task_id) || '') !== f.from_task)
    if (next.length !== viewer.topics.length) viewer.topics = next
  }
  if (channel) {
    if (f.type === 'topic_merged') {
      const next = channel.messages.filter((m) => !ids.has(String((m && m.msg_id) || '')))
      if (next.length !== channel.messages.length) channel.messages = next
    }
    const here = chan(channel.active)
    if (here && (here === f.channel || here === f.from_channel)) void channel.catchUp()
  }
  for (const s of [main, pane]) {
    if (!s || !s.taskId) continue
    const t = String(s.taskId)
    if (t === f.task_id && typeof getTopic === 'function') {
      void Promise.resolve(getTopic(t)).then((d) => {
        if (String(s.taskId) === t) s.admit((d && d.messages) || [])
      }).catch(() => {})
    } else if (f.type === 'topic_unmerged' && t === f.from_task && typeof s.drop === 'function') {
      for (const id of ids) s.drop(id)
    }
  }
  return f
}

/**
 * A topic_promoted / topic_demoted frame (8f588edd), normalized; null for
 * anything else. `msg_ids` always includes `msg_id` (the promoted message).
 */
export function promoteFrame(frame) {
  const f = frame && typeof frame === 'object' ? frame : null
  if (!f || (f.type !== 'topic_promoted' && f.type !== 'topic_demoted')) return null
  const msgId = String(f.msg_id || '')
  const ids = Array.isArray(f.msg_ids) ? f.msg_ids.map(String).filter(Boolean) : []
  if (msgId && !ids.includes(msgId)) ids.unshift(msgId)
  return {
    type: f.type,
    msg_id: msgId,
    task_id: String(f.task_id || ''),
    from_task: String(f.from_task || ''),
    channel: chan(f.channel),
    from_channel: chan(f.from_channel),
    msg_ids: ids,
  }
}

/** The frame a successful promote answer stands for (applied at once, before the socket copy). */
export function promoteFrameFromAnswer(answer) {
  const a = answer && typeof answer === 'object' ? answer : {}
  return promoteFrame({ ...a, type: a.kind === 'demote' ? 'topic_demoted' : 'topic_promoted' })
}

/**
 * A promote (or its undo) applied to every store that can hold its rows. A
 * promote splits one reply out of its topic into a NEW topic of the same
 * channel, so - like a merge - the safe, idempotent reflection is to drop the
 * moved rows from the source pane and re-READ the affected topic/channel from
 * the hub, not to reshuffle rows by hand. Returns the normalized frame, or null
 * for anything that is not a promote.
 */
export function applyPromoteToStores(frame, { channel, main, pane, viewer, getTopic } = {}) {
  const f = promoteFrame(frame)
  if (!f) return null
  const ids = new Set(f.msg_ids)
  // The undo drops the (now gone) new topic from the topics list.
  if (viewer && Array.isArray(viewer.topics) && f.type === 'topic_demoted' && f.from_task) {
    const next = viewer.topics.filter((r) => String((r && r.task_id) || '') !== f.from_task)
    if (next.length !== viewer.topics.length) viewer.topics = next
  }
  if (channel) {
    const here = chan(channel.active)
    if (here && here === f.channel) void channel.catchUp()
  }
  for (const s of [main, pane]) {
    if (!s || !s.taskId) continue
    const t = String(s.taskId)
    // the pane the rows land in (the new topic on a promote, the restored
    // source on an undo, both f.task_id) re-reads its window; the pane they
    // left (f.from_task) drops them.
    if (t === f.task_id && typeof getTopic === 'function') {
      void Promise.resolve(getTopic(t)).then((d) => {
        if (String(s.taskId) === t) s.admit((d && d.messages) || [])
      }).catch(() => {})
    } else if (t === f.from_task && typeof s.drop === 'function') {
      for (const id of ids) s.drop(id)
    }
  }
  return f
}

/**
 * The catalogue key for a refused or failed PROMOTE (8f588edd): the move
 * wording (the hub tokens are the move tokens), plus - like a merge - a 404
 * with NO hub token that means the endpoint is not deployed yet (the WUI
 * shipped ahead of the hub); that must read as "not available yet", never a
 * silent nothing.
 */
export function promoteErrorKey(e) {
  const o = e && typeof e === 'object' ? e : {}
  const tok = 'token' in o ? String(o.token || '') : ''
  const status = Number(o.status || 0)
  if (tok === 'not_allowed' || tok === 'forbidden') return 'feed.move.error_forbidden'
  if (['lobby', 'not_in_channel', 'issue_topic', 'is_card', 'cycle', 'not_found'].includes(tok)) return `feed.move.error_${tok}`
  if (!tok && status === 404) return 'feed.merge.error_unavailable'
  return 'feed.move.error'
}

/** The catalogue key for a refused or failed move. */
export function moveErrorKey(e) {
  const tok = e && typeof e === 'object' && 'token' in e ? String(e.token || '') : ''
  if (tok === 'not_allowed' || tok === 'forbidden') return 'feed.move.error_forbidden'
  if (['lobby', 'not_in_channel', 'issue_topic', 'same_place', 'is_card', 'not_a_card', 'cycle', 'unknown_channel', 'not_found'].includes(tok)) return `feed.move.error_${tok}`
  return 'feed.move.error'
}

/**
 * The catalogue key for a refused or failed MERGE (714c7028): merge-specific
 * wording, plus one extra case - a 404 with NO hub token is the endpoint not
 * being there yet (the WUI shipped ahead of the hub). That must read as "not
 * available yet", never a silent nothing (prd t1 493564b7: the hub served the
 * merge UI before it served POST /merge-topic).
 */
export function mergeErrorKey(e) {
  const o = e && typeof e === 'object' ? e : {}
  const tok = 'token' in o ? String(o.token || '') : ''
  const status = Number(o.status || 0)
  if (tok === 'not_allowed' || tok === 'forbidden') return 'feed.merge.error_forbidden'
  if (['lobby', 'not_in_channel', 'issue_topic', 'same_place', 'not_a_card', 'cycle', 'not_found'].includes(tok)) return `feed.merge.error_${tok}`
  if (!tok && status === 404) return 'feed.merge.error_unavailable'
  return 'feed.merge.error'
}

/** The task ids an old channel URL can name: ?topic=, ?thread=, then ?in= (the parent of a message-rooted topic). */
export function queryTasks(query) {
  const q = query && typeof query === 'object' ? query : {}
  const one = (v) => String((Array.isArray(v) ? v[0] : v) || '')
  const out = []
  for (const k of ['topic', 'thread', 'in']) {
    const v = one(q[k])
    if (v && !out.includes(v)) out.push(v)
  }
  return out
}

/**
 * The channel an old channel URL must be sent to (spec 3.1 deep links): the
 * channel of the task's rows (the move override applied) when they were
 * moved and that is not the channel on screen; '' otherwise. A row that was
 * never moved is not redirected: a link naming a topic of another channel
 * keeps its old behaviour (the pane closes).
 */
export function movedChannelFor(rows, current) {
  const here = chan(current)
  for (const r of Array.isArray(rows) ? rows : []) {
    const c = chan(r && r.channel)
    if (!c) continue
    return r.moved_at && c !== here ? c : ''
  }
  return ''
}

/**
 * The topic picker's rows: topics of the channels the viewer may post in,
 * not the reply's own topic, filtered by `query` (title or #channel), newest
 * activity first.
 */
export function moveTopicChoices(topics, { channels = [], exclude = [], query = '', lobbyTaskId = '' } = {}) {
  const allowed = new Set(moveChannelTargets(channels, '').map((c) => c.channel_id))
  const skip = new Set((exclude || []).map(String).filter(Boolean))
  if (lobbyTaskId) skip.add(String(lobbyTaskId))
  const q = String(query || '').trim().toLowerCase()
  const seen = new Set()
  const out = []
  for (const t of Array.isArray(topics) ? topics : []) {
    const task = String((t && t.task_id) || '')
    const c = chan(t && t.channel)
    if (!task || seen.has(task) || skip.has(task) || !allowed.has(c)) continue
    const title = String((t && (t.subject || t.title)) || '').trim()
    if (q && !title.toLowerCase().includes(q) && !`#${c}`.includes(q)) continue
    seen.add(task)
    out.push({ task_id: task, channel: c, title, last_ts: String((t && (t.last_ts || t.first_ts)) || '') })
  }
  return out.sort((a, b) => b.last_ts.localeCompare(a.last_ts))
}

/**
 * One move (an answer turned frame, or the hub's frame) applied to every
 * store that can hold its rows. The stores are passed in (pinia setup-store
 * proxies: their refs assign through), so this module stays out of the
 * initial chunk.
 * - the channel feed: rows take their new place, the ones that left the open
 *   channel go, and a channel the rows left or joined is read again (merged
 *   by msg_id) so its cards and reply counts follow;
 * - the live feeds: a reply that left the open task goes, a task that gained
 *   one reads its newest window again (`getTopic`);
 * - the topic list row of a moved topic names its new channel;
 * - the pinned root of a message-rooted pane.
 * Returns the normalized frame, or null for anything that is not a move.
 */
export function applyMoveToStores(frame, { channel, main, pane, viewer, topic, getTopic } = {}) {
  const f = moveFrame(frame)
  if (!f) return null
  const ids = new Set(f.msg_ids)
  if (channel) {
    let next = applyMoveRows(channel.messages, f)
    const here = chan(channel.active)
    if (here) next = next.filter((m) => !ids.has(String((m && m.msg_id) || '')) || chan(m.channel) === here)
    if (next !== channel.messages) channel.messages = next
    if (here && (f.channel === here || f.from_channel === here)) void channel.catchUp()
  }
  for (const s of [main, pane]) {
    if (!s) continue
    const next = applyMoveRows(s.messages, f)
    if (next !== s.messages) s.messages = next
    for (const id of moveLeavesTask(f, s.taskId)) s.drop(id)
    if (moveJoinsTask(f, s.taskId) && typeof getTopic === 'function') {
      const task = s.taskId
      void Promise.resolve(getTopic(task)).then((d) => {
        if (s.taskId === task) s.admit((d && d.messages) || [])
      }).catch(() => {})
    }
  }
  if (viewer && f.type === 'topic_moved' && f.channel && Array.isArray(viewer.topics) && viewer.topics.some((r) => r.task_id === f.task_id)) {
    viewer.topics = viewer.topics.map((r) => (r.task_id === f.task_id ? { ...r, channel: f.channel } : r))
  }
  if (topic && topic.rootMsg && ids.has(String(topic.rootMsg.msg_id || ''))) {
    topic.applyEditedRoot(applyMoveRows([topic.rootMsg], f)[0])
  }
  return f
}
