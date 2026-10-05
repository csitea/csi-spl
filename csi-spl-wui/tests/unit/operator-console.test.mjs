// Operator console (spec 074 T008): the row reader, the status of a row,
// search + status filter, the create body, the visibility rule (the list
// answered AND names the operator workspace), and the mock hub the e2e runs
// against (403 operator.workspaces unless opted in; soft archive).
// Run: node tests/unit/operator-console.test.mjs
import { readFileSync } from 'node:fs'
import {
  OPERATOR_MOCK_KEY,
  OPERATOR_MOCK_STORE_KEY,
  filterOperatorWorkspaces,
  mockOperatorArchive,
  mockOperatorCreate,
  mockOperatorList,
  mockOperatorPatch,
  normalizeOperatorWorkspaces,
  operatorConsoleVisible,
  operatorCreateBody,
  operatorForbidden,
  operatorRootKey,
  operatorWorkspaceStatus,
  replaceOperatorWorkspace,
} from '../../src/utils/operator-console.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

function memStore(init = {}) {
  const m = new Map(Object.entries(init))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}

console.log('operator-console')

const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

const rows = normalizeOperatorWorkspaces({ workspaces: [
  { id: 'acme', display_name: 'Acme', billing_status: 'active', suspended_at: null, archived_at: null, operator: false },
  { id: 't1', display_name: 'Operator', operator: true },
  { id: 'beta', display_name: 'Beta Labs', suspended_at: '2026-10-02T09:00:00Z', archived_at: null },
  { id: 'gamma', display_name: '', suspended_at: '2026-10-03T09:00:00Z', archived_at: '2026-10-03T09:00:00Z' },
  { display_name: 'no id' },
] })
ok('reader drops a row without an id', rows.length === 4, JSON.stringify(rows.map((r) => r.id)))
ok('reader keeps operator only when it is true', rows.filter((r) => r.operator).map((r) => r.id).join() === 't1')

ok('status: active / suspended / archived (archived outranks suspended)',
  ['acme', 'beta', 'gamma'].map((id) => operatorWorkspaceStatus(rows.find((r) => r.id === id))).join() === 'active,suspended,archived')

const all = filterOperatorWorkspaces(rows)
ok('the operator workspace sorts first, then by name', all.map((r) => r.id).join() === 't1,acme,beta,gamma', all.map((r) => r.id).join())
ok('status filter: suspended', filterOperatorWorkspaces(rows, { status: 'suspended' }).map((r) => r.id).join() === 'beta')
ok('status filter: archived', filterOperatorWorkspaces(rows, { status: 'archived' }).map((r) => r.id).join() === 'gamma')
ok('status filter: an unknown value is all', filterOperatorWorkspaces(rows, { status: 'nope' }).length === 4)
ok('search matches the display name, any case', filterOperatorWorkspaces(rows, { q: 'LABS' }).map((r) => r.id).join() === 'beta')
ok('search matches the id', filterOperatorWorkspaces(rows, { q: 'gamm' }).map((r) => r.id).join() === 'gamma')
ok('CONTROL: search with no match is empty', filterOperatorWorkspaces(rows, { q: 'zzz' }).length === 0)

ok('visible when the list names the operator workspace', operatorConsoleVisible(rows))
ok('CONTROL: hidden when no row is the operator workspace', !operatorConsoleVisible(rows.filter((r) => !r.operator)))
ok('CONTROL: hidden with no list', !operatorConsoleVisible(null))

const good = operatorCreateBody({ id: ' New-WS ', displayName: ' New ', adminEmail: 'Boss@Example.com', billingStatus: 'grace' })
ok('create body: trimmed, lower-cased id and email', JSON.stringify(good.body) === JSON.stringify({ id: 'new-ws', display_name: 'New', first_admin_email: 'boss@example.com', billing_status: 'grace' }), JSON.stringify(good))
ok('create body: only the id is required', JSON.stringify(operatorCreateBody({ id: 'x' }).body) === '{"id":"x"}')
ok('CONTROL: create refuses a bad id', operatorCreateBody({ id: '-x' }).error === 'operator.error_id')
ok('CONTROL: create refuses an id over 32', operatorCreateBody({ id: 'a'.repeat(33) }).error === 'operator.error_id')
ok('CONTROL: create refuses an email without the at sign', operatorCreateBody({ id: 'x', adminEmail: 'nope' }).error === 'operator.error_email')
ok('CONTROL: create refuses an unknown billing status', operatorCreateBody({ id: 'x', billingStatus: 'free' }).error === 'operator.error_billing')

