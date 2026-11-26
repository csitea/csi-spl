// csi-spl-wui/src/utils/topic-loops.mjs
//
// Spec 182 row L3 (SPL-6034): the pure half of a topic's Discussion loops
// (HUM-10, t1 f08c0c58, msg 19acb8f9): the trigger keys of section 1.2
// (v0.4; msgs d44af000 and a1d73b19; owner Q11 C, msg 46e61a8c, drops
// "before each human reply"),
// the form's rules (section 4.1 step 2), the request body and the row state
// of the loop JSON (section 7.1.2). TopicLoopsDialog.vue draws them; the
// mock (spool-client-mock.mjs) checks a write with the same rules the hub
// answers 400 bad_loop for. Pure: the Node tests import it. Its types:
// topic-loops.d.ts (the shim file's module count may only fall).
//
// Spec 182 v0.11 (HUM-10, t1 6e8c1cdb, SPL-6580 / SPL-6582): one trigger per
// loop (msg febf1db4, radio buttons; it reverses Q3 B), and that trigger,
// with its parameter, is the loop's title (msgs 543a5bde, 9e3161d9,
// a04bba37). The title is derived, never stored: loopTitle. A loop stored
// before v0.11 with several triggers still reads and fires as it is; its
// form opens on the first, and saving it keeps only the one chosen.

import { isKnownTimeZone } from './date-iso.mjs'

/**
 * Every key a stored loop may carry, in store TopicLoopTriggers order:
 * post_has_file (v0.4) is no longer offered (v0.11 change 9, msg d8e02722,
 * split by poster), but a loop stored with it still reads, fires and keeps
 * its label.
 */
const LOOP_KEYS = Object.freeze([
  'after_agent_reply',
  'before_agent_reply',
  'after_human_reply',
  'every_hour',
  'every_n_minutes',
  'post_has_keyword',
  'post_has_file',
  'post_has_file_agent',
  'post_has_file_human',
  'blocker_posted',
  'no_reply_after_human',
  'issue_status_changed',
  'daily_at',
])
/** Section 1.2, the twelve the form offers, in the order it lists them. */
export const LOOP_TRIGGERS = Object.freeze(LOOP_KEYS.filter((k) => k !== 'post_has_file'))
export const LOOP_EVERY_N = 'every_n_minutes'
export const LOOP_KEYWORD = 'post_has_keyword'
export const LOOP_IDLE = 'no_reply_after_human'
export const LOOP_DAILY = 'daily_at'
/* n of each n minutes and of no reply for n minutes */
export const LOOP_INTERVAL_MIN = 5
export const LOOP_INTERVAL_MAX = 1440
export const LOOP_PROMPT_MAX = 4000
export const LOOP_KEYWORD_MAX = 200
const HHMM = /^([01]\d|2[0-3]):[0-5]\d$/

const KEY = 'feed.topic_loops.'

/**
 * The form as the dialog holds it: `interval` is the n of "each n minutes",
 * `idle` the n of "no reply for n minutes", `dailyAt` / `dailyTz` the time
 * and zone of "every day at"; `tz` is the zone a new loop starts with (the
 * browser's, 4.1 step 2).
 */
export function emptyLoopForm(tz = 'UTC') {
  return { prompt: '', trigger: '', others: [], interval: 30, keyword: '', idle: 30, dailyAt: '09:00', dailyTz: String(tz || 'UTC') }
}

/**
 * A loop JSON (7.1.2) back into the form, for Edit: `trigger` is its one
 * trigger; `others` the rest of a loop stored before v0.11 with several,
 * which the form names and a save drops.
 */
export function loopForm(loop, tz = 'UTC') {
  const l = loop && typeof loop === 'object' ? loop : {}
  const minutes = (v) => (Number.isInteger(Number(v)) && Number(v) > 0 ? Number(v) : 30)
  const [trigger = '', ...others] = knownTriggers(l.triggers)
  return {
    prompt: String(l.prompt || ''),
    trigger,
    others,
    interval: minutes(l.interval_min),
    keyword: String(l.keyword || ''),
    idle: minutes(l.idle_min),
    dailyAt: String(l.daily_at || '09:00'),
    dailyTz: String(l.daily_tz || tz || 'UTC'),
  }
}

