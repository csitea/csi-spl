/**
 * Per-workspace agent caps by vendor (spec 147, owner HUM-10 msg 9c96ca9e:
 * "the spool-hub admin should be able to define a max amount of agents and
 * their kind per workspace"). A cap is (workspace, vendor, max_live): no row
 * = unlimited, 0 = that vendor is blocked.
 *   GET /v1/tenant/agent-caps                      every member: caps + live, read-only
 *   GET /v1/operator/workspaces/{id}/agent-caps    operator admin only
 *   PUT /v1/operator/workspaces/{id}/agent-caps    operator admin only; null removes a cap
 * The hub's 403 operator.workspaces is the gate on every write; the
 * workspace settings page never renders an input, whatever it is sent.
 * Node tests import this file; OperatorPane.vue, tenant-settings/agents.vue
 * and the lazy client half (its mock) do too.
 */

import { storageGetJson } from './prefs.mjs'
import { OPERATOR_MOCK_KEY, OPERATOR_WS_ID_RE } from './operator-console.mjs'

/** The five vendors, in the order the forms show them (spec 147 P1). */
export const AGENT_CAP_VENDORS = Object.freeze(['claude', 'grok', 'agy', 'mistral', 'qwen'])
/** The mock's caps per workspace, and its live counts per workspace (e2e). */
export const AGENT_CAPS_MOCK_KEY = 'spool.mock.agent_caps'
export const AGENT_CAPS_MOCK_LIVE_KEY = 'spool.mock.agent_caps_live'
/** The workspace the mock's tenant view reads. */
export const AGENT_CAPS_MOCK_TENANT = 'example-ws'

function capOf(v) {
  const n = typeof v === 'number' ? v : (typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN)
  return Number.isInteger(n) && n >= 0 ? n : null
}

/** A hub answer (either route) -> { workspaceId, caps, live, canEdit }; caps[v] null = unlimited. */
export function normalizeAgentCaps(body) {
  const b = body && typeof body === 'object' ? body : {}
  const caps = {}
  const live = {}
  for (const v of AGENT_CAP_VENDORS) {
    caps[v] = capOf(b.caps?.[v])
    const n = Number(b.live?.[v])
    live[v] = Number.isInteger(n) && n >= 0 ? n : 0
  }
  return { workspaceId: String(b.workspace_id || ''), caps, live, canEdit: b.can_edit === true }
}

/** 'unlimited' | 'at_limit' | 'available' for one vendor. */
export function agentCapStatus(cap, live) {
  if (cap === null || cap === undefined) return 'unlimited'
  return live >= cap ? 'at_limit' : 'available'
}

/**
 * The read-only rows of the workspace settings table. Never editable: the
 * workspace page shows caps, it does not set them (spec 147 P3), even when a
 * body says can_edit.
 */
export function agentCapRows(view) {
  const v = view || normalizeAgentCaps(null)
  return AGENT_CAP_VENDORS.map((vendor) => ({
    vendor,
    cap: v.caps[vendor],
    live: v.live[vendor],
    status: agentCapStatus(v.caps[vendor], v.live[vendor]),
    editable: false,
  }))
}

/**
 * The operator form's draft: one string per vendor, '' = unlimited.
 * @returns {Record<string, string>}
 */
export function agentCapsDraft(view) {
  /** @type {Record<string, string>} */
  const out = {}
  for (const v of AGENT_CAP_VENDORS) {
    const c = view?.caps?.[v]
    out[v] = c === null || c === undefined ? '' : String(c)
  }
  return out
}

/** The draft -> { body } for the PUT (every vendor named; '' -> null), or { error: <i18n key> }. */
export function agentCapsPutBody(draft) {
  const caps = {}
  for (const v of AGENT_CAP_VENDORS) {
    const s = String(draft?.[v] ?? '').trim()
    if (s === '') { caps[v] = null; continue }
    if (!/^[0-9]{1,6}$/.test(s)) return { error: 'operator.caps_error' }
    caps[v] = Number(s)
  }
  return { body: { caps } }
}

/* ---- the mock hub (NUXT_PUBLIC_USE_MOCK) --------------------------------- */

function capsError(status, token, detail, permission) {
  const err = new Error(detail || token)
  err.status = status
  err.token = token
  err.detail = detail || ''
  if (permission) err.permission = permission
  return err
}

function browserStore() {
  try {
    if (typeof globalThis.localStorage !== 'undefined') return globalThis.localStorage
  } catch { /* private mode */ }
  return null
}

function mockMap(store, key) {
  const m = store && typeof store.getItem === 'function' ? storageGetJson(key, null, store) : null
  return m && typeof m === 'object' && !Array.isArray(m) ? m : {}
}

function mockCapsOf(store, id) {
  const caps = {}
  const row = mockMap(store, AGENT_CAPS_MOCK_KEY)[id] || {}
  for (const v of AGENT_CAP_VENDORS) if (capOf(row[v]) !== null) caps[v] = capOf(row[v])
  return caps
}

function mockOperatorGate(store, id) {
  let on = ''
  try { on = store ? store.getItem(OPERATOR_MOCK_KEY) || '' : '' } catch { on = '' }
  if (on !== '1') throw capsError(403, 'forbidden', 'only an admin of the operator workspace manages agent caps', 'operator.workspaces')
  if (!OPERATOR_WS_ID_RE.test(String(id || ''))) throw capsError(404, 'not_found', `workspace '${id}' does not exist`)
}

/** The mock's GET /v1/tenant/agent-caps (the mock tenant is AGENT_CAPS_MOCK_TENANT). */
export function mockTenantAgentCaps(store = browserStore()) {
  const id = AGENT_CAPS_MOCK_TENANT
  const set = mockCapsOf(store, id)
  const liveRow = mockMap(store, AGENT_CAPS_MOCK_LIVE_KEY)[id] || {}
  const caps = {}
  const live = {}
  for (const v of AGENT_CAP_VENDORS) {
    caps[v] = v in set ? set[v] : null
    live[v] = capOf(liveRow[v]) ?? 0
  }
  return { workspace_id: id, caps, live, can_edit: false }
}

/** The mock's GET /v1/operator/workspaces/{id}/agent-caps. */
export function mockOperatorAgentCaps(id, store = browserStore()) {
  mockOperatorGate(store, id)
  return { workspace_id: id, caps: mockCapsOf(store, id) }
}

/** The mock's PUT: a vendor set to null loses its cap; the hub's 400 tokens on a bad one. */
export function mockOperatorPutAgentCaps(id, body = {}, store = browserStore()) {
  mockOperatorGate(store, id)
  const next = mockCapsOf(store, id)
  for (const [v, c] of Object.entries(body?.caps || {})) {
    if (!AGENT_CAP_VENDORS.includes(v)) throw capsError(400, 'bad_vendor', `vendor '${v}' is not supported`)
    if (c === null) { delete next[v]; continue }
    if (capOf(c) === null || typeof c !== 'number') throw capsError(400, 'bad_cap', 'max_live must be a non-negative integer')
    next[v] = c
  }
  const all = mockMap(store, AGENT_CAPS_MOCK_KEY)
  all[id] = next
  try { if (store) store.setItem(AGENT_CAPS_MOCK_KEY, JSON.stringify(all)) } catch { /* quota */ }
  return { workspace_id: id, caps: next }
}
