/**
 * In-browser notification rules (005 contracts/verbosity-notify-v1.md §2).
 * Escalate only on HUM-* mention, DM received, or #alerts. Nothing else.
 */

import { storageGet, storageGetJson, storageSet, storageSetJson } from './prefs.mjs'
import { BOX_ID_SRC, PARTICIPANT_ID_SRC } from './agent-id.mjs'
import { isViewersOwn } from './typed-by.mjs'

export const CHIME_KEY = 'spool.chime'
/* 051: which sound the chime plays, per device (owner dd88348d: "the beep
   sound is too plain. Could it be something more funny"). */
export const CHIME_SOUND_KEY = 'spool.chime-sound'
export const MENTION_RE = new RegExp(String.raw`@(${PARTICIPANT_ID_SRC})(?:@${BOX_ID_SRC})?\b`, 'g')

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

/** The viewer's own row: their post, or a line they typed at an agent's terminal (CLE-77889). */
export function isSelf(msg, selfId) {
  return isViewersOwn(msg, selfId)
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
 * Ping (chime + browser alert) on every new message from someone else, unless
 * its channel is muted. A DM has no channel, so a muted channel does not
 * silence it.
 *
 * Bug A (t1 5002067f, HUM-24 2026-09-29: "notifications for new messages are
 * enabled, but no signal comes"): this used to ping only what escalates (a
 * mention, a DM, #alerts), so an ordinary reply from a member or an agent
 * raised a rail badge and nothing else. Escalation now only picks the alert's
 * title and the mention badge; muting a channel is the noise control.
 *
 * Spec 096 T005 (Q1): `ctx.status` is the reader's own status. Unavailable
 * with the pause box ticked (and not yet expired) silences; Busy never does.
 */
export function shouldPing(msg, ctx = {}, muted = []) {
  if (!msg) return false
  if (isViewersOwn(msg, ctx && ctx.selfId)) return false
  const st = ctx && ctx.status
  if (st && st.state === 'unavailable' && st.pauseNotify && !(Date.parse(st.until) <= Date.now())) return false
  const ch = normalizeChannel(msg && msg.channel) || normalizeChannel(ctx && ctx.channel)
  if (!ch) return true
  const set = new Set((muted || []).map((id) => normalizeChannel(id)))
  return !set.has(ch)
}

/**
 * HUM-24 (t1 cd9b0f47, a member: "when a new message arrives I get no
 * notification"): the open feed pinged only while the reader was away from
 * the tab, as if every message in it were on screen. A reply is not: the
 * middle pane shows one card per topic, and a reply only moves that card's
 * count. So a reply into a topic whose thread is not open is off screen and
 * signals like a message in another channel.
 * A reply: it names a parent topic, it was written in a thread pane
 * (is_parent 0), or another message of the feed already holds its task_id.
 * @param {object} msg the new message
 * @param {object[]} [feed] the open feed's messages (msg itself may be in it)
 * @param {string[]} [openTopics] task ids whose thread is on screen
 * @returns {boolean}
 */
export function offScreenReply(msg, feed = [], openTopics = []) {
  if (!msg || !msg.task_id) return false
  const task = String(msg.task_id)
  const parent = msg.parent_task_id && String(msg.parent_task_id) !== task ? String(msg.parent_task_id) : ''
  const reply = Boolean(parent) || msg.is_parent === 0
    || (feed || []).some((m) => m && String(m.task_id || '') === task && m.msg_id !== msg.msg_id)
  if (!reply) return false
  const open = new Set((openTopics || []).filter(Boolean).map(String))
  return !open.has(task) && !(parent && open.has(parent))
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
export function notificationOptions(body, chime, tag, data) {
  const o = { body: String(body || ''), silent: !chime }
  /* CLE-77890: what a tap opens (notificationTarget); the worker reads it back */
  if (data) o.data = data
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
 * CLE-77890 (owner, t1 bd6d7291: "whenever I click on the announcements from
 * the android, it does not jump to the actual UI of the announcement, but just
 * keeps me there where I was"): a tap on an alert opens its message. The
 * worker (public/sw.js) posts NOTIFY_OPEN to an open tab, which answers on the
 * message's port and routes to `url`; an older bundle that never answers is
 * navigated there, and with no tab open one is opened at `url`.
 */
export const NOTIFY_OPEN = 'spool:notification-open'

/**
 * The target an alert carries in its `data`: the message id and its deep link
 * /m/<msg_id> (CLE-77882), locale-aware through `pathFor`. No id: the app root.
 * @param {{ msg_id?: string } | null | undefined} msg
 * @param {(p: string) => string} [pathFor] localePath
 * @returns {{ msgId: string, url: string }}
 */
export function notificationTarget(msg, pathFor = (p) => p) {
  const msgId = String((msg && msg.msg_id) || '').toLowerCase()
  const path = msgId ? '/m/' + encodeURIComponent(msgId) : '/'
  return { msgId, url: String(pathFor(path) || path) }
}

/** sessionStorage: a tapped alert's target until its route is reached. */
export const PENDING_OPEN_KEY = 'spool.notify-open'

/** How long a pending tap stays worth opening after a reload. */
export const PENDING_OPEN_MS = 30000

/**
 * The tap a reload cut short, from its stored JSON: { url } while it is
 * younger than PENDING_OPEN_MS and names a same-origin path, else null.
 */
export function pendingOpen(raw, now) {
  let v = null
  try { v = JSON.parse(String(raw || 'null')) } catch { return null }
  const url = String((v && v.url) || '')
  const at = Number(v && v.at)
  if (!url.startsWith('/') || url.startsWith('//')) return null
  if (!Number.isFinite(at) || now - at < 0 || now - at > PENDING_OPEN_MS) return null
  return { url }
}

/**
 * Raise one browser alert. Desktop browsers take `new Notification()`; Android
 * Chrome THROWS on it ("Illegal constructor", bug A: the phone never showed an
 * alert and the error was swallowed) and only shows one through the service
 * worker's registration, so a throw falls back to that.
 *
 * CLE-77890: `env.onOpen(data)` runs when a desktop alert is clicked (after the
 * tab is brought forward); an Android alert's click is the worker's.
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
      const n = new N(title, opts)
      if (typeof env.onOpen === 'function') {
        n.onclick = (e) => {
          if (e && typeof e.preventDefault === 'function') e.preventDefault()
          try {
            if (typeof window !== 'undefined') window.focus()
          } catch { /* not allowed: the click still opens the message */ }
          if (typeof n.close === 'function') n.close()
          env.onOpen(opts && opts.data)
        }
      }
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

/* The motifs and the player are in notify-sound.mjs, loaded on the first
   chime: here they sat in the initial JS (027 ci_initial_gzip_kb, SPL-3573). */
/** The sound names, in the order Settings lists them: the keys of notify-sound.mjs SOUND_LIBRARY. */
export const SOUND_NAMES = ['plain', 'pop', 'chirp', 'marimba', 'boing']

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
