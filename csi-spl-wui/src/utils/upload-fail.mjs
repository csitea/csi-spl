/**
 * SPL-2285: an upload that cannot reach the hub must SAY SO, quickly.
 *
 * Owner HUM-10 (t1 f1ccedf9, 2026-10-17 17:18Z, prd hub outage 17:08-17:40Z):
 * one picture "10 times", "does not work". The prd request log for his
 * address holds an OPTIONS /v1/files 204 at 17:14:06Z and no POST after it,
 * with ~70 socket reconnects in the minutes before. The upload never landed
 * and nothing on the screen said so, so he tried again and again.
 *
 * What makes that failure visible now:
 *   - the upload waits a few seconds at most for the live socket, the source
 *     of its upload token; still down -> 'hub_down' (upload-retry.mjs);
 *   - the POST has a stall limit (uploadStallMs); past it the request is
 *     aborted -> 'hub_down', never an endless "sending";
 *   - a transport failure (the browser's "Failed to fetch") is 'hub_down', and
 *     a 4xx / 5xx answer is an upload error naming its status and token.
 * The composer shows either with its Retry (send-failure.mjs, TopBar.vue).
 */

/* Out of the initial JS (ci_initial_gzip_kb): the lazy client imports this
   module, and upload-retry.mjs loads it with import() when a file uploads. */

/** The rejection for a hub the upload cannot reach (socket down, no answer). */
export function hubDownError(cause) {
  return Object.assign(new Error('hub unreachable'), { status: 0, token: 'hub_down', cause })
}

/** How long an upload waits for a socket that is (re)connecting (SPL-2285). */
export const UPLOAD_LINK_WAIT_MS = 5000

/** The live socket is dialling or redialling: no upload token can come from it. */
export function linkDown(live) {
  const s = live && live.state ? live.state.value : ''
  return s === 'connecting' || s === 'reconnecting'
}

/**
 * SPL-2285: wait up to `waitMs` for a (re)connecting socket, then throw
 * 'hub_down'. An open socket, the mock and a client with no
 * state pass at once, so a working upload waits for nothing.
 */
export async function linkUp(live, waitMs = UPLOAD_LINK_WAIT_MS, stepMs = 100) {
  if (live && typeof live.ensure === 'function') live.ensure()
  for (let waited = 0; linkDown(live); waited += stepMs) {
    if (waited >= waitMs) throw hubDownError()
    await new Promise((r) => setTimeout(r, stepMs))
  }
}

/** The rejection for a hub that answered the upload with an error status. */
export function uploadHttpError(status, token) {
  return Object.assign(new Error(`spool ${status} ${token || '/v1/files'}`), { status, token, upload: true })
}

/** Base stall limit of one POST /v1/files, before the time its bytes may take. */
export const UPLOAD_STALL_BASE_MS = 15000
/** The slowest link the stall limit allows for: 100 KB/s (1 ms per 100 bytes). */
export const UPLOAD_STALL_BYTES_PER_MS = 100

/** How long one upload of `bytes` may go unanswered: a 916 KB picture, ~24 s. */
export function uploadStallMs(bytes) {
  const n = Number(bytes)
  return UPLOAD_STALL_BASE_MS + Math.ceil((Number.isFinite(n) && n > 0 ? n : 0) / UPLOAD_STALL_BYTES_PER_MS)
}

/**
 * POST through `fetchFn`, aborted after `stallMs`. A transport failure or the
 * stall is 'hub_down'; an answer (any status) goes back to the caller.
 * @param {(url: string, init: object) => Promise<Response>} fetchFn
 * @param {string} url
 * @param {object} init
 * @param {number} stallMs
 * @returns {Promise<Response>}
 */
export async function postWithStall(fetchFn, url, init, stallMs) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), stallMs)
  try {
    return await fetchFn(url, { ...init, signal: ctl.signal })
  } catch (err) {
    throw hubDownError(err)
  } finally {
    clearTimeout(timer)
  }
}

/** e2e hook (mock bundle only): the localStorage key naming how the mock upload fails. */
export const MOCK_UPLOAD_FAIL_KEY = 'spool.mock.upload-fail'

/**
 * The mock bundle's stand-in for the hub's POST /v1/files while the e2e hook
 * is set: 'down' rejects as a refused connection does, '503' answers 503
 * unavailable, 'hang' never answers (only the stall abort ends it). Unset or
 * unknown: null, and the mock uploads as it always has.
 * @param {string | null} mode
 * @returns {((url: string, init: { signal?: AbortSignal }) => Promise<Response>) | null}
 */
export function mockUploadFetch(mode) {
  if (mode === 'down') return () => Promise.reject(new TypeError('Failed to fetch'))
  if (mode === '503') {
    return () => Promise.resolve(new Response(JSON.stringify({ error: 'unavailable' }), { status: 503, headers: { 'content-type': 'application/json' } }))
  }
  if (mode === 'hang') {
    return (_url, init) => new Promise((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')))
    })
  }
  return null
}
