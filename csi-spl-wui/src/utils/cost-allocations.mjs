/**
 * Spec 143 costs-allocation.md (SPL-5291; owner HUM-10, t1 41a74806, poll
 * 0c5e94b4 answer C and poll 01cbbdea answers 1B 2B 3B): Settings -> Cost
 * allocation splits an estate Persons or Cloud item across workspaces by
 * hand, over
 *   GET|PUT /v1/operator/cost-allocations  (the operator workspace's admin)
 *   GET|PUT /v1/tenant/cost-allocations    (a customer admin, among the
 *                                           workspaces they administer)
 * (hub internal/hub/cost_allocations*.go, store/cost_allocations.go).
 *
 * A split has no month: it holds for every month, past ones too (2B). The
 * month picks only the amounts shown. Shares are basis points (10000 = 100 %);
 * the form takes percentages with up to two decimals. A customer admin's
 * body names only their own workspaces' shares (they never read the
 * others); the hub keeps the rest. The checks mirror the hub's, so Save is
 * disabled before a bad split is sent; the hub still has the last word and
 * its text is shown as it comes.
 *
 * Lazy like cost-entries.mjs: only the settings page, the card and the lazy
 * spool client import it. Node tests import it.
 */

import { mockError, mockGate, mockStore } from './monitoring-paid.mjs'

/** A whole split, in basis points. */
const COST_ALLOC_FULL_BP = 10000
/** e2e opt-in (mock only): the mock's splits, a JSON array kept between page loads. */
export const COST_ALLOC_MOCK_KEY = 'spool.mock.cost_allocations'
/**
 * e2e opt-in (mock only): the workspace ids the signed-in person administers,
 * a JSON array. Set, the tenant door answers for them (a customer admin);
 * unset, it answers 403 as the hub does to anyone who is no admin.
 */
export const COST_ALLOC_MOCK_ADMIN_KEY = 'spool.mock.cost_alloc_admin_of'

const str = (v) => (typeof v === 'string' ? v : '')
const int = (v) => (Number.isInteger(v) ? v : 0)
const micro = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null)

/** The item's key as one string (source, project_or_vendor, kind). */
export function costAllocKey(it) {
  return [str(it.source), str(it.projectOrVendor ?? it.project_or_vendor), str(it.kind)].join('\u0000')
}

function sharesOf(list) {
  return (Array.isArray(list) ? list : [])
    .filter((s) => s && typeof s === 'object' && str(s.workspace_id))
    .map((s) => ({
      workspaceId: str(s.workspace_id),
      bp: int(s.share_bp),
      usdMicros: micro(s.usd_micros),
      eurMicros: micro(s.eur_micros),
    }))
}

/**
 * Either door's GET as one view. `door` is 'operator' or 'tenant'. An item's
 * `targetBp` is what its rows must sum to on Save: the whole (10000) for the
 * operator, what the admin's workspaces hold (`held_bp`) for a customer admin.
 */
export function costAllocViewOf(body, door = 'operator') {
  const b = body && typeof body === 'object' ? body : {}
  const items = (Array.isArray(b.items) ? b.items : []).filter((it) => it && typeof it === 'object').map((it) => ({
    source: str(it.source),
    projectOrVendor: str(it.project_or_vendor),
    kind: str(it.kind),
    origin: str(it.origin),
    label: it.label === 'persons' ? 'persons' : 'cloud',
    usdMicros: micro(it.usd_micros),
    eurMicros: micro(it.eur_micros),
    unpriced: Boolean(it.unpriced),
    shares: sharesOf(it.shares),
    targetBp: door === 'tenant' ? int(it.held_bp) : COST_ALLOC_FULL_BP,
  }))
  const workspaces = (Array.isArray(b.workspaces) ? b.workspaces : [])
    .filter((w) => w && typeof w === 'object' && str(w.id))
    .map((w) => ({ id: str(w.id), name: str(w.name) || str(w.id) }))
  return { month: str(b.month), door: door === 'tenant' ? 'tenant' : 'operator', items, workspaces }
}

