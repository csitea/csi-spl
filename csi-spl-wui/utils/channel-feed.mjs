/** Pure feed helpers. Node tests import this file; Vue stores wrap it. */

import { applyVerbosity as filterByKind } from './verbosity.mjs'

export function topLevel(messages) {
  return messages
    .filter((m) => !m.parent_task_id)
    .slice()
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
}

export function threadOf(messages, parentTaskId) {
  if (!parentTaskId) return []
  return messages
    .filter((m) => m.task_id === parentTaskId || m.parent_task_id === parentTaskId)
    .slice()
    .sort((a, b) => String(a.ts).localeCompare(String(b.ts)))
}

export function replyCount(messages, taskId) {
  return messages.filter((m) => m.parent_task_id === taskId).length
}

/** Visibility by `kind` only (verbosity-notify-v1.md). Body prefixes are not a filter. */
export function applyVerbosity(messages, level) {
  return filterByKind(messages, level)
}

export function parseMention(text) {
  const raw = String(text || '')
  const m = raw.match(/^@([A-Z]{2,4}-\d+)\b\s*([\s\S]*)$/)
  if (!m) return { to: '@channel', kind: 'note', body: raw }
  return { to: m[1], kind: 'task', body: m[2] }
}

export function displayName(id, box) {
  if (!id) return 'unknown'
  return box ? `${id}@${box}` : id
}

export function initials(id) {
  const s = String(id || '?')
  const m = s.match(/^([A-Z]{2,4})-(\d+)$/)
  if (m) return m[1].slice(0, 2)
  return s.slice(0, 2).toUpperCase()
}

export function hueFor(id) {
  let h = 0
  for (const ch of String(id || '')) h = (h * 31 + ch.charCodeAt(0)) >>> 0
  return h % 360
}

export function formatBytes(n) {
  const v = Number(n) || 0
  if (v < 1024) return `${v} B`
  if (v < 1024 * 1024) return `${(v / 1024).toFixed(1)} KiB`
  return `${(v / (1024 * 1024)).toFixed(1)} MiB`
}

export function formatTs(ts) {
  const d = new Date(ts)
  if (Number.isNaN(d.getTime())) return String(ts || '')
  return d.toISOString().slice(11, 16)
}

export function renderBody(src) {
  const escaped = String(src || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
  return escaped
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/@([A-Z]{2,4}-\d+)/g, '<span class="mention">@$1</span>')
    .replace(/\n/g, '<br>')
}
