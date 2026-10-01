import { withSessionRetry } from './live-follow.mjs'
import { parentSection } from './parent-section.mjs'

/**
 * CLE-77882 (Flow + Search rework, lane A, owner t1 635f8072): open ANY
 * message in its original place. The Flow list and the Search results stay
 * on the left; a click shows the message where it was posted - its channel
 * or DM with its topic open, scrolled to it and marked for ~2 s; a thread
 * reply opens its thread on the right with the reply marked.
 *
 * Loaded only when a message is opened (composables/useOpenMessage imports
 * this file dynamically), so none of it sits in the initial chunk.
 *
 * The place itself is the one Open parent section rule
 * (utils/parent-section-open.mjs): it pushes /channel/<ch> or /dm/<peer>
 * with ?topic= (?in=) and #<msg_id>, reads older pages until the card is
 * there, and keeps the thread open on it. This file adds what a caller
 * holding only an id needs (a deep link /m/<msg_id>), the failure reasons,
 * and the mark.
 */

/** How long the opened message stays marked. */
export const OPEN_FOCUS_MS = 2000

/** The classes the mark sets: `open-focus`, and the search flash it shares a style with. */
export const OPEN_FOCUS_CLASSES = ['open-focus', 'search-focus']

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

/** Is this a message id the hub can answer for? (lower-case uuid) */
export function isMessageId(id) {
  return UUID.test(String(id || ''))
}

/** The deep link of one message: /m/<msg_id>, locale-aware through `pathFor`. */
export function messageHref(msgId, pathFor = (p) => p) {
  const id = String(msgId || '')
  if (!id) return ''
  const path = '/m/' + encodeURIComponent(id)
  return String(pathFor(path) || path)
}

/**
 * Why a hub read of the message failed. The hub answers 404 for a message
 * that is gone and for one the reader may not see (rdb 0028: it never tells
 * which), so both are `not_found`; 403 is the role without topics.read.
 * @returns {'not_found' | 'no_access' | 'error'}
 */
export function failureReason(err) {
  const status = Number(err && err.status)
  if (status === 403) return 'no_access'
  if (status === 404 || status === 410 || status === 400) return 'not_found'
  return 'error'
}

/**
 * A row that cannot be opened as it is: a tombstone, or an archived card.
 * @returns {'' | 'deleted' | 'archived'}
 */
export function rowReason(row) {
  const m = row && typeof row === 'object' ? row : {}
  if (m.deleted || m.deleted_at || m.tombstone) return 'deleted'
  if (m.archived === true || m.archived_at) return 'archived'
  return ''
}

/**
 * The full row of a message the caller knows only by id.
 *
 * move-v1 §4 (`moveInfo`) names its task and channel under the reader's
 * own door; the topic read then gives the row itself, with the DM ends
 * and the parent a reply needs. A topic longer than one read still opens:
 * the channel and task are enough for a channel message.
 *
 * @param {string} msgId
 * @param {any} api the spool client
 * @param {{ limit?: number }} [opts]
 * @returns {Promise<{ row: Record<string, any>, archived?: boolean } | { reason: 'not_found' | 'no_access' | 'archived' | 'error' }>}
 */
export async function resolveMessage(msgId, api, { limit = 200 } = {}) {
  const id = String(msgId || '').toLowerCase()
  if (!isMessageId(id)) return { reason: 'not_found' }
  let info
  try {
    info = await withSessionRetry(api, () => api.moveInfo(id))
  } catch (e) {
    return { reason: failureReason(e) }
  }
  const taskId = String((info && info.task_id) || '')
  if (!taskId) return { reason: 'not_found' }
  let rows = []
  try {
    rows = (await withSessionRetry(api, () => api.getTopic(taskId, { limit }))).messages || []
  } catch (e) {
    const reason = failureReason(e)
    if (reason !== 'not_found') return { reason }
  }
  const found = rows.find((m) => String((m && m.msg_id) || '') === id)
  const parent = String((info && info.parent_task_id) || '')
  const row = found || { msg_id: id, task_id: taskId, channel: (info && info.channel) || null, ...(parent ? { parent_task_id: parent } : {}) }
  /* the task's opening card: archived, it is in no feed (topic-archive-v1) */
  const root = rows[0]
  if (root && root.msg_id && typeof api.topicSize === 'function') {
    try {
      const size = await withSessionRetry(api, () => api.topicSize(String(root.msg_id)))
      if (size && size.archived === true) return { reason: 'archived' }
    } catch { /* not a card (a lobby message), or no answer: open it */ }
  }
  return { row }
}