/**
 * Which door this reader sets splits through, with its first answer:
 * { door: 'operator' | 'tenant', body } or null (neither: the section stays
 * hidden). `call(door, month)` is the spool client's list call; `opts.operator`
 * false skips the operator probe (/v1/view/me says no operator admin),
 * `opts.tenant` false skips the tenant one (no tenant.settings). A customer
 * admin with no item holding a share in their workspaces has nothing to split.
 */
export async function probeCostAllocDoor(call, opts = {}, month = '') {
  if (opts.operator !== false) {
    try { return { door: 'operator', body: await call('operator', month) } } catch { /* not the operator's admin */ }
  }
  if (opts.tenant !== false) {
    try {
      const body = await call('tenant', month)
      if (body && Array.isArray(body.items) && body.items.length) return { door: 'tenant', body }
    } catch { /* no admin */ }
  }
  return null
}

/** The items of one label ('persons' | 'cloud'), by name. */
export function costAllocItemsOf(view, label) {
  return (view && Array.isArray(view.items) ? view.items : [])
    .filter((it) => it.label === label)
    .sort((a, b) => a.projectOrVendor.localeCompare(b.projectOrVendor) || a.kind.localeCompare(b.kind))
}

/** Basis points as a percentage string: 6000 -> '60', 3333 -> '33.33', 3330 -> '33.3'. */
export function bpToPct(bp) {
  const n = int(bp)
  return n % 100 === 0 ? String(n / 100) : (n / 100).toFixed(2).replace(/0$/, '')
}

/**
 * A typed percentage as basis points: '' -> 0, '60' -> 6000, '33.33' -> 3333,
 * '33,33' -> 3333 (a decimal comma). null when it is not a number from 0 to
 * 100 with at most two decimals.
 */
export function pctToBp(text) {
  const s = str(text).trim().replace(',', '.')
  if (s === '') return 0
  if (!/^\d{1,3}(\.\d{1,2})?$/.test(s)) return null
  const bp = Math.round(Number(s) * 100)
  return bp <= COST_ALLOC_FULL_BP ? bp : null
}

/**
 * The edit rows of an item: one per workspace a share may go to, its share
 * as a percentage ('' when none). A share in a workspace the list no longer
 * names (archived since) is kept on screen, under its id.
 */
export function costAllocRows(item, workspaces) {
  const by = new Map(item.shares.map((s) => [s.workspaceId, s.bp]))
  const rows = workspaces.map((w) => ({ workspaceId: w.id, name: w.name, pct: by.has(w.id) ? bpToPct(by.get(w.id)) : '' }))
  for (const s of item.shares) {
    if (!workspaces.some((w) => w.id === s.workspaceId)) rows.push({ workspaceId: s.workspaceId, name: s.workspaceId, pct: bpToPct(s.bp) })
  }
  return rows
}

/**
 * The rows' sum in basis points and the first thing Save may not send, as an
 * i18n key under tenant_settings ('' = fine). `targetBp` is what the rows
 * must sum to; every row empty is a removal, allowed only where the target
 * is the whole (the operator's door).
 */
export function checkCostAllocRows(rows, targetBp = COST_ALLOC_FULL_BP) {
  let sum = 0
  for (const r of rows) {
    const bp = pctToBp(r.pct)
    if (bp === null) return { sumBp: null, err: 'cost_alloc_err_number' }
    sum += bp
  }
  if (sum === 0 && targetBp === COST_ALLOC_FULL_BP) return { sumBp: 0, err: '' }
  if (sum !== targetBp) return { sumBp: sum, err: 'cost_alloc_err_sum' }
  return { sumBp: sum, err: '' }
}

/** The PUT body of checked rows: the shares above 0 only; none = remove the split. */
export function costAllocBody(item, rows) {
  const shares = []
  for (const r of rows) {
    const bp = pctToBp(r.pct)
    if (bp) shares.push({ workspace_id: r.workspaceId, share_bp: bp })
  }
  return { source: item.source, project_or_vendor: item.projectOrVendor, kind: item.kind, shares }
}

