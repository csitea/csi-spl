/**
 * The operator console (spec 074 T008; owner HUM-10, t1 aa35699c): a section
 * of the right-most pane that manages the instance's workspaces through
 * GET/POST /v1/operator/workspaces and PATCH/DELETE /v1/operator/workspaces/{id}.
 * Only an admin of the operator workspace gets a 200 there; everyone else a
 * 403 that names permission operator.workspaces, which stays the real gate.
 * The section hides itself unless the list answered and one row of it is the
 * operator workspace (`operator: true`).
 * Node tests import this file; OperatorPane.vue and the mock client do too.
 */

/** The mock plays a workspace admin; this opt-in makes it the operator admin (e2e). */
export const OPERATOR_MOCK_KEY = 'spool.mock.operator_admin'
/** The mock's workspace rows, kept across reloads. */
export const OPERATOR_MOCK_STORE_KEY = 'spool.mock.operator_workspaces'
/** The status filter, in its menu order; '' = every status. */
export const OPERATOR_STATUSES = Object.freeze(['active', 'suspended', 'archived'])
/** billing_status values the hub accepts (internal/billing ValidStatus). */
export const OPERATOR_BILLING = Object.freeze(['manual', 'active', 'grace', 'unpaid', 'internal'])
/** msg.ValidTenantID's shape (the reserved names are the hub's to refuse). */
export const OPERATOR_WS_ID_RE = /^[a-z0-9][a-z0-9-]{0,31}$/

/** True when err is the hub's "not the operator admin" 403. */
export function operatorForbidden(err) {
  return Boolean(err) && Number(err.status) === 403 && err.permission === 'operator.workspaces'
}

function str(v) {
  return typeof v === 'string' ? v : ''
}

/** One workspace row of the hub → the console's view. */
export function normalizeOperatorWorkspace(raw) {
  const b = raw && typeof raw === 'object' ? raw : {}
  return {
    id: str(b.id),
    displayName: str(b.display_name),
    billingStatus: str(b.billing_status),
    planId: str(b.plan_id),
    createdAt: str(b.created_at),
    suspendedAt: str(b.suspended_at),
    archivedAt: str(b.archived_at),
    operator: b.operator === true,
  }
}

/** GET /v1/operator/workspaces body → rows; junk rows (no id) are dropped. */
export function normalizeOperatorWorkspaces(body) {
  const list = body && Array.isArray(body.workspaces) ? body.workspaces : []
  return list.map(normalizeOperatorWorkspace).filter((w) => w.id)
}

/** archived outranks suspended: DELETE sets both. */
export function operatorWorkspaceStatus(ws) {
  if (ws && ws.archivedAt) return 'archived'
  if (ws && ws.suspendedAt) return 'suspended'
  return 'active'
}

/** Whether the console shows: the list answered and it names the operator workspace. */
export function operatorConsoleVisible(rows) {
  return Array.isArray(rows) && rows.some((w) => w && w.operator === true)
}

/**
 * The rows to show for a search text and a status ('' = all). The search
 * matches the id or the display name, case-insensitive. The operator
 * workspace sorts first, then by display name (else id).
 */
export function filterOperatorWorkspaces(rows, opts = {}) {
  const q = String(opts.q || '').trim().toLowerCase()
  const status = OPERATOR_STATUSES.includes(opts.status) ? opts.status : ''
  const name = (w) => (w.displayName || w.id).toLowerCase()
  return (Array.isArray(rows) ? rows : [])
    .filter((w) => !status || operatorWorkspaceStatus(w) === status)
    .filter((w) => !q || w.id.toLowerCase().includes(q) || w.displayName.toLowerCase().includes(q))
    .sort((a, b) => (Number(b.operator) - Number(a.operator)) || name(a).localeCompare(name(b)))
}

/**
 * The create form's draft → { body } for POST /v1/operator/workspaces, or
 * { error } naming the i18n key of the first field the hub would refuse.
 */
export function operatorCreateBody(draft = {}) {
  const id = String(draft.id || '').trim().toLowerCase()
  const displayName = String(draft.displayName || '').trim()
  const email = String(draft.adminEmail || '').trim().toLowerCase()
  const billing = String(draft.billingStatus || '')
  if (!OPERATOR_WS_ID_RE.test(id)) return { error: 'operator.error_id' }
  if (email && (email.length > 320 || !email.includes('@'))) return { error: 'operator.error_email' }
  if (billing && !OPERATOR_BILLING.includes(billing)) return { error: 'operator.error_billing' }
  const body = { id }
  if (displayName) body.display_name = displayName
  if (email) body.first_admin_email = email
  if (billing) body.billing_status = billing
  return { body }
}

/**
 * The root private key a create answered ONCE ('' when the caller sent its
 * own public key). Read as `body ? body.root_private_key : ''` so the built
 * bundle never reads like `root_private_key=` (checkout-client's leak check).
 */
export function operatorRootKey(body) {
  const v = body && typeof body === 'object' ? body.root_private_key : ''
  return typeof v === 'string' ? v : ''
}

