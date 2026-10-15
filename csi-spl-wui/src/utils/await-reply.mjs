// SPL-1994 (owner HUM-10, t1 72898ea2 msg def4a52d): "as soon as the system
// receives the prompt, a spinning hourglass must appear". SPL-2026 (msg
// 8285fce1): "it should appear right after i click send". A person's post
// shows an hourglass on the post and on its topic row from the moment send is
// clicked (the `pending` optimistic row) and after the ack, until the first
// agent post in that topic after it. A send held for the network (`waiting`)
// or one that failed (its row is removed) shows none: never spin on a post
// the hub never got. No agent in the topic, or none after `spinMs` (cnf
// env.wui.await_reply_minutes, default 10), and it turns into a calm
// "waiting" mark instead of spinning forever.
//
// Read from the rows the WUI already holds; the hub has no field for it.
//
// The animation is ONE swappable piece (owner msgs ad9882d2, 0f442e7c): an
// animation id names an entry of AWAIT_ANIMATIONS, either a CSS animation (a
// class) or a short looping clip (animated WebP or a video, lazy-loaded, no
// autoplay under prefers-reduced-motion). components/AwaitReply.vue renders
// whichever is picked.
//
// SPL-2027 (owner HUM-10, t1 72898ea2 msgs c4aae6fc, 1689b768, f7779032):
// more of them - a small robot running, a brain that swells and pops from too
// much thinking - and a per-person pick (Settings -> Appearance), kept in this
// browser per signed-in person (no hub field). Every one draws 20% bigger
// than the first hourglass, inside the same box.

import { isAgentId } from './agent-id.mjs'
import { storageGet, storageSet } from './prefs.mjs'

/** The animation used when nobody picked one. */
export const DEFAULT_AWAIT_ANIM = 'hourglass'

/**
 * id -> how it is drawn. `css`: the component draws its glyph with this class
 * (the keyframes live in AwaitReply.vue). `clip`: `src` is a same-origin
 * looping file, `type` its media type (image/webp plays as an <img>, video/*
 * as a muted <video>), `poster` the still shown under reduced motion.
 */
export const AWAIT_ANIMATIONS = Object.freeze({
  hourglass: Object.freeze({ kind: 'css', className: 'await-anim--hourglass' }),
  robot: Object.freeze({ kind: 'css', className: 'await-anim--robot' }),
  brain: Object.freeze({ kind: 'css', className: 'await-anim--brain' }),
})

/**
 * The ids a person can pick, in the order the setting lists them. A literal,
 * not Object.keys(AWAIT_ANIMATIONS): that top-level call reads as a side
 * effect, so Nuxt's auto-import barrel kept this whole module in the entry
 * chunk (ci_initial_gzip_kb 154.6 -> 155.3 KB, over 155). A unit test keeps
 * the two in step.
 */
export const AWAIT_ANIM_IDS = Object.freeze(['hourglass', 'robot', 'brain'])

/** The entry for `id`; the default one for an unknown or empty id. */
export function awaitAnimation(id) {
  const key = String(id || '')
  const known = Object.prototype.hasOwnProperty.call(AWAIT_ANIMATIONS, key)
  const pick = known ? key : DEFAULT_AWAIT_ANIM
  return { id: pick, ...AWAIT_ANIMATIONS[pick] }
}

/** localStorage key of a pick made signed out; the prefix of each person's own key. */
export const AWAIT_ANIM_KEY = 'spool-await-anim'
/** A person's pick key, per tenant and person, so a shared browser keeps each one's own. */
export function awaitAnimKey(claims) {
  const hum = String((claims && claims.hum) || '')
  if (!hum) return AWAIT_ANIM_KEY
  const tenant = String((claims && claims.t) || '')
  return `${AWAIT_ANIM_KEY}:${tenant ? tenant + ':' : ''}${hum}`
}

