/**
 * SPL-1006 — an open tab picks up a new deploy, safely.
 *
 * sw.js is network-only on purpose, so nothing ever swapped the bundle of a
 * tab that stays open: on 2026-09-27 prd shipped 64 WUI builds in five hours
 * and a phone PWA kept running whichever one it had opened on. The running
 * build's commit is baked in at `nuxt generate` (runtimeConfig
 * public.buildCommit, from GITHUB_SHA) and compared with the deployed
 * /build.json; this file holds the decisions, plugins/build-watch.client.ts
 * the wiring.
 *
 *   same commit                     -> nothing
 *   newer, nothing being typed      -> reload silently (route kept)
 *   newer, a draft / dialog open    -> the "new version" bar; reload on tap,
 *                                      or by itself once the input is empty
 *   newer, but THIS tab already reloaded for that commit (the guard)
 *                                   -> never again by itself: the bar only
 */

import { BUILD_JSON_TIMEOUT_MS } from './build-stamp.mjs'

/** How often a visible tab asks (the brief: every 5 minutes). */
export const CHECK_EVERY_MS = 5 * 60_000
/** Focus + visibilitychange can fire together; one fetch per this window. */
export const MIN_GAP_MS = 20_000
/** While the bar waits, how often "is the input empty now?" is asked. */
export const IDLE_POLL_MS = 2_000
/** sessionStorage key: the commit this tab last reloaded itself for. */
export const GUARD_KEY = 'spool.build-reload-for'

/** A full or short hex sha, lower-cased; '' for anything else. */
export function normCommit(c) {
  const s = String(c || '').trim().toLowerCase()
  return /^[0-9a-f]{7,40}$/.test(s) ? s : ''
}

/** True when both are real commits and name different builds. */
export function isNewer(running, live) {
  const r = normCommit(running)
  const l = normCommit(live)
  if (!r || !l) return false
  return !(r.startsWith(l) || l.startsWith(r))
}

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
 * @param {Document} [doc]
 */
export function pageBusy(doc = globalThis.document) {
  if (!doc) return false
  if (typingIn(doc.activeElement)) return true
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
