// csi-spl-wui/src/utils/monitoring-allocation.mjs
//
// SPL-2031 (owner HUM-10, t1 dbf2f39b, msgs d8f64bc3, d4cdda5f, 22472356,
// 6cab186b): Monitoring -> Boxes shows what the admins set (Workspace
// settings -> Fleet load and Vendor split) READ-ONLY, each value with a small
// "(planned)" marker; a "(measured)" value goes beside it later. This file
// turns the two reads into rows; the components only draw them.
//
// `planned: true` marks a value an admin set (the marker shows). `measured`
// is reserved and always null here: the later lane fills it, never with
// made-up data.

import { FLEET_AGENT_KINDS, fleetBoxBandOf, fleetBoxCpuOf } from './fleet-load.mjs'

/** The vendors of the flat split, in the settings page's order. */
export const SPLIT_VENDORS = Object.freeze(['claude', 'grok', 'agy', 'qwen', 'mistral'])

/** Where an admin edits each part (Workspace settings pages). */
export const ALLOCATION_EDIT_PATHS = Object.freeze({
  fleet: '/tenant-settings/fleet-load',
  split: '/tenant-settings/split',
})

/**
 * One read-only value. The label is an i18n key (`labelKey`) or a literal
 * (`label`: a box id, an agent type); the value is an i18n key with params
 * (`valueKey`, `params`) or a literal (`text`).
 * @typedef {{ id: string, labelKey: string, label: string, valueKey: string,
 *   params: Record<string, unknown>, text: string, planned: true, measured: null }} AllocationRow
 */

/**
 * @param {string} id
 * @param {{ labelKey?: string, label?: string, valueKey?: string, params?: Record<string, unknown>, text?: string }} parts
 * @returns {AllocationRow}
 */
function row(id, parts) {
  return {
    id,
    labelKey: parts.labelKey || '',
    label: parts.label || '',
    valueKey: parts.valueKey || '',
    params: parts.params || {},
    text: parts.text || '',
    planned: true,
    measured: null,
  }
}

/** @param {boolean} on */
const onOff = (on) => (on ? 'tenant_settings.fleet_load_kind_on' : 'tenant_settings.fleet_load_kind_off')

/**
 * The fleet-wide rows from a normalizeFleetLoad() view: the band, the runner
 * CPU cap, CI overflow and its cores. [] without a view (no access).
 * @param {import('./fleet-load.mjs').FleetLoadView | null | undefined} view
 * @returns {AllocationRow[]}
 */
export function fleetAllocationRows(view) {
  if (!view) return []
  return [
    row('fleet-band', { labelKey: 'monitoring.alloc.fleet_band', valueKey: 'monitoring.alloc.band_val', params: { low: view.low, high: view.high } }),
    row('runner-cpu', { labelKey: 'tenant_settings.fleet_load_cpu', valueKey: 'monitoring.alloc.pct_val', params: { n: view.runnerCpuPct } }),
    row('ci-overflow', { labelKey: 'tenant_settings.fleet_load_ci_overflow', valueKey: onOff(view.ciOverflow) }),
    row('runner-cpus', { labelKey: 'tenant_settings.fleet_load_runner_cpus', text: String(view.runnerCpus) }),
  ]
}

/**
 * The box order as rows, first box first. [] when no order is set.
 * @param {import('./fleet-load.mjs').FleetLoadView | null | undefined} view
 * @returns {AllocationRow[]}
 */
export function boxOrderRows(view) {
  const list = view && Array.isArray(view.boxOrder) ? view.boxOrder : []
  return list.map((box, i) => row('order-' + box, { label: String(i + 1) + '.', text: box }))
}

/**
 * The per-box bands as rows: "<low>..<high> % of cores", and the box's own
 * runner CPU cap where set (empty = the fleet's).
 * @param {import('./fleet-load.mjs').FleetLoadView | null | undefined} view
 * @returns {AllocationRow[]}
 */
export function boxBandRows(view) {
  const list = view && Array.isArray(view.boxes) ? view.boxes : []
  return list.map((b) => {
    const cpu = b.runnerCpuPct ?? null
    return cpu === null
      ? row('band-' + b.box, { label: b.box, valueKey: 'monitoring.alloc.band_val', params: { low: b.low, high: b.high } })
      : row('band-' + b.box, { label: b.box, valueKey: 'monitoring.alloc.band_cpu_val', params: { low: b.low, high: b.high, n: cpu } })
  })
}

/**
 * One row per agent type: on or off.
 * @param {import('./fleet-load.mjs').FleetLoadView | null | undefined} view
 * @returns {AllocationRow[]}
 */
export function agentKindRows(view) {
  if (!view) return []
  const off = Array.isArray(view.kindsOff) ? view.kindsOff : []
  return FLEET_AGENT_KINDS.map((k) => row('kind-' + k, { label: k, valueKey: onOff(!off.includes(k)) }))
}

/**
 * The flat vendor split (tenant settings agentSplit) as rows. [] when unread.
 * @param {Record<string, number> | null | undefined} split
 * @returns {AllocationRow[]}
 */
export function splitRows(split) {
  if (!split || typeof split !== 'object') return []
  return SPLIT_VENDORS.map((v) => row('split-' + v, {
    labelKey: 'tenant_settings.split_' + v,
    valueKey: 'monitoring.alloc.share_val',
    params: { n: Number(split[v]) || 0 },
  }))
}

/**
 * One box's allocation as rows: its band in force (its own, else the
 * fleet's) and its place in the box order. [] without a view (no access).
 * @param {import('./fleet-load.mjs').FleetLoadView | null | undefined} view
 * @param {string} box
 * @returns {AllocationRow[]}
 */
export function boxAllocationRows(view, box) {
  if (!view) return []
  const own = fleetBoxBandOf(view, box)
  const cpu = fleetBoxCpuOf(view, box)
  const order = Array.isArray(view.boxOrder) ? view.boxOrder : []
  const place = order.indexOf(box) + 1
  const band = own
    ? row('box-band', { labelKey: 'boxes.band_title', valueKey: 'monitoring.alloc.band_own_val', params: { low: own.low, high: own.high } })
    : row('box-band', { labelKey: 'boxes.band_title', valueKey: 'monitoring.alloc.band_fleet_val', params: { low: view.low, high: view.high } })
  const rows = [band]
  if (cpu !== null) rows.push(row('box-cpu', { labelKey: 'tenant_settings.fleet_load_cpu', valueKey: 'monitoring.alloc.pct_val', params: { n: cpu } }))
  rows.push(place
    ? row('box-place', { labelKey: 'monitoring.alloc.place', valueKey: 'monitoring.alloc.place_val', params: { n: place, total: order.length } })
    : row('box-place', { labelKey: 'monitoring.alloc.place', valueKey: 'monitoring.alloc.place_none' }))
  return rows
}

/**
 * The read-only contract the unit test holds the components to: no form
 * control and no save in the template, no PATCH or save call in the script.
 * Returns what it found ([] = read-only).
 * @param {string} source a .vue file's text
 * @returns {string[]}
 */
export function editControlsIn(source) {
  const text = String(source)
  const tpl = text.split('<script')[0]
  const found = []
  for (const m of tpl.matchAll(/<(input|select|textarea|button|form)\b/gi)) found.push('<' + m[1].toLowerCase())
  for (const m of text.matchAll(/\b(patch[A-Z]\w*|save)\s*\(/g)) found.push(m[1] + '(')
  return found
}
