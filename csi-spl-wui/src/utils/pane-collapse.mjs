// csi-spl-wui/src/utils/pane-collapse.mjs
//
// Spec 050 (owner, prd t1 topic d2c03bc9, 2026-09-29): a small triangle at the
// BOTTOM corner of each of the 3 vertical panels in the channels view — the
// channels sidebar (left), the topic/messages feed (middle), and the thread
// pane (right) — collapses that panel to a thin strip and expands it back.
//
//   - The corner side follows the SAME Win/Mac rule as the close X (SPL-1133):
//     `close_buttons = mac` → the start (left) corner, `windows` → the end
//     (right) corner. `collapseSide()` maps the claim; CSS logical properties
//     (inset-inline-*) then mirror it in RTL exactly as the X does. This decides
//     only WHERE the toggle sits, not which way its arrow points.
//   - Direction (owner, prd t1 topic 80e40aca): the arrow points the way the
//     panel MOVES — toward the edge it docks to while open, back toward the
//     interior while collapsed. The dock edge is derived from the panel's ACTUAL
//     position (relative to the filler pane), NOT from the corner rule, so with
//     the messages AND thread panels both collapsed both strips sit on the right
//     and both point ◀ (collapseDir / arrowPointsEnd). RTL mirrors it in CSS.
//   - Collapsed state is remembered (owner Q5). Storage is split with CLE-35099
//     (SPL-1182): they own the divider widths (`pane_sizes`), this owns the
//     collapsed flags under the sibling key `pane_collapsed`
//     ({channels,topic,threads} booleans). Kept in localStorage now, shaped so
//     CLE-35099 lifts it to `tenant_memberships.settings.pane_collapsed` with no
//     reshape when SPL-1182's account sync lands.
//
// Pure and framework-free so tests/unit/pane-collapse.test.mjs can pin it.

import { parseCloseButtons } from './view-prefs.mjs'

/** The three collapsible panels, in visual (left→right) order. */
export const PANES = Object.freeze(['channels', 'topic', 'threads'])

/** localStorage key (per device, today). */
export const COLLAPSE_STORAGE_KEY = 'spool.pane-collapsed'

/** The sibling key CLE-35099's SPL-1182 hosts next to `pane_sizes`. */
export const COLLAPSE_ACCOUNT_KEY = 'pane_collapsed'

/** A clean {channels,topic,threads} boolean map from any input. */
export function normalizeCollapsed(raw) {
  const src = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
  const out = {}
  for (const p of PANES) out[p] = src[p] === true
  return out
}

/**
 * The corner a triangle sits in, the SAME left/right rule as the close X:
 * mac = 'start' (left), windows = 'end' (right). CSS inset-inline-* mirrors it
 * in RTL, so the physical corner matches the X in every direction.
 * @param {unknown} closeButtons the `close_buttons` session claim
 * @returns {'start' | 'end'}
 */
export function collapseSide(closeButtons) {
  return parseCloseButtons(closeButtons) === 'mac' ? 'start' : 'end'
}

/**
 * The one panel that absorbs the slack the fixed and collapsed panels leave.
 * Normally the middle (topic) feed, which is `flex:1`; when it is collapsed the
 * open thread pane takes over, else the channels sidebar; when every panel is
 * collapsed there is no filler (all strips, the degenerate case).
 * @param {Record<string, boolean>} collapsed
 * @param {boolean} topicOpen is the right thread pane in the DOM
 * @returns {'channels' | 'topic' | 'threads' | 'none'}
 */
export function fillerPane(collapsed, topicOpen) {
  const c = normalizeCollapsed(collapsed)
  if (!c.topic) return 'topic'
  if (topicOpen && !c.threads) return 'threads'
  if (!c.channels) return 'channels'
  return 'none'
}

/**
 * The logical edge a panel DOCKS to when collapsed — i.e. where its thin strip
 * physically sits (owner, prd t1 topic 80e40aca: "the arrows pointer should
 * point to the direction of the collapse or the expansion of the control", and
 * the follow-up on topic 80e40aca: with the messages AND thread panels both
 * collapsed both strips sit on the RIGHT and expand LEFT, so both must point ◀).
 *
 * The edge is derived from the panel's ACTUAL position, not from the Win/Mac
 * corner rule: in the flex row [channels · topic · threads] the filler pane
 * (fillerPane) takes the slack, so every other pane packs to the edge AWAY from
 * the filler — panes left of the filler dock to inline-start, panes right of it
 * dock to inline-end.
 * - channels is the leading panel  → it always docks to inline-'start';
 * - threads  is the trailing panel → it always docks to inline-'end';
 * - topic    is the middle panel: it docks to inline-start when the filler is to
 *   its right (an open thread pane), and to inline-end when the filler is to its
 *   left (the channels sidebar, e.g. when the thread pane is closed or itself
 *   collapsed — the both-collapsed bug). Computed as if topic were collapsed, so
 *   the answer is the same whether it is open or already a strip.
 * In logical terms so RTL mirrors for free.
 * @param {'channels'|'topic'|'threads'} pane
 * @param {Record<string, boolean>} [collapsed] the collapsed map of all panes
 * @param {boolean} [topicOpen] is the right thread pane in the DOM
 * @returns {'start'|'end'}
 */
export function collapseDir(pane, collapsed, topicOpen) {
  if (pane === 'channels') return 'start'
  if (pane === 'threads') return 'end'
  /* topic (middle): where does its own strip land? The filler is on one side of
     it; topic packs to the opposite edge. Force topic collapsed so an open topic
     reports the edge it WILL dock to. */
  const filler = fillerPane({ ...normalizeCollapsed(collapsed), topic: true }, topicOpen === true)
  if (filler === 'threads') return 'start' // filler on the right → topic docks left
  if (filler === 'channels') return 'end' // filler on the left  → topic docks right
  return 'start' // 'none' (all three collapsed): the middle strip leans start
}

/**
 * Which way the collapse triangle points, as a logical direction: true = it
 * points toward inline-END (▶ in LTR, ◀ in RTL), false = toward inline-START.
 * The arrow points the way the control will MOVE when clicked — toward the dock
 * edge while open (where it collapses to), back toward the interior while
 * collapsed (where it expands from). ONE rule for every pane; the CSS just
 * renders the two directions.
 * @param {boolean} collapsed
 * @param {'channels'|'topic'|'threads'} pane
 * @param {Record<string, boolean>} [collapsedMap] the collapsed map of all panes
 * @param {boolean} [topicOpen] is the right thread pane in the DOM
 */
export function arrowPointsEnd(collapsed, pane, collapsedMap, topicOpen) {
  const dir = collapseDir(pane, collapsedMap, topicOpen)
  /* open: point toward the dock edge; collapsed: point back to expand */
  return collapsed === true ? dir === 'start' : dir === 'end'
}

/** Read the persisted collapsed map from a Storage-like object. */
export function loadCollapsed(storage) {
  try {
    const raw = storage && typeof storage.getItem === 'function' ? storage.getItem(COLLAPSE_STORAGE_KEY) : null
    return normalizeCollapsed(raw ? JSON.parse(raw) : null)
  } catch {
    return normalizeCollapsed(null)
  }
}

/** Write the collapsed map to a Storage-like object (best effort). */
export function saveCollapsed(storage, collapsed) {
  try {
    if (storage && typeof storage.setItem === 'function') {
      storage.setItem(COLLAPSE_STORAGE_KEY, JSON.stringify(normalizeCollapsed(collapsed)))
    }
  } catch {
    /* private mode / quota: the pref is a nicety, never worth throwing */
  }
}
