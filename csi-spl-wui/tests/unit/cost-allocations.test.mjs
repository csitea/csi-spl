// Spec 143 costs-allocation.md section 6 (SPL-5291; owner HUM-10, t1
// 41a74806, polls 0c5e94b4 C and 01cbbdea 1B 2B 3B): Settings -> Cost
// allocation. The percent and basis-point round trip, the sum check Save
// waits on, the PUT body, both doors' views, the door probe, the mock's
// operator and customer-admin rounds (the spec's four rules), and the client
// ops reaching the hub's paths.
//
// Run: node tests/unit/cost-allocations.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  COST_ALLOC_MOCK_ADMIN_KEY,
  COST_ALLOC_MOCK_KEY,
  bpToPct,
  checkCostAllocRows,
  costAllocBody,
  costAllocItemsOf,
  costAllocRows,
  costAllocSplitText,
  costAllocViewOf,
  mockCostAllocList,
  mockCostAllocPut,
  mockTenantCostAllocList,
  mockTenantCostAllocPut,
  pctToBp,
  probeCostAllocDoor,
} from '../../src/utils/cost-allocations.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

function memStore(seed = {}) {
  const m = new Map(Object.entries(seed))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}
const opStore = () => memStore({ [TOKENS_MOCK_OPERATOR_KEY]: '1' })
const WS = [{ id: 'a', name: 'Acme' }, { id: 'g', name: 'Globex' }, { id: 't1', name: 'Operator' }]
const rows = (...pcts) => pcts.map((pct, i) => ({ workspaceId: WS[i].id, name: WS[i].name, pct }))
const run = (key) => ({ source: 'gcp_billing', project_or_vendor: 'example-prd', kind: key })

describe('percent <-> basis points', () => {
  for (const [bp, pct] of [[10000, '100'], [6000, '60'], [3333, '33.33'], [3330, '33.3'], [1, '0.01'], [0, '0']]) {
    it(bp + ' bp reads ' + pct + ' %, and back', () => {
      assert.equal(bpToPct(bp), pct)
      assert.equal(pctToBp(pct), bp)
    })
  }
  it('an empty field is 0, a decimal comma is a point', () => {
    assert.equal(pctToBp(''), 0)
    assert.equal(pctToBp(' 33,33 '), 3333)
  })
  for (const bad of ['-1', '100.01', '101', '1.234', 'abc', '1e2', '50%']) {
    it('"' + bad + '" is no share', () => assert.equal(pctToBp(bad), null))
  }
})

describe('Save waits on the sum', () => {
  it('60 + 40 is a whole split', () => assert.deepEqual(checkCostAllocRows(rows('60', '40', '')), { sumBp: 10000, err: '' }))
  it('60 + 30 (90 %) is not', () => assert.deepEqual(checkCostAllocRows(rows('60', '30', '')), { sumBp: 9000, err: 'cost_alloc_err_sum' }))
  it('three thirds of 33.33 + one 0.01 are', () => {
    const r = [...rows('33.33', '33.33', '33.33'), { workspaceId: 'x', name: 'x', pct: '0.01' }]
    assert.equal(checkCostAllocRows(r).err, '')
  })
  it('a bad number names the number, not the sum', () => assert.equal(checkCostAllocRows(rows('60', 'x', '40')).err, 'cost_alloc_err_number'))
  it('every row empty removes the operator split', () => assert.deepEqual(checkCostAllocRows(rows('', '', '')), { sumBp: 0, err: '' }))
  it('a customer admin sums to what they hold, and cannot empty it', () => {
    assert.equal(checkCostAllocRows(rows('20', '50'), 7000).err, '')
    assert.equal(checkCostAllocRows(rows('20', '60'), 7000).err, 'cost_alloc_err_sum')
    assert.equal(checkCostAllocRows(rows('', ''), 7000).err, 'cost_alloc_err_sum')
  })
})

describe('the PUT body', () => {
  const item = { source: 'cost_entry', projectOrVendor: 'Support desk', kind: 'hr' }
  it('sends the shares above 0 as basis points', () => {
    assert.deepEqual(costAllocBody(item, rows('60', '', '40')), {
      source: 'cost_entry', project_or_vendor: 'Support desk', kind: 'hr',
      shares: [{ workspace_id: 'a', share_bp: 6000 }, { workspace_id: 't1', share_bp: 4000 }],
    })
  })
  it('no share is a removal', () => assert.deepEqual(costAllocBody(item, rows('', '0', '')).shares, []))
})

