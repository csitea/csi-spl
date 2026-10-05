/**
 * Timeouts for the WUI's raw fetch() reads (refactor round 3, row 6).
 * A hung TCP connection (a phone changing networks, a stalled proxy) never
 * settles a fetch with no signal, so its page sits on 'loading' for good.
 * Each call site passes `signal: AbortSignal.timeout(<one of these>)`; the
 * abort rejects the fetch, and every caller already maps a rejection to its
 * 'failed' (or '') state, so the normal path is unchanged.
 * Node tests import this file.
 */

/** A doc, help page or docs tree read: markdown or a small JSON list. */
export const DOC_READ_TIMEOUT_MS = 15_000

/** A workspace doc PUT / DELETE: longer, so a large save is never cut. */
export const DOC_WRITE_TIMEOUT_MS = 60_000

/** GET /v1/wui/revision, the live socket's build check. */
export const REVISION_FETCH_MS = 10_000

/** The timeout for a workspace docs call: a GET (or no method) reads, anything else writes. */
export function docFetchTimeoutMs(method) {
  const m = String(method || 'GET').toUpperCase()
  return m === 'GET' || m === 'HEAD' ? DOC_READ_TIMEOUT_MS : DOC_WRITE_TIMEOUT_MS
}
