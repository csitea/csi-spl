/**
 * Fleet load target (rdb 0118, GET/PATCH /v1/operator/fleet-load).
 * The hub keeps it on the operator workspace. A 403 names permission
 * operator.workspaces for everyone else. NULL on a field is the default.
 * Node tests import this file; the settings card does too.
 */

export const FLEET_OPERATOR_KEY = 'spool.mock.fleet_operator'
export const FLEET_STORE_KEY = 'spool.mock.fleet_load'
export const FLEET_BOX_MAX = 32
export const FLEET_BOX_RE = /^[a-z0-9][a-z0-9-]{0,31}$/
export const FLEET_DEFAULT_LOW = 50
export const FLEET_DEFAULT_HIGH = 75
/** The hub's 400 bad_setting detail (internal/hub/fleet_load.go). */
export const FLEET_BAD_SETTING = 'low is 1..99 and high 2..100 (% of cores) with low < high; box_order is distinct box ids ([a-z0-9-], up to 32 each), at most 32'

export function validFleetBox(id) {
  return FLEET_BOX_RE.test(String(id || ''))
}

/** True when this caller is not an admin of the operator workspace. */
export function fleetLoadForbidden(err) {
  return Boolean(err) && Number(err.status) === 403 && err.permission === 'operator.workspaces'
}

/** The hub's own sentence for a 400 bad_setting; '' for every other failure. */
export function fleetLoadStatusDetail(err) {
  if (!err || err.token !== 'bad_setting') return ''
  return typeof err.detail === 'string' ? err.detail : ''
}

function intOrNull(v) {
  if (v == null || v === '') return null
  const n = Number(v)
  return Number.isInteger(n) ? n : null
}

function boxList(v) {
  if (!Array.isArray(v)) return []
  return v.map((x) => String(x))
}

/** GET body → the card's view. Junk becomes the defaults. */
export function normalizeFleetLoad(body) {
  const b = body && typeof body === 'object' ? body : {}
  const d = b.defaults && typeof b.defaults === 'object' ? b.defaults : {}
  const defaults = {
    low: intOrNull(d.low) ?? FLEET_DEFAULT_LOW,
    high: intOrNull(d.high) ?? FLEET_DEFAULT_HIGH,
    boxOrder: Array.isArray(d.box_order) ? boxList(d.box_order) : [],
  }
  const s = b.stored && typeof b.stored === 'object' ? b.stored : {}
  const stored = {
    low: s.low == null ? null : intOrNull(s.low),
    high: s.high == null ? null : intOrNull(s.high),
    boxOrder: s.box_order == null ? null : boxList(s.box_order),
  }
  const boxOrder = Array.isArray(b.box_order)
    ? boxList(b.box_order)
    : (stored.boxOrder ? stored.boxOrder.slice() : defaults.boxOrder.slice())
  return {
    low: intOrNull(b.low) ?? (stored.low ?? defaults.low),
    high: intOrNull(b.high) ?? (stored.high ?? defaults.high),
    boxOrder,
    source: typeof b.source === 'string' ? b.source : '',
    stored,
    defaults,
  }
}

/**
 * PATCH body. A reset flag sends null (the hub's "back to default").
 * An unchanged field is left out. `saved` is normalizeFleetLoad().
 */
export function fleetLoadPatchBody(saved, draft) {
  const body = {}
  if (!saved || !draft) return body
  if (draft.resetLow) body.low = null
  else if (Number(draft.low) !== saved.low) body.low = Number(draft.low)
  if (draft.resetHigh) body.high = null
  else if (Number(draft.high) !== saved.high) body.high = Number(draft.high)
  const order = Array.isArray(draft.boxOrder) ? draft.boxOrder : []
  if (draft.resetOrder) body.box_order = null
  else if (order.join('\n') !== (saved.boxOrder || []).join('\n')) body.box_order = order.slice()
  return body
}

/** Box ids to offer, from GET /v1/tenant/box-stats rows (then hours). */
export function suggestFleetBoxes(stats) {
  const rows = stats && Array.isArray(stats.rows) ? stats.rows : []
  const hours = stats && Array.isArray(stats.hours) ? stats.hours : []
  const out = []
  for (const r of rows.concat(hours)) {
    const id = String((r && r.box) || '').trim()
    if (!validFleetBox(id) || out.includes(id)) continue
    out.push(id)
    if (out.length >= FLEET_BOX_MAX) break
  }
  return out
}

function fleetError(status, token, detail, permission) {
  const err = new Error(detail || token)
  err.status = status
  err.token = token
  err.detail = detail || ''
  if (permission) err.permission = permission
  return err
}