describe('the views', () => {
  const body = {
    month: '2026-10',
    items: [
      { ...run('Cloud SQL'), origin: 'gcp', label: 'cloud', usd_micros: 5e8, eur_micros: 4.6e8, shares: [{ workspace_id: 'g', share_bp: 4000 }, { workspace_id: 'a', share_bp: 6000 }] },
      { source: 'cost_entry', project_or_vendor: 'Support desk', kind: 'hr', label: 'persons', usd_micros: 1e9, eur_micros: null, shares: [] },
    ],
    workspaces: [{ id: 'a', name: 'Acme' }, { id: 'g', name: '' }],
  }
  it('the operator view targets the whole split', () => {
    const v = costAllocViewOf(body, 'operator')
    assert.equal(v.door, 'operator')
    assert.deepEqual(v.items.map((x) => x.targetBp), [10000, 10000])
    assert.deepEqual(v.workspaces, [{ id: 'a', name: 'Acme' }, { id: 'g', name: 'g' }])
    assert.deepEqual(costAllocItemsOf(v, 'persons').map((x) => x.projectOrVendor), ['Support desk'])
    assert.equal(costAllocSplitText(v.items[0].shares, v.workspaces), 'Acme 60 % · g 40 %')
    assert.equal(costAllocSplitText(v.items[1].shares, v.workspaces), '')
  })
  it('the tenant view targets what is held', () => {
    const v = costAllocViewOf({ items: [{ ...run('Cloud Run'), label: 'cloud', held_bp: 7000, shares: [] }] }, 'tenant')
    assert.equal(v.items[0].targetBp, 7000)
  })
  it('an edit lists every workspace, and keeps a share in one the list no longer names', () => {
    const v = costAllocViewOf({ ...body, items: [{ ...body.items[0], shares: [{ workspace_id: 'gone', share_bp: 10000 }] }] })
    assert.deepEqual(costAllocRows(v.items[0], v.workspaces).map((r) => [r.workspaceId, r.pct]), [['a', ''], ['g', ''], ['gone', '100']])
  })
  it('a junk body reads as nothing', () => assert.deepEqual(costAllocViewOf(null), { month: '', door: 'operator', items: [], workspaces: [] }))
})

describe('the door probe', () => {
  const answers = (op, tenant) => async (door) => {
    const a = door === 'operator' ? op : tenant
    if (a instanceof Error) throw a
    return a
  }
  const no = Object.assign(new Error('403'), { status: 403 })
  it('the operator admin', async () => assert.equal((await probeCostAllocDoor(answers({ items: [] }, no))).door, 'operator'))
  it('a customer admin holding a share', async () => assert.equal((await probeCostAllocDoor(answers(no, { items: [{}] }))).door, 'tenant'))
  it('a customer admin holding nothing has no section', async () => assert.equal(await probeCostAllocDoor(answers(no, { items: [] })), null))
  it('nobody', async () => assert.equal(await probeCostAllocDoor(answers(no, no)), null))
  it('operator: false skips the operator read', async () => {
    let asked = ''
    await probeCostAllocDoor(async (door) => { asked += door; throw no }, { operator: false })
    assert.equal(asked, 'tenant')
  })
})

describe('the mock, the operator door', () => {
  it('403 to anyone but an operator admin', () => {
    assert.throws(() => mockCostAllocList('', memStore()), (e) => e.status === 403)
    assert.throws(() => mockCostAllocPut({}, memStore()), (e) => e.status === 403)
  })
  it('lists Persons and Cloud only, sets a 60/40 split, then removes it', () => {
    const st = opStore()
    const first = mockCostAllocList('2026-10', st)
    assert.equal(first.month, '2026-10')
    assert.deepEqual([...new Set(first.items.map((x) => x.label))].sort(), ['cloud', 'persons'])
    mockCostAllocPut({ ...run('Cloud SQL'), shares: [{ workspace_id: 'acme', share_bp: 6000 }, { workspace_id: 'globex', share_bp: 4000 }] }, st)
    const it2 = mockCostAllocList('', st).items.find((x) => x.kind === 'Cloud SQL')
    assert.deepEqual(it2.shares.map((s) => s.share_bp), [6000, 4000])
    mockCostAllocPut({ ...run('Cloud SQL'), shares: [] }, st)
    assert.deepEqual(JSON.parse(st.getItem(COST_ALLOC_MOCK_KEY)), [])
  })
  for (const [name, shares] of [
    ['a sum of 9999', [{ workspace_id: 'acme', share_bp: 9999 }]],
    ['an unknown workspace', [{ workspace_id: 'nope', share_bp: 10000 }]],
    ['a zero share', [{ workspace_id: 'acme', share_bp: 0 }, { workspace_id: 'globex', share_bp: 10000 }]],
  ]) {
    it('400 on ' + name, () => assert.throws(() => mockCostAllocPut({ ...run('Cloud SQL'), shares }, opStore()), (e) => e.status === 400 && e.token === 'bad_cost_allocation'))
  }
})

