/**
 * A workspace's own agent vendor keys (spec 127 v1.4 4.3 and 8, row W1;
 * spec 159 v0.2 section 10, row T7). The hub routes are write only:
 *   GET    /v1/vendor-keys          { kinds: [{ kind, available, set, last4,
 *                                    base_url, set_by, set_at, exhausted? }], confirmed }
 *   PUT    /v1/vendor-keys/{kind}   { key, base_url? } -> 204
 *   DELETE /v1/vendor-keys/{kind}   -> 204
 *   POST   /v1/vendor-keys/{kind}/retry   -> 204 (spec 159 9: an exhausted key
 *                                    leased again; the hub half is row T5)
 * vendor_keys.manage (biz_owner and admin, spec 159 3) on every route. No
 * route answers the key; nothing here keeps it: the page holds the typed
 * key in one input, sends it once and clears it (127 L12). The mock below
 * stores last4 only, so a test that greps the browser's storage for the
 * key proves the page, not the mock.
 * Node tests import this file; tenant-settings/agent-keys.vue and the lazy
 * client half (its mock) do too.
 */

import { storageGetJson, storageSetJson } from './prefs.mjs'
import { mockMeGet } from './act-as-mock.mjs'

/** The five kinds, in the order the page lists them (127 3). */
export const VENDOR_KEY_KINDS = Object.freeze(['claude', 'grok', 'agy', 'mistral', 'qwen'])
/** The permission every route needs (hub rbac.VendorKeysManage). */
export const VENDOR_KEYS_PERM = 'vendor_keys.manage'
/** The mock's stored rows per kind ({ last4, set_at, set_by, base_url, exhausted }). */
export const VENDOR_KEYS_MOCK_KEY = 'spool.mock.vendor_keys'
/** The mock's "this caller is unconfirmed" switch (e2e: '1'). */
export const VENDOR_KEYS_MOCK_UNCONFIRMED_KEY = 'spool.mock.vendor_keys_unconfirmed'
/** The kinds the hub takes keys for today (hub VendorKeyAvailable, spec 159 4.2). */
export const VENDOR_KEYS_MOCK_AVAILABLE = Object.freeze(['claude', 'qwen'])

/**
 * A GET body -> { rows, confirmed }. One row per kind, in VENDOR_KEY_KINDS
 * order, whatever the body lists; a kind the body leaves out reads as not
 * available. confirmed defaults to true (an old hub without the field).
 */
export function normalizeVendorKeys(body) {
  const b = body && typeof body === 'object' ? body : {}
  const list = Array.isArray(b.kinds) ? b.kinds : []
  const rows = VENDOR_KEY_KINDS.map((kind) => {
    const r = list.find((x) => x && x.kind === kind) || {}
    return {
      kind,
      available: r.available === true,
      set: r.set === true,
      last4: typeof r.last4 === 'string' ? r.last4 : '',
      baseUrl: typeof r.base_url === 'string' ? r.base_url : '',
      setBy: typeof r.set_by === 'string' ? r.set_by : '',
      setAt: typeof r.set_at === 'string' ? r.set_at : '',
      exhausted: r.exhausted === true,
    }
  })
  return { rows, confirmed: b.confirmed !== false }
}

/**
 * The state the page shows for one row (spec 159 10): 'not_available',
 * 'exhausted' (with retry), 'set' or 'not_set'. Unconfirmed is the page's
 * state, not a row's: the rows still read, nothing can be changed.
 */
export function vendorKeyState(row) {
  if (!row || !row.available) return 'not_available'
  if (row.set && row.exhausted) return 'exhausted'
  return row.set ? 'set' : 'not_set'
}

/**
 * The PUT body for a typed key, or { error: <i18n key> }. The key is
 * trimmed only of its ends; one with a space or control character inside is
 * refused here as the hub refuses it (bad_key). qwen needs an https base_url.
 */
export function vendorKeyPutBody(kind, key, baseUrl) {
  const k = String(key ?? '').trim()
  if (!k || k.length > 4096 || /[\s\p{Cc}]/u.test(k)) return { error: 'tenant_settings.agent_keys.error.bad_key' }
  if (kind !== 'qwen') return { body: { key: k } }
  const u = String(baseUrl ?? '').trim()
  let ok = false
  try { ok = new URL(u).protocol === 'https:' && !/\s/.test(u) } catch { ok = false }
  if (!ok) return { error: 'tenant_settings.agent_keys.error.bad_base_url' }
  return { body: { key: k, base_url: u } }
}

