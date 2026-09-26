/**
 * In-browser notification rules (005 contracts/verbosity-notify-v1.md §2).
 * Escalate only on HUM-* mention, DM received, or #alerts. Nothing else.
 */

import { storageGet, storageGetJson, storageSet, storageSetJson } from './prefs.mjs'

export const CHIME_KEY = 'spool.chime'
export const MENTION_RE = /@([A-Z]{2,4}-\d+)(?:@[a-z0-9][a-z0-9-]{0,31})?\b/g

export function normalizeChannel(name) {
  const s = String(name || '').replace(/^#/, '').trim().toLowerCase()
  if (!s) return ''
  if (s === 'general') return 'lobby'
  return s
}

export function mentionedIds(body) {
  const ids = []
  const s = String(body || '')
  const re = new RegExp(MENTION_RE.source, 'g')
  let m
  while ((m = re.exec(s))) ids.push(m[1])
  return ids
}

export function isSelf(msg, selfId) {
  const self = String(selfId || '')
  return Boolean(self) && String((msg && msg.from) || '') === self
}

export function isDm(msg, ctx = {}) {
  if (ctx.isDm || ctx.peer) return true
  return Boolean(msg) && msg.channel === null
}

export function channelKey(msg, ctx = {}) {
  if (isDm(msg, ctx)) {
    const peer = ctx.peer || [msg && msg.from, msg && msg.from_box].filter(Boolean).join('@')
    return `dm:${peer}`
  }
  const ch = normalizeChannel(msg && msg.channel) || normalizeChannel(ctx.channel) || 'lobby'
  return `ch:${ch}`
}

export function mentionsSelf(msg, selfId) {
  const self = String(selfId || '')
  if (!self) return false
  if (String((msg && msg.to) || '') === self) return true
  return mentionedIds(msg && msg.body).includes(self)
}

export function escalateReason(msg, ctx = {}) {
  if (!msg) return null
  if (isSelf(msg, ctx.selfId)) return null
  const ch = normalizeChannel(msg.channel) || normalizeChannel(ctx.channel)
  if (ch === 'alerts') return 'alerts'
  if (isDm(msg, ctx)) return 'dm'
  if (mentionsSelf(msg, ctx.selfId)) return 'mention'
  return null
}

export function shouldEscalate(msg, ctx = {}) {
  return escalateReason(msg, ctx) != null
}

/** This browser only. Not a hub field. */
export const MUTED_CHANNELS_KEY = 'spool.muted-channels'

export function loadMutedChannels(store) {
  const raw = storageGetJson(MUTED_CHANNELS_KEY, [], store)
  const ids = Array.isArray(raw) ? raw : []
  return [...new Set(ids.map((id) => normalizeChannel(id)).filter(Boolean))]
}

export function saveMutedChannels(ids, store) {
  const clean = [...new Set((ids || []).map((id) => normalizeChannel(id)).filter(Boolean))]
  storageSetJson(MUTED_CHANNELS_KEY, clean, store)
  return clean
}

export function toggleMutedChannel(ids, channel) {
  const id = normalizeChannel(channel)
  const next = new Set((ids || []).map((x) => normalizeChannel(x)).filter(Boolean))
  if (!id) return [...next]
  if (next.has(id)) next.delete(id)
  else next.add(id)
  return [...next]
}

/**
 * Ping only when the message would escalate and its channel is not muted.
 * A DM has no channel, so a muted channel does not silence it.
 */
export function shouldPing(msg, ctx = {}, muted = []) {
  if (!escalateReason(msg, ctx)) return false
  const ch = normalizeChannel(msg && msg.channel) || normalizeChannel(ctx && ctx.channel)
  if (!ch) return true
  const set = new Set((muted || []).map((id) => normalizeChannel(id)))
  return !set.has(ch)
}

export function notifyCopy(msg, reason) {
  const from = String((msg && msg.from) || 'spool')
  const body = String((msg && msg.body) || '').slice(0, 140)
  if (reason === 'alerts') return { title: `#alerts · ${from}`, body }
  if (reason === 'dm') return { title: `DM from ${from}`, body }
  if (reason === 'mention') return { title: `${from} mentioned you`, body }
  return { title: from, body }
}

/**
 * i18n sibling of notifyCopy: the same title as a catalogue key + params
 * (`notify.title_*`), the body untouched (it is message data). Components and
 * stores translate the key; notifyCopy stays the English reference.
 */
export function notifyCopyKey(msg, reason) {
  const from = String((msg && msg.from) || 'spool')
  const body = String((msg && msg.body) || '').slice(0, 140)
  if (reason === 'alerts') return { titleKey: 'notify.title_alerts', params: { from }, body }
  if (reason === 'dm') return { titleKey: 'notify.title_dm', params: { from }, body }
  if (reason === 'mention') return { titleKey: 'notify.title_mention', params: { from }, body }
  return { titleKey: 'notify.title_other', params: { from }, body }
}

export function loadChime(store) {
  return storageGet(CHIME_KEY, '0', store) === '1'
}

export function saveChime(on, store) {
  return storageSet(CHIME_KEY, on ? '1' : '0', store)
}

/* owner, 2026-09-26: the bell is an ON/OFF switch, not just the browser's
   permission. ALERTS_KEY holds the reader's choice; default ON, so a browser
   that had already granted permission keeps alerting as before. */
export const ALERTS_KEY = 'spool.alerts'

export function loadAlerts(store) {
  return storageGet(ALERTS_KEY, '1', store) !== '0'
}

export function saveAlerts(on, store) {
  return storageSet(ALERTS_KEY, on ? '1' : '0', store)
}

/** Browser alerts actually fire: the browser granted them AND the reader wants them. */
export function alertsActive(permission, enabled) {
  return permission === 'granted' && Boolean(enabled)
}

export function previewUnread(n) {
  const v = Number(n) || 0
  if (v <= 0) return ''
  return v > 99 ? '99+' : String(v)
}
