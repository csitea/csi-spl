import { queryWithTopic, topicTargetFor } from './topic-open.mjs'

/**
 * Right-click menu on a message. Same shape as the left-pane row menu:
 * an icon and a translated name per action. Edit and Delete are the author's
 * own browser message only — the same gate as the e shortcut. Copy link is
 * on every message.
 *
 * Every message also has Open: a topic card in the middle (is_topic=1) opens
 * its topic on the right, as the replies button does; a thread line is
 * selected and scrolled into view. The order is Open, Copy link, Edit.
 *
 * A thread line (`parent`) also has Open parent section, right
 * after Open: the channel or DM the thread lives in, the parent card
 * selected there and the thread kept open (utils/parent-section.mjs).
 * HUM-10 (topic c15b557e): its words name that place - `parentKind` 'dm'
 * "Open in direct msg view", 'channel' "Open in channels view"; an issue
 * discussion (or no kind) keeps "Open parent section".
 *
 * A topic card ends with Archive and/or Delete, each with its Material glyph
 * on the left. Archive is offered when `topicArchive` (SPL-983 / specs/041 its
 * author, the tenant owner or an admin; CLE-77819 also a member it is addressed
 * to), Delete when `topicDelete` (the narrower author / owner / admin rule).
 * `topic` is the shorthand for both. That Delete removes the card AND every
 * child, so it replaces the one-message Delete: deleting the card alone would
 * strand its replies.
 *
 * SPL-1024 (specs/045): a card the viewer may move (`moveChannel`: its
 * author, the tenant owner or an admin, a channel topic) gets Move to
 * channel…, a reply they may move (`moveTopic`) Move to topic…, right before
 * the Archive / Delete block. It is the keyboard and touch way to do what the
 * drag does.
 *
 * On a phone (`touch`, SPL-991) the menu is the long-press bottom sheet, the
 * only way to reach what a desktop row shows on hover: it starts with Reply
 * and Add emoji (the row's smile button is hidden on a phone), and adds Copy text, and Kind when the viewer may re-type the message
 * (`kind`; the desktop keeps that on the kind badge). The desktop menu is
 * unchanged.
 *
 * HUM-10 (t1 7d9faaad): `hide` adds Hide from flow (eye-off) right after Copy
 * link. The card sets it only for a topic-view reply a left swipe may hide.
 * Choosing it runs that swipe's hide, on this device only. `feed.swipe_hide`
 * ("Release to hide") is the gesture hint and is not this item's name.
 *
 * t1 7a6be5a3 (owner): on the phone sheet Archive, the most used entry, sits
 * right after Edit (before Kind, Move and Merge), higher up for the thumb;
 * Delete stays last. The desktop keeps Archive next to Delete.
 *
 * CLE-77891 (HUM-24): a topic card's menu has the same shape for every viewer.
 * `locks` (utils/topic-menu.mjs topicMenuLocks) names, per entry, why the
 * viewer may not use it; such an entry is still listed, `disabled` with that
 * reason as `hintKey`, instead of vanishing. Without `locks` (a reply, a
 * thread line) nothing changes.
 *
 * @param {{ editable?: boolean, mergePrev?: boolean, mergeNext?: boolean, parent?: boolean, parentKind?: 'dm' | 'channel' | 'issue' | '', topic?: boolean, topicArchive?: boolean, topicDelete?: boolean, touch?: boolean, kind?: boolean, moveChannel?: boolean, moveTopic?: boolean, mergeTopic?: boolean, promoteTopic?: boolean, hide?: boolean, locks?: { edit?: string, move?: string, merge?: string, archive?: string, delete?: string } }} [opts]
 * @returns {{ id: 'reply' | 'react' | 'open' | 'parent' | 'edit' | 'copy' | 'copy-text' | 'kind' | 'merge-prev' | 'merge-next' | 'move-channel' | 'move-topic' | 'merge-topic' | 'promote-topic' | 'hide-flow' | 'delete' | 'archive' | 'delete-topic', icon: 'reply' | 'smile' | 'open' | 'parent' | 'pencil' | 'copy' | 'tag' | 'merge' | 'move' | 'trash' | 'archive' | 'delete' | 'eye-off', labelKey: string, disabled?: boolean, hintKey?: string }[]}
 */
/** HUM-10 (topic c15b557e): the parent item's words per place */
const PARENT_LABEL = { dm: 'feed.msg_menu.open_in_dm', channel: 'feed.msg_menu.open_in_channels' }

