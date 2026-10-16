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
// animation id names an entry of AWAIT_ANIMATIONS, and components/AwaitReply.vue
// renders whichever is showing. SPL-2113: each is a CSS/SVG drawing in code
// (no image or video file), its own lazy component.
//
// SPL-2027 (owner HUM-10, t1 72898ea2 msgs c4aae6fc, 1689b768, f7779032):
// more of them - a small robot running, a brain that swells and pops from too
// much thinking - and a per-person pick (Settings -> Appearance). Every one draws 20% bigger
// than the first hourglass, inside the same box.
//
// SPL-2043 (owner HUM-10, t1 72898ea2 msgs c48092cf, 19feedf8): "3 seconds
// for one, then 3 seconds for the other, and then 3 seconds for the robot ...
// They should change all of the time." The mark cycles its drawings,
// AWAIT_ROTATE_STEP_MS each, off the wall clock, so every waiting post on
// screen shows the same drawing.
//
// SPL-2113 (owner HUM-10, t1 3aa9fac2 msgs d45ec26e, c33a028e, 1ea9f107):
// at least 15 drawings, a dancing robot among them; the person ticks any of
// them in a vertical checkbox list (Settings -> Appearance), at least one;
// the ticked ones take turns. No cap: one plays at a time, each drawing is
// loaded only when it shows. Kept in the person's account (the hub's
// per-workspace `await_anims`), the old browser pick migrated once.

import { isAgentId } from './agent-id.mjs'
import { storageGet } from './prefs.mjs'

/** The still drawing: reduced motion, a `wait` mark, a drawing not loaded yet. */
export const STILL_AWAIT_ANIM = 'hourglass'
/** How long each ticked drawing shows before the next takes its turn. */
export const AWAIT_ROTATE_STEP_MS = 3000

/**
 * id -> how it is drawn: every entry is a CSS/SVG drawing in code, its class
 * on the mark (`await-anim--<id>`). The hourglass is drawn by AwaitReply.vue
 * itself (the still mark must show at once); every other drawing is its own
 * small component under components/await-anim/, loaded only when it shows.
 * SPL-2113 (owner HUM-10, t1 3aa9fac2 msgs d45ec26e, c33a028e): at least 15,
 * a dancing robot among them.
 */
export const AWAIT_ANIMATIONS = Object.freeze({
  hourglass: Object.freeze({ kind: 'css', className: 'await-anim--hourglass' }),
  robot: Object.freeze({ kind: 'css', className: 'await-anim--robot' }),
  brain: Object.freeze({ kind: 'css', className: 'await-anim--brain' }),
  'dancing-robot': Object.freeze({ kind: 'css', className: 'await-anim--dancing-robot' }),
  dots: Object.freeze({ kind: 'css', className: 'await-anim--dots' }),
  spinner: Object.freeze({ kind: 'css', className: 'await-anim--spinner' }),
  radar: Object.freeze({ kind: 'css', className: 'await-anim--radar' }),
  gears: Object.freeze({ kind: 'css', className: 'await-anim--gears' }),
  bulb: Object.freeze({ kind: 'css', className: 'await-anim--bulb' }),
  coffee: Object.freeze({ kind: 'css', className: 'await-anim--coffee' }),
  orbit: Object.freeze({ kind: 'css', className: 'await-anim--orbit' }),
  pendulum: Object.freeze({ kind: 'css', className: 'await-anim--pendulum' }),
  bars: Object.freeze({ kind: 'css', className: 'await-anim--bars' }),
  pencil: Object.freeze({ kind: 'css', className: 'await-anim--pencil' }),
  rocket: Object.freeze({ kind: 'css', className: 'await-anim--rocket' }),
  clock: Object.freeze({ kind: 'css', className: 'await-anim--clock' }),
  wave: Object.freeze({ kind: 'css', className: 'await-anim--wave' }),
})

/**
 * Every drawing, in the order the setting lists them and the ticked ones
 * take turns. A literal, not Object.keys(AWAIT_ANIMATIONS): that top-level
 * call reads as a side effect, so Nuxt's auto-import barrel kept this whole
 * module in the entry chunk (ci_initial_gzip_kb 154.6 -> 155.3 KB, over 155).
 * A unit test keeps the two in step.
 */
export const AWAIT_ANIM_IDS = Object.freeze(['hourglass', 'robot', 'brain', 'dancing-robot', 'dots', 'spinner', 'radar', 'gears', 'bulb', 'coffee', 'orbit', 'pendulum', 'bars', 'pencil', 'rocket', 'clock', 'wave'])
/** The ticked set nobody picked: the first three drawings (SPL-2043's rotation). */
export const DEFAULT_AWAIT_SET = Object.freeze(['hourglass', 'robot', 'brain'])

/** The entry for animation `id`; the hourglass for an unknown or empty id. */
export function awaitAnimation(id) {
  const key = String(id || '')
  const known = Object.prototype.hasOwnProperty.call(AWAIT_ANIMATIONS, key)
  const pick = known ? key : STILL_AWAIT_ANIM
  return { id: pick, ...AWAIT_ANIMATIONS[pick] }
}

/**
 * A valid ticked set from what the hub (the `await_anims` claim) holds: the
 * known ids, once each, in catalogue order; none known (or never picked) =
 * DEFAULT_AWAIT_SET. An id a newer WUI wrote and this one lacks is skipped.
 */