/** Replace one row by id (a PATCH / DELETE answer), keeping the order. */
export function replaceOperatorWorkspace(rows, row) {
  const next = normalizeOperatorWorkspace(row)
  if (!next.id) return rows
  const list = Array.isArray(rows) ? rows : []
  return list.some((w) => w.id === next.id) ? list.map((w) => (w.id === next.id ? next : w)) : [...list, next]
}

/* ---- the mock hub (NUXT_PUBLIC_USE_MOCK=1), the e2e's stand-in ---- */

function opError(status, token, detail, permission) {
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

/** The mock's seed: its own (operator) workspace and one of each status. */
export function operatorMockSeed() {
  const at = '2026-10-01T09:00:00Z'
  return [
    { id: 't1', display_name: 'Operator', billing_status: 'internal', plan_id: '', created_at: at, suspended_at: null, archived_at: null, operator: true },
    { id: 'acme', display_name: 'Acme', billing_status: 'active', plan_id: '', created_at: at, suspended_at: null, archived_at: null, operator: false },
    { id: 'beta', display_name: 'Beta Labs', billing_status: 'grace', plan_id: '', created_at: at, suspended_at: '2026-10-02T09:00:00Z', archived_at: null, operator: false },
    { id: 'gamma', display_name: 'Gamma', billing_status: 'unpaid', plan_id: '', created_at: at, suspended_at: '2026-10-03T09:00:00Z', archived_at: '2026-10-03T09:00:00Z', operator: false },
  ]
}

function mockGate(store) {
  let on = ''
  try { on = store ? store.getItem(OPERATOR_MOCK_KEY) || '' : '' } catch { on = '' }
  if (on !== '1') throw opError(403, 'forbidden', 'only an admin of the operator workspace manages workspaces', 'operator.workspaces')
}

function mockRead(store) {
  let raw = null
  try { raw = store ? store.getItem(OPERATOR_MOCK_STORE_KEY) : null } catch { raw = null }
  if (raw) {
    try {
      const rows = JSON.parse(raw)
      if (Array.isArray(rows)) return rows
    } catch { /* reseed */ }
  }
  return operatorMockSeed()
}

function mockWrite(store, rows) {
  try { if (store) store.setItem(OPERATOR_MOCK_STORE_KEY, JSON.stringify(rows)) } catch { /* quota */ }
}

/** The mock's GET /v1/operator/workspaces. */
export function mockOperatorList(store = browserStore()) {
  mockGate(store)
  return { workspaces: mockRead(store) }
}

/** The mock's POST: 409 on an existing id, the hub's 400 tokens on a bad field. */
export function mockOperatorCreate(body = {}, store = browserStore(), now = new Date().toISOString()) {
  mockGate(store)
  const id = String(body.id || '')
  if (!OPERATOR_WS_ID_RE.test(id)) throw opError(400, 'bad_tenant', 'id must be a valid workspace slug')
  const rows = mockRead(store)
  if (rows.some((w) => w.id === id)) throw opError(409, 'exists', 'a workspace with that id exists')
  const ws = { id, display_name: String(body.display_name || ''), billing_status: String(body.billing_status || 'manual'),
    plan_id: '', created_at: now, suspended_at: null, archived_at: null, operator: false }
  mockWrite(store, [...rows, ws])
  const out = { workspace: ws, root_private_key: 'MOCK-ROOT-KEY' }
  if (body.first_admin_email) out.invite = { status: 'invited', email: body.first_admin_email, role: 'admin', mail: 'not_sent' }
  return out
}

function mockTarget(store, id) {
  const rows = mockRead(store)
  const ws = rows.find((w) => w.id === id)
  if (!ws) throw opError(404, 'not_found', 'no such workspace')
  return { rows, ws }
}

/** The mock's PATCH: suspended true / false (resume clears the archive too, as the hub does). */
export function mockOperatorPatch(id, patch = {}, store = browserStore(), now = new Date().toISOString()) {
  mockGate(store)
  const { rows, ws } = mockTarget(store, id)
  if (patch.suspended === true && ws.operator) throw opError(409, 'self', 'the operator workspace cannot suspend itself')
  const next = { ...ws }
  if (typeof patch.display_name === 'string') next.display_name = patch.display_name
  if (typeof patch.billing_status === 'string') next.billing_status = patch.billing_status
  if (patch.suspended === true) next.suspended_at = next.suspended_at || now
  if (patch.suspended === false) { next.suspended_at = null; next.archived_at = null }
  mockWrite(store, rows.map((w) => (w.id === id ? next : w)))
  return { workspace: next }
}

/** The mock's DELETE: soft, suspend + archive. */
export function mockOperatorArchive(id, store = browserStore(), now = new Date().toISOString()) {
  mockGate(store)
  const { rows, ws } = mockTarget(store, id)
  if (ws.operator) throw opError(409, 'self', 'the operator workspace cannot archive itself')
  const next = { ...ws, suspended_at: ws.suspended_at || now, archived_at: ws.archived_at || now }
  mockWrite(store, rows.map((w) => (w.id === id ? next : w)))
  return { workspace: next }
}
