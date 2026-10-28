/**
 * Spec 107 section 1.2 (T012): the active-tab minute recorder. A minute is
 * counted when the tab is visible AND focused (`document.hasFocus()`) AND the
 * member gave input (key, pointer, touch, wheel, scroll) in the last 60 s; a
 * background tab, a second monitor without focus or a tab left open
 * overnight counts nothing. Each minute keeps the one target open when it
 * was first seen (t:<task>, ch:<name>, dm:<peer>, else ws), in an in-memory
 * buffer that goes to the hub every 5 min, when the tab is hidden and on
 * pagehide (keepalive). Off ("Count my reading time" off): nothing is
 * counted and the buffer is dropped, never sent.
 *
 * A lazy chunk, started by utils/hours-recorder-boot.ts where read-sync
 * starts (027: never in the initial chunk). Pure of Vue and the hub: the
 * boot passes the window, the clock, the target, the switch and the sender,
 * so node tests drive it with a fake clock.
 */

export const MINUTE_MS = 60_000
export const INPUT_WINDOW_MS = 60_000
export const FLUSH_MS = 5 * 60_000
export const TICK_MS = 15_000
/** The hub's PUT /v1/me/hours/minutes takes 1..60 rows per call. */
export const BATCH_MAX = 60
/** One day of minutes; past it the oldest are dropped (a hub out for a day). */
export const BUFFER_MAX = 1440
export const INPUT_EVENTS = Object.freeze(['keydown', 'pointerdown', 'touchstart', 'wheel', 'scroll'])
/** The mock workspace's sink: every batch the mock hub was sent, as a JSON array. */
export const HOURS_MINUTES_MOCK_LOG = 'spl.hours-minutes.mock'

const seg = (s) => {
  try { return decodeURIComponent(s) } catch { return s }
}

/**
 * The open target from the address: a topic (`?topic=` or /t/<id>) wins,
 * then the channel, the DM, the lobby; anything else is the workspace (ws).
 * A locale prefix (/de/channel/x) is skipped.
 * @param {string} path
 * @param {string} [search]
 */
export function hoursTargetOf(path, search = '') {
  const topic = new URLSearchParams(String(search || '')).get('topic')
  if (topic && topic.trim()) return `t:${topic.trim().slice(0, 200)}`
  const parts = String(path || '').split('/').filter(Boolean)
  for (let i = 0; i < parts.length; i++) {
    const next = parts[i + 1] ? seg(parts[i + 1]).slice(0, 200) : ''
    if (parts[i] === 't' && next) return `t:${next}`
    if (parts[i] === 'channel' && next) return `ch:${next}`
    if (parts[i] === 'dm' && next) return `dm:${next}`
    if (parts[i] === 'lobby') return 'ch:lobby'
  }
  return 'ws'
}

/** buffer entries [minute ms, target] -> the hub's rows, oldest first */
const asRows = (entries) => [...entries].sort((a, b) => a[0] - b[0])
  .map(([at, target]) => ({ at: new Date(at).toISOString(), target }))

/** wires input, visibility and pagehide; returns the undo */
function listen(env, onInput, onVisibility, onPageHide) {
  for (const ev of INPUT_EVENTS) env.win.addEventListener(ev, onInput, { capture: true, passive: true })
  env.doc.addEventListener('visibilitychange', onVisibility)
  env.win.addEventListener('pagehide', onPageHide)
  return () => {
    for (const ev of INPUT_EVENTS) env.win.removeEventListener(ev, onInput, { capture: true })
    env.doc.removeEventListener('visibilitychange', onVisibility)
    env.win.removeEventListener('pagehide', onPageHide)
  }
}

/** the recorder's shared state over its env and clock */
function hoursState(env, now) {
  return {
    env,
    now,
    /** minute start (ms) -> target */
    buffer: new Map(),
    lastInput: -Infinity,
    lastFlush: now(),
    /** the last minute handed to the hub: never counted again */
    sentUpTo: -Infinity,
  }
}

/** true when counting is on; off drops the buffer */
function hoursOn(st) {
  if (st.env.enabled()) return true
  st.buffer.clear()
  return false
}

