/**
 * Fleet load target (rdb 0118, GET/PATCH /v1/operator/fleet-load).
 * The hub keeps it on the operator workspace. A 403 names permission
 * operator.workspaces for everyone else. NULL on a field is the default.
 * rdb 0134: `boxes` is a per-box band {box: {low, high}} that overrides the
 * fleet band for the boxes it names; a PATCH replaces the whole map.
 * rdb 0149: `agent_kinds_off` is the agent kinds no box starts a new lane of
 * (never all four); `agent_kinds_paused` is {kind: {until, reason, box}}, a
 * timed pause a box reported when that kind hit its usage limit. A PATCH
 * replaces the kinds off; {agent_kinds_paused: {kind: null}} lifts a pause.
 * rdb 0152: `runner_cpu_pct` is the % of a box's cores CI runners plus agents
 * may use, fleet-wide (default 80), and a band may carry its own
 * {low, high, runner_cpu_pct}. Every boxes PATCH carries each band's own cap,
 * since the hub replaces the whole map.
 * rdb 0185: `ci_overflow` (default true) lets CI overflow to the box runners;
 * `runner_cpus` is the cores those runners may take, 0..256, default 0 = the
 * box's cnf share, fleet-wide and per box {low, high, runner_cpus}.
 * SPL-3876 (owner HUM-10, t1 f456ecd5 msg 61cd77e7): a band may carry an
 * `aim`, low <= aim <= high, the level the box pick aims to keep that box at;
 * absent = high. Every boxes PATCH carries each band's aim back.
 * Node tests import this file; the settings card does too.
 */

import { storageGetJson } from './prefs.mjs'

export const FLEET_OPERATOR_KEY = 'spool.mock.fleet_operator'
export const FLEET_STORE_KEY = 'spool.mock.fleet_load'
/* SPL-4451 (mock only): how many GET /v1/operator/fleet-load the mock answered, for the e2e */
export const FLEET_READS_KEY = 'spool.mock.fleet_reads'
export const FLEET_BOX_MAX = 32
export const FLEET_BOX_RE = /^[a-z0-9][a-z0-9-]{0,31}$/
export const FLEET_DEFAULT_LOW = 50
export const FLEET_DEFAULT_HIGH = 75
/** store.DefaultRunnerCPUPct: 20 % of every box kept free. */
export const FLEET_DEFAULT_RUNNER_CPU = 80
/** rdb 0185 defaults: CI overflow on, no core count (the cnf share). */
export const FLEET_DEFAULT_CI_OVERFLOW = true
export const FLEET_DEFAULT_RUNNER_CPUS = 0
/** store.MaxRunnerCPUs */
export const FLEET_RUNNER_CPUS_MAX = 256
/** The agent kinds a box can start (store.AgentKinds), in the hub's order. */
export const FLEET_AGENT_KINDS = ['claude', 'grok', 'agy', 'qwen', 'mistral']
/** The hub's 400 bad_setting detail (internal/hub/fleet_load.go). */
export const FLEET_BAD_SETTING = 'low is 1..99 and high 2..100 (% of cores) with low < high; box_order is distinct box ids ([a-z0-9-], up to 32 each), at most 32; boxes maps up to 32 box ids to {low, high} with the same ranges; agent_kinds_off is distinct kinds of claude, grok, agy, qwen, mistral, never all five; agent_kinds_paused maps a kind to null (lift its pause); runner_cpu_pct is 1..100 (% of cores), fleet-wide or per box in boxes; ci_overflow is true or false; runner_cpus is 0..256 (cores, 0 = the cnf share), fleet-wide or per box in boxes'

export function validFleetBox(id) {
  return FLEET_BOX_RE.test(String(id || ''))
}

/**
 * SPL-4451: whether to read GET /v1/operator/fleet-load for this reader.
 * Not when /v1/view/me says operator_admin false: the hub would answer 403,
 * a red line in every non-operator's console. An unknown reader (no me, a
 * hub that sends no flag yet, the mock's default null me) reads as before,
 * and the hub's 403 stays the gate.
 */
