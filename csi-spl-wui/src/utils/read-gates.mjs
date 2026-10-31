// csi-spl-wui/src/utils/read-gates.mjs
//
// SPL-4453 (rows 5 and 9 of the F12 console report SPL-4422; owner HUM-10,
// t1 1b1d7403, msg 0f86a237): decide from GET /v1/view/me whether a read that
// only an operator admin or the workspace's staff may make is worth sending.
// A member then gets the page's no-access line and the console no 403. An
// unknown reader (no answer, or a door-off guest with no permission list)
// still reads: the hub's 403 stays the control, as utils/access.mjs fails open.

import { accessAllows } from './access.mjs'
import { monitoringStaff } from './monitoring-tabs.mjs'

/** me as utils/access.mjs normalizeMe returns it (operatorAdmin once the hub sends operator_admin, SPL-4451). */
/** @typedef {{ role?: string | null, roles?: string[], tenantOwner?: boolean, permissions?: string[] | null, operatorAdmin?: boolean | null } | null | undefined} GateMe */

/** @param {GateMe} me */
function meKnown(me) {
  return Boolean(me) && Array.isArray(me?.permissions)
}

/**
 * The operator routes (GET /v1/operator/fleet-tokens, /v1/operator/fleet-lanes):
 * the hub's operatorActor admits a member whose primary role is admin in the
 * operator workspace. Any other known role never passes; `operatorAdmin`
 * false (the hub's own answer, SPL-4451) does not either.
 * @param {GateMe} me
 */
export function operatorReadable(me) {
  if (!meKnown(me)) return true
  return me?.role === 'admin' && me?.operatorAdmin !== false
}

/**
 * The staff routes (GET /v1/view/lanes, /v1/view/file-streams,
 * /v1/reporting/marketing): the hub's TenantOwner || Has(rbac.Admin). The
 * biz_owner role is the tenant owner (hub rbac.go, BizOwner TenantOwner: true).
 * @param {GateMe} me
 */
export function staffReadable(me) {
  if (!meKnown(me)) return true
  const roles = Array.isArray(me?.roles) ? me.roles : []
  return monitoringStaff(me) || me?.role === 'biz_owner' || roles.includes('biz_owner')
}

/**
 * A route the hub gates on one permission (GET /v1/tenant/box-stats: audit.read).
 * @param {GateMe} me
 * @param {string} perm
 */
export function permReadable(me, perm) {
  return accessAllows(me, perm)
}

/**
 * Which lanes read to send (Monitoring -> Lanes, an agent's card): 'fleet'
 * (the operator route, falling back to the own lanes on its 403), 'own'
 * (GET /v1/view/lanes straight away) or 'none' (no request: the no-access line).
 * @param {GateMe} me
 * @returns {'fleet' | 'own' | 'none'}
 */
export function lanesReadPlan(me) {
  if (operatorReadable(me)) return 'fleet'
  return staffReadable(me) ? 'own' : 'none'
}

/**
 * The reader's /v1/view/me, loaded once if the access store has none yet
 * (stores/access.ts); null when it did not answer (the gates then fail open).
 * @param {{ me: GateMe, load: () => Promise<void> }} access
 * @returns {Promise<GateMe>}
 */
export async function gateMe(access) {
  if (!access.me) await access.load()
  return access.me
}

/**
 * One gated read, counted for the e2e: in a mock build (api.mock) a 403 the
 * mock hub answers is recorded as 'GET <path>' in globalThis.SPOOL_MOCK_403
 * (the list SPL-4452's settings e2e counts too), then rethrown. A live build
 * records nothing.
 * @template T
 * @param {{ mock?: boolean } | null | undefined} api
 * @param {string | (() => string)} path a function when the read picks its route as it goes (readLanes)
 * @param {() => Promise<T>} read
 * @returns {Promise<T>}
 */
export async function countedRead(api, path, read) {
  try {
    return await read()
  } catch (e) {
    if (api?.mock && /** @type {{ status?: number }} */ (e)?.status === 403) {
      const g = /** @type {{ SPOOL_MOCK_403?: string[] }} */ (globalThis)
      g.SPOOL_MOCK_403 = [...(g.SPOOL_MOCK_403 || []), 'GET ' + (typeof path === 'function' ? path() : path)]
    }
    throw e
  }
}
