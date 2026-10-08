// csi-spl-wui/src/utils/feed-first.mjs
//
// Spec 109 T006 (w1-trace.md section 5, item 2): on a desktop load that lands
// on /lobby, the first render built the whole shell and the feed in one long
// task (145..510 ms on prd, ~350 ms on a mock bundle at CPU 4x), and the first
// message painted only after it. Now the feed's first rows paint first; the
// rest of the shell (ChannelSidebar: the rail and panel 1; the top bar and its
// widgets) mounts in a later task.
//
// layouts/default.vue decides, once per document, whether it holds the shell
// back (`useState('shell-in')` false: a desktop document on /lobby; a phone
// never, its level 1 IS the sidebar) and lets it in after SHELL_CAP_MS whatever
// happens. pages/lobby.vue lets it in earlier: in an idle slot after the frame
// that showed its first rows (whenPainted, below). Only the lobby page imports
// this module, so it rides in the lobby's chunk, not in the shell's.

/** requestIdleCallback's timeout once the rows painted: a busy page still gets its shell. */
export const FEED_FIRST_IDLE_MS = 300

/**
 * Run fn once, after the next frame painted, in an idle slot (timeout idleMs).
 * @param {() => void} fn
 * @param {{ win?: any, idleMs?: number }} [o]
 */
export function whenPainted(fn, o = {}) {
  const win = o.win || globalThis
  const idleMs = o.idleMs ?? FEED_FIRST_IDLE_MS
  const idle = () => {
    if (typeof win.requestIdleCallback === 'function') win.requestIdleCallback(fn, { timeout: idleMs })
    else win.setTimeout(fn, 0)
  }
  if (typeof win.requestAnimationFrame === 'function') win.requestAnimationFrame(() => win.setTimeout(idle, 0))
  else idle()
}
