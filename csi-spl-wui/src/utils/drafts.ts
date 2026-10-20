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
import { storageGetJson, storageSetJson } from '~/utils/prefs.mjs'

export type DraftEntry = { text: string, ts: number }
export type DraftPlaces = Record<string, DraftEntry>
export type DraftTarget = string | { taskId?: unknown, peer?: unknown, channel?: unknown } | null | undefined
export type DraftPending = { human: unknown, place: unknown, text: unknown }

export const DRAFTS_KEY = 'spool.drafts' as const
export const DRAFT_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000
export const DRAFT_MAX_ENTRIES = 50

const PLACE_RE = /^(ch|dm|t):.+$/

/**
 * The place key of a send target, or '' when it names none.
 * A topic wins over the channel it lives in (the send is a reply there);
 * a peer is a DM; a channel (with or without its `#`) is a new topic there.
 * An already-formed place (`ch:x`, `dm:x`, `t:x`) is returned as is;
 * `new:<channel>` is folded into `ch:<channel>`.
 */
export function draftPlaceOf(target: DraftTarget): string {
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

function isEntry(e: unknown): e is DraftEntry {
  const x = e as Partial<DraftEntry> | null
  return Boolean(x) && typeof x === 'object' && typeof x?.text === 'string' && x.text !== ''
    && Number.isFinite(x.ts)
}

/**
 * One member's drafts without the stale ones: entries older than 30 days
 * and all but the newest 50 are dropped, so are malformed entries.
 * @param places `{<place>: {text, ts}}`
 * @param now ms since epoch
 */
function prunePlaces(places: unknown, now: number): DraftPlaces {
  if (!places || typeof places !== 'object' || Array.isArray(places)) return {}
  const kept = Object.entries(places)
    .filter((kv): kv is [string, DraftEntry] => PLACE_RE.test(kv[0]) && isEntry(kv[1]) && now - kv[1].ts <= DRAFT_MAX_AGE_MS)
    .sort((a, b) => b[1].ts - a[1].ts)
    .slice(0, DRAFT_MAX_ENTRIES)
  const out: DraftPlaces = {}
  for (const [place, e] of kept) out[place] = { text: e.text, ts: e.ts }
  return out
}

/**
 * FR-004: the whole `spool.drafts` value with every member's drafts pruned
 * (30 days, newest 50 per member). A member left with none is dropped.
 */
export function pruneDrafts(all: unknown, now = Date.now()): Record<string, DraftPlaces> {
  if (!all || typeof all !== 'object' || Array.isArray(all)) return {}
  const out: Record<string, DraftPlaces> = {}
  for (const [humanId, places] of Object.entries(all)) {
    if (!humanId) continue
    const kept = prunePlaces(places, now)
    if (Object.keys(kept).length) out[humanId] = kept
  }
  return out
}

function readAll(store: Storage | undefined, now: number): Record<string, DraftPlaces> {
  return pruneDrafts(storageGetJson(DRAFTS_KEY, {}, store), now)
}

function writeAll(store: Storage | undefined, all: Record<string, DraftPlaces>): boolean {
  return storageSetJson(DRAFTS_KEY, all, store)
}

/**
 * The member's drafts, `{<place>: {text, ts}}`, pruned on load; the pruned
 * value is written back. No member, nothing.
 */
export function loadDrafts(store: Storage | undefined, humanId: unknown, now = Date.now()): DraftPlaces {
  const id = String(humanId ?? '')
  if (!id) return {}
  const all = readAll(store, now)
  writeAll(store, all)
  return all[id] || {}
}

/**
 * The draft text of one place, or ''.
 */
export function draftText(store: Storage | undefined, humanId: unknown, place: DraftTarget, now = Date.now()): string {
  const p = draftPlaceOf(place)
  if (!p) return ''
  return loadDrafts(store, humanId, now)[p]?.text || ''
}

/**
 * FR-002: keep `text` as the draft of `place`. Blank text (only whitespace)
 * is no draft: the place is cleared instead.
 * @returns written
 */
export function saveDraft(store: Storage | undefined, humanId: unknown, place: DraftTarget, text: unknown, now = Date.now()): boolean {
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
 * @returns written
 */
export function clearDraft(store: Storage | undefined, humanId: unknown, place: DraftTarget, now = Date.now()): boolean {
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
 * @returns written
 */
export function clearDrafts(store: Storage | undefined, humanId: unknown, now = Date.now()): boolean {
  const id = String(humanId ?? '')
  if (!id) return false
  const all = readAll(store, now)
  delete all[id]
  return writeAll(store, all)
}

/*
 * 088 FR-001: a phone freezes the page as soon as the reader switches app or
 * locks the screen, so the composer's 300 ms debounce may never fire. The
 * composer registers a getter of its pending draft; `flushDraft()` writes it
 * at once (drafts-flush.client.ts calls it on hide and on pagehide).
 */
let draftSource: (() => DraftPending | null | false | undefined) | null = null

/**
 * Register the composer's pending-draft getter: it returns
 * `{human, place, text}` while a debounced save is pending, else null.
 * One source at a time; the returned function unregisters it.
 */
export function registerDraftSource(source: () => DraftPending | null | false | undefined): () => void {
  draftSource = typeof source === 'function' ? source : null
  return () => {
    if (draftSource === source) draftSource = null
  }
}

/**
 * 088 FR-001: write the pending debounced draft now, through saveDraft
 * (same format). Nothing registered or nothing pending, nothing written.
 * @returns written
 */
export function flushDraft(store?: Storage, now = Date.now()): boolean {
  const pending = draftSource?.()
  if (!pending || typeof pending !== 'object') return false
  return saveDraft(store, pending.human, pending.place as DraftTarget, pending.text, now)
}
