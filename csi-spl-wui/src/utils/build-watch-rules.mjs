// SPL-1006: the decisions of utils/build-watch.mjs (see its header for the
// table). Loaded only by the lazy build-watch polling and the PWA shell
// check, never by a first-screen chunk (ci_initial_gzip_kb).
import { BUILD_JSON_TIMEOUT_MS } from './build-stamp.mjs'
import { RESUME_AFTER_MS, isNewer, normCommit } from './build-watch.mjs'

/**
 * A /build.json read that failed on a resume is retried after these delays:
 * a phone's radio is often still waking when the app comes back, the read
 * failed, and the tab then ran the old build until the 5-minute tick.
 */
export const RETRY_DELAYS_MS = [2_000, 5_000, 10_000, 20_000]

/**
 * What to do about the live build.
 * @param {{ running: string, live: string, busy: boolean, guard?: string }} s
 * @returns {'none' | 'reload' | 'prompt'}
 */
export function decide({ running, live, busy, guard }) {
  if (!isNewer(running, live)) return 'none'
  if (normCommit(guard) && normCommit(guard) === normCommit(live)) return 'prompt'
  return busy ? 'prompt' : 'reload'
}

/** An element the user can type into, and whose content we would lose. */
function holdsText(el) {
  if (!el || el.closest?.('[data-build-watch-ignore]')) return false
  if (el.isContentEditable) return String(el.textContent || '').trim() !== ''
  const tag = String(el.tagName || '').toLowerCase()
  if (tag === 'textarea') return !el.disabled && !el.readOnly && String(el.value || '') !== ''
  if (tag !== 'input') return false
  const type = String(el.type || 'text').toLowerCase()
  if (/^(hidden|checkbox|radio|button|submit|reset|range|color|file|image)$/.test(type)) return false
  // a closed combobox shows its SELECTED option (the language switcher reads
  // "English"), not a draft; one being typed into is expanded
  if (el.getAttribute?.('role') === 'combobox' && el.getAttribute('aria-expanded') !== 'true') return false
  return !el.disabled && !el.readOnly && String(el.value || '') !== ''
}

/** The focused element takes typed text: a text field, textarea or editor. */
function typingIn(el) {
  if (!el || el.closest?.('[data-build-watch-ignore]')) return false
  if (el.isContentEditable) return true
  const tag = String(el.tagName || '').toLowerCase()
  if (tag !== 'textarea' && tag !== 'input') return false
  if (el.disabled || el.readOnly) return false
  if (tag === 'textarea') return true
  const type = String(el.type || 'text').toLowerCase()
  if (/^(hidden|checkbox|radio|button|submit|reset|range|color|file|image)$/.test(type)) return false
  // a closed combobox (the language switcher) is a picker, not a keyboard
  return !(el.getAttribute?.('role') === 'combobox' && el.getAttribute('aria-expanded') !== 'true')
}

function shown(el) {
  return Boolean(el && el.getClientRects && el.getClientRects().length > 0)
}

/**
 * Is anything on the page that a reload would lose? Read from the DOM, so it
 * covers every composer, editor and form without each one registering:
 *   - a text field / textarea / contenteditable with content
 *   - a text field the reader is IN, even an empty one (HUM-27): the
 *     on-screen keyboard is up. Switching its typing language (Gboard's
 *     input-method picker, Samsung's language list) takes the window focus
 *     and gives it back, the window `focus` asks /build.json, and on a
 *     newer deploy an empty composer read as idle: the tab reloaded under
 *     the finger and the keyboard was gone ("the keyboard disappears when I
 *     switch the language")
 *   - an open dialog (UiDialog, pickers, sheets: role=dialog|alertdialog)
 *   - a message still in flight (a pending row: data-pending="true")
 * `resumed` (HUM-10 fb8d109f): the tab was hidden for RESUME_AFTER_MS or
 * more. An EMPTY field that kept the focus while the phone was away holds
 * nothing to lose; counting it as busy left the reopened app on the old
 * build with only the bar. Text, a dialog or a pending row still count.
 * @param {Document} [doc]
 * @param {{ resumed?: boolean }} [opts]
 */
export function pageBusy(doc = globalThis.document, { resumed = false } = {}) {
  if (!doc) return false
  if (!resumed && typingIn(doc.activeElement)) return true
  for (const el of doc.querySelectorAll('textarea, input, [contenteditable=""], [contenteditable="true"]')) {
    if (holdsText(el)) return true
  }
  for (const el of doc.querySelectorAll('[role=dialog], [role=alertdialog], [aria-modal=true]')) {
    if (!el.closest('[data-build-watch-ignore]') && shown(el)) return true
  }
  return Boolean(doc.querySelector('[data-pending=true]'))
}

/**
 * Read the deployed commit. Never throws, and is bounded by
 * BUILD_JSON_TIMEOUT_MS: an offline tab, a hung request or a missing
 * build.json (lde) reads as '' and means "nothing to do".
 * @param {(input: string, init?: object) => Promise<Response>} [fetchImpl]
 * @param {{ timeoutMs?: number }} [opts]  test seam for the timeout
 */
export async function readLiveCommit(fetchImpl, { timeoutMs = BUILD_JSON_TIMEOUT_MS } = {}) {
  const f = fetchImpl || (typeof fetch === 'function' ? fetch : null)
  if (!f) return { commit: '', stamp: null }
  const ctl = typeof AbortController === 'function' ? new AbortController() : null
  const timer = ctl ? setTimeout(() => ctl.abort(), timeoutMs) : null
  try {
    const r = await f('/build.json', { cache: 'no-store', signal: ctl?.signal })
    if (!r || !r.ok) return { commit: '', stamp: null }
    const j = await r.json()
    const commit = normCommit(j && j.commit)
    return commit ? { commit, stamp: j } : { commit: '', stamp: null }
  } catch {
    return { commit: '', stamp: null }
  } finally {
    if (timer) clearTimeout(timer)
  }
}

/**
 * Delay before the next /build.json read after `failed` failed reads in a
 * row on a resume; -1 = give up (the 5-minute tick takes over).
 * @param {number} failed
 */
export function retryDelay(failed) {
  const n = Number(failed) || 0
  return n >= 1 && n <= RETRY_DELAYS_MS.length ? RETRY_DELAYS_MS[n - 1] : -1
}

/**
 * Was the tab hidden long enough for its return to count as a resume?
 * @param {number} hiddenAt epoch ms the tab went hidden, 0 = never
 * @param {number} [now]
 */
export function isResume(hiddenAt, now = Date.now()) {
  const h = Number(hiddenAt) || 0
  return h > 0 && now - h >= RESUME_AFTER_MS
}
