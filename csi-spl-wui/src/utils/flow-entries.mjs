/**
 * Flow (owner, topic 635f8072, 2026-10-01): the left panel is a stream of
 * short message entries, newest first, like a messages dropdown - who, where,
 * a short text, the time and an unread dot. A click opens the message in its
 * original place (lane A's openMessage). Pure: no Vue, no store.
 */

import { dmPeerOf } from './channel-feed.mjs'
import { isUnread, when } from './read-cursor.mjs'
import { isViewersOwn } from './typed-by.mjs'
import { eventAsMessage, flowEventKind } from './flow-badge.mjs'

/** How many entries the panel holds. Older ones fall off the end. */
export const FLOW_CAP = 200
/**
 * Entries one page of the Flow shows: the first paint, and each Load more
 * (owner 73c9704c: "use the last 30 entries ... to be quick and nimble").
 */
export const FLOW_PAGE = 30
/** Characters of the message shown in an entry. */
export const FLOW_TEXT_CHARS = 90

/**
 * One line of plain text from a markdown body: code fences, emphasis,
 * links and images reduced to their words, whitespace collapsed, cut at
 * `max` characters (code points, so an emoji is not split).
 */
export function flowText(body, max = FLOW_TEXT_CHARS) {
  const flat = String(body || '')
    .replace(/```[^\n]*\n?/g, ' ')
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/[*_~`>#]+/g, '')
    .replace(/\s+/g, ' ')
    .trim()
  const chars = Array.from(flat)
  return chars.length <= max ? flat : chars.slice(0, max).join('').trimEnd() + '…'
}

/** A reply: it sits in another message's thread. */
export function isThreadReply(m) {
  const parent = String((m && m.parent_task_id) || '')
  return Boolean(parent) && parent !== String((m && m.task_id) || '')
}

/** The read-cursor key a message counts under (notify.mjs channelKey shape). */
export function flowKeyOf(m, self = '') {
  const ch = String((m && m.channel) || '')
  if (ch) return 'ch:' + ch
  const peer = dmPeerOf(m, self)
  return peer ? 'dm:' + peer : ''
}

/**
 * One entry, or null for a row with no id or no text and no file.
 * `where` is the channel id (`kind: 'channel'`) or the DM peer label
 * (`kind: 'dm'`); `reply` marks a thread reply.
 */
export function flowEntry(m, self = '') {
  if (!m || !m.msg_id) return null
  const text = flowText(m.body)
  const files = Array.isArray(m.files) ? m.files.length : 0
  if (!text && !files) return null
  const ch = String(m.channel || '')
  const peer = ch ? '' : dmPeerOf(m, self)
  return {
    key: String(m.msg_id),
    msg_id: String(m.msg_id),
    task_id: String(m.task_id || ''),
    parent_task_id: m.parent_task_id ? String(m.parent_task_id) : null,
    channel: ch || null,
    from: String(m.from || ''),
    from_box: String(m.from_box || ''),
    to: String(m.to || ''),
    to_box: String(m.to_box || ''),
    typed_by: m.typed_by ? String(m.typed_by) : '',
    kind: ch ? 'channel' : 'dm',
    where: ch || peer,
    reply: isThreadReply(m),
    text,
    files,
    at: when(m),
    /* CLE-77889: a line the viewer typed at an agent's terminal is theirs too */
    mine: isViewersOwn(m, self),
  }
}

/**
 * Spec 062 Mine: one entry from the hub's thin flow event (spec 4.2), with
 * `event` (why it concerns the viewer; a poke reads as its mention) and
 * `fresh` (the hub's unread verdict, null when it sent none).
 */
export function flowEventEntry(ev, self = '') {
  const e = flowEntry(eventAsMessage(ev), self)
  if (!e) return null
  const kind = flowEventKind(ev.kind)
  if (kind) e.event = kind
  e.fresh = typeof ev.unread === 'boolean' ? ev.unread : null
  return e
}

/**
 * Fold messages into the held entries: deduped by msg_id (a later copy - an
 * edit - replaces the held one), newest first, at most `cap`. Ties break on
 * msg_id so the order does not flicker. Returns `held` itself when nothing
 * changed, so a store can skip the write. `build` makes one entry (Mine
 * passes flowEventEntry).
 */
export function mergeFlow(held, messages, self = '', cap = FLOW_CAP, build = flowEntry) {
  const by = new Map((held || []).map((e) => [e.key, e]))
  let changed = false
  for (const m of messages || []) {
    const e = build(m, self)
    if (!e) continue
    const was = by.get(e.key)
    if (was && was.text === e.text && was.at === e.at && was.files === e.files && was.fresh === e.fresh && was.event === e.event) continue
    by.set(e.key, e)
    changed = true
  }
  if (!changed) return held || []
  return [...by.values()]
    .sort((a, b) => {
      const c = String(b.at).localeCompare(String(a.at))
      return c !== 0 ? c : a.key.localeCompare(b.key)
    })
    .slice(0, cap)
}

/** Spec 062 Mine: the hub's flow events folded into the held Mine entries. */
export function mergeMine(held, events, self = '') {
  return mergeFlow(held, events, self, FLOW_CAP, flowEventEntry)
}

/** An entry leaves the stream (the message was deleted). */
export function dropFlow(held, msgId) {
  const id = String(msgId || '')
  const list = held || []
  return list.some((e) => e.key === id) ? list.filter((e) => e.key !== id) : list
}

/**
 * The unread dot: not the reader's own message, newer than the read cursor
 * of its channel / DM, and not opened from the Flow in this tab (`opened`).
 */
export function flowUnread(entry, cursors = {}, opened = null) {
  if (!entry || entry.mine) return false
  if (opened && opened.has(entry.key)) return false
  /* spec 062 FR-006: a Mine entry carries the hub's verdict (f:<msg_id> or its place's mark) */
  if (typeof entry.fresh === 'boolean') return entry.fresh
  const key = entry.kind === 'channel' ? 'ch:' + entry.channel : 'dm:' + entry.where
  return isUnread({ msg_id: entry.msg_id, ts: entry.at }, cursors[key])
}

/**
 * The entries the panel shows: the newest `shown` of `held` that the topic
 * pages read so far can vouch for. A page of topics holds each topic's
 * newest few lines only, so while an older page is unread (`boundary` =
 * the oldest read topic's last activity) an entry older than it could still
 * be preceded by a newer line of an unread topic: it waits for that page.
 * `more` = Load more has something to give (held beyond the window, or an
 * unread page).
 */
export function flowWindow(held, shown = FLOW_PAGE, boundary = '') {
  const list = held || []
  const cut = boundary ? Date.parse(boundary) : NaN
  const safe = Number.isFinite(cut) ? list.filter((e) => !(Date.parse(e.at) < cut)) : list
  const entries = safe.slice(0, Math.max(0, shown))
  return { entries, more: Boolean(boundary) || entries.length < list.length }
}
