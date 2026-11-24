/**
 * The part of live-ws.mjs the entry chunk needs (SPL-6342): useLive reads the
 * remembered ?as= id, the socket URL and the upload token's age before the
 * socket code has loaded. live-ws.mjs re-exports all of it, so its callers
 * and tests are unchanged; the socket itself loads through live-ws-lazy.mjs.
 */
import { normalizeId, PARTICIPANT_ID_SRC } from './agent-id.mjs'

/** wui-live-ws §2: hello.as must be a v:1 agent id (e.g. HUM-2, c-004); anything else is omitted and the hub assigns a guest GST-<n> (0.4.1). */
export const AGENT_ID_RE = new RegExp(`^${PARTICIPANT_ID_SRC}$`)

/**
 * @param {unknown} s
 * @returns {string}
 */
export function cleanAs(s) {
  return normalizeId(s)
}

/**
 * true when the upload token is missing or expires within `skewMs`.
 * @param {unknown} expiresAt
 * @param {number} [now]
 * @param {number} [skewMs]
 * @returns {boolean}
 */
export function tokenStale(expiresAt, now = Date.now(), skewMs = 15000) {
  const t = Date.parse(String(expiresAt || ''))
  return !Number.isFinite(t) || t - now <= skewMs
}

export const WS_PATH = '/v1/wui/ws'

/**
 * http(s)://host → ws(s)://host + path
 * @param {string} base
 * @param {string} [path]
 * @returns {string}
 */
export function wsUrl(base, path = WS_PATH) {
  const b = String(base || '').replace(/\/+$/, '')
  if (!/^https?:\/\//.test(b)) throw new Error('ws base must be http(s)')
  return b.replace(/^http/, 'ws') + path
}
