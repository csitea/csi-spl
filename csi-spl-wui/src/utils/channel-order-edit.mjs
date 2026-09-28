/**
 * SPL-1034 (specs/045 §3.8): editing a person's Channels order. Loaded on
 * first use (utils/channel-order.mjs is the eager half). Node tests import
 * this file.
 */
import { CHANNEL_ORDER_MAX, normalizeChannelOrder } from './channel-order.mjs'

/**
 * The list to store after the person reordered what is on screen: the WHOLE
 * displayed order, with every stored id that is not displayed now kept right
 * after the id it followed before (at the top when it led the list).
 * @param {string[]} displayed the ids as drawn, top first
 * @param {string[]} stored the list stored before this change
 * @returns {string[]}
 */
export function mergeChannelOrder(displayed, stored) {
  const out = normalizeChannelOrder(displayed)
  const shown = new Set(out)
  let prev = ''
  let lead = 0
  for (const id of normalizeChannelOrder(stored)) {
    if (!shown.has(id)) {
      const at = prev ? out.indexOf(prev) + 1 : lead++
      out.splice(at, 0, id)
      shown.add(id)
    }
    prev = id
  }
  return out.slice(0, CHANNEL_ORDER_MAX)
}

/**
 * Move up (-1) / Move down (+1) from a row menu: swap `id` with its
 * neighbour in the displayed order. Returns the new displayed order, or
 * null when there is no neighbour that way (the first / last row).
 * @param {string[]} displayed
 * @param {string} id
 * @param {-1 | 1} step
 * @returns {string[] | null}
 */
export function stepChannelOrder(displayed, id, step) {
  const list = Array.isArray(displayed) ? displayed.map((k) => String(k)) : []
  const from = list.indexOf(String(id))
  const to = from + (step < 0 ? -1 : 1)
  if (from < 0 || to < 0 || to >= list.length) return null
  const next = list.slice()
  next[from] = list[to]
  next[to] = list[from]
  return next
}

/** Same lists, same order. */
export function sameChannelOrder(a, b) {
  const x = Array.isArray(a) ? a : []
  const y = Array.isArray(b) ? b : []
  return x.length === y.length && x.every((v, i) => v === y[i])
}