export function fleetLoadReadable(me) {
  return !(me && me.operatorAdmin === false)
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

/** True for a runner CPU cap the hub takes: an integer 1..100. */
export function fleetCpuOk(v) {
  return Number.isInteger(v) && v >= 1 && v <= 100
}

/** True for a runner core count the hub takes: an integer 0..256. */
export function fleetCpusOk(v) {
  return Number.isInteger(v) && v >= 0 && v <= FLEET_RUNNER_CPUS_MAX
}

/** A band's own cap, or null (the box uses the fleet's); '' and junk are null. */
function bandCpu(b) {
  const n = intOrNull(b && b.runnerCpuPct)
  return n == null ? null : n
}

/**
 * {box: {low, high, runner_cpu_pct?, runner_cpus?}} → [{box, low, high, runnerCpuPct?, runnerCpus?}]
 * sorted by box; junk entries dropped. runnerCpuPct / runnerCpus are there only when set.
 */
export function fleetBandList(v) {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return []
  const out = []
  for (const [box, b] of Object.entries(v)) {
    const low = intOrNull(b && b.low)
    const high = intOrNull(b && b.high)
    if (low == null || high == null) continue
    const cpu = intOrNull(b.runner_cpu_pct)
    const cpus = intOrNull(b.runner_cpus)
    const aim = intOrNull(b.aim)
    const band = { box: String(box), low, high }
    if (aim) band.aim = aim
    if (cpu) band.runnerCpuPct = cpu
    if (cpus) band.runnerCpus = cpus
    out.push(band)
  }
  return out.sort((a, b) => (a.box < b.box ? -1 : a.box > b.box ? 1 : 0))
}

/** [{box, low, high, runnerCpuPct?, runnerCpus?}] → {box: {low, high, runner_cpu_pct?, runner_cpus?}}; a null cap / count is left out. */
export function fleetBandMap(list) {
  const out = {}
  for (const b of Array.isArray(list) ? list : []) {
    const band = { low: Number(b.low), high: Number(b.high) }
    if (b.aim != null && b.aim !== '') band.aim = Number(b.aim)
    if (b.runnerCpuPct != null && b.runnerCpuPct !== '') band.runner_cpu_pct = Number(b.runnerCpuPct)
    if (b.runnerCpus != null && b.runnerCpus !== '') band.runner_cpus = Number(b.runnerCpus)
    out[b.box] = band
  }
  return out
}

/** True when one per-box band is a box id with both marks in range, low < high, its aim (if any) low..high, its cap (if any) 1..100 and its cores (if any) 0..256. */
export function fleetBandOk(b) {
  if (!b || !validFleetBox(b.box)) return false
  const low = Number(b.low)
  const high = Number(b.high)
  if (b.runnerCpuPct != null && b.runnerCpuPct !== '' && !fleetCpuOk(Number(b.runnerCpuPct))) return false
  if (b.runnerCpus != null && b.runnerCpus !== '' && !fleetCpusOk(Number(b.runnerCpus))) return false
  if (b.aim != null && b.aim !== '' && !fleetAimOk(b)) return false
  return Number.isInteger(low) && Number.isInteger(high) && low >= 1 && low <= 99 && high >= 2 && high <= 100 && low < high
}

/** A kinds list → the known kinds it names, distinct, in FLEET_AGENT_KINDS order. */
export function fleetKindList(v) {
  const names = Array.isArray(v) ? v.map((x) => String(x)) : []
  return FLEET_AGENT_KINDS.filter((k) => names.includes(k))
}

/** {kind: {until, reason, box}} → [{kind, until, reason, box}] in FLEET_AGENT_KINDS order; junk dropped. */
export function fleetPauseList(v) {
  if (!v || typeof v !== 'object' || Array.isArray(v)) return []
  const out = []
  for (const kind of FLEET_AGENT_KINDS) {
    const p = v[kind]
    if (!p || typeof p !== 'object' || typeof p.until !== 'string' || !p.until) continue
    out.push({ kind, until: p.until, reason: typeof p.reason === 'string' ? p.reason : '', box: typeof p.box === 'string' ? p.box : '' })
  }
  return out
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
    runnerCpuPct: intOrNull(d.runner_cpu_pct) ?? FLEET_DEFAULT_RUNNER_CPU,
    ciOverflow: typeof d.ci_overflow === 'boolean' ? d.ci_overflow : FLEET_DEFAULT_CI_OVERFLOW,
    runnerCpus: intOrNull(d.runner_cpus) ?? FLEET_DEFAULT_RUNNER_CPUS,
  }
  const s = b.stored && typeof b.stored === 'object' ? b.stored : {}
  const stored = {
    low: s.low == null ? null : intOrNull(s.low),
    high: s.high == null ? null : intOrNull(s.high),
    boxOrder: s.box_order == null ? null : boxList(s.box_order),
    boxes: s.boxes == null ? null : fleetBandList(s.boxes),
    kindsOff: s.agent_kinds_off == null ? null : fleetKindList(s.agent_kinds_off),
    runnerCpuPct: s.runner_cpu_pct == null ? null : intOrNull(s.runner_cpu_pct),
    ciOverflow: typeof s.ci_overflow === 'boolean' ? s.ci_overflow : null,
    runnerCpus: s.runner_cpus == null ? null : intOrNull(s.runner_cpus),
  }
  const boxOrder = Array.isArray(b.box_order)
    ? boxList(b.box_order)
    : (stored.boxOrder ? stored.boxOrder.slice() : defaults.boxOrder.slice())
  return {
    low: intOrNull(b.low) ?? (stored.low ?? defaults.low),
    high: intOrNull(b.high) ?? (stored.high ?? defaults.high),
    boxOrder,
    boxes: b.boxes != null ? fleetBandList(b.boxes) : (stored.boxes ? stored.boxes.slice() : []),
    kindsOff: b.agent_kinds_off != null ? fleetKindList(b.agent_kinds_off) : (stored.kindsOff ? stored.kindsOff.slice() : []),
    paused: fleetPauseList(b.agent_kinds_paused),
    runnerCpuPct: intOrNull(b.runner_cpu_pct) ?? (stored.runnerCpuPct ?? defaults.runnerCpuPct),
    ciOverflow: typeof b.ci_overflow === 'boolean' ? b.ci_overflow : (stored.ciOverflow ?? defaults.ciOverflow),
    runnerCpus: intOrNull(b.runner_cpus) ?? (stored.runnerCpus ?? defaults.runnerCpus),
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
  if (draft.resetCpu) body.runner_cpu_pct = null
  else if (draft.runnerCpuPct != null && Number(draft.runnerCpuPct) !== saved.runnerCpuPct) body.runner_cpu_pct = Number(draft.runnerCpuPct)
  if (draft.resetOverflow) body.ci_overflow = null
  else if (typeof draft.ciOverflow === 'boolean' && draft.ciOverflow !== saved.ciOverflow) body.ci_overflow = draft.ciOverflow
  if (draft.resetCpus) body.runner_cpus = null
  else if (draft.runnerCpus != null && Number(draft.runnerCpus) !== saved.runnerCpus) body.runner_cpus = Number(draft.runnerCpus)
  if (Array.isArray(draft.kindsOff)) {
    const off = fleetKindList(draft.kindsOff)
    if (off.join() !== fleetKindList(saved.kindsOff).join()) body.agent_kinds_off = off
  }
  const lift = fleetKindList(draft.lift).filter((k) => (saved.paused || []).some((p) => p.kind === k))
  if (lift.length) body.agent_kinds_paused = Object.fromEntries(lift.map((k) => [k, null]))
  return body
}

/** True when the kinds off leave at least one kind on (the hub refuses all four). */
export function fleetKindsOk(kindsOff) {
  return fleetKindList(kindsOff).length < FLEET_AGENT_KINDS.length
}

/** True when a band's aim is a whole % within its own low..high (SPL-3876); an empty aim is no aim. */
export function fleetAimOk(b) {
  if (!b || b.aim == null || b.aim === '') return true
  const aim = Number(b.aim)
  return Number.isInteger(aim) && aim >= Number(b.low) && aim <= Number(b.high)
}

/** One box's own band from a normalizeFleetLoad() view; null = it uses the fleet band. */
export function fleetBoxBandOf(view, box) {
  const list = view && Array.isArray(view.boxes) ? view.boxes : []
  const b = list.find((x) => x.box === box)
  return b ? { low: b.low, high: b.high } : null
}

/** One box's own runner core count from a normalizeFleetLoad() view; null = it uses the fleet's. */
export function fleetBoxCpusOf(view, box) {
  const list = view && Array.isArray(view.boxes) ? view.boxes : []
  const b = list.find((x) => x.box === box)
  const n = b ? intOrNull(b.runnerCpus) : null
  return n == null ? null : n
}

/** One box's own runner CPU cap from a normalizeFleetLoad() view; null = it uses the fleet's. */
export function fleetBoxCpuOf(view, box) {
  const list = view && Array.isArray(view.boxes) ? view.boxes : []
  const b = list.find((x) => x.box === box)
  return b ? bandCpu(b) : null
}

/**
 * The Boxes view's PATCH body: set (band) or remove (null) ONE box's entry.
 * The other boxes' bands, the fleet band and the box order stay as `view` has
 * them (the hub replaces the whole map, so the rest is sent back unchanged).
 * A set keeps the box's own runner_cpu_pct (rdb 0152), runner_cpus (rdb
 * 0185) and aim (SPL-3876); a remove drops the entry, cap and all.
 */
export function fleetBoxBandPatch(view, box, band) {
  if (!view || !validFleetBox(box)) return {}
  const others = (Array.isArray(view.boxes) ? view.boxes : []).filter((b) => b.box !== box)
  const cpu = fleetBoxCpuOf(view, box)
  const cpus = fleetBoxCpusOf(view, box)
  const kept = (Array.isArray(view.boxes) ? view.boxes : []).find((b) => b.box === box)
  const own = { box, low: Number(band && band.low), high: Number(band && band.high) }
  if (kept && kept.aim != null) own.aim = kept.aim
  if (cpu != null) own.runnerCpuPct = cpu
  if (cpus != null) own.runnerCpus = cpus
  const boxes = band ? others.concat(own) : others
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
  if (stored.runnerCpuPct != null && !fleetCpuOk(stored.runnerCpuPct)) return false
  if (stored.ciOverflow != null && typeof stored.ciOverflow !== 'boolean') return false
  if (stored.runnerCpus != null && !fleetCpusOk(stored.runnerCpus)) return false
  const off = stored.kindsOff
  if (off != null) {
    if (!Array.isArray(off) || fleetKindList(off).length !== off.length || !fleetKindsOk(off)) return false
  }
  const bands = stored.boxes
  if (bands == null) return true
  if (!Array.isArray(bands) || bands.length > FLEET_BOX_MAX) return false
  return bands.every(fleetBandOk)
}

const isInt = (v) => typeof v === 'number' && Number.isInteger(v)
const isBool = (v) => typeof v === 'boolean'
const hasKey = (o, k) => Object.prototype.hasOwnProperty.call(o, k)

/** The scalar PATCH keys: wire key, stored key, type check (null resets each). */
const FLEET_PATCH_SCALARS = [
  ['low', 'low', isInt],
  ['high', 'high', isInt],
  ['runner_cpu_pct', 'runnerCpuPct', isInt],
  ['ci_overflow', 'ciOverflow', isBool],
  ['runner_cpus', 'runnerCpus', isInt],
]

/** A PATCH `boxes` map as a band list; undefined = the hub refuses it. */
function fleetPatchBands(boxes) {
  const list = []
  for (const [box, b] of Object.entries(boxes)) {
    const hasCpu = b && typeof b === 'object' && hasKey(b, 'runner_cpu_pct')
    const hasCpus = b && typeof b === 'object' && hasKey(b, 'runner_cpus')
    const hasAim = b && typeof b === 'object' && hasKey(b, 'aim')
    if (!b || typeof b !== 'object' || Object.keys(b).length !== 2 + (hasCpu ? 1 : 0) + (hasCpus ? 1 : 0) + (hasAim ? 1 : 0)) return undefined
    if (!Number.isInteger(b.low) || !Number.isInteger(b.high)) return undefined
    if (hasCpu && !fleetCpuOk(b.runner_cpu_pct)) return undefined
    if (hasCpus && !Number.isInteger(b.runner_cpus)) return undefined
    if (hasAim && (!Number.isInteger(b.aim) || b.aim < 1)) return undefined
    const one = { box, low: b.low, high: b.high }
    if (hasAim) one.aim = b.aim
    if (hasCpu) one.runnerCpuPct = b.runner_cpu_pct
    if (hasCpus) one.runnerCpus = b.runner_cpus
    list.push(one)
  }
  return list.length === 0 ? null : fleetBandList(fleetBandMap(list))
}

/** A copy of a stored row, every field present (null = unset). */
function fleetStoredCopy(stored) {
  const s = stored || {}
  return {
    low: s.low != null ? s.low : null,
    high: s.high != null ? s.high : null,
    boxOrder: Array.isArray(s.boxOrder) ? s.boxOrder.slice() : null,
    boxes: Array.isArray(s.boxes) ? s.boxes.slice() : null,
    kindsOff: Array.isArray(s.kindsOff) ? s.kindsOff.slice() : null,
    paused: s.paused && typeof s.paused === 'object' ? { ...s.paused } : null,
    runnerCpuPct: s.runnerCpuPct != null ? s.runnerCpuPct : null,
    ciOverflow: typeof s.ciOverflow === 'boolean' ? s.ciOverflow : null,
    runnerCpus: s.runnerCpus != null ? s.runnerCpus : null,
  }
}

/**
 * Apply one PATCH to a stored row. null = the hub refused it (bad_setting).
 * An empty box_order is stored as unset, matching store.FleetLoadStored.apply.
 */
export function applyFleetPatch(stored, patch) {
  const next = fleetStoredCopy(stored)
  const p = patch && typeof patch === 'object' ? patch : {}
  for (const [wire, key, ok] of FLEET_PATCH_SCALARS) {
    if (!hasKey(p, wire)) continue
    if (p[wire] === null) next[key] = null
    else if (ok(p[wire])) next[key] = p[wire]
    else return null
  }
  if (hasKey(p, 'box_order')) {
    if (p.box_order === null) next.boxOrder = null
    else if (Array.isArray(p.box_order)) {
      const ids = p.box_order.map((x) => String(x))
      next.boxOrder = ids.length === 0 ? null : ids
    } else return null
  }
  if (hasKey(p, 'boxes')) {
    if (p.boxes === null) next.boxes = null
    else if (p.boxes && typeof p.boxes === 'object' && !Array.isArray(p.boxes)) {
      const bands = fleetPatchBands(p.boxes)
      if (bands === undefined) return null
      next.boxes = bands
    } else return null
  }
  if (hasKey(p, 'agent_kinds_off')) {
    if (p.agent_kinds_off === null) next.kindsOff = null
    else if (Array.isArray(p.agent_kinds_off)) {
      const ks = p.agent_kinds_off.map((x) => String(x))
      if (new Set(ks).size !== ks.length) return null
      next.kindsOff = ks.length === 0 ? null : ks
    } else return null
  }
  if (hasKey(p, 'agent_kinds_paused') && p.agent_kinds_paused !== null) {
    const m = p.agent_kinds_paused
    if (!m || typeof m !== 'object' || Array.isArray(m)) return null
    const left = { ...(next.paused || {}) }
    for (const [k, v] of Object.entries(m)) {
      if (v !== null || !FLEET_AGENT_KINDS.includes(k)) return null
      delete left[k]
    }
    next.paused = Object.keys(left).length ? left : null
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
    agent_kinds_off: stored.kindsOff == null ? [] : stored.kindsOff.slice(),
    agent_kinds_paused: stored.paused == null ? {} : { ...stored.paused },
    runner_cpu_pct: stored.runnerCpuPct == null ? FLEET_DEFAULT_RUNNER_CPU : stored.runnerCpuPct,
    ci_overflow: stored.ciOverflow == null ? FLEET_DEFAULT_CI_OVERFLOW : stored.ciOverflow,
    runner_cpus: stored.runnerCpus == null ? FLEET_DEFAULT_RUNNER_CPUS : stored.runnerCpus,
    source: 'hub',
    stored: {
      low: stored.low,
      high: stored.high,
      box_order: stored.boxOrder == null ? null : stored.boxOrder.slice(),
      boxes: stored.boxes == null ? null : fleetBandMap(stored.boxes),
      agent_kinds_off: stored.kindsOff == null ? null : stored.kindsOff.slice(),
      agent_kinds_paused: stored.paused == null ? null : { ...stored.paused },
      runner_cpu_pct: stored.runnerCpuPct,
      ci_overflow: stored.ciOverflow,
      runner_cpus: stored.runnerCpus,
    },
    defaults: {
      low: FLEET_DEFAULT_LOW,
      high: FLEET_DEFAULT_HIGH,
      box_order: [],
      boxes: {},
      agent_kinds_off: [],
      agent_kinds_paused: {},
      runner_cpu_pct: FLEET_DEFAULT_RUNNER_CPU,
      ci_overflow: FLEET_DEFAULT_CI_OVERFLOW,
      runner_cpus: FLEET_DEFAULT_RUNNER_CPUS,
    },
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
  if (!p || typeof p !== 'object') return { low: null, high: null, boxOrder: null, boxes: null, kindsOff: null, paused: null, runnerCpuPct: null, ciOverflow: null, runnerCpus: null }
  return {
    low: p.low == null ? null : Number(p.low),
    high: p.high == null ? null : Number(p.high),
    boxOrder: p.box_order == null ? null : boxList(p.box_order),
    boxes: p.boxes == null ? null : fleetBandList(p.boxes),
    kindsOff: p.agent_kinds_off == null ? null : fleetKindList(p.agent_kinds_off),
    /* the e2e plants a pause here, as a box's fleet_load_pause would */
    paused: p.agent_kinds_paused && typeof p.agent_kinds_paused === 'object' ? { ...p.agent_kinds_paused } : null,
    runnerCpuPct: p.runner_cpu_pct == null ? null : Number(p.runner_cpu_pct),
    ciOverflow: typeof p.ci_overflow === 'boolean' ? p.ci_overflow : null,
    runnerCpus: p.runner_cpus == null ? null : Number(p.runner_cpus),
  }
}

function countRead(store) {
  try { store.setItem(FLEET_READS_KEY, String((Number(store.getItem(FLEET_READS_KEY)) || 0) + 1)) } catch { /* no count */ }
}

/** The mock's operator_admin on /v1/view/me: the e2e's operator opt-in. */
export function mockFleetOperator(store) {
  const st = store || browserStore()
  return Boolean(st) && isOperator(st)
}

function isOperator(store) {
  try { return store.getItem(FLEET_OPERATOR_KEY) === '1' } catch { return false }
}

/** Mock GET. 403 operator.workspaces unless the e2e opted into the operator admin. */
export function mockFleetRead(store) {
  const st = store || browserStore()
  if (st) countRead(st)
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
    agent_kinds_off: next.kindsOff,
    agent_kinds_paused: next.paused,
    runner_cpu_pct: next.runnerCpuPct,
    ci_overflow: next.ciOverflow,
    runner_cpus: next.runnerCpus,
  }))
  return fleetBody(next)
}