/** The known keys of `list` (offered or not), distinct, in LOOP_KEYS order. */
function knownTriggers(list) {
  const on = new Set(Array.isArray(list) ? list.map(String) : [])
  return LOOP_KEYS.filter((k) => on.has(k))
}

function minutesOk(v) {
  const n = Number(v)
  return Number.isInteger(n) && n >= LOOP_INTERVAL_MIN && n <= LOOP_INTERVAL_MAX
}

/** An IANA zone this browser knows, at most 64 characters (the hub checks it again with time.LoadLocation). */
function knownTimeZone(tz) {
  const z = String(tz || '')
  return z.length <= 64 && isKnownTimeZone(z)
}

/** The broken rule of the trigger's own field (v0.4), '' when it holds. */
function fieldError(f, k) {
  if (k === LOOP_EVERY_N && !minutesOk(f.interval)) return KEY + 'err_interval'
  const kw = String(f.keyword ?? '').trim()
  if (k === LOOP_KEYWORD && (!kw || kw.length > LOOP_KEYWORD_MAX)) return KEY + 'err_keyword'
  if (k === LOOP_IDLE && !minutesOk(f.idle)) return KEY + 'err_interval'
  if (k === LOOP_DAILY && !HHMM.test(String(f.dailyAt ?? ''))) return KEY + 'err_daily_at'
  if (k === LOOP_DAILY && !knownTimeZone(f.dailyTz)) return KEY + 'err_daily_tz'
  return ''
}

/**
 * The form's first broken rule as an i18n key, '' when it may be saved:
 * a prompt of 1..4000 characters, EXACTLY ONE known trigger (v0.11, msg
 * febf1db4), and that trigger's field when it has one: n of 5..1440 (each
 * n minutes, no reply for n minutes), a keyword of 1..200 characters, a
 * time hh:mm and a known zone (every day at).
 *
 * @param {{ prompt?: unknown, trigger?: unknown, interval?: unknown, keyword?: unknown, idle?: unknown, dailyAt?: unknown, dailyTz?: unknown }} form
 */
export function loopFormError(form) {
  const f = form && typeof form === 'object' ? form : {}
  const prompt = String(f.prompt ?? '').trim()
  if (!prompt) return KEY + 'err_prompt'
  if (prompt.length > LOOP_PROMPT_MAX) return KEY + 'err_prompt_long'
  const k = String(f.trigger ?? '')
  if (!LOOP_TRIGGERS.includes(k)) return KEY + 'err_trigger'
  return fieldError(f, k)
}

/** POST / PUT body of 7.1.2: the one trigger, and its field when it has one. */
export function loopBody(form) {
  const f = form && typeof form === 'object' ? form : {}
  const triggers = knownTriggers([f.trigger])
  const body = { prompt: String(f.prompt ?? '').trim(), triggers }
  if (triggers.includes(LOOP_EVERY_N)) body.interval_min = Number(f.interval)
  if (triggers.includes(LOOP_KEYWORD)) body.keyword = String(f.keyword ?? '').trim()
  if (triggers.includes(LOOP_IDLE)) body.idle_min = Number(f.idle)
  if (triggers.includes(LOOP_DAILY)) {
    body.daily_at = String(f.dailyAt ?? '')
    body.daily_tz = String(f.dailyTz || 'UTC')
  }
  return body
}

/** The form as the loop JSON its save would store, for loopTitle: the title follows each pick. */
export function formLoop(form) {
  const f = form && typeof form === 'object' ? form : {}
  return { triggers: knownTriggers([f.trigger]), interval_min: f.interval, keyword: String(f.keyword ?? '').trim(), idle_min: f.idle, daily_at: f.dailyAt, daily_tz: f.dailyTz }
}

/**
 * The form's kept extra triggers (a loop stored with several, v0.11) as loop
 * JSON for loopTitle, WITH the form's fields, so a kept "every n minutes"
 * names its n (R7 a-099 N1: without them the note read "Every  minutes").
 */
export function formOthersLoop(form) {
  const f = form && typeof form === 'object' ? form : {}
  return { ...formLoop(f), triggers: knownTriggers(f.others) }
}