const replaced = replaceOperatorWorkspace(rows, { id: 'acme', display_name: 'Acme', suspended_at: '2026-10-04T00:00:00Z' })
ok('replace swaps the row in place', replaced[0].id === 'acme' && operatorWorkspaceStatus(replaced[0]) === 'suspended')
ok('replace appends a new row', replaceOperatorWorkspace(rows, { id: 'new' }).length === 5)

ok('root key: read once from a create answer', operatorRootKey({ root_private_key: 'k' }) === 'k')
ok('CONTROL: root key is empty when absent or not a string', operatorRootKey({}) === '' && operatorRootKey({ root_private_key: 1 }) === '' && operatorRootKey(null) === '')
ok('forbidden: 403 operator.workspaces', operatorForbidden({ status: 403, permission: 'operator.workspaces' }))
ok('CONTROL: forbidden is false for another 403', !operatorForbidden({ status: 403, permission: 'members.invite' }))

/* the mock hub */
const off = memStore()
let threw = null
try { mockOperatorList(off) } catch (e) { threw = e }
ok('mock: 403 operator.workspaces without the opt-in', operatorForbidden(threw))
const on = memStore({ [OPERATOR_MOCK_KEY]: '1' })
const seed = normalizeOperatorWorkspaces(mockOperatorList(on))
ok('mock: the seed has one row of each status and the operator', operatorConsoleVisible(seed)
  && ['active', 'suspended', 'archived'].every((st) => seed.some((r) => operatorWorkspaceStatus(r) === st)))
const onThrows = { getItem: (k) => { if (k === OPERATOR_MOCK_KEY) return '1'; throw new Error('denied') } }
ok('mock: a throwing getItem on the rows reseeds', mockOperatorList(onThrows).workspaces.length === seed.length)
const onNull = { getItem: (k) => (k === OPERATOR_MOCK_KEY ? '1' : null) }
const onJsonNull = { getItem: (k) => (k === OPERATOR_MOCK_KEY ? '1' : 'null') }
ok('mock: unset (null) or JSON-null rows reseed',
  mockOperatorList(onNull).workspaces.length === seed.length && mockOperatorList(onJsonNull).workspaces.length === seed.length)
const made = mockOperatorCreate({ id: 'delta', display_name: 'Delta', first_admin_email: 'a@example.com' }, on, '2026-10-04T10:00:00Z')
ok('mock create: the row, a root key once, the invite', made.workspace.id === 'delta' && typeof made.root_private_key === 'string' && made.invite.status === 'invited')
let dup = null
try { mockOperatorCreate({ id: 'delta' }, on) } catch (e) { dup = e }
ok('mock create: 409 on an existing id', dup && dup.status === 409 && dup.token === 'exists')
ok('mock: rows persist in the store', JSON.parse(on.getItem(OPERATOR_MOCK_STORE_KEY)).some((r) => r.id === 'delta'))
const sus = mockOperatorPatch('acme', { suspended: true }, on, '2026-10-04T11:00:00Z')
ok('mock suspend stamps suspended_at', sus.workspace.suspended_at === '2026-10-04T11:00:00Z')
const arc = mockOperatorArchive('acme', on, '2026-10-04T12:00:00Z')
ok('mock archive: soft, suspended + archived', arc.workspace.archived_at === '2026-10-04T12:00:00Z' && arc.workspace.suspended_at === '2026-10-04T11:00:00Z')
const res = mockOperatorPatch('acme', { suspended: false }, on)
ok('mock resume clears both stamps (the hub does too)', res.workspace.suspended_at === null && res.workspace.archived_at === null)
let self = null
try { mockOperatorArchive('t1', on) } catch (e) { self = e }
ok('CONTROL: mock refuses to archive the operator workspace (409 self)', self && self.status === 409 && self.token === 'self')

/* the pane is the third kind of the ONE right-pane section, and lazy */
const layout = readFileSync(new URL('../../src/layouts/default.vue', import.meta.url), 'utf8')
ok('the layout mounts OperatorPane in the one section chain', /<OperatorPane v-else-if="section === OPERATOR"/.test(layout))
ok('the layout loads OperatorPane lazily', /defineAsyncComponent\(\(\) => import\('@\/components\/OperatorPane\.vue'\)\)/.test(layout))
const sidebar = readFileSync(new URL('../../src/components/ChannelSidebar.vue', import.meta.url), 'utf8')
ok('the rail button shows only when the pane store says visible', /v-if="operatorPane\.visible"[\s\S]{0,200}data-testid="operator-console-open"/.test(sidebar))

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll operator-console checks passed.')
