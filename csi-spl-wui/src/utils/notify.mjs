/**
 * In-browser notification rules (005 contracts/verbosity-notify-v1.md §2).
 * Escalate only on HUM-* mention, DM received, or #alerts. Nothing else.
 */

import { storageGet, storageGetJson, storageSet, storageSetJson } from './prefs.mjs'

export const CHIME_KEY = 'spool.chime'
/* 051: which sound the chime plays, per device (owner dd88348d: "the beep
   sound is too plain. Could it be something more funny"). */
export const CHIME_SOUND_KEY = 'spool.chime-sound'
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

/* SPL-998: the note is the ONE switch for sound. A browser Notification plays
   the operating system's own alert sound unless it is `silent`, so with the
   bell on and the note off every alert still beeped. Every alert the WUI
   raises takes its options from here. */
export function notificationOptions(body, chime) {
  return { body: String(body || ''), silent: !chime }
}

/** SPL-998: another tab flipped the note or the bell (a `storage` event; null = cleared).
 *  051: a sound change in another tab counts too. */
export function isSoundPrefKey(key) {
  return key === CHIME_KEY || key === ALERTS_KEY || key === CHIME_SOUND_KEY || key === null
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

/**
 * 051: the sound the chime plays. Each is a short motif of one or more
 * oscillator segments, all generated in code — no audio files, no licensing,
 * nothing bundled (distribution hygiene). A segment:
 *   { type?, f, to?, dur, gain, at?, env? }
 * `type` is the oscillator wave (default sine); `f` the frequency; `to` an
 * exponential glide target over the segment; `dur` its length in seconds;
 * `gain` its peak; `at` a start offset from the motif's start; `env` a quick
 * attack/decay envelope (a bare gain clicks, an envelope pops or rings).
 * `plain` is the pre-051 880 Hz beep, kept as an explicit choice.
 */
export const SOUND_LIBRARY = {
  plain: { segs: [{ f: 880, dur: 0.12, gain: 0.04 }] },
  pop: { segs: [{ f: 520, to: 150, dur: 0.1, gain: 0.07, env: true }] },
  chirp: { segs: [
    { f: 620, dur: 0.07, gain: 0.05, env: true },
    { f: 990, dur: 0.09, gain: 0.05, env: true, at: 0.075 },
  ] },
  marimba: { segs: [
    { type: 'triangle', f: 523, dur: 0.2, gain: 0.06, env: true },
    { type: 'triangle', f: 1046, dur: 0.14, gain: 0.02, env: true },
  ] },
  boing: { segs: [{ type: 'sawtooth', f: 400, to: 130, dur: 0.24, gain: 0.05, env: true }] },
}

/** The sound names, in the order Settings lists them. */
export const SOUND_NAMES = Object.keys(SOUND_LIBRARY)

/** The default a fresh device gets (dd88348d: fun, not the plain beep). */
export const DEFAULT_SOUND = 'chirp'

/** A stored name that is not in the library falls back to the default. */
export function normalizeSound(name) {
  return SOUND_NAMES.includes(String(name)) ? String(name) : DEFAULT_SOUND
}

export function loadChimeSound(store) {
  return normalizeSound(storageGet(CHIME_SOUND_KEY, DEFAULT_SOUND, store))
}

export function saveChimeSound(name, store) {
  return storageSet(CHIME_SOUND_KEY, normalizeSound(name), store)
}

/**
 * Play a named sound. One AudioContext per call, closed when its last
 * oscillator ends — a context keeps an audio thread and buffers alive for the
 * life of the tab otherwise, one more per alert (CLE-35075).
 *
 * @param {string} name a key of SOUND_LIBRARY (unknown => DEFAULT_SOUND)
 * @param {(new () => any) | undefined} [Ctx] AudioContext (a test seam)
 * @returns {boolean} whether the sound was started
 */
export function playSound(name, Ctx = typeof AudioContext === 'undefined' ? undefined : AudioContext) {
  if (typeof Ctx !== 'function') return false
  const spec = SOUND_LIBRARY[name] || SOUND_LIBRARY[DEFAULT_SOUND]
  let ctx = null
  try {
    ctx = new Ctx()
    const t0 = ctx.currentTime
    let last = null
    let lastStop = t0
    for (const s of spec.segs) {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      if (s.type) osc.type = s.type
      const start = t0 + (s.at || 0)
      const stop = start + s.dur
      if (s.to) {
        osc.frequency.setValueAtTime(s.f, start)
        osc.frequency.exponentialRampToValueAtTime(s.to, stop)
      } else {
        osc.frequency.value = s.f
      }
      if (s.env) {
        gain.gain.setValueAtTime(0.0001, start)
        gain.gain.exponentialRampToValueAtTime(s.gain, start + 0.01)
        gain.gain.exponentialRampToValueAtTime(0.0001, stop)
      } else {
        gain.gain.value = s.gain
      }
      osc.connect(gain)
      gain.connect(ctx.destination)
      osc.start(start)
      osc.stop(stop)
      if (stop >= lastStop) { lastStop = stop; last = osc }
    }
    if (last) last.onended = () => { void Promise.resolve(ctx.close()).catch(() => {}) }
    return true
  } catch {
    /* autoplay policies */
    if (ctx) void Promise.resolve().then(() => ctx.close()).catch(() => {})
    return false
  }
}

/**
 * The pre-051 880 Hz beep, kept for back-compat: `playSound('plain', …)`.
 * @param {(new () => any) | undefined} [Ctx] AudioContext (a test seam)
 * @returns {boolean} whether a beep was started
 */
export function playChime(Ctx = typeof AudioContext === 'undefined' ? undefined : AudioContext) {
  return playSound('plain', Ctx)
}
