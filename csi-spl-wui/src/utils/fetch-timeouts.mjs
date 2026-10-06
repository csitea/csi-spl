/**
 * Timeouts for the WUI's raw fetch() calls (refactor round 3, row 6; the
 * utils' boot, roster, checkout and keys calls: round 4, row 3).
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

/** A boot read: GET /config.json and GET /v1/demo, small JSON the page waits on. */
export const BOOT_READ_TIMEOUT_MS = 10_000

/** GET /v1/view/roster, the avatar files and human names. */
export const ROSTER_READ_TIMEOUT_MS = 15_000

/**
 * A checkout or keys-v1 call. Both clients send their POSTs (a payment, a key
 * registration) through the same call as their GETs, so every call gets the
 * write budget and a slow write is never cut.
 */
export const ACCOUNT_CALL_TIMEOUT_MS = DOC_WRITE_TIMEOUT_MS

/** The timeout for a workspace docs call: a GET (or no method) reads, anything else writes. */
export function docFetchTimeoutMs(method) {
  const m = String(method || 'GET').toUpperCase()
  return m === 'GET' || m === 'HEAD' ? DOC_READ_TIMEOUT_MS : DOC_WRITE_TIMEOUT_MS
}
