// csi-spl-wui/src/composables/debugAudience.mjs
//
// Who may see the diagnostics panel — the whole access decision as pure
// predicates (ported from the donor WUI), so the unit suite EXECUTES
// the gate instead of grepping a re-implementation of it.
//
//   diagnosticsGranted(user)          — THE GATE. Did this human tick
//                                       "Debug pane" in their settings?
//   canSeeDebugPanel(roles, allowed)  — role predicate; decides only what the
//                                       panel calls itself, never who sees it.
//
// Properties this file exists to hold:
//
//   1. The allowed role set is PASSED IN, never hard-coded here.
//   2. It FAILS SHUT. null / undefined / a non-array / an empty array / an
//      unknown role string all return false. "The session probe could not
//      answer" arrives here as null and is therefore NOT granted.
//   3. It is not gateable by anything the visitor controls. No query
//      parameter, no cookie, no localStorage key, no build-time env flag is
//      consulted here or anywhere downstream.
//
// The spool reads the setting from the session claims (GET /api/v1/auth/session,
// spec 010 auth-v1 §3). It is the human's OWN "Debug pane" checkbox in
// Settings → Appearance (components/DebugPaneSetting.vue): the hub
// keeps it per human (rdb 0038 humans.diagnostics_enabled, default false =
// nobody) and answers it on every session read, so it is never part of the
// signed cookie: there is no such field for a browser to assert, and unticking
// hides the panel at once (the store mirrors the checkbox) and for good at the
// next probe rather than 12h later. The checkbox is the SOLE gate — the old
// operator list (SPOOL_HUB_AUTH_DIAGNOSTICS_EMAILS) is retired, because under
// "list OR checkbox" unticking would change nothing for a listed address.

/**
 * Does this role list hold one of the allowed roles?
 *
 * @param {unknown} roles the `roles` array from the session claims, or null
 *   when there is no proven session.
 * @param {readonly string[]} allowed the role set to admit.
 * @returns {boolean}
 */
export function canSeeDebugPanel(roles, allowed) {
  if (!Array.isArray(roles) || roles.length === 0) return false
  if (!Array.isArray(allowed) || allowed.length === 0) return false
  for (const r of roles) {
    if (typeof r !== 'string') continue
    // Exact match only. No case folding, no trimming, no prefix matching: a
    // looser client-side comparison would admit an identity the server would
    // refuse.
    if (allowed.includes(r)) return true
  }
  return false
}

/**
 * Did THIS signed-in human switch the diagnostics panel on ("Debug pane")?
 *
 * Reads `diagnostics_enabled` from the session claims. The human sets it only
 * through the hub (PUT /api/v1/auth/preferences, a signed-in JSON call); it is
 * not settable by a query parameter or a storage key, not derivable from a
 * cookie the WUI can read, and not present in the prerendered bundle.
 *
 * FAILS SHUT, and strictly: only the literal boolean `true` is a grant. A
 * missing key (a hub that does not emit it), `null`, the string "true", `1`,
 * or an absent user all return false. The truthiness of `1` and `"false"` is
 * exactly the coercion that turns "the field was not deployed yet" into
 * "everyone is granted".
 *
 * @param {unknown} user the session claims, or null when there is no proven
 *   session.
 * @returns {boolean}
 */
export function diagnosticsGranted(user) {
  if (!user || typeof user !== 'object') return false
  return user.diagnostics_enabled === true
}

/**
 * The WHOLE gate: the human's own setting, and nothing else. It is NOT
 * `role OR setting`: under OR a role alone would admit, and unticking the box
 * would change nothing.
 *
 * @param {unknown} user the session claims, or null.
 * @returns {boolean}
 */
export function debugPanelVisibleFor(user) {
  return diagnosticsGranted(user)
}
