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

// Owner HUM-10 (e3ce4c34): the docs e2e reads a public doc as a settled
// signed-OUT visitor. The mock's default answer is 'unknown' (read as signed
// in), so that spec opts into 'out' with this key (`true`). Never consulted
// in a live build.
export const MOCK_SIGNED_OUT_KEY = 'spool.mock.signed_out'

/** Did the e2e opt into a settled signed-out mock session? */
export function mockSignedOut(store) {
  return storageGetJson(MOCK_SIGNED_OUT_KEY, false, store) === true
}

/**
 * The mock's answer to the session probe (auth-client session()): signed-in
 * only when the act-as spec opts in, 'out' when the docs spec opts in, else
 * 'unknown', exactly as the pre-054 mock answered (its /session probe 404'd),
 * so the other e2e specs are byte-for-byte the same.
 */
export function mockSessionAnswer(store) {
  if (mockSignedOut(store)) return { state: 'out', claims: null }
  const claims = mockSessionGet(store)
  return claims ? { state: 'in', claims } : { state: 'unknown', claims: null }
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

// Spec 073 4.7: the OPT-IN mock role + permission list ({ role, permissions })
// that me() reports, so an e2e plays a biz_owner who lacks agents.join.
// Absent by default: me() stays null = unrestricted. Never read live.
export const MOCK_ME_KEY = 'spool.mock.me'

/** The opt-in mock { role, permissions }, or null. */
export function mockMeGet(store) {
  const v = storageGetJson(MOCK_ME_KEY, null, store)
  return v && Array.isArray(v.permissions) ? { role: String(v.role || ''), permissions: v.permissions.map(String) } : null
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

/**
 * CLE-77819 test hook (mock only): the workspace "Who can archive topics" an
 * e2e opts into with localStorage `spool.mock.archive_policy`; '' = off.
 */
export function mockArchivePolicy() {
  try {
    const v = typeof localStorage !== 'undefined' ? String(localStorage.getItem('spool.mock.archive_policy') || '') : ''
    return ['everyone', 'admins', 'starter'].includes(v) ? v : ''
  } catch { return '' }
}

/**
 * CLE-77891 test hook (mock only), next to the archive policy: the mock
 * member's role ('admin' | 'developer', default developer) an e2e opts into
 * with localStorage `spool.mock.role`. Read only when the policy hook is on.
 */
export function mockRole() {
  try {
    const v = typeof localStorage !== 'undefined' ? String(localStorage.getItem('spool.mock.role') || '') : ''
    return ['admin', 'developer'].includes(v) ? v : 'developer'
  } catch { return 'developer' }
}

/**
 * specs/025 me() in the mock: null = unrestricted, unless an e2e opted into
 * act-as (specs/054), a role + permission list (spec 073 4.7) or an archive
 * policy (CLE-77819). `dir` is the client's directory loader (act-as names
 * the target from it). Kept here, out of spool-client.mjs, so it is lazy.
 */
export async function mockMe(dir) {
  const a = mockActAsGet()
  const meMock = mockMeGet()
  if (meMock && (!a || !a.target_hum)) return meMock
  const policy = mockArchivePolicy()
  if (policy && (!a || !a.target_hum)) return { role: mockRole(), tenant_owner: false, topic_archive_policy: policy }
  if (!a || !a.target_hum) return null
  let name = a.target_hum
  try {
    const m = (await dir()).list().members.find((x) => x.human_id === a.target_hum)
    if (m && m.display_name) name = m.display_name
  } catch { /* keep the id */ }
  return { act_as: { target_hum: a.target_hum, target_name: name, expires_at: a.expires_at || '' } }
}
