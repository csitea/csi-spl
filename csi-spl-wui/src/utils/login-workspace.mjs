// SPL-6413 (owner HUM-10, t1 bedfacca msg 3c421dd7): "the drop down of the
// workspaces MUST NOT BE VISIBLE in the login". The sign-in bar names the one
// workspace being signed into, never the list: the session's memberships fill
// the app shell's drop box only after the sign-in succeeded.
import { validTenant } from './tenant.mjs'

/** The name the sign-in bar shows on the apex (no workspace in the URL). */
export const LOGIN_APEX_LABEL = 'spool-hub'

/** Whether a Nuxt route name (with its `___<locale>` suffix) is the sign-in page. */
export function isLoginRoute(name) {
  return typeof name === 'string' && name.split('___')[0] === 'login'
}

/**
 * The workspace the sign-in bar names: the page host's tenant (a
 * `<t>.<apex>` host), else a valid `?tenant=`, else LOGIN_APEX_LABEL. The
 * apex tenant counts as the apex. Never a session's memberships: nothing
 * before a successful sign-in lists another workspace.
 *
 * @param {unknown} hostTenant the page host's tenant ('' = not a tenant host)
 * @param {unknown} queryTenant the ?tenant= value, or ''
 * @param {unknown} apexTenant the apex tenant (NUXT_PUBLIC_TENANT)
 * @returns {string}
 */
export function loginWorkspaceLabel(hostTenant, queryTenant, apexTenant) {
  const str = (v) => (typeof v === 'string' ? v.trim().toLowerCase() : '')
  const apex = str(apexTenant)
  for (const t of [str(hostTenant), str(queryTenant)]) {
    if (t && t !== apex && validTenant(t)) return t
  }
  return LOGIN_APEX_LABEL
}

/**
 * The browser tab's workspace name on the sign-in page (R7 W1): the bar's
 * label as "<label>.spool-hub", or plain "spool-hub" on the apex. Like the
 * label, never a session's memberships.
 *
 * @param {string} label loginWorkspaceLabel's result
 * @returns {string}
 */
export function loginTabName(label) {
  return !label || label === LOGIN_APEX_LABEL ? LOGIN_APEX_LABEL : `${label}.${LOGIN_APEX_LABEL}`
}