describe('the mock, a customer admin of acme and globex (spec section 3)', () => {
  const seeded = () => {
    const st = memStore({ [TOKENS_MOCK_OPERATOR_KEY]: '1', [COST_ALLOC_MOCK_ADMIN_KEY]: JSON.stringify(['acme', 'globex']) })
    mockCostAllocPut({ ...run('Cloud SQL'), shares: [{ workspace_id: 'acme', share_bp: 4000 }, { workspace_id: 'globex', share_bp: 3000 }, { workspace_id: 't1', share_bp: 3000 }] }, st)
    return st
  }
  const refusedFor = (rule) => (e) => e.status === 403 && e.token === 'cost_allocation.outside' && e.message.startsWith(rule)
  it('403 without the opt-in', () => assert.throws(() => mockTenantCostAllocList('', memStore()), (e) => e.status === 403))
  it('sees its own shares only, and what it holds', () => {
    const v = mockTenantCostAllocList('', seeded())
    assert.equal(v.items.length, 1)
    assert.equal(v.items[0].held_bp, 7000)
    assert.deepEqual(v.items[0].shares.map((s) => s.workspace_id).sort(), ['acme', 'globex'])
    assert.deepEqual(v.workspaces.map((w) => w.id), ['acme', 'globex'])
  })
  it('moves 40/30 to 20/50 with a body of its own shares; t1 keeps 3000', () => {
    const st = seeded()
    mockTenantCostAllocPut({ ...run('Cloud SQL'), shares: [{ workspace_id: 'acme', share_bp: 2000 }, { workspace_id: 'globex', share_bp: 5000 }] }, st)
    const s = mockCostAllocList('', st).items.find((x) => x.kind === 'Cloud SQL').shares
    assert.deepEqual(Object.fromEntries(s.map((x) => [x.workspace_id, x.share_bp])), { acme: 2000, globex: 5000, t1: 3000 })
  })
  it('rule 1: changing t1\'s share', () => assert.throws(() => mockTenantCostAllocPut({ ...run('Cloud SQL'), shares: [{ workspace_id: 'acme', share_bp: 4000 }, { workspace_id: 'globex', share_bp: 3000 }, { workspace_id: 't1', share_bp: 3000 - 1 }] }, seeded()), refusedFor('rule 1')))
  it('rule 3: lowering what they hold', () => assert.throws(() => mockTenantCostAllocPut({ ...run('Cloud SQL'), shares: [{ workspace_id: 'acme', share_bp: 6000 }] }, seeded()), refusedFor('rule 3')))
  it('rule 4: an item with no share in their workspaces', () => assert.throws(() => mockTenantCostAllocPut({ ...run('Cloud Run'), shares: [{ workspace_id: 'acme', share_bp: 10000 }] }, seeded()), refusedFor('rule 4')))
})

describe('the wiring', () => {
  const lazy = read('src/utils/spool-client-lazy.mjs')
  it('the client reaches both doors over the one fleetPaid stub', () => {
    assert.match(lazy, /'\/v1\/' \+ door \+ '\/cost-allocations'/)
    assert.match(lazy, /json\('PUT', b\)/)
    assert.doesNotMatch(read('src/utils/spool-client.mjs'), /'costAllocations'/, 'no new stub name in the initial client')
  })
  it('the settings nav knows the section and the page probes it', () => {
    assert.match(read('src/utils/tenant-settings-nav.ts'), /id: 'cost-allocation'/)
    assert.match(read('src/pages/tenant-settings.vue'), /probeCostAllocDoor/)
    assert.match(read('src/pages/tenant-settings/cost-allocation.vue'), /CostAllocationCard/)
  })
})