/** counts this minute when the tab is visible, focused and had input in the last 60 s */
function hoursSample(st) {
  if (!hoursOn(st)) return
  if (st.env.doc.visibilityState !== 'visible' || !st.env.doc.hasFocus()) return
  const t = st.now()
  if (t - st.lastInput > INPUT_WINDOW_MS) return
  const key = Math.floor(t / MINUTE_MS) * MINUTE_MS
  if (key <= st.sentUpTo || st.buffer.has(key)) return
  st.buffer.set(key, String(st.env.target() || 'ws'))
  while (st.buffer.size > BUFFER_MAX) st.buffer.delete(st.buffer.keys().next().value)
}

/** sends the buffer to the hub in batches of <= BATCH_MAX, oldest first */
async function hoursFlush(st, keepalive) {
  st.lastFlush = st.now()
  if (!hoursOn(st) || !st.buffer.size) return
  const rows = [...st.buffer.entries()].sort((a, b) => a[0] - b[0])
  st.buffer.clear()
  st.sentUpTo = Math.max(st.sentUpTo, rows[rows.length - 1][0])
  const tz = String(st.env.tz() || 'UTC')
  for (let i = 0; i < rows.length; i += BATCH_MAX) await hoursSendPart(st, rows.slice(i, i + BATCH_MAX), tz, keepalive)
}

/** sends one batch; off the network it goes back to the buffer */
async function hoursSendPart(st, part, tz, keepalive) {
  try {
    await st.env.send({ tz, minutes: asRows(part) }, { keepalive })
  } catch (e) {
    /* off the network: keep them for the next flush; a refusal (409 frozen, 400) is final */
    if (e && e.status) return
    for (const [at, target] of part) if (!st.buffer.has(at)) st.buffer.set(at, target)
  }
}

/** the timer step: sample, and flush once FLUSH_MS has passed */
function hoursTick(st) {
  hoursSample(st)
  if (st.now() - st.lastFlush >= FLUSH_MS) void hoursFlush(st, false)
}

/** hidden flushes at once (keepalive); visible again samples */
function hoursOnVisibility(st) {
  if (st.env.doc.visibilityState === 'hidden') void hoursFlush(st, true)
  else hoursSample(st)
}

/**
 * @param {{
 *   win: { addEventListener: Function, removeEventListener: Function },
 *   doc: { visibilityState: string, hasFocus: () => boolean, addEventListener: Function, removeEventListener: Function },
 *   now?: () => number,
 *   target: () => string,
 *   enabled: () => boolean,
 *   tz: () => string,
 *   send: (body: { tz: string, minutes: { at: string, target: string }[] }, opts: { keepalive: boolean }) => Promise<unknown>,
 *   setTimer?: (fn: () => void, ms: number) => unknown,
 *   clearTimer?: (id: unknown) => void,
 * }} env
 */
export function createHoursRecorder(env) {
  const now = env.now || (() => Date.now())
  const setTimer = env.setTimer || ((fn, ms) => setInterval(fn, ms))
  const clearTimer = env.clearTimer || ((id) => clearInterval(id))
  const st = hoursState(env, now)
  const sample = () => hoursSample(st)
  const flush = (keepalive = false) => hoursFlush(st, keepalive)
  const tick = () => hoursTick(st)
  const onInput = () => {
    st.lastInput = now()
    sample()
  }
  const unlisten = listen(env, onInput, () => hoursOnVisibility(st), () => { void flush(true) })
  const timer = setTimer(tick, TICK_MS)

  return {
    sample,
    flush,
    tick,
    /** the buffered minutes, oldest first (tests) */
    pending: () => asRows(st.buffer.entries()),
    stop() {
      clearTimer(timer)
      unlisten()
      st.buffer.clear()
    },
  }
}

/**
 * The mock workspace's hub: appends the batch to localStorage under
 * HOURS_MINUTES_MOCK_LOG (synchronous, so a pagehide flush lands).
 * @param {{ getItem: (k: string) => string | null, setItem: (k: string, v: string) => void }} storage
 * @param {{ tz: string, minutes: { at: string, target: string }[] }} body
 */
export function mockSendHoursMinutes(storage, body) {
  let log = []
  try {
    const v = JSON.parse(storage.getItem(HOURS_MINUTES_MOCK_LOG) || '[]')
    if (Array.isArray(v)) log = v
  } catch { /* a junk log starts again */ }
  log.push(body)
  storage.setItem(HOURS_MINUTES_MOCK_LOG, JSON.stringify(log))
  return { stored: body.minutes.length }
}