/** A refusal -> its i18n key under tenant_settings.agent_keys.error. */
export function vendorKeysErrorKey(err) {
  const token = err && typeof err.token === 'string' ? err.token : ''
  const known = ['forbidden', 'admin_unconfirmed', 'act_as_refused', 'vendor_keys_off', 'kind_not_available', 'bad_key', 'bad_base_url']
  return 'tenant_settings.agent_keys.error.' + (known.includes(token) ? token : 'generic')
}

/* ---- the mock hub (NUXT_PUBLIC_USE_MOCK) --------------------------------- */

function vkError(status, token, detail) {
  const err = new Error(detail || token)
  err.status = status
  err.token = token
  err.detail = detail || ''
  return err
}

function browserStore() {
  try {
    if (typeof globalThis.localStorage !== 'undefined') return globalThis.localStorage
  } catch { /* private mode */ }
  return null
}

function mockRows(store) {
  const m = store ? storageGetJson(VENDOR_KEYS_MOCK_KEY, null, store) : null
  return m && typeof m === 'object' && !Array.isArray(m) ? m : {}
}

/* the hub's gate: vendor_keys.manage when the mock plays a role (me() null
   plays the owner); a write also refuses an unconfirmed manager. */
function mockGate(store, write) {
  const me = mockMeGet(store)
  if (me && !me.permissions.includes(VENDOR_KEYS_PERM)) throw vkError(403, 'forbidden', 'vendor_keys.manage required')
  let unconfirmed = false
  try { unconfirmed = Boolean(store) && store.getItem(VENDOR_KEYS_MOCK_UNCONFIRMED_KEY) === '1' } catch { unconfirmed = false }
  if (write && unconfirmed) throw vkError(403, 'admin_unconfirmed', 'an operator-made manager manages keys only after a confirmed one confirms them')
  return !unconfirmed
}

function mockKind(kind) {
  if (!VENDOR_KEY_KINDS.includes(kind)) throw vkError(404, 'unknown_kind', 'not a vendor key kind')
  if (!VENDOR_KEYS_MOCK_AVAILABLE.includes(kind)) throw vkError(409, 'kind_not_available', "not available for workspace keys: waiting for the vendor's terms or its gate")
}

/** The mock's GET /v1/vendor-keys. */
export function mockVendorKeys(store = browserStore()) {
  const confirmed = mockGate(store, false)
  const rows = mockRows(store)
  const kinds = VENDOR_KEY_KINDS.map((kind) => {
    const r = rows[kind]
    const o = { kind, available: VENDOR_KEYS_MOCK_AVAILABLE.includes(kind), set: Boolean(r) }
    if (r) {
      Object.assign(o, { last4: r.last4, set_by: r.set_by, set_at: r.set_at, exhausted: r.exhausted === true })
      if (r.base_url) o.base_url = r.base_url
    }
    return o
  })
  return { kinds, confirmed }
}

/** The mock's PUT: validates as the hub does and keeps last4 only, never the key. */
export function mockPutVendorKey(kind, body = {}, store = browserStore()) {
  mockGate(store, true)
  mockKind(kind)
  const key = typeof body?.key === 'string' ? body.key : ''
  if (!key || key.length > 4096 || /[\s\p{Cc}]/u.test(key)) throw vkError(422, 'bad_key', 'key must be 1 to 4096 characters with no space or control character')
  if (kind === 'qwen' && !/^https:\/\/\S+$/.test(String(body?.base_url || ''))) throw vkError(422, 'bad_base_url', 'qwen needs an https base_url')
  const rows = mockRows(store)
  rows[kind] = { last4: key.slice(-4), set_by: 'HUM-1', set_at: new Date().toISOString() }
  if (kind === 'qwen') rows[kind].base_url = body.base_url
  storageSetJson(VENDOR_KEYS_MOCK_KEY, rows, store)
  return null
}

/** The mock's DELETE. */
export function mockDeleteVendorKey(kind, store = browserStore()) {
  mockGate(store, true)
  if (!VENDOR_KEY_KINDS.includes(kind)) throw vkError(404, 'unknown_kind', 'not a vendor key kind')
  const rows = mockRows(store)
  delete rows[kind]
  storageSetJson(VENDOR_KEYS_MOCK_KEY, rows, store)
  return null
}

/** The mock's retry: the exhausted mark goes, the key stays. */
export function mockRetryVendorKey(kind, store = browserStore()) {
  mockGate(store, true)
  mockKind(kind)
  const rows = mockRows(store)
  if (rows[kind]) rows[kind] = { ...rows[kind], exhausted: false }
  storageSetJson(VENDOR_KEYS_MOCK_KEY, rows, store)
  return null
}
