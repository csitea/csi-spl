// csi-spl-wui/src/utils/perf-idle.mjs
//
// When the real-user timing collector may start (spec 066 section 12.4): after
// the page's load event AND in an idle slot of the main thread, so neither the
// collector chunk's fetch, parse and run nor startPerfRum's observers land on
// the first load or on a send / open the user is waiting for.
//
// The plugin (plugins/perf-rum.client.ts) waits here twice: once before the
// dynamic import of perf-rum.mjs, and once more before startPerfRum, because
// the chunk evaluates in a task of its own, not in the idle slot that asked
// for it.
//
// requestIdleCallback carries a timeout so a page that is never idle still
// starts its collector; where the browser has no requestIdleCallback (Safari),
// a setTimeout of PERF_IDLE_FALLBACK_MS stands in. Small and dependency-free:
// it is in the initial chunk with the plugin. Never throws.

/** requestIdleCallback's timeout: start by then even on a busy page. */
export const PERF_IDLE_TIMEOUT_MS = 4_000
/** No requestIdleCallback: start this long after load instead. */
export const PERF_IDLE_FALLBACK_MS = 1_500

/**
 * Run fn once, after the load event and in an idle slot.
 * @param {() => void} fn
 * @param {{ win?: any, timeout?: number, fallbackMs?: number }} [o]
 */
export function perfWhenIdle(fn, o = {}) {
  const win = o.win || globalThis
  const timeout = o.timeout ?? PERF_IDLE_TIMEOUT_MS
  const fallbackMs = o.fallbackMs ?? PERF_IDLE_FALLBACK_MS
  let done = false
  const run = () => {
    if (done) return
    done = true
    try { fn() } catch { /* RUM off for this tab */ }
  }
  const idle = () => {
    try {
      if (typeof win.requestIdleCallback === 'function') win.requestIdleCallback(run, { timeout })
      else win.setTimeout(run, fallbackMs)
    } catch { /* RUM off for this tab */ }
  }
  try {
    const doc = win.document
    if (doc && doc.readyState !== 'complete' && typeof win.addEventListener === 'function') {
      win.addEventListener('load', idle, { once: true })
    } else {
      idle()
    }
  } catch { /* RUM off for this tab */ }
}
