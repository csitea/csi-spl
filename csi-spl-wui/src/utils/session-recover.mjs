/**
 * HUM-10 fb8d109f — a reload into a new build keeps the session.
 *
 * Owner, 2026-10-05: after a deploy the phone app "seems completely
 * broken"; signing out and in again was the only cure. The cookie survives
 * a reload, but the ONE session probe of a page load is often sent while the
 * phone's radio is still waking (the app was just reopened) or while the hub
 * is rolling a new revision. It answers 'unknown' (auth-v1 §4: never
 * treated as signed out), and the shell then reads nothing at all - an empty
 * member view - and nothing ever asked again. Signing out and in only
 * worked because the sign-in sets the state to 'in'.
 *
 * plugins/session-recover.client.ts asks again:
 *   - 'unknown' (or a probe still 'loading'): after RECOVER_DELAYS_MS, then
 *     every RECOVER_EVERY_MS, and at once on `online` or a return to the tab
 *   - 'in' and the tab was away for RESUME_AFTER_MS or more: once, so a
 *     session that ended while the phone was away goes to the sign-in page
 *     with a plain message (?ended=1), never a blank screen
 *
 * WAS_SIGNED_IN_KEY remembers that this browser held a session; only then
 * does a settled 'out' read as "your session ended". A sign-out by hand
 * clears it first, so it never says so.
 */

import { RESUME_AFTER_MS } from './build-watch.mjs'

/** Delays of the first re-probes of an 'unknown' session, then RECOVER_EVERY_MS. */
export const RECOVER_DELAYS_MS = [1_000, 2_000, 4_000, 8_000, 15_000]
export const RECOVER_EVERY_MS = 30_000
/** localStorage: '1' while this browser holds (or last held) a session. */
export const WAS_SIGNED_IN_KEY = 'spool.was-signed-in'
/** The login query flag the signed-out redirect adds for an ended session. */
export const ENDED_QUERY = 'ended'

/**
 * Delay before re-probe number `attempt` (0-based) of an unsettled session.
 * @param {number} attempt
 */
export function recoverDelay(attempt) {
  const n = Math.max(0, Math.floor(Number(attempt) || 0))
  return n < RECOVER_DELAYS_MS.length ? RECOVER_DELAYS_MS[n] : RECOVER_EVERY_MS
}

/** A state the shell cannot read with: the probe failed, or never answered. */
export function unsettled(state) {
  return state === 'unknown' || state === 'loading'
}

/**
 * Probe again now that the tab is visible again (or the network is back)?
 * @param {{ state: string, hiddenMs: number }} s
 */
export function reprobeOnReturn({ state, hiddenMs }) {
  if (unsettled(state)) return true
  return state === 'in' && Number(hiddenMs) >= RESUME_AFTER_MS
}

function store(s) {
  if (s) return s
  try { return globalThis.localStorage || null } catch { return null }
}

/** Remember (true) or forget (false) that this browser holds a session. */
export function markSignedIn(on, s) {
  const st = store(s)
  if (!st) return
  try {
    if (on) st.setItem(WAS_SIGNED_IN_KEY, '1')
    else st.removeItem(WAS_SIGNED_IN_KEY)
  } catch { /* storage blocked */ }
}

/** Did this browser hold a session that it never signed out of by hand? */
export function wasSignedIn(s) {
  const st = store(s)
  if (!st) return false
  try { return st.getItem(WAS_SIGNED_IN_KEY) === '1' } catch { return false }
}
