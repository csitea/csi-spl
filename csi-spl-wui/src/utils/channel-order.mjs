/**
 * SPL-1034 (specs/045 §3.8): a person's own order of the Channels list,
 * kept per tenant on the hub (GET /v1/view/me `channel_order`,
 * PUT /v1/me/channel-order, contracts/move-v1.md §7).
 *
 * Rendering is pinRows (utils/sidebar-row-menu.mjs): the stored ids first, in
 * their order, every other channel after them in today's order. A stored id
 * that is not listed now is not drawn but stays stored (it may come back).
 * The editing helpers (merge / step / compare) are channel-order-edit.mjs,
 * loaded on first use: the initial script stays inside its budget (027 §6).
 * Node tests import this file.
 */

/** The hub's cap on one stored list (400 bad_json above it). */
export const CHANNEL_ORDER_MAX = 200

/** A channel id as the hub stores it: `#` dropped, lower case, trimmed. */
function channelKey(raw) {
  return String(raw == null ? '' : raw).trim().replace(/^#/, '').toLowerCase()
}

/**
 * The wire value -> a clean list: strings only, normalized, duplicates
 * removed (first wins). null / not a list = [] (never set).
 * @param {unknown} raw
 * @returns {string[]}
 */
export function normalizeChannelOrder(raw) {
  if (!Array.isArray(raw)) return []
  const out = []
  const seen = new Set()
  for (const v of raw) {
    if (typeof v !== 'string') continue
    const id = channelKey(v)
    if (!id || seen.has(id)) continue
    seen.add(id)
    out.push(id)
  }
  return out
}

/** Where the lde mock keeps the order across a reload (no hub there). */
export const MOCK_CHANNEL_ORDER_KEY = 'spool.mock.channel-order'