/** "Acme 60 % · Globex 40 %", the larger share first; '' when not split. */
export function costAllocSplitText(shares, workspaces) {
  const name = (id) => (workspaces.find((w) => w.id === id) || {}).name || id
  return [...shares].sort((a, b) => b.bp - a.bp || a.workspaceId.localeCompare(b.workspaceId))
    .map((s) => name(s.workspaceId) + ' ' + bpToPct(s.bp) + ' %').join(' · ')
}

/* ---- the mock (lde, e2e) ---- */

/** The mock estate: two Persons and three Cloud items, USD micros per month. */
const MOCK_ITEMS = Object.freeze([
  { source: 'cost_entry', project_or_vendor: 'Design contractor', kind: 'hr', origin: 'hand', usd: 4200e6 },
  { source: 'cost_entry', project_or_vendor: 'Support desk', kind: 'hr', origin: 'hand', usd: 2600e6 },
  { source: 'gcp_billing', project_or_vendor: 'example-prd', kind: 'Cloud Run', origin: 'gcp', usd: 312.5e6 },
  { source: 'gcp_billing', project_or_vendor: 'example-prd', kind: 'Cloud SQL', origin: 'gcp', usd: 540e6 },
  { source: 'cost_entry', project_or_vendor: 'Hosting invoice', kind: 'cloud', origin: 'hand', usd: 180e6 },
])
const MOCK_WORKSPACES = Object.freeze([
  { id: 't1', name: 'Operator' },
  { id: 'acme', name: 'Acme' },
  { id: 'globex', name: 'Globex' },
])
const MOCK_EUR = 0.92

function mockReadJson(store, key, fallback) {
  try {
    const v = JSON.parse((store && store.getItem(key)) || 'null')
    return Array.isArray(v) ? v : fallback
  } catch { return fallback }
}

function mockWrite(store, list) {
  try { if (store) store.setItem(COST_ALLOC_MOCK_KEY, JSON.stringify(list)) } catch { /* the mock forgets */ }
}

const mockKeyOf = (b) => costAllocKey({ source: b.source, projectOrVendor: b.project_or_vendor, kind: b.kind })
const mockSplitOf = (list, key) => (list.find((s) => mockKeyOf(s) === key) || { shares: [] }).shares
const mockLabel = (it) => (it.kind === 'hr' ? 'persons' : 'cloud')

function mockShares(body) {
  if (!MOCK_ITEMS.some((it) => mockKeyOf(it) === mockKeyOf(body))) throw mockError(400, 'bad_cost_allocation', 'no such Persons or Cloud item')
  const shares = Array.isArray(body.shares) ? body.shares : []
  const seen = new Set()
  for (const s of shares) {
    if (!MOCK_WORKSPACES.some((w) => w.id === s.workspace_id) || seen.has(s.workspace_id)) throw mockError(400, 'bad_cost_allocation', 'unknown or repeated workspace ' + s.workspace_id)
    if (!Number.isInteger(s.share_bp) || s.share_bp < 1 || s.share_bp > COST_ALLOC_FULL_BP) throw mockError(400, 'bad_cost_allocation', 'a share must be 1..10000 basis points')
    seen.add(s.workspace_id)
  }
  return shares
}

/** The mock's operator GET; 403 to anyone but an operator admin (monitoring-paid.mjs mockGate). */
export function mockCostAllocList(month = '', store = mockStore(), now = new Date()) {
  mockGate(store)
  const list = mockReadJson(store, COST_ALLOC_MOCK_KEY, [])
  const items = MOCK_ITEMS.map((it) => ({
    source: it.source, project_or_vendor: it.project_or_vendor, kind: it.kind, origin: it.origin, label: mockLabel(it),
    usd_micros: it.usd, eur_micros: Math.round(it.usd * MOCK_EUR), second_micros: null,
    shares: mockSplitOf(list, mockKeyOf(it)),
  }))
  return { month: month || now.toISOString().slice(0, 7), second_currency: 'EUR', items, workspaces: [...MOCK_WORKSPACES] }
}

