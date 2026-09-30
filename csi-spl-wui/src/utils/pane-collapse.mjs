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
//     (inset-inline-*) then mirror it in RTL exactly as the X does.
//   - Direction, taken literally from the owner ("point to either close or open
//     the panel to left or from left, and in Hebrew the other direction"): open
//     points left (◀, close), the collapsed strip points right (▶, open); RTL
//     mirrors both in CSS.
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
 * The logical edge a panel collapses TOWARD (owner, prd t1 topic 80e40aca:
 * "the arrows pointer should point to the direction of the collapse or the
 * expansion of the control"). In logical terms so RTL mirrors for free:
 * - channels is the leading panel  → it always recedes to inline-'start';
 * - threads  is the trailing panel → it always recedes to inline-'end';
 * - topic    is the middle panel, pinned to no shell edge, so it recedes to the
 *   corner its own toggle sits in (`side`, the Win/Mac close_buttons rule).
 * @param {'channels'|'topic'|'threads'} pane
 * @param {'start'|'end'} [side] the toggle corner (collapseSide), for topic
 * @returns {'start'|'end'}
 */
export function collapseDir(pane, side) {
  if (pane === 'channels') return 'start'
  if (pane === 'threads') return 'end'
  return side === 'end' ? 'end' : 'start'
}

/**
 * Which way the collapse triangle points, as a logical direction: true = it
 * points toward inline-END (▶ in LTR, ◀ in RTL), false = toward inline-START.
 * The arrow points the way the control will MOVE when clicked — toward the
 * collapse edge while open, back toward where it expands while collapsed.
 * ONE rule for every pane; the CSS just renders the two directions.
 * @param {boolean} collapsed
 * @param {'channels'|'topic'|'threads'} pane
 * @param {'start'|'end'} [side] the toggle corner (collapseSide), for topic
 */
export function arrowPointsEnd(collapsed, pane, side) {
  const dir = collapseDir(pane, side)
  /* open: point toward the collapse edge; collapsed: point back to expand */
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
