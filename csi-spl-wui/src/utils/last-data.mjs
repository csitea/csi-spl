/**
 * When the hub last returned data, for the top-bar clock.
 *
 * The shared client and the live socket call noteLastData(). It stores
 * one number (Date.now()) and asks for at most one paint per frame.
 * It does not tick, and it does not write a store.
 */

const PLACEHOLDER = '--:--:--'

let at = 0
let scheduled = false
let epoch = 0
const listeners = new Set()

function pad(n) {
  return String(n).padStart(2, '0')
}

function schedule(fn) {
  if (typeof requestAnimationFrame === 'function') {
    requestAnimationFrame(fn)
    return
  }
  const t = setTimeout(fn, 0)
  if (t && typeof t.unref === 'function') t.unref()
}

function flush(gen) {
  if (gen !== epoch) return
  scheduled = false
  const stamp = at
  for (const fn of listeners) {
    try { fn(stamp) } catch { /* the clock must not break the response that stamped it */ }
  }
}

/** Local HH:mm:ss, zero-padded, 24-hour. No instant yet: `--:--:--`. */
export function formatLastDataClock(ms) {
  if (typeof ms !== 'number' || !Number.isFinite(ms) || ms <= 0) return PLACEHOLDER
  const d = new Date(ms)
  if (Number.isNaN(d.getTime())) return PLACEHOLDER
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}

/** Local `yyyy-mm-dd HH:mm:ss` for the tooltip. '' when there is no instant. */
export function formatLastDataDate(ms) {
  if (typeof ms !== 'number' || !Number.isFinite(ms) || ms <= 0) return ''
  const d = new Date(ms)
  if (Number.isNaN(d.getTime())) return ''
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${formatLastDataClock(ms)}`
}

/** Latest stamp in ms, or 0 before the first successful response. */
export function lastDataAt() {
  return at
}

/**
 * Record that the hub just returned data. One number, no object.
 * Listeners run once per frame with the latest stamp, even when many
 * responses land together.
 */
export function noteLastData(when) {
  const n = when === undefined ? Date.now() : Number(when)
  if (!Number.isFinite(n) || n <= 0) return at
  at = n
  if (!scheduled) {
    scheduled = true
    const gen = epoch
    schedule(() => flush(gen))
  }
  return at
}

/** Subscribe. Returns an unsubscribe. The callback receives the ms stamp. */
export function onLastData(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

/** Tests only: drop the stamp and every listener. */
export function resetLastData() {
  at = 0
  listeners.clear()
  epoch += 1
  scheduled = false
}