/** The person's picked animation id; the default when none or an unknown one is stored. */
export function readAwaitAnim(claims, store) {
  return awaitAnimation(storageGet(awaitAnimKey(claims), '', store)).id
}

/** Store the person's pick (an unknown id stores the default); returns the stored id. */
export function writeAwaitAnim(claims, id, store) {
  const pick = awaitAnimation(id).id
  storageSet(awaitAnimKey(claims), pick, store)
  return pick
}

export const DEFAULT_AWAIT_MINUTES = 10
/** Past this age a post shows nothing: an old unanswered line is history, not a wait. */
export const AWAIT_SHOW_MAX_MS = 24 * 60 * 60 * 1000

/** cnf minutes (a runtime-config text) -> ms; anything but a positive number = the default. */
export function awaitSpinMs(raw) {
  const s = String(raw ?? '').trim()
  const n = Number(s)
  const min = s !== '' && Number.isFinite(n) && n > 0 ? n : DEFAULT_AWAIT_MINUTES
  return Math.round(min * 60 * 1000)
}

const PERSON_RE = /^(HUM|GST)-[0-9]+$/

/** A person's line: a member or guest, or one a person typed at an agent's terminal. */
export function isPersonPost(m) {
  return Boolean(m && (m.typed_by || PERSON_RE.test(String(m.from || ''))))
}

/** An agent's own line (not one a person typed at its terminal). */
export function isAgentPost(m) {
  return Boolean(m && !m.typed_by && isAgentId(m.from))
}

/** When the hub had it: received_at, else the sent ts; NaN when neither parses. */
export function receivedAt(m) {
  return Date.parse(String((m && (m.received_at || m.ts)) || ''))
}

/**
 * The open wait in one topic, or null.
 *
 * @param {Array<Record<string, any>>} rows the topic's messages, any order
 * @param {{ now: number, spinMs?: number, showMs?: number, agents?: boolean }} opts
 *   `agents`: an agent is known to be there although no row shows one (a
 *   channel with agent members)
 * @returns {{ msgId: string, taskId: string, state: 'spin' | 'wait', at: number, until: number } | null}
 *   `until`: when the state changes next (spin -> wait, wait -> nothing)
 */
export function awaitState(rows, opts) {
  const now = Number(opts && opts.now)
  const spinMs = Number(opts && opts.spinMs) > 0 ? Number(opts.spinMs) : awaitSpinMs('')
  const showMs = Number(opts && opts.showMs) > 0 ? Number(opts.showMs) : AWAIT_SHOW_MAX_MS
  let lastAgent = -Infinity
  let agentSeen = Boolean(opts && opts.agents)
  let target = null
  let targetAt = -Infinity
  for (const m of rows || []) {
    if (!m || m.topic_row) continue
    if (isAgentPost(m)) {
      agentSeen = true
      const at = receivedAt(m)
      if (at > lastAgent) lastAgent = at
    } else if (isPersonPost(m)) {
      if (isAgentId(m.to)) agentSeen = true
      /* a row held for the network is newer than anything stored and the hub
         has not got it: it hides the mark. A pending row (send just clicked)
         carries its own client time and spins like a received one. */
      const at = m.waiting ? Infinity : receivedAt(m)
      if (at > targetAt) { target = m; targetAt = at }
    }
  }
  if (!target || target.waiting || !(targetAt > lastAgent)) return null
  const age = now - targetAt
  if (!Number.isFinite(age) || age >= showMs) return null
  const spinning = agentSeen && age < spinMs
  return {
    msgId: String(target.msg_id || ''),
    taskId: String(target.task_id || ''),
    state: spinning ? 'spin' : 'wait',
    at: targetAt,
    until: targetAt + (spinning ? spinMs : showMs),
  }
}

/** The soonest `until` of some states (null entries skipped); Infinity when none. */
export function nextAwaitChange(states) {
  let next = Infinity
  for (const s of states || []) if (s && s.until < next) next = s.until
  return next
}
