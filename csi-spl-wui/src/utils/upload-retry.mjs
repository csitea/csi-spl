/**
 * CLE-77795: a file upload (POST /v1/files) must never fail with 401 while the
 * member session is valid.
 *
 * The upload carries a short-lived Bearer "upload token" minted on the live
 * WebSocket and kept in the hub's PER-PROCESS memory (max-instances=1, OQ-05).
 * A hub redeploy — or a Cloud Run instance recycle — starts a new process with
 * an EMPTY token map, while this tab's socket may still sit on the drained
 * revision (it keeps ponging, so the token looks fresh to us). The POST then
 * lands on the live revision, which never minted that token, and is refused
 * 401 'door' before the body is even read. That is why the SAME file uploaded
 * fine on a later manual retry: by then the socket had redialled.
 *
 * The fix mirrors the box client's session probe (redeploy_test.go): on a 401
 * 'door', redial onto the live revision, re-mint the token, and retry ONCE. A
 * second 'door' means the session itself is gone → a "session expired" prompt.
 *
 * SPL-2285: a hub the upload cannot reach (socket down for a few seconds, no
 * connection, no answer) is 'hub_down', which the composer names with a Retry.
 * SPL-5755: a 'hub_down' that comes while the socket redials (the hub closed
 * it under the upload) is retried once, after the redial, before it is shown.
 */

/** The hub's 401 for a bad/missing/expired upload token (rest.go tokenTenant). */
export function isUploadDoor(err) {
  const e = err || {}
  return e.status === 401 && e.token === 'door'
}

/** The rejection a truly-expired session earns; carries a token like the others. */
export function sessionExpiredError() {
  return Object.assign(new Error('session expired'), { status: 401, token: 'session_expired' })
}

/**
 * Upload one File/Blob, transparently refreshing the token and retrying once on
 * a 401 'door'. `api` is the spool client (uploadFile), `live` the live
 * composable (freshUploadToken(force)).
 * @template T
 * @returns {Promise<T>}
 */
export async function uploadWithFreshToken(api, live, file) {
  /* SPL-2285: the retry, the socket wait and 'hub_down' load with the upload, never with `/` (ci_home_gzip_kb) */
  const up = await import('./upload-fail.mjs')
  /* a socket still down after the wait is 'hub_down' at once, never retried */
  await up.linkUp(live)
  try {
    return await up.uploadWithLink(api, live, file)
  } catch (e) {
    if (!hubDownWhileRedialling(e, up.linkDown(live))) throw e
  }
  /* SPL-5755: the hub closed the socket (a roll, 1012 max_life) under the
     upload: wait for the redial and send the same bytes once more */
  return up.uploadWithLink(api, live, file)
}

/** SPL-5755: 'hub_down' while the live socket redials is a drop under the upload, worth one retry. */
export function hubDownWhileRedialling(err, redialling) {
  return Boolean(redialling) && /** @type {{ token?: unknown } | null | undefined} */ (err)?.token === 'hub_down'
}