/** The mock's operator PUT: the hub's 400s, then stores the split (none = removed). */
export function mockCostAllocPut(body, store = mockStore()) {
  mockGate(store)
  const shares = mockShares(body)
  const sum = shares.reduce((n, s) => n + s.share_bp, 0)
  if (shares.length && sum !== COST_ALLOC_FULL_BP) throw mockError(400, 'bad_cost_allocation', 'the shares sum to ' + sum + ' basis points, not 10000 (100 %)')
  const key = mockKeyOf(body)
  const rest = mockReadJson(store, COST_ALLOC_MOCK_KEY, []).filter((s) => mockKeyOf(s) !== key)
  mockWrite(store, shares.length ? [...rest, { ...body, shares }] : rest)
  return { ...body, shares }
}

function mockAdminOf(store) {
  const mine = mockReadJson(store, COST_ALLOC_MOCK_ADMIN_KEY, null)
  if (!mine) throw mockError(403, 'forbidden', 'only a workspace admin splits a cost')
  return mine.map(String)
}

/** The mock's tenant GET: the items holding a share in the admin's workspaces, their shares only. */
export function mockTenantCostAllocList(month = '', store = mockStore(), now = new Date()) {
  const mine = mockAdminOf(store)
  const list = mockReadJson(store, COST_ALLOC_MOCK_KEY, [])
  const items = []
  for (const it of MOCK_ITEMS) {
    const held = mockSplitOf(list, mockKeyOf(it)).filter((s) => mine.includes(s.workspace_id))
    if (!held.length) continue
    items.push({
      source: it.source, project_or_vendor: it.project_or_vendor, kind: it.kind, label: mockLabel(it),
      held_bp: held.reduce((n, s) => n + s.share_bp, 0),
      shares: held.map((s) => ({
        ...s,
        usd_micros: Math.floor(it.usd * s.share_bp / COST_ALLOC_FULL_BP),
        eur_micros: Math.floor(it.usd * MOCK_EUR * s.share_bp / COST_ALLOC_FULL_BP),
        second_micros: null,
      })),
    })
  }
  return { month: month || now.toISOString().slice(0, 7), second_currency: 'EUR', items, workspaces: MOCK_WORKSPACES.filter((w) => mine.includes(w.id)) }
}

/**
 * The mock's tenant PUT, as store.MergeCostAllocWithin + CheckCostAllocWithin:
 * the body completed with the stored shares outside the admin's workspaces,
 * then the spec's four rules (costs-allocation.md section 3), 403
 * cost_allocation.outside naming the rule.
 */
export function mockTenantCostAllocPut(body, store = mockStore()) {
  const mine = mockAdminOf(store)
  const key = mockKeyOf(body)
  const list = mockReadJson(store, COST_ALLOC_MOCK_KEY, [])
  const old = mockSplitOf(list, key)
  const own = (s) => mine.includes(s.workspace_id)
  const sent = mockShares(body)
  const next = [...sent, ...old.filter((s) => !own(s) && !sent.some((x) => x.workspace_id === s.workspace_id))]
  const held = (xs) => xs.filter(own).reduce((n, s) => n + s.share_bp, 0)
  const refuse = (why) => { throw mockError(403, 'cost_allocation.outside', why) }
  if (!held(old)) refuse('rule 4: no workspace you administer holds a share of this item')
  for (const s of old) if (!own(s) && (next.find((x) => x.workspace_id === s.workspace_id) || {}).share_bp !== s.share_bp) refuse('rule 1: the share of workspace ' + s.workspace_id + ' is not yours to change')
  for (const s of next) if (!own(s) && !old.some((x) => x.workspace_id === s.workspace_id)) refuse('rule 2: workspace ' + s.workspace_id + ' is not one you administer')
  if (held(next) !== held(old)) refuse('rule 3: your workspaces hold ' + held(old) + ' basis points; the split gives them ' + held(next))
  mockWrite(store, [...list.filter((s) => mockKeyOf(s) !== key), { ...body, shares: next }])
  return { ...body, shares: next }
}
