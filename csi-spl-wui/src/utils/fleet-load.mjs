/**
 * Fleet load target (rdb 0118, GET/PATCH /v1/operator/fleet-load).
 * The hub keeps it on the operator workspace. A 403 names permission
 * operator.workspaces for everyone else. NULL on a field is the default.
 * rdb 0134: `boxes` is a per-box band {box: {low, high}} that overrides the
 * fleet band for the boxes it names; a PATCH replaces the whole map.
 * Node tests import this file; the settings card does too.
 */

import { storageGetJson } from './prefs.mjs'

export const FLEET_OPERATOR_KEY = 'spool.mock.fleet_operator'
export const FLEET_STORE_KEY = 'spool.mock.fleet_load'
export const FLEET_BOX_MAX = 32
export const FLEET_BOX_RE = /^[a-z0-9][a-z0-9-]{0,31}$/
export const FLEET_DEFAULT_LOW = 50
export const FLEET_DEFAULT_HIGH = 75
/** The hub's 400 bad_setting detail (internal/hub/fleet_load.go). */
export const FLEET_BAD_SETTING = 'low is 1..99 and high 2..100 (% of cores) with low < high; box_order is distinct box ids ([a-z0-9-], up to 32 each), at most 32; boxes maps up to 32 box ids to {low, high} with the same ranges'

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

/** {box: {low, high}} → [{box, low, high}] sorted by box; junk entries dropped. */
export function fleetBandList(v) {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return []
  const out = []
  for (const [box, b] of Object.entries(v)) {
    const low = intOrNull(b && b.low)
    const high = intOrNull(b && b.high)
    if (low == null || high == null) continue
    out.push({ box: String(box), low, high })
  }
  return out.sort((a, b) => (a.box < b.box ? -1 : a.box > b.box ? 1 : 0))
}

/** [{box, low, high}] → {box: {low, high}}. */
export function fleetBandMap(list) {
  const out = {}
  for (const b of Array.isArray(list) ? list : []) out[b.box] = { low: Number(b.low), high: Number(b.high) }
  return out
}

/** True when one per-box band is a box id with both marks in range and low < high. */
export function fleetBandOk(b) {
  if (!b || !validFleetBox(b.box)) return false
  const low = Number(b.low)
  const high = Number(b.high)
  return Number.isInteger(low) && Number.isInteger(high) && low >= 1 && low <= 99 && high >= 2 && high <= 100 && low < high
}

function sameBands(a, b) {
  const x = fleetBandList(fleetBandMap(a))
  const y = fleetBandList(fleetBandMap(b))
  return JSON.stringify(x) === JSON.stringify(y)
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
    boxes: s.boxes == null ? null : fleetBandList(s.boxes),
  }
  const boxOrder = Array.isArray(b.box_order)
    ? boxList(b.box_order)
    : (stored.boxOrder ? stored.boxOrder.slice() : defaults.boxOrder.slice())
  return {
    low: intOrNull(b.low) ?? (stored.low ?? defaults.low),
    high: intOrNull(b.high) ?? (stored.high ?? defaults.high),
    boxOrder,
    boxes: b.boxes != null ? fleetBandList(b.boxes) : (stored.boxes ? stored.boxes.slice() : []),
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
  const bands = Array.isArray(draft.boxes) ? draft.boxes : []
  if (draft.resetBoxes) body.boxes = null
  else if (!sameBands(bands, saved.boxes || [])) body.boxes = fleetBandMap(bands)
  return body
}

/** One box's own band from a normalizeFleetLoad() view; null = it uses the fleet band. */
export function fleetBoxBandOf(view, box) {
  const list = view && Array.isArray(view.boxes) ? view.boxes : []
  const b = list.find((x) => x.box === box)
  return b ? { low: b.low, high: b.high } : null
}

/**
 * The Boxes view's PATCH body: set (band) or remove (null) ONE box's entry.
 * The other boxes' bands, the fleet band and the box order stay as `view` has
 * them (the hub replaces the whole map, so the rest is sent back unchanged).
 */
export function fleetBoxBandPatch(view, box, band) {
  if (!view || !validFleetBox(box)) return {}
  const others = (Array.isArray(view.boxes) ? view.boxes : []).filter((b) => b.box !== box)
  const boxes = band ? others.concat({ box, low: Number(band.low), high: Number(band.high) }) : others
  return fleetLoadPatchBody(view, {
    low: view.low,
    high: view.high,
    boxOrder: (view.boxOrder || []).slice(),
    resetLow: false,
    resetHigh: false,
    resetOrder: false,
    boxes,
    resetBoxes: false,
  })
}

/** A box's load as a whole % of its cores (load5 / cpus * 100, as box-pick reads it); null = no sample. */
export function boxLoadPct(row) {
  const load5 = Number(row && row.load5)
  const cpus = Number(row && row.cpus)
  if (!row || !Number.isFinite(load5) || !(cpus > 0)) return null
  return Math.floor((load5 / cpus) * 100)
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
  if (order != null) {
    if (!Array.isArray(order) || order.length > FLEET_BOX_MAX) return false
    const seen = new Set()
    for (const b of order) {
      if (!validFleetBox(b) || seen.has(b)) return false
      seen.add(b)
    }
  }
  const bands = stored.boxes
  if (bands == null) return true
  if (!Array.isArray(bands) || bands.length > FLEET_BOX_MAX) return false
  return bands.every(fleetBandOk)
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
    boxes: stored && Array.isArray(stored.boxes) ? stored.boxes.slice() : null,
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
  if (Object.prototype.hasOwnProperty.call(p, 'boxes')) {
    if (p.boxes === null) next.boxes = null
    else if (p.boxes && typeof p.boxes === 'object' && !Array.isArray(p.boxes)) {
      const list = []
      for (const [box, b] of Object.entries(p.boxes)) {
        if (!b || typeof b !== 'object' || Object.keys(b).length !== 2) return null
        if (!Number.isInteger(b.low) || !Number.isInteger(b.high)) return null
        list.push({ box, low: b.low, high: b.high })
      }
      next.boxes = list.length === 0 ? null : fleetBandList(fleetBandMap(list))
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
    boxes: stored.boxes == null ? {} : fleetBandMap(stored.boxes),
    source: 'hub',
    stored: {
      low: stored.low,
      high: stored.high,
      box_order: stored.boxOrder == null ? null : stored.boxOrder.slice(),
      boxes: stored.boxes == null ? null : fleetBandMap(stored.boxes),
    },
    defaults: { low: FLEET_DEFAULT_LOW, high: FLEET_DEFAULT_HIGH, box_order: [], boxes: {} },
  }
}

/* Byte-identical twin: browserStore() in operator-console.mjs (merging them is a later lane). */
function browserStore() {
  try {
    if (typeof globalThis.localStorage !== 'undefined') return globalThis.localStorage
  } catch { /* private mode */ }
  return null
}

/** The stored row; unset, unreadable or junk is all-null (the defaults). */
function readStored(store) {
  /* keep the "no store" guard: storageGetJson would fall back to localStorage */
  const p = store && typeof store.getItem === 'function' ? storageGetJson(FLEET_STORE_KEY, null, store) : null
  if (!p || typeof p !== 'object') return { low: null, high: null, boxOrder: null, boxes: null }
  return {
    low: p.low == null ? null : Number(p.low),
    high: p.high == null ? null : Number(p.high),
    boxOrder: p.box_order == null ? null : boxList(p.box_order),
    boxes: p.boxes == null ? null : fleetBandList(p.boxes),
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
    boxes: next.boxes == null ? null : fleetBandMap(next.boxes),
  }))
  return fleetBody(next)
}
