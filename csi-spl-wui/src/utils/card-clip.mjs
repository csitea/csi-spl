/** Level-1 card height in the middle pane (CLE-34989, specs/033 FR-020..FR-026).
 *
 *  Owner, 2026-09-25: "clip the size of the msg with is_parent=1 to max 5 rows
 *  of text or max 30% of the screen if picture is involved ... the rest should
 *  be expandable via the similar expandable draggable handle which exists in
 *  the omnibox ... There should be a control which sets the height of those
 *  posts to 3 different ways - only titles (where title is the first 90 chars),
 *  this default of 5 rows max and all size".
 *
 *  Three modes, per browser (prefs.mjs, try/catch):
 *    titles — the first 90 chars of the body on one line, no attachments;
 *    rows   — (default) the body clipped at 5 text rows, or at 30% of the
 *             window when the card carries a picture; a grip drags it taller;
 *    full   — nothing clipped (the card as it was before this change).
 *  SPL-945 (owner 2026-09-26, "the same way of changing the view should be
 *  applied to the threads msgs as well, aka the is_parent=0 msgs"): the right
 *  (thread) pane has the same control and its own stored mode.
 *  SPL-963 (owner 2026-09-26, "clicking on the titles, 5 rows and full does
 *  not work for all of the listings"): every list that shows messages takes
 *  a pane's mode. The middle pane (msgs): lobby, channel, DM, search
 *  results. The right pane (thread): the thread with its root card, the /t
 *  page, the new-topic cards (BornTopics), and the issue discussion.
 */
import { storageGet, storageSet } from './prefs.mjs'
import { isPreviewableImage } from './file-preview.mjs'

export const CARD_CLIP_KEY = 'spool-card-clip'
/** SPL-945: the thread pane's mode, kept apart from the middle pane's. */
export const CARD_CLIP_THREAD_KEY = 'spool-card-clip-thread'
/** The storage key of a pane's mode: `msgs` (middle) or `thread` (right). */
export function cardClipKey(pane) {
  return pane === 'thread' ? CARD_CLIP_THREAD_KEY : CARD_CLIP_KEY
}
export const CARD_CLIP_MODES = Object.freeze(['titles', 'rows', 'full'])
export const CARD_CLIP_DEFAULT = 'rows'
/** Text rows a level-1 card shows in the default mode. */
export const CARD_CLIP_ROWS = 5
/** Share of the window a card with a picture may take in the default mode. */
export const CARD_CLIP_PICTURE_SHARE = 0.3
/** Characters of the body that make a card's title. */
export const CARD_TITLE_CHARS = 90
/** One keyboard step of the grip (ArrowDown / ArrowUp), in rows. */
export const CARD_GRIP_STEP_ROWS = 2

/** A mode from anything (storage string, prop); else `fallback`. */
export function parseCardClipMode(raw, fallback = CARD_CLIP_DEFAULT) {
  const s = String(raw ?? '').trim()
  return CARD_CLIP_MODES.includes(s) ? s : fallback
}

export function readCardClipMode(store, pane = 'msgs') {
  return parseCardClipMode(storageGet(cardClipKey(pane), null, store))
}

export function writeCardClipMode(mode, store, pane = 'msgs') {
  return storageSet(cardClipKey(pane), parseCardClipMode(mode), store)
}

/** The appearance-page default. It outlives a sign-in. Unset means rows. */
export const CARD_CLIP_DEFAULT_KEY = 'spool-card-clip-default'

export function readCardClipDefault(store) {
  const raw = storageGet(CARD_CLIP_DEFAULT_KEY, null, store)
  if (raw == null || String(raw).trim() === '') return CARD_CLIP_DEFAULT
  return parseCardClipMode(raw)
}

export function writeCardClipDefault(mode, store) {
  return storageSet(CARD_CLIP_DEFAULT_KEY, parseCardClipMode(mode), store)
}

/** A pane's override for this sign-in only (sessionStorage). */
export function cardClipSessionKey(pane) {
  return 'spool-card-clip-session-' + (pane === 'thread' ? 'thread' : 'msgs')
}

function sessionBag(bag) {
  if (bag && typeof bag.getItem === 'function') return bag
  try {
    if (typeof globalThis !== 'undefined' && globalThis.sessionStorage) return globalThis.sessionStorage
  } catch { /* denied */ }
  return null
}

export function readCardClipSession(pane = 'msgs', bag) {
  const s = sessionBag(bag)
  if (!s) return ''
  try {
    const raw = s.getItem(cardClipSessionKey(pane))
    return raw && CARD_CLIP_MODES.includes(String(raw).trim()) ? String(raw).trim() : ''
  } catch {
    return ''
  }
}

export function writeCardClipSession(mode, pane = 'msgs', bag) {
  const s = sessionBag(bag)
  if (!s) return false
  try {
    s.setItem(cardClipSessionKey(pane), parseCardClipMode(mode))
    return true
  } catch {
    return false
  }
}

export function clearCardClipSession(bag) {
  const s = sessionBag(bag)
  if (!s) return
  try {
    s.removeItem(cardClipSessionKey('msgs'))
    s.removeItem(cardClipSessionKey('thread'))
  } catch { /* private mode */ }
}

