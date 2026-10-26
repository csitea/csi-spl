/**
 * Spec 079 FR-001: one unread model. Every surface (row, rail, card, tab
 * title) reads its number from here instead of computing its own from one of
 * three inputs (hub Flow counts, hub row keys, local cursors).
 *
 * Inputs, all optional:
 *  - keys: the hub's Flow row keys (`ch:<id>`, `dm:<peer>`, `t:<task_id>`), or
 *    null on an older hub. When present they win (spec Q3).
 *  - cursors: the local read cursors (read-cursor.mjs), `t:<id>` carrying `count`.
 *  - channelUnread: `ch:<id>` -> n, from the hub channel rows.
 *  - dmUnread: `dm:<peer>` -> n, from the notification store.
 *  - muted: muted channel ids; shown on their row, left out of the title (Q2).
 *  - topics: [{ task_id, total }] (hub reply total, read against the t: cursor)
 *    or [{ task_id, messages }] (counted against the t: cursor, own excluded).
 *  - self: the viewer's id, for counting `messages`.
 *
 * Pure, no state: useUnread() (T003) holds it reactively.
 */

import { rowUnread, sectionTotal } from './flow-keys.mjs'
import { countUnread, topicKey, topicUnread } from './read-cursor.mjs'
import { unreadTotal } from './tab-title.mjs'

const PREFIX = { channels: 'ch:', dms: 'dm:', topics: 't:' }

/** The local (no hub keys) unread per place key. */
function localUnread({ cursors, channelUnread, dmUnread, topics, self }) {
  const out = { ...(channelUnread || {}), ...(dmUnread || {}) }
  const cs = cursors || {}
  for (const t of topics || []) {
    const key = topicKey(t && t.task_id ? String(t.task_id) : '')
    if (!key) continue
    out[key] = Array.isArray(t.messages)
      ? countUnread(t.messages, cs[key], self)
      : topicUnread(t.total, cs[key])
  }
  return out
}

/**
 * @param {{
 *   keys?: Record<string, number> | null,
 *   cursors?: Record<string, any>,
 *   channelUnread?: Record<string, number>,
 *   dmUnread?: Record<string, number>,
 *   muted?: string[],
 *   topics?: { task_id: string, total?: number, messages?: any[] }[],
 *   self?: string,
 * }} [inputs]
 * @returns {{ rows: Map<string, number>, sections: { channels: number, dms: number, topics: number }, title: number }}
 *   rows holds only places with unread (n > 0); a missing key reads 0.
 */
export function unreadModel(inputs = {}) {
  const keys = inputs.keys || null
  const own = localUnread(inputs)
  const rows = new Map()
  for (const key of new Set([...Object.keys(keys || {}), ...Object.keys(own)])) {
    const n = rowUnread(keys, own, key)
    if (n > 0) rows.set(key, n)
  }
  const flat = Object.fromEntries(rows)
  const sections = {}
  for (const [name, prefix] of Object.entries(PREFIX)) {
    const ids = [...rows.keys()].filter((k) => k.startsWith(prefix)).map((k) => k.slice(prefix.length))
    sections[name] = sectionTotal(flat, prefix, ids)
  }
  return { rows, sections, title: unreadTotal(flat, inputs.muted || []) }
}

/**
 * Spec 079 FR-006 (SPL-3587, owner HUM-10 csitea 739eb4f1: "(3)" in the tab
 * while the rows showed 1): the tab title's number is the sum of the rows the
 * sidebar lists, as the rail's Channels and Direct messages numbers are
 * (useSidebarCounts listedSum). A `ch:` key with no sidebar row - the issues
 * and tasks boards, whose lines the hub still counts per place - is in no
 * section a person can open, so it stays out of the title. DM rows: every
 * `dm:` key gets a row (flowDmPeers), so all count. Muted channels are left
 * out (Q2).
 *
 * @param {Map<string, number>} rows unreadModel's rows
 * @param {Iterable<string>} channelIds the channel ids the sidebar lists
 * @param {string[]} [muted] muted channel ids
 * @returns {number}
 */
export function tabUnread(rows, channelIds, muted = []) {
  const off = new Set(muted || [])
  let n = 0
  for (const id of new Set(channelIds || [])) {
    if (!off.has(id)) n += Math.max(0, Number(rows.get('ch:' + id)) || 0)
  }
  for (const [k, v] of rows) {
    if (k.startsWith('dm:')) n += Math.max(0, Number(v) || 0)
  }
  return n
}
