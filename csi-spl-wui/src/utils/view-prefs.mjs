// csi-spl-wui/src/utils/view-prefs.mjs
//
// Settings -> Behaviour -> "Message order" and "Omnibox position" (owner,
// topic c6994436): two per-person layout choices. The hub keeps each on the
// account (humans.message_order / humans.composer_position, rdb 0070) and
// answers them as the `message_order` / `composer_position` session claims,
// null when never picked. The first value of each list is the default, which
// is today's layout, so nobody's view changes until they choose.
//
//   message_order     'newest-first'  newest message at the top (spec 013)
//                     'newest-last'   messages appended, newest at the bottom
//   composer_position 'top'           the Omnibox in the top bar
//                     'bottom'        docked under the middle pane (> 820 px)
//   issues_view       'list'          the Issues sheet, one flat list
//                     'status'        the same rows grouped by status
//                                     (SPL-1028, rdb 0072, Linear's view)
//   close_buttons     'mac'           every close X in the top left (the
//                                     owner's default, SPL-1133, rdb 0077)
//                     'windows'       every close X in the top right
//
// The hub lists the same values in the same order (auth.ViewPrefs); the unit
// test tests/unit/view-prefs.test.mjs pins the two lists equal.

export const MESSAGE_ORDERS = Object.freeze(['newest-first', 'newest-last'])
export const COMPOSER_POSITIONS = Object.freeze(['top', 'bottom'])
export const ISSUES_VIEWS = Object.freeze(['list', 'status'])
export const CLOSE_BUTTONS = Object.freeze(['mac', 'windows'])

/** Each claim's values, default first. */
export const VIEW_PREFS = Object.freeze({
  message_order: MESSAGE_ORDERS,
  composer_position: COMPOSER_POSITIONS,
  issues_view: ISSUES_VIEWS,
  close_buttons: CLOSE_BUTTONS,
})

export const DEFAULT_MESSAGE_ORDER = MESSAGE_ORDERS[0]
export const DEFAULT_COMPOSER_POSITION = COMPOSER_POSITIONS[0]

/** One of `key`'s values exactly, else its default. */
export function parseViewPref(key, raw) {
  const vals = VIEW_PREFS[key] || []
  return vals.includes(raw) ? raw : vals[0]
}

export function parseMessageOrder(raw) {
  return parseViewPref('message_order', raw)
}

export function parseComposerPosition(raw) {
  return parseViewPref('composer_position', raw)
}

export function parseIssuesView(raw) {
  return parseViewPref('issues_view', raw)
}

export function parseCloseButtons(raw) {
  return parseViewPref('close_buttons', raw)
}

/**
 * SPL-1133: does a close button placed at `side` of its header show? Every
 * header carries the one shared UiCloseButton at BOTH ends, and exactly one
 * of the two renders, so the DOM (and the Tab order) matches what is drawn.
 * 'start' = top left = Mac style; 'end' = top right = Windows style.
 * @param {'start' | 'end'} side
 * @param {unknown} pref the close_buttons claim
 */
export function closeButtonShown(side, pref) {
  return (parseCloseButtons(pref) === 'mac') === (side === 'start')
}

/**
 * The rows a feed draws, in DOM order. Every store hands a feed its rows
 * newest first (and windows the newest N of them, so the window is right in
 * both orders); 'newest-last' only reverses what is drawn. The DOM order is
 * the reading order (spec 013 section 2): never flex column-reverse.
 * @template T
 * @param {T[]} rows newest first
 * @param {unknown} order
 * @returns {T[]}
 */
export function displayOrder(rows, order) {
  const list = Array.isArray(rows) ? rows : []
  return parseMessageOrder(order) === 'newest-last' ? list.slice().reverse() : list
}

/**
 * The radio's save, optimistic like the "Text fields" one: mirror the claim
 * at once so every pane follows, save it, and put the old value back on a
 * refusal.
 * @param {string} key a VIEW_PREFS key
 * @param {unknown} want
 * @param {{ current: unknown, apply: (v: string) => void,
 *           save: (v: string) => Promise<{ ok: boolean }> }} io
 * @returns {Promise<{ ok: boolean, value: string, out?: unknown }>}
 */
export async function applyViewPref(key, want, { current, apply, save }) {
  const vals = VIEW_PREFS[key] || []
  const prev = parseViewPref(key, current)
  if (!vals.includes(want)) return { ok: false, value: prev }
  if (want === prev && vals.includes(current)) return { ok: true, value: prev }
  apply(want)
  let out
  try {
    out = await save(want)
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (out && out.ok) return { ok: true, value: want }
  apply(prev)
  return { ok: false, value: prev, out }
}
