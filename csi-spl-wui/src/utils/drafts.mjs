/**
 * 080 FR-001..FR-004, FR-008: one composer draft per place, kept in the
 * browser under `spool.drafts` as `{<human_id>: {<place>: {text, ts}}}`.
 *
 * A place is where a send would go: `ch:<channel>`, `dm:<peer>`,
 * `t:<task_id>` (a topic reply). A new topic in a channel is the channel's
 * place. Pure and device-neutral: no DOM, no Vue; `store` is any
 * Storage-shaped object (default localStorage, see prefs.mjs), so the desktop
 * composer and the mobile drafts reuse the same model.
 */
import { storageGetJson, storageSetJson } from './prefs.mjs'

export const DRAFTS_KEY = 'spool.drafts'
export const DRAFT_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000
export const DRAFT_MAX_ENTRIES = 50

const PLACE_RE = /^(ch|dm|t):.+$/

/**
 * The place key of a send target, or '' when it names none.
 * A topic wins over the channel it lives in (the send is a reply there);
 * a peer is a DM; a channel (with or without its `#`) is a new topic there.
 * An already-formed place (`ch:x`, `dm:x`, `t:x`) is returned as is;
 * `new:<channel>` is folded into `ch:<channel>`.
 * @param {string | { taskId?: unknown, peer?: unknown, channel?: unknown } | null | undefined} target
 * @returns {string}
 */
export function draftPlaceOf(target) {
  if (typeof target === 'string') {
    const s = target.trim()
    if (s.startsWith('new:')) return draftPlaceOf({ channel: s.slice(4) })
    return PLACE_RE.test(s) ? s : ''
  }
  if (!target || typeof target !== 'object') return ''
  const taskId = String(target.taskId ?? '').trim()
  if (taskId) return `t:${taskId}`
  const peer = String(target.peer ?? '').trim().replace(/^@/, '')
  if (peer) return `dm:${peer}`
  const channel = String(target.channel ?? '').trim().replace(/^#/, '')
  if (channel) return `ch:${channel}`
  return ''
}

function isEntry(e) {
  return Boolean(e) && typeof e === 'object' && typeof e.text === 'string' && e.text !== ''
    && Number.isFinite(e.ts)
}

/**
 * One member's drafts without the stale ones: entries older than 30 days
 * and all but the newest 50 are dropped, so are malformed entries.
 * @param {unknown} places  `{<place>: {text, ts}}`
 * @param {number} now  ms since epoch
 * @returns {Record<string, { text: string, ts: number }>}
 */
function prunePlaces(places, now) {
  if (!places || typeof places !== 'object' || Array.isArray(places)) return {}
  const kept = Object.entries(places)
    .filter(([place, e]) => PLACE_RE.test(place) && isEntry(e) && now - e.ts <= DRAFT_MAX_AGE_MS)
    .sort((a, b) => b[1].ts - a[1].ts)
    .slice(0, DRAFT_MAX_ENTRIES)
  const out = {}
  for (const [place, e] of kept) out[place] = { text: e.text, ts: e.ts }
  return out
}

/**
 * FR-004: the whole `spool.drafts` value with every member's drafts pruned
 * (30 days, newest 50 per member). A member left with none is dropped.
 * @param {unknown} all
 * @param {number} [now]
 * @returns {Record<string, Record<string, { text: string, ts: number }>>}
 */
export function pruneDrafts(all, now = Date.now()) {
  if (!all || typeof all !== 'object' || Array.isArray(all)) return {}
  const out = {}
  for (const [humanId, places] of Object.entries(all)) {
    if (!humanId) continue
    const kept = prunePlaces(places, now)
    if (Object.keys(kept).length) out[humanId] = kept
  }
  return out
}

function readAll(store, now) {
  return pruneDrafts(storageGetJson(DRAFTS_KEY, {}, store), now)
}

function writeAll(store, all) {
  return storageSetJson(DRAFTS_KEY, all, store)
}

/**
 * The member's drafts, `{<place>: {text, ts}}`, pruned on load; the pruned
 * value is written back. No member, nothing.
 * @param {Storage | undefined} store
 * @param {unknown} humanId
 * @param {number} [now]
 */
export function loadDrafts(store, humanId, now = Date.now()) {
  const id = String(humanId ?? '')
  if (!id) return {}
  const all = readAll(store, now)
  writeAll(store, all)
  return all[id] || {}
}

/**
 * The draft text of one place, or ''.
 * @param {Storage | undefined} store
 * @param {unknown} humanId
 * @param {unknown} place
 * @param {number} [now]
 */
export function draftText(store, humanId, place, now = Date.now()) {
  const p = draftPlaceOf(place)
  if (!p) return ''
  return loadDrafts(store, humanId, now)[p]?.text || ''
}

/**
 * FR-002: keep `text` as the draft of `place`. Blank text (only whitespace)
 * is no draft: the place is cleared instead.
 * @param {Storage | undefined} store
 * @param {unknown} humanId
 * @param {unknown} place
 * @param {unknown} text
 * @param {number} [now]
 * @returns {boolean} written
 */
export function saveDraft(store, humanId, place, text, now = Date.now()) {
  const id = String(humanId ?? '')
  const p = draftPlaceOf(place)
  if (!id || !p) return false
  const body = String(text ?? '')
  if (!body.trim()) return clearDraft(store, humanId, p, now)
  const all = readAll(store, now)
  all[id] = prunePlaces({ ...(all[id] || {}), [p]: { text: body, ts: now } }, now)
  return writeAll(store, all)
}

/**
 * FR-003: a successful send drops that place's draft.
 * @param {Storage | undefined} store
 * @param {unknown} humanId
 * @param {unknown} place
 * @param {number} [now]
 * @returns {boolean} written
 */
export function clearDraft(store, humanId, place, now = Date.now()) {
  const id = String(humanId ?? '')
  const p = draftPlaceOf(place)
  if (!id || !p) return false
  const all = readAll(store, now)
  if (all[id]) {
    delete all[id][p]
    if (!Object.keys(all[id]).length) delete all[id]
  }
  return writeAll(store, all)
}

/**
 * FR-008: sign-out drops every draft of that member; other members keep theirs.
 * @param {Storage | undefined} store
 * @param {unknown} humanId
 * @param {number} [now]
 * @returns {boolean} written
 */
export function clearDrafts(store, humanId, now = Date.now()) {
  const id = String(humanId ?? '')
  if (!id) return false
  const all = readAll(store, now)
  delete all[id]
  return writeAll(store, all)
}
