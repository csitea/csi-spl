/** Left-strip tabs, top to bottom. */

import { channelActivity } from './channel-feed.mjs'
import { productPath } from './signed-out-redirect.mjs'

export const SIDE_TABS = ['dm', 'channels', 'topics', 'flow']

/** Names accepted after `/switch-pane:`. `messages` is the direct-message pane.
 *  `topic` and `topics` are the same pane. */
const SWITCH_PANE_NAMES = {
  messages: 'dm',
  channels: 'channels',
  topics: 'topics',
  topic: 'topics',
  flow: 'flow',
}

/**
 * The open route picks a tab when the page is one of the four lists.
 * Search and settings return null so the reader's own choice stays.
 * The call site starts on direct messages.
 * @param {string} path vue-router path, no query
 * @returns {'dm' | 'channels' | 'topics' | 'flow' | null}
 */
export function tabForPath(path) {
  const p = productPath(path)
  if (p === '/dm' || p.startsWith('/dm/')) return 'dm'
  if (p === '/channel' || p.startsWith('/channel/')) return 'channels'
  if (p === '/' || p === '/t' || p.startsWith('/t/')) return 'topics'
  return null
}

/**
 * One list of every channel, direct-message peer and topic, newest
 * activity first. A row with no clock sorts after every dated row.
 * Ties break on the row key so the order does not flicker.
 * @param {{ channels?: unknown[], peers?: unknown[], topics?: unknown[], liveAt?: Record<string, string>, dmAt?: Record<string, string> }} [src]
 */
export function flowRows(src = {}) {
  const liveAt = src.liveAt || {}
  const dmAt = src.dmAt || {}
  const rows = []
  for (const c of src.channels || []) {
    const id = String((c && (c.channel_id || c.channel)) || '')
    if (!id) continue
    rows.push({
      kind: 'channel',
      key: 'ch:' + id,
      id,
      at: channelActivity(c, liveAt),
      label: String((c && c.name) || id),
    })
  }
  for (const p of src.peers || []) {
    const label = String((p && p.label) || '')
    if (!label) continue
    rows.push({
      kind: 'dm',
      key: 'dm:' + label,
      id: String((p && p.id) || ''),
      box: String((p && p.box) || ''),
      at: String(dmAt[label] || ''),
      label,
      online: Boolean(p && p.online),
    })
  }
  for (const t of src.topics || []) {
    const id = String((t && t.task_id) || '')
    if (!id) continue
    const people = Array.isArray(t.participants) ? t.participants.filter(Boolean).join(', ') : ''
    rows.push({
      kind: 'topic',
      key: 'th:' + id,
      id,
      at: String((t && (t.last_ts || t.first_ts)) || ''),
      label: String((t && t.subject) || people || id),
    })
  }
  rows.sort((a, b) => {
    const c = String(b.at).localeCompare(String(a.at))
    return c !== 0 ? c : a.key.localeCompare(b.key)
  })
  return rows
}

/**
 * Omnibox command `/switch-pane: <name>`.
 * `null` — this line is not the command (send it as a message).
 * `''` — it is the command, but the name is not a pane (do not send).
 * Otherwise the pane id: messages → dm, channels, topics (also topic), flow.
 * @param {string} text
 * @returns {'dm' | 'channels' | 'topics' | 'flow' | '' | null}
 */
export function switchPaneOf(text) {
  const s = String(text || '').trim()
  const m = s.match(/^\/switch-pane:\s*(.*)$/i)
  if (!m) return null
  const name = m[1].trim().toLowerCase()
  if (!name || /\s/.test(name)) return ''
  return Object.prototype.hasOwnProperty.call(SWITCH_PANE_NAMES, name) ? SWITCH_PANE_NAMES[name] : ''
}