export function msgMenuItems(opts = {}) {
  const o = opts && typeof opts === 'object' ? opts : {}
  const editable = Boolean(o.editable)
  const touch = Boolean(o.touch)
  const copy = { id: 'copy', icon: 'copy', labelKey: 'feed.msg_menu.copy_link' }
  const edit = { id: 'edit', icon: 'pencil', labelKey: 'feed.msg_menu.edit' }
  const items = []
  const locks = o.locks && typeof o.locks === 'object' ? o.locks : {}
  /** the entry when allowed, else - when locked - the entry disabled with its reason */
  const gated = (on, item, lock) => {
    if (on) items.push(item)
    else if (lock) items.push({ ...item, disabled: true, hintKey: String(lock) })
  }
  if (touch) {
    items.push({ id: 'reply', icon: 'reply', labelKey: 'feed.msg_menu.reply' })
    items.push({ id: 'react', icon: 'smile', labelKey: 'feed.emoji.add' })
  }
  items.push({ id: 'open', icon: 'open', labelKey: 'feed.msg_menu.open' })
  if (o.parent) items.push({ id: 'parent', icon: 'parent', labelKey: PARENT_LABEL[o.parentKind] || 'feed.msg_menu.open_parent' })
  if (touch) items.push({ id: 'copy-text', icon: 'copy', labelKey: 'feed.msg_menu.copy_text' })
  items.push(copy)
  if (o.hide) items.push({ id: 'hide-flow', icon: 'eye-off', labelKey: 'feed.msg_menu.hide_flow' })
  gated(editable, edit, locks.edit)
  // CLE-77819: Archive and Delete are gated apart - a member the card is
  // addressed to may archive but not delete. `topic` stays the both-shorthand.
  const wantArchive = Boolean(o.topic || o.topicArchive)
  const wantDelete = Boolean(o.topic || o.topicDelete)
  const archive = () => gated(wantArchive, { id: 'archive', icon: 'archive', labelKey: 'feed.msg_menu.archive' }, locks.archive)
  if (touch) archive()
  if (touch && o.kind) items.push({ id: 'kind', icon: 'tag', labelKey: 'feed.msg_menu.kind' })
  if (editable && o.mergePrev) items.push({ id: 'merge-prev', icon: 'merge', labelKey: 'feed.msg_menu.merge_prev' })
  if (editable && o.mergeNext) items.push({ id: 'merge-next', icon: 'merge', labelKey: 'feed.msg_menu.merge_next' })
  gated(o.moveChannel, { id: 'move-channel', icon: 'move', labelKey: 'feed.msg_menu.move_channel' }, locks.move)
  // 714c7028: a topic card can also MERGE its whole topic into another topic.
  gated(o.mergeTopic, { id: 'merge-topic', icon: 'merge', labelKey: 'feed.msg_menu.merge_topic' }, locks.merge)
  if (o.moveTopic) items.push({ id: 'move-topic', icon: 'move', labelKey: 'feed.msg_menu.move_topic' })
  // 8f588edd: a reply can also be PROMOTED into a new topic of its own - the
  // keyboard / touch way to do what the drag into the topics list does.
  if (o.promoteTopic) items.push({ id: 'promote-topic', icon: 'move', labelKey: 'feed.msg_menu.promote_topic' })
  if (!touch) archive()
  if (wantDelete || locks.delete) gated(wantDelete, { id: 'delete-topic', icon: 'delete', labelKey: 'feed.msg_menu.delete' }, locks.delete)
  else if (editable && !wantArchive) items.push({ id: 'delete', icon: 'trash', labelKey: 'feed.msg_menu.delete' })
  return items
}

function at(m) {
  return String((m && (m.received_at || m.ts)) || '')
}

/** The thread is the task. A row with no task is not in a thread. */
function threadKey(m) {
  return String((m && m.task_id) || '')
}

/**
 * The message sent immediately before or after `msg` in the same thread.
 *
 * `rows` is the list on screen. Previous is the older neighbor, next is the
 * newer one. A message from another task is not a neighbor, even when it
 * sits next to this row in a mixed list.
 *
 * @param {unknown[]} rows
 * @param {unknown} msg
 * @param {'previous' | 'next'} which
 * @returns {object | null}
 */
export function threadNeighbor(rows, msg, which) {
  return neighborIn(threadNeighbors(rows), msg, which)
}

function byThreadOrder(a, b) {
  const c = at(a).localeCompare(at(b))
  return c !== 0 ? c : String(a.msg_id || '').localeCompare(String(b.msg_id || ''))
}

/**
 * Every row's thread neighbors at once: one pass that groups `rows` by
 * thread and sorts each group once. threadNeighbor() per row sorted the whole
 * thread for every row it was asked about (a feed asks twice per card on
 * every render), O(n^2 log n); a feed builds this once per `rows` and reads
 * it per card (CLE-35075). The same order and tie-break as before, and a
 * repeated msg_id keeps its first position, as findIndex did.
 *
 * @param {unknown[]} rows
 * @returns {Map<string, { previous: object | null, next: object | null }>} keyed by thread + NUL + msg_id
 */
export function threadNeighbors(rows) {
  const groups = new Map()
  for (const m of Array.isArray(rows) ? rows : []) {
    const key = threadKey(m)
    if (!m || !key || !String(m.msg_id || '')) continue
    const g = groups.get(key)
    if (g) g.push(m)
    else groups.set(key, [m])
  }
  const out = new Map()
  for (const [key, peers] of groups) {
    peers.sort(byThreadOrder)
    for (let i = 0; i < peers.length; i++) {
      const k = key + '\0' + String(peers[i].msg_id)
      if (!out.has(k)) out.set(k, { previous: i > 0 ? peers[i - 1] : null, next: i < peers.length - 1 ? peers[i + 1] : null })
    }
  }
  return out
}