function forbidden() {
  return fleetError(403, 'forbidden', 'only an admin of the operator workspace manages workspaces', 'operator.workspaces')
}

/** The hub's CheckFleetLoad, on the stored row (null = unset). */
export function fleetStoredOk(stored) {
  if (!stored) return false
  const low = stored.low
  const high = stored.high
  if (low != null && (!Number.isInteger(low) || low < 1 || low > 99)) return false
  if (high != null && (!Number.isInteger(high) || high < 2 || high > 100)) return false
  const eLow = low == null ? FLEET_DEFAULT_LOW : low
  const eHigh = high == null ? FLEET_DEFAULT_HIGH : high
  if (eLow >= eHigh) return false
  const order = stored.boxOrder
  if (order == null) return true
  if (!Array.isArray(order) || order.length > FLEET_BOX_MAX) return false
  const seen = new Set()
  for (const b of order) {
    if (!validFleetBox(b) || seen.has(b)) return false
    seen.add(b)
  }
  return true
}

/**
 * Apply one PATCH to a stored row. null = the hub refused it (bad_setting).
 * An empty box_order is stored as unset, matching store.FleetLoadStored.apply.
 */
export function applyFleetPatch(stored, patch) {
  const next = {
    low: stored && stored.low != null ? stored.low : null,
    high: stored && stored.high != null ? stored.high : null,
    boxOrder: stored && Array.isArray(stored.boxOrder) ? stored.boxOrder.slice() : null,
  }
  const p = patch && typeof patch === 'object' ? patch : {}
  if (Object.prototype.hasOwnProperty.call(p, 'low')) {
    if (p.low === null) next.low = null
    else if (typeof p.low === 'number' && Number.isInteger(p.low)) next.low = p.low
    else return null
  }
  if (Object.prototype.hasOwnProperty.call(p, 'high')) {
    if (p.high === null) next.high = null
    else if (typeof p.high === 'number' && Number.isInteger(p.high)) next.high = p.high
    else return null
  }
  if (Object.prototype.hasOwnProperty.call(p, 'box_order')) {
    if (p.box_order === null) next.boxOrder = null
    else if (Array.isArray(p.box_order)) {
      const ids = p.box_order.map((x) => String(x))
      next.boxOrder = ids.length === 0 ? null : ids
    } else return null
  }
  return fleetStoredOk(next) ? next : null
}

function fleetBody(stored) {
  const low = stored.low == null ? FLEET_DEFAULT_LOW : stored.low
  const high = stored.high == null ? FLEET_DEFAULT_HIGH : stored.high
  const boxOrder = stored.boxOrder == null ? [] : stored.boxOrder.slice()
  return {
    low,
    high,
    box_order: boxOrder,
    source: 'hub',
    stored: {
      low: stored.low,
      high: stored.high,
      box_order: stored.boxOrder == null ? null : stored.boxOrder.slice(),
    },
    defaults: { low: FLEET_DEFAULT_LOW, high: FLEET_DEFAULT_HIGH, box_order: [] },
  }
}

function browserStore() {
  try {
    if (typeof globalThis.localStorage !== 'undefined') return globalThis.localStorage
  } catch { /* private mode */ }
  return null
}

function readStored(store) {
  let raw = null
  try { raw = store.getItem(FLEET_STORE_KEY) } catch { raw = null }
  if (!raw) return { low: null, high: null, boxOrder: null }
  try {
    const p = JSON.parse(raw)
    return {
      low: p.low == null ? null : Number(p.low),
      high: p.high == null ? null : Number(p.high),
      boxOrder: p.box_order == null ? null : boxList(p.box_order),
    }
  } catch {
    return { low: null, high: null, boxOrder: null }
  }
}

function isOperator(store) {
  try { return store.getItem(FLEET_OPERATOR_KEY) === '1' } catch { return false }
}

/** Mock GET. 403 operator.workspaces unless the e2e opted into the operator admin. */
export function mockFleetRead(store) {
  const st = store || browserStore()
  if (!st || !isOperator(st)) throw forbidden()
  return fleetBody(readStored(st))
}

/** Mock PATCH. Same refusals as the hub, and the row survives a reload. */
export function mockFleetWrite(patch, store) {
  const st = store || browserStore()
  if (!st || !isOperator(st)) throw forbidden()
  const next = applyFleetPatch(readStored(st), patch)
  if (!next) throw fleetError(400, 'bad_setting', FLEET_BAD_SETTING)
  st.setItem(FLEET_STORE_KEY, JSON.stringify({
    low: next.low,
    high: next.high,
    box_order: next.boxOrder,
  }))
  return fleetBody(next)
}