/** Which place a row opens: channel, DM, the Issues tab, or its topic page. */
export function placeKind(row, self = '') {
  const to = parentSection(row, { self })
  return to ? to.kind : 'topic'
}

/** Is the element laid out on screen? (a hidden panel's copy is not) */
function isShown(el) {
  if (!el || typeof el.getBoundingClientRect !== 'function') return true
  const r = el.getBoundingClientRect()
  return r.width > 0 && r.height > 0
}

/**
 * Mark the copies of the message the reader can SEE, for `hold` ms from the
 * first one. A hidden copy is skipped (on a phone the middle card is there,
 * hidden, long before the thread pane draws the copy on screen), and a copy
 * that shows DURING the hold is marked too. Gives up after `tries` without one.
 */
export function markOpened(msgId, { tries = 100, every = 100, hold = OPEN_FOCUS_MS, doc = globalThis.document } = {}) {
  if (!doc || !msgId) return
  const sel = `.msg[data-msg-id="${CSS.escape(String(msgId))}"]`
  const marked = new Set()
  let left = tries
  let until = 0
  const tick = () => {
    for (const el of doc.querySelectorAll(sel)) {
      if (marked.has(el) || !isShown(el)) continue
      marked.add(el)
      for (const c of OPEN_FOCUS_CLASSES) el.classList.add(c)
    }
    if (!until && marked.size) until = Date.now() + hold
    if (until && Date.now() >= until) {
      for (const el of marked) for (const c of OPEN_FOCUS_CLASSES) el.classList.remove(c)
      return
    }
    if (!until && left-- <= 0) return
    setTimeout(tick, until ? Math.min(every, Math.max(0, until - Date.now())) : every)
  }
  tick()
}

/**
 * Open a message where it was posted.
 *
 * @param {string | Record<string, any>} ref a msg_id, or the row (Flow entry, search hit)
 * @param {{ self: string, api: any, router: any, localePath: (p: string) => string, replace?: boolean,
 *           openSection?: (msg: any, deps: any) => Promise<boolean>, mark?: (id: string) => void }} deps
 * @returns {Promise<{ ok: true, kind: string, msgId: string } | { ok: false, reason: string, msgId: string }>}
 */
export async function openMessage(ref, deps) {
  let row = ref && typeof ref === 'object' ? ref : null
  const msgId = String(row ? row.msg_id || '' : ref || '').toLowerCase()
  if (!msgId) return { ok: false, reason: 'not_found', msgId }
  const early = rowReason(row)
  if (early) return { ok: false, reason: early, msgId }
  if (!row || !row.task_id) {
    const got = await resolveMessage(msgId, deps.api)
    if ('reason' in got) return { ok: false, reason: got.reason, msgId }
    row = got.row
  }
  const late = rowReason(row)
  if (late) return { ok: false, reason: late, msgId }

  const router = deps.replace ? { ...deps.router, push: (to) => deps.router.replace(to) } : deps.router
  const openSection = deps.openSection || (await import('./parent-section-open.mjs')).openParentSection
  let kind = placeKind(row, deps.self)
  let opened = false
  try {
    opened = await openSection(row, { ...deps, router })
  } catch {
    opened = false
  }
  if (!opened) {
    /* a DM row naming only the reader: its topic page, at the message */
    const task = String(row.parent_task_id || row.task_id || '')
    if (!task) return { ok: false, reason: 'not_found', msgId }
    await router.push({ path: deps.localePath('/t/' + encodeURIComponent(task)), hash: '#' + msgId })
    kind = 'topic'
  }
  ;(deps.mark || markOpened)(msgId)
  return { ok: true, kind, msgId }
}