/**
 * threadNeighbor() read from a threadNeighbors() index.
 *
 * @param {ReturnType<typeof threadNeighbors>} index
 * @param {unknown} msg
 * @param {'previous' | 'next'} which
 */
export function neighborIn(index, msg, which) {
  const id = String((msg && msg.msg_id) || '')
  const key = threadKey(msg)
  if (!id || !key || (which !== 'previous' && which !== 'next')) return null
  const hit = index.get(key + '\0' + id)
  return hit ? hit[which] : null
}

/**
 * may `msg` be merged AWAY (deleted into a neighbor)? Not when it
 * opens its topic: a task's first row with is_parent 1 is the topic's card,
 * and the hub refuses it (409 is_card) rather than leave a topic with no
 * card. Lobby rows are each their own card and stay mergeable. A row whose
 * older neighbor is not loaded reads as the first one, so the item is then
 * hidden, never offered and refused.
 *
 * @param {unknown[]} rows
 * @param {unknown} msg
 * @param {string} [lobbyTaskId]
 */
export function mergeableSource(rows, msg, lobbyTaskId = '') {
  return mergeableSourceIn(threadNeighbors(rows), msg, lobbyTaskId)
}

/**
 * mergeableSource() read from a threadNeighbors() index.
 *
 * @param {ReturnType<typeof threadNeighbors>} index
 * @param {unknown} msg
 * @param {string} [lobbyTaskId]
 */
export function mergeableSourceIn(index, msg, lobbyTaskId = '') {
  const m = msg && typeof msg === 'object' ? msg : null
  if (!m) return false
  const task = threadKey(m)
  if (m.is_parent === 0 || (task && task === String(lobbyTaskId || ''))) return true
  return neighborIn(index, m, 'previous') !== null
}

/**
 * Both bodies, older first, as one message. A blank line keeps the two
 * parts apart. Empty sides contribute nothing.
 *
 * @param {unknown} older
 * @param {unknown} newer
 */
export function joinBodies(older, newer) {
  const a = String(older == null ? '' : older).replace(/\s+$/, '')
  const b = String(newer == null ? '' : newer).replace(/^\s+/, '')
  if (!a) return b
  if (!b) return a
  return `${a}\n\n${b}`
}

/**
 * The address copied for one message: the topic page, with the message id
 * as the hash, so two messages in one topic do not share a link.
 *
 * @param {unknown} msg
 * @param {(path: string) => string} pathFor locale-aware path, e.g. localePath
 * @returns {string} a path, or '' when the message names no topic
 */
export function messageLink(msg, pathFor) {
  const m = msg && typeof msg === 'object' ? msg : {}
  const task = String(m.task_id || m.parent_task_id || '')
  const id = String(m.msg_id || '')
  if (!task || typeof pathFor !== 'function') return ''
  const path = String(pathFor('/t/' + task) || '')
  if (!path) return ''
  return id ? `${path}#${id}` : path
}

/**
 * The address copied for a topic card in the middle pane: this page, with
 * the card's topic in ?topic= (and ?in= for a #lobby message). Pasting it
 * opens the same list with that topic open in the right pane. Every other
 * query parameter is kept.
 *
 * @param {unknown} msg
 * @param {{ path?: string, query?: Record<string, unknown>, currentTaskId?: string }} [where]
 * @returns {string} a path with a query, or '' when the card names no topic
 */
export function topicPaneLink(msg, where = {}) {
  const w = where && typeof where === 'object' ? where : {}
  const path = String(w.path || '')
  const target = topicTargetFor(msg, { currentTaskId: String(w.currentTaskId || '') })
  if (!path || !target) return ''
  return withQuery(path, queryWithTopic(w.query || {}, target))
}

/**
 * The address copied for a thread line in the right pane: this page with the
 * open topic kept in ?topic= / ?in=, and the line's id as the hash. Pasting it
 * opens the pane and scrolls to that line. A page with no ?topic= (the
 * /t/<task> page) falls back to messageLink.
 *
 * @param {unknown} msg
 * @param {{ path?: string, query?: Record<string, unknown>, pathFor?: (path: string) => string }} [where]
 * @returns {string}
 */
export function threadLineLink(msg, where = {}) {
  const w = where && typeof where === 'object' ? where : {}
  const query = w.query && typeof w.query === 'object' ? w.query : {}
  const topic = Array.isArray(query.topic) ? query.topic[0] : query.topic
  const path = String(w.path || '')
  if (!topic || !path) return messageLink(msg, w.pathFor)
  const id = String((msg && msg.msg_id) || '')
  const url = withQuery(path, query)
  return id ? `${url}#${id}` : url
}

function withQuery(path, query) {
  const qs = new URLSearchParams()
  for (const [k, v] of Object.entries(query || {})) {
    for (const one of Array.isArray(v) ? v : [v]) {
      if (one !== undefined && one !== null) qs.append(k, String(one))
    }
  }
  const text = qs.toString()
  return text ? `${path}?${text}` : path
}
