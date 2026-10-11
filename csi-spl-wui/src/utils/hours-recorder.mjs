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
  /** minute start (ms) -> target */
  const buffer = new Map()
  let lastInput = -Infinity
  let lastFlush = now()
  /** the last minute handed to the hub: never counted again */
  let sentUpTo = -Infinity

  function on() {
    if (env.enabled()) return true
    buffer.clear()
    return false
  }

  function sample() {
    if (!on()) return
    if (env.doc.visibilityState !== 'visible' || !env.doc.hasFocus()) return
    const t = now()
    if (t - lastInput > INPUT_WINDOW_MS) return
    const key = Math.floor(t / MINUTE_MS) * MINUTE_MS
    if (key <= sentUpTo || buffer.has(key)) return
    buffer.set(key, String(env.target() || 'ws'))
    while (buffer.size > BUFFER_MAX) buffer.delete(buffer.keys().next().value)
  }

  async function flush(keepalive = false) {
    lastFlush = now()
    if (!on() || !buffer.size) return
    const rows = [...buffer.entries()].sort((a, b) => a[0] - b[0])
    buffer.clear()
    sentUpTo = Math.max(sentUpTo, rows[rows.length - 1][0])
    const tz = String(env.tz() || 'UTC')
    for (let i = 0; i < rows.length; i += BATCH_MAX) await sendPart(rows.slice(i, i + BATCH_MAX), tz, keepalive)
  }

  async function sendPart(part, tz, keepalive) {
    try {
      await env.send({ tz, minutes: asRows(part) }, { keepalive })
    } catch (e) {
      /* off the network: keep them for the next flush; a refusal (409 frozen, 400) is final */
      if (e && e.status) return
      for (const [at, target] of part) if (!buffer.has(at)) buffer.set(at, target)
    }
  }

  const onInput = () => {
    lastInput = now()
    sample()
  }
  const onVisibility = () => {
    if (env.doc.visibilityState === 'hidden') void flush(true)
    else sample()
  }
  const onPageHide = () => { void flush(true) }
  const tick = () => {
    sample()
    if (now() - lastFlush >= FLUSH_MS) void flush(false)
  }

  const unlisten = listen(env, onInput, onVisibility, onPageHide)
  const timer = setTimer(tick, TICK_MS)

  return {
    sample,
    flush,
    tick,
    /** the buffered minutes, oldest first (tests) */
    pending: () => asRows(buffer.entries()),
    stop() {
      clearTimer(timer)
      unlisten()
      buffer.clear()
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