export function awaitAnimSet(list) {
  const want = new Set(Array.isArray(list) ? list.map(String) : [])
  const set = AWAIT_ANIM_IDS.filter((id) => want.has(id))
  return set.length ? set : [...DEFAULT_AWAIT_SET]
}

/**
 * `set` with `id` ticked (`on`) or unticked, in catalogue order. Unticking
 * the last one, or an unknown id, changes nothing: the same array comes back,
 * so a caller can tell (at least one stays ticked).
 */
export function toggleAwaitAnim(set, id, on) {
  const cur = awaitAnimSet(set)
  const key = String(id || '')
  if (!AWAIT_ANIM_IDS.includes(key) || cur.includes(key) === Boolean(on)) return set
  const next = on ? awaitAnimSet([...cur, key]) : cur.filter((x) => x !== key)
  return next.length ? next : set
}

/** The rotation step at wall-clock `now` (ms): one per AWAIT_ROTATE_STEP_MS; 0 when it does not parse. */
export function rotateStepAt(now) {
  const n = Math.floor(Number(now) / AWAIT_ROTATE_STEP_MS)
  return Number.isFinite(n) ? n : 0
}

/** The drawing of ticked set `set` at rotation step `step`: the set in turn, from the first. */
export function awaitSetAt(set, step) {
  const ids = awaitAnimSet(set)
  const n = Number.isFinite(Number(step)) ? Math.trunc(Number(step)) : 0
  return ids[((n % ids.length) + ids.length) % ids.length]
}

/** The drawing `set` shows at wall-clock `now` (ms). */
export function rotateAnimAt(now, set = DEFAULT_AWAIT_SET) {
  return awaitSetAt(set, rotateStepAt(now))
}

/** ms from `now` to the next rotate step (1..AWAIT_ROTATE_STEP_MS). */
export function msToNextRotate(now) {
  const into = ((Number(now) % AWAIT_ROTATE_STEP_MS) + AWAIT_ROTATE_STEP_MS) % AWAIT_ROTATE_STEP_MS
  return Number.isFinite(into) ? AWAIT_ROTATE_STEP_MS - into : AWAIT_ROTATE_STEP_MS
}

/**
 * ONE clock for every rotating mark: a single timer while anyone listens,
 * none once the last one leaves (no per-row timers that drift or leak).
 * `subscribe(fn)` calls fn(step) now and on every step (the wall-clock step
 * number; each mark maps it onto the person's ticked set, so every mark on
 * screen shows the same drawing); it returns the unsubscribe.
 * `now`/`setTimer`/`clearTimer` are seams for a fake clock.
 */
export function createRotateClock({ now = () => Date.now(), setTimer = (fn, ms) => setTimeout(fn, ms), clearTimer = (h) => clearTimeout(h) } = {}) {
  const fns = new Set()
  let timer = null
  const tick = () => {
    const t = now()
    const step = rotateStepAt(t)
    for (const fn of fns) fn(step)
    timer = setTimer(tick, msToNextRotate(t))
  }
  return {
    subscribe(fn) {
      fns.add(fn)
      if (timer === null) tick()
      else fn(rotateStepAt(now()))
      return () => {
        if (!fns.delete(fn) || fns.size || timer === null) return
        clearTimer(timer)
        timer = null
      }
    },
    get listeners() { return fns.size },
    get running() { return timer !== null },
  }
}

/**
 * SPL-2027/2043 kept the pick in this browser, per person and tenant, under
 * these keys; SPL-2113 keeps it in the account. The old key is read once to
 * migrate it (planAwaitMigration) and then removed.
 */
export const AWAIT_ANIM_KEY = 'spool-await-anim'
/** The old per-person key (tenant and person), the browser-wide one signed out. */
export function awaitAnimKey(claims) {
  const hum = String((claims && claims.hum) || '')
  if (!hum) return AWAIT_ANIM_KEY
  const tenant = String((claims && claims.t) || '')
  return `${AWAIT_ANIM_KEY}:${tenant ? tenant + ':' : ''}${hum}`
}

/** An old single pick as a ticked set: `rotate` = the default three, one drawing = that one; anything else null. */
export function legacyAwaitSet(pick) {
  const key = String(pick || '')
  if (key === 'rotate') return [...DEFAULT_AWAIT_SET]
  return ['hourglass', 'robot', 'brain'].includes(key) ? [key] : null
}

/**
 * What to migrate for a signed-in person whose account holds no pick yet:
 * `{ key, set }` (`set` null = an unusable old value, only drop the key), or
 * null (nothing stored in this browser, the account already has a pick, or
 * signed out).
 */
export function planAwaitMigration(claims, store) {
  if (!claims || !claims.hum || Array.isArray(claims.await_anims)) return null
  const key = awaitAnimKey(claims)
  const old = storageGet(key, null, store)
  return old === null ? null : { key, set: legacyAwaitSet(old) }
}

/** Remove the old key once the account holds the pick; never throws. */
export function dropLegacyAwaitAnim(key, store) {
  try {
    const s = store || globalThis.localStorage
    if (s) s.removeItem(key)
    return true
  } catch {
    return false
  }
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