/**
 * One loop's checked boxes as [i18n key, params] pairs for the list row, in
 * the form's order; a box with a field names its value.
 *
 * @param {unknown} loop
 * @returns {[string, Record<string, unknown>][]}
 */
export function loopTriggerLabels(loop) {
  const l = loop && typeof loop === 'object' ? /** @type {Record<string, unknown>} */ (loop) : {}
  return knownTriggers(l.triggers).map((k) => {
    if (k === LOOP_EVERY_N) return [KEY + 'every_n', { n: l.interval_min ?? '' }]
    if (k === LOOP_KEYWORD) return [KEY + 'keyword_row', { keyword: l.keyword ?? '' }]
    if (k === LOOP_IDLE) return [KEY + 'idle_row', { n: l.idle_min ?? '' }]
    if (k === LOOP_DAILY) return [KEY + 'daily_row', { time: l.daily_at ?? '', tz: l.daily_tz || 'UTC' }]
    return [KEY + 'trigger.' + k, {}]
  })
}

/**
 * The loop's title (v0.11, change 1): its trigger's label with its
 * parameter, first letter upper case ("Every 30 minutes", "Before each
 * agent reply"); a loop stored with several triggers names them all, comma
 * separated; '' with none. `t` is vue-i18n's; `locale` cases the first
 * letter (Turkish i). The hub's fire line carries the same English title
 * (hub/topic_loop_title.go, its parity test reads en.json).
 *
 * @param {unknown} loop
 * @param {(key: string, params?: Record<string, unknown>) => string} t
 * @param {string} [locale]
 */
export function loopTitle(loop, t, locale) {
  return loopTriggerLabels(loop).map(([key, params], i) => {
    const label = String(t(key, params))
    return i === 0 ? upperFirst(label, locale) : label
  }).join(', ')
}

function upperFirst(s, locale) {
  const first = [...s][0] || ''
  let up
  try {
    up = first.toLocaleUpperCase(locale || undefined)
  } catch {
    up = first.toUpperCase()
  }
  return up + s.slice(first.length)
}

/** The prompt's first non-empty line, for the list row. */
export function loopFirstLine(prompt) {
  return String(prompt || '').split('\n').map((s) => s.trim()).find(Boolean) || ''
}

/**
 * The row's state (4.1 step 2, 4.5): 'paused', 'idle' (an `on` loop that
 * would not fire; `why` is its i18n key), 'held' by the cap (`until` is
 * held_until) or 'on'.
 *
 * @param {unknown} loop
 * @returns {{ state: 'on' | 'paused' | 'held' | 'idle', until: string, why: string }}
 */
export function loopRowState(loop) {
  const l = loop && typeof loop === 'object' ? /** @type {Record<string, unknown>} */ (loop) : {}
  if (l.state === 'paused') return { state: 'paused', until: '', why: '' }
  if (l.idle === 'author_left' || l.idle === 'author_no_right') return { state: 'idle', until: '', why: KEY + 'idle_' + l.idle }
  if (l.held_until) return { state: 'held', until: String(l.held_until), why: '' }
  return { state: 'on', until: '', why: '' }
}

/** Every route's refusal of 7.1.2 as the i18n key the dialog shows. */
const ERR = {
  bad_loop: 'err_bad_loop',
  not_allowed: 'err_not_allowed',
  demo_read_only: 'err_demo',
  not_found: 'err_not_found',
  topic_archived: 'err_archived',
  not_implemented: 'err_not_implemented',
}

/** @param {unknown} e a thrown client error ({ status, token }) */
export function loopErrorKey(e) {
  const err = e && typeof e === 'object' ? /** @type {Record<string, unknown>} */ (e) : {}
  const token = String(err.token || '')
  if (ERR[token]) return KEY + ERR[token]
  if (err.status === 501) return KEY + ERR.not_implemented
  return KEY + 'err_failed'
}

/** A `topic_loops` frame (7.1.2) for `taskId`: its loops, else null. */
export function loopsFromFrame(frame, taskId) {
  const f = frame && typeof frame === 'object' ? /** @type {Record<string, unknown>} */ (frame) : {}
  if (f.type !== 'topic_loops' || !taskId || String(f.task_id || '') !== String(taskId)) return null
  return Array.isArray(f.loops) ? f.loops : []
}