/** Session override, else the appearance default, else rows. */
export function readEffectiveCardClip(pane = 'msgs', store, bag) {
  const over = readCardClipSession(pane, bag)
  if (over) return over
  return readCardClipDefault(store)
}

function modeOrNull(raw) {
  if (raw == null) return null
  const s = String(raw).trim()
  return CARD_CLIP_MODES.includes(s) ? s : null
}

function localBag(store) {
  if (store && typeof store.getItem === 'function') return store
  try {
    if (typeof globalThis !== 'undefined' && globalThis.localStorage) return globalThis.localStorage
  } catch { /* denied */ }
  return null
}

/**
 * SPL-954: an old lasting per-pane value becomes the appearance default.
 * The middle pane wins when both panes stored one. A pane whose old value
 * differs, and a pane that was never stored when that default is not rows,
 * is pinned for this sign-in so the screen does not jump. The old keys are
 * then removed. A browser that already has a default is left alone, apart
 * from dropping leftover old keys.
 */
export function migrateCardClip(store, bag) {
  const loc = localBag(store)
  if (!loc) return { migrated: false }
  const had = storageGet(CARD_CLIP_DEFAULT_KEY, null, loc)
  const hadDefault = had != null && String(had).trim() !== ''
  const msgsRaw = storageGet(CARD_CLIP_KEY, null, loc)
  const threadRaw = storageGet(CARD_CLIP_THREAD_KEY, null, loc)
  const msgs = modeOrNull(msgsRaw)
  const thread = modeOrNull(threadRaw)
  let migrated = false
  if (!hadDefault && (msgs || thread)) {
    const chosen = msgs || thread
    writeCardClipDefault(chosen, loc)
    if (msgs && msgs !== chosen) writeCardClipSession(msgs, 'msgs', bag)
    if (thread && thread !== chosen) writeCardClipSession(thread, 'thread', bag)
    if (!msgs && chosen !== CARD_CLIP_DEFAULT) writeCardClipSession(CARD_CLIP_DEFAULT, 'msgs', bag)
    if (!thread && chosen !== CARD_CLIP_DEFAULT) writeCardClipSession(CARD_CLIP_DEFAULT, 'thread', bag)
    migrated = true
  }
  if (msgsRaw != null) {
    try { loc.removeItem(CARD_CLIP_KEY) } catch { /* private mode */ }
  }
  if (threadRaw != null) {
    try { loc.removeItem(CARD_CLIP_THREAD_KEY) } catch { /* private mode */ }
  }
  return { migrated }
}

/**
 * SPL-963: the class of a list line that is not a MessageCard (a search hit,
 * an issue comment). `titles` is one line, `rows` at most 5 lines, `full`
 * all of it. The page's CSS draws each class.
 */
export function listClipClass(mode) {
  return 'list-clip--' + parseCardClipMode(mode)
}

/**
 * The title of a card: the first 90 characters of its body, on one line.
 * Whitespace runs (newlines included) fold to one space, and a ``` fence
 * marker is dropped, so a card that opens with a code block still reads.
 * A cut title ends in an ellipsis; the 90 counts code points, not UTF-16
 * units, so an emoji is never split in half.
 */
export function cardTitle(body, max = CARD_TITLE_CHARS) {
  const flat = String(body ?? '')
    .replace(/```[^\s`]*/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
  const chars = Array.from(flat)
  if (chars.length <= max) return flat
  return chars.slice(0, max).join('').trimEnd() + '…'
}

/** True when one of the card's files shows as an inline picture. */
export function cardHasPicture(files) {
  if (!Array.isArray(files)) return false
  return files.some((f) => f && isPreviewableImage(f.name, f.bytes))
}

/**
 * The clip height of a card body in px, or null for "not clipped".
 * @param {{ mode: string, picture: boolean, lineHeightPx: number, viewportPx: number, userPx?: number | null }} s
 *   `userPx` is a grip drag on this card; it replaces the automatic height
 *   (taller or shorter), and is never below one text row.
 * @returns {number | null}
 */
export function cardClipPx(s) {
  const mode = parseCardClipMode(s.mode)
  if (mode !== 'rows') return null
  const line = Math.max(1, Number(s.lineHeightPx) || 0)
  if (typeof s.userPx === 'number' && Number.isFinite(s.userPx)) {
    return Math.max(Math.round(line), Math.round(s.userPx))
  }
  if (s.picture) {
    const vp = Math.max(0, Number(s.viewportPx) || 0)
    return Math.max(Math.round(line * CARD_CLIP_ROWS), Math.round(vp * CARD_CLIP_PICTURE_SHARE))
  }
  return Math.round(line * CARD_CLIP_ROWS)
}

/** The height a grip drag asks for: start + pointer travel, from one row to `maxPx`. */
export function cardDragPx(startPx, dy, lineHeightPx, maxPx) {
  const min = Math.max(1, Math.round(Number(lineHeightPx) || 1))
  const max = Math.max(min, Math.round(Number(maxPx) || min))
  return Math.min(max, Math.max(min, Math.round(Number(startPx) + Number(dy))))
}

/** Clipped when the content is taller than the box (1px of rounding slack). */
export function cardIsClipped(scrollPx, clientPx) {
  return Number(scrollPx) > Number(clientPx) + 1
}
