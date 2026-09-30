/**
 * specs/054: the OPT-IN mock for "act as", used ONLY by the e2e bundle
 * (NUXT_PUBLIC_USE_MOCK=1). It lets the browser test drive the real flow —
 * start → banner → stop — with no hub: `actAsStart` writes this key and `me()`
 * reports `act_as` from it, exactly as the hub's cookie swap would. The key is
 * absent by default, so the other e2e specs (and a normal mock session) see no
 * act-as and this is inert. It is never consulted in a live build.
 */
import { storageGetJson, storageSetJson } from './prefs.mjs'

export const MOCK_ACT_AS_KEY = 'spool.mock.act_as'

// The avatar menu (and its "Act as…" item) shows only for a signed-in session.
// The mock is signed-OUT by default (so the login e2e specs keep working), so
// the act-as e2e opts INTO a signed-in mock session with this key. Absent for
// every other spec — they are untouched. Never consulted in a live build.
export const MOCK_SESSION_KEY = 'spool.mock.session'

/** The opt-in mock session claims ({ hum, name, email, t }), or null. */
export function mockSessionGet(store) {
  return storageGetJson(MOCK_SESSION_KEY, null, store)
}

/** Clear the opt-in mock session (the mock's stand-in for a real sign-out). */
export function mockSessionClear(store) {
  try {
    (store || window.localStorage).removeItem(MOCK_SESSION_KEY)
    return true
  } catch {
    return false
  }
}

/** The stored mock act-as ({ target_hum, expires_at }), or null. */
export function mockActAsGet(store) {
  return storageGetJson(MOCK_ACT_AS_KEY, null, store)
}

/** Record a mock act-as (the mock's stand-in for the hub minting a clone). */
export function mockActAsSet(value, store) {
  return storageSetJson(MOCK_ACT_AS_KEY, value, store)
}

/** Clear the mock act-as (the mock's stand-in for the sign-out). */
export function mockActAsClear(store) {
  try {
    (store || window.localStorage).removeItem(MOCK_ACT_AS_KEY)
    return true
  } catch {
    return false
  }
}
