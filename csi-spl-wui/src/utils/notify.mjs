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

/** The member id without its @box: "HUM-24@wui" and "HUM-24" are one reader. */
function baseId(id) {
  return String(id || '').split('@')[0]
}

/**
 * Ping (chime + browser alert) on every new message from someone else, unless
 * its channel is muted. A DM has no channel, so a muted channel does not
 * silence it.
 *
 * Bug A (t1 5002067f, HUM-24 2026-09-29: "notifications for new messages are
 * enabled, but no signal comes"): this used to ping only what escalates (a
 * mention, a DM, #alerts), so an ordinary reply from a member or an agent
 * raised a rail badge and nothing else. Escalation now only picks the alert's
 * title and the mention badge; muting a channel is the noise control.
 */
export function shouldPing(msg, ctx = {}, muted = []) {
  if (!msg) return false
  const self = baseId(ctx && ctx.selfId)
  if (self && baseId(msg.from) === self) return false
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
export function notificationOptions(body, chime, tag) {
  const o = { body: String(body || ''), silent: !chime }
  /* bug A: one alert per feed, the newest replacing the last, so a busy
     channel does not stack a pile of popups */
  if (tag) {
    o.tag = String(tag)
    /* HUM-24 (311427c6): a same-tag alert REPLACES the last one SILENTLY
       unless renotify is set, so while the first alert of a feed still sat in
       the phone's tray (or the desktop's notification centre) every later
       message of that feed changed it without a popup, sound or vibration */
    o.renotify = true
  }
  return o
}

/**
 * Raise one browser alert. Desktop browsers take `new Notification()`; Android
 * Chrome THROWS on it ("Illegal constructor", bug A: the phone never showed an
 * alert and the error was swallowed) and only shows one through the service
 * worker's registration, so a throw falls back to that.
 *
 * @returns {Promise<boolean>} whether an alert was raised
 */
export async function showAlert(title, opts, env = {}) {
  const N = 'Notification' in env ? env.Notification : (typeof Notification === 'undefined' ? undefined : Notification)
  const sw = 'serviceWorker' in env
    ? env.serviceWorker
    : (typeof navigator !== 'undefined' && navigator.serviceWorker ? navigator.serviceWorker : undefined)
  if (typeof N === 'function') {
    try {
      new N(title, opts)
      return true
    } catch {
      /* Android Chrome: only the service worker may show one */
    }
  }
  try {
    const reg = sw && typeof sw.getRegistration === 'function' ? await sw.getRegistration() : null
    if (!reg || typeof reg.showNotification !== 'function') return false
    await reg.showNotification(title, opts)
    return true
  } catch {
    return false
  }
}

/**
 * A ping gate: at most one sound per `ms`, so a burst of agent replies plays
 * one chime, not twenty overlapping ones.
 */
export function pingThrottle(ms = 2000, now = () => Date.now()) {
  let last = -Infinity
  return () => {
    const t = now()
    if (t - last < ms) return false
    last = t
    return true
  }
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

/**
 * HUM-24 (311427c6, third report: "the notification for new messages doesn't
 * work"): the bell is the reader's switch and defaults ON, so it read "alerts
 * on" in a browser that had never been asked for permission, or that blocks
 * it, and nothing told the reader why no alert came. This names the real
 * state for Settings:
 *   off         the reader switched alerts off
 *   on          wanted and allowed: alerts fire
 *   ask         wanted, the browser has not been asked yet (one click allows)
 *   blocked     wanted, the browser denies them (only its site settings undo it)
 *   install     wanted, iPhone / iPad Safari: only a Home Screen app may notify
 *   unsupported wanted, this browser has no notifications at all
 */
export function alertState(permission, enabled, env = {}) {
  if (!enabled) return 'off'
  if (permission === 'granted') return 'on'
  if (permission === 'denied') return 'blocked'
  if (permission === 'default') return 'ask'
  return needsHomeScreen(env) ? 'install' : 'unsupported'
}

/**
 * iOS / iPadOS Safari exposes notifications only to a web app opened from the
 * Home Screen (16.4+); in a browser tab `Notification` does not exist. An
 * iPad reports itself as a Mac, so a Mac with a touch screen counts.
 * @param {{ ua?: string, maxTouchPoints?: number, standalone?: boolean }} env
 */
export function needsHomeScreen(env = {}) {
  const ua = String(env.ua || '')
  const ios = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && Number(env.maxTouchPoints) > 1)
  return ios && !env.standalone
}

export function previewUnread(n) {
  const v = Number(n) || 0
  if (v <= 0) return ''
  return v > 99 ? '99+' : String(v)
}

/**
 * CLE-77845 (owner, topic 5dc55d94): a DM's rail badge reads "<new>/<total>"
 * (e.g. "2/7"), the new part capped like previewUnread. No new message: no
 * badge. A total we do not know (0, or below the new count while a refetch is
 * behind a live bump) falls back to the plain new count.
 */
export function dmBadgeText(unread, total) {
  const n = previewUnread(unread)
  if (!n) return ''
  const u = Number(unread) || 0
  const t = Number(total) || 0
  if (t < u) return n
  return `${n}/${t > 999 ? '999+' : t}`
}

/**
 * CLE-77873 (owner, t1 d6c9661e: "the amount of unread msgs vs the amount of
 * total msgs on the direct msgs do not show"): a DM with nothing new still
 * shows its total, plain ("7"), as a topic card reads "7 >>" with none unread
 * (CLE-77804) - never "0/7". '' while the total is unknown.
 * @param {number} total
 */
export function dmTotalText(total) {
  const t = Number(total) || 0
  if (t <= 0) return ''
  return t > 999 ? '999+' : String(t)
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
 * HUM-24 (311427c6, msg 826e3ff8: "only marimba and the cartoon sound work,
 * the other sound options are empty"): the context used to close the moment
 * its last oscillator ended IN CONTEXT TIME, but the speaker plays
 * `outputLatency` behind that clock (Android ~0.1-0.3 s, more on Bluetooth),
 * so the close threw away the audio still on its way out. Pop (0.10 s),
 * plain (0.12 s) and chirp (0.165 s) were dropped whole; marimba (0.20 s) and
 * boing (0.23 s) only lost their tail - exactly the three silent options.
 * The close now waits for the output latency plus this margin.
 */
export const CLOSE_GRACE_S = 1

/** How long after the last note ends (context time) the context may close, in ms. */
export function closeDelayMs(ctx) {
  const lat = Math.max(Number(ctx && ctx.outputLatency) || 0, Number(ctx && ctx.baseLatency) || 0)
  return Math.round((lat + CLOSE_GRACE_S) * 1000)
}

/* the first notes of a context just woken can be cut while the output starts.
   HUM-24 (311427c6, msg ddd345ea: "no, the others still don't work" on
   4.8.1): every chime opens a NEW context, so a new output stream, and a
   Bluetooth / Android audio route drops what plays while it wakes (~0.15-0.3
   s). Only the sounds longer than that (marimba 0.20 s, boing 0.23 s) got past
   it, so the notes now start after a quarter second of silence. */
export const LEAD_S = 0.25

/**
 * Play a named sound. One AudioContext per call, closed shortly after its
 * last oscillator ends — a context keeps an audio thread and buffers alive
 * for the life of the tab otherwise, one more per alert (CLE-35075).
 *
 * @param {string} name a key of SOUND_LIBRARY (unknown => DEFAULT_SOUND)
 * @param {(new () => any) | undefined} [Ctx] AudioContext (a test seam)
 * @param {(fn: () => void, ms: number) => unknown} [later] setTimeout (a test seam)
 * @returns {boolean} whether the sound was started
 */
export function playSound(name, Ctx = typeof AudioContext === 'undefined' ? undefined : AudioContext, later = setTimeout) {
  if (typeof Ctx !== 'function') return false
  const spec = SOUND_LIBRARY[name] || SOUND_LIBRARY[DEFAULT_SOUND]
  let ctx = null
  const drop = () => { if (ctx) void Promise.resolve().then(() => ctx.close()).catch(() => {}) }
  /* the notes are scheduled from the clock as it reads when they can play */
  const schedule = () => {
    const t0 = ctx.currentTime + LEAD_S
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
    if (last) {
      last.onended = () => {
        later(() => { void Promise.resolve(ctx.close()).catch(() => {}) }, closeDelayMs(ctx))
      }
    }
  }
  try {
    ctx = new Ctx()
    /* bug A: a context made outside a click starts `suspended` under the
       autoplay policy and plays nothing; resuming it is allowed once the
       page has had any click or key press.
       HUM-24 (311427c6, lead from CLE-35004): schedule only once the resume
       has resolved - notes scheduled from the clock BEFORE it may already lie
       in the past when it runs, and a short motif then never sounds */
    if (ctx.state === 'suspended' && typeof ctx.resume === 'function') {
      void Promise.resolve(ctx.resume())
        .then(() => schedule())
        .catch(drop)
      return true
    }
    schedule()
    return true
  } catch {
    /* autoplay policies */
    drop()
    return false
  }
}

/**
 * The pre-051 880 Hz beep, kept for back-compat: `playSound('plain', …)`.
 * @param {(new () => any) | undefined} [Ctx] AudioContext (a test seam)
 * @param {(fn: () => void, ms: number) => unknown} [later] setTimeout (a test seam)
 * @returns {boolean} whether a beep was started
 */
export function playChime(Ctx = typeof AudioContext === 'undefined' ? undefined : AudioContext, later = setTimeout) {
  return playSound('plain', Ctx, later)
}
