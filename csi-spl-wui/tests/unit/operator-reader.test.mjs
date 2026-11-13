// SPL-5181 (owner HUM-10, t1 8426e63e, t1 36406a93): the operator workspace's
// product owner reads the costs, the Expenses tabs and Monitoring -> Lanes,
// through the hub's operator_reader flag, with no write control and without
// widening monitoringStaff.
//
// Run: node tests/unit/operator-reader.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { expensesReads, normalizeMe, operatorReads } from '../../src/utils/access.mjs'
import { mockPaidCreate, mockPaidList } from '../../src/utils/monitoring-paid.mjs'
import { mockCostEntryList } from '../../src/utils/cost-entries.mjs'
import { monitoringStaff, visibleMonitoringTabs } from '../../src/utils/monitoring-tabs.mjs'
import { lanesReadPlan } from '../../src/utils/read-gates.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const po = normalizeMe({ human_id: 'h', role: 'product_owner', roles: ['product_owner'], permissions: [], operator_admin: false, operator_reader: true })
const otherPo = normalizeMe({ human_id: 'h', role: 'product_owner', roles: ['product_owner'], permissions: [], operator_admin: false, operator_reader: false })
const clone = normalizeMe({ human_id: 'h', role: 'admin', roles: ['admin'], permissions: [], operator_admin: true, operator_reader: false })
const ids = (who) => visibleMonitoringTabs(who).map((t) => t.id)

describe('operator reader', () => {
  it('the hub flag decides; only a hub that sends none falls back to the console probe', () => {
    assert.equal(operatorReads(po, false), true)
    assert.equal(operatorReads(otherPo, false), false)
    assert.equal(operatorReads(clone, true), false, 'a clone of the admin: the probe answered, the flag refuses')
    assert.equal(operatorReads(normalizeMe({ role: 'admin' }), true), true)
    assert.equal(operatorReads(normalizeMe({ role: 'admin' }), false), false)
    assert.equal(operatorReads(null, false), false)
  })
  it('the Lanes tab shows to the operator reader, and Topics and File streams do not', () => {
    const tabs = ids({ operatorReader: true })
    assert.ok(tabs.includes('lanes'))
    assert.ok(!tabs.includes('topics'))
    assert.ok(!tabs.includes('file-streams'))
    assert.ok(!ids({ operatorReader: false }).includes('lanes'))
  })
  it('monitoringStaff is not widened', () => assert.equal(monitoringStaff(po), false))
  it('the operator product owner reads the fleet route; another product owner sends no read; a clone of the admin its own lanes', () => {
    assert.equal(lanesReadPlan(po), 'fleet')
    assert.equal(lanesReadPlan(otherPo), 'none')
    assert.equal(lanesReadPlan(clone), 'own')
  })
  it('the cards take readonly and draw no write control under it', () => {
    for (const [file, marks] of [
      ['src/components/expenses/CostEntriesCard.vue', ['v-if="!adding && !readonly"', '<td v-if="!readonly" class="ce-row-actions">']],
      ['src/components/monitoring/token-burn/PaidItemsCard.vue', ['v-if="!form && !readonly"', '<td v-if="!readonly" class="pd-row-actions">']],
    ]) for (const m of marks) assert.ok(read(file).includes(m), file + ': ' + m)
    const page = read('src/pages/expenses/[[tab]].vue')
    assert.ok(page.includes('<PaidItemsCard :readonly="!operator.visible" />'))
    assert.ok(page.includes(':type="entryType" :readonly="!operator.visible" />'))
  })
})

// SPL-5420 (owner HUM-10, t1 ea5d52a7): the operator workspace's biz_owner and
// internal_accountant open Expenses through the hub's expenses_reader, read
// only, and are not made operator readers.
describe('expenses reader', () => {
  const bizOwner = normalizeMe({ human_id: 'h', role: 'biz_owner', roles: ['biz_owner'], permissions: [], operator_reader: false, expenses_reader: true })
  const otherOwner = normalizeMe({ human_id: 'h', role: 'biz_owner', roles: ['biz_owner'], permissions: [], operator_reader: false, expenses_reader: false })
  it('the hub flag decides; a hub that sends none falls back to the operator reader', () => {
    assert.equal(expensesReads(bizOwner, false), true)
    assert.equal(operatorReads(bizOwner, false), false, 'the biz_owner is no operator reader')
    assert.equal(expensesReads(otherOwner, true), false, 'another workspace: the flag refuses whatever the probe says')
    assert.equal(expensesReads(po, false), true, 'an older hub: operator_reader stands in')
    assert.equal(expensesReads(otherPo, false), false)
    assert.equal(expensesReads(normalizeMe({ role: 'admin' }), true), true)
    assert.equal(expensesReads(null, false), false)
  })
  it('the rail and the page ask useExpensesReader, the page keeps the cards read only for a non-admin', () => {
    assert.match(read('src/composables/useRailOrder.ts'), /useExpensesReader\(\)/)
    const page = read('src/pages/expenses/[[tab]].vue')
    assert.ok(page.includes('const reader = useExpensesReader()'))
    assert.ok(page.includes('<PaidItemsCard :readonly="!operator.visible" />'))
  })
  it('the mock reads open to a played expenses reader; its writes do not', () => {
    const mem = new Map()
    const store = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, String(v)), removeItem: (k) => mem.delete(k) }
    assert.throws(() => mockPaidList(store), (e) => e.status === 403)
    assert.throws(() => mockCostEntryList('hr', store), (e) => e.status === 403)
    mem.set('spool.mock.me', JSON.stringify({ role: 'biz_owner', permissions: [], expenses_reader: true }))
    assert.deepEqual(mockPaidList(store).items, [])
    assert.deepEqual(mockCostEntryList('hr', store).entries, [])
    assert.throws(() => mockPaidCreate({ vendor: 'claude' }, store), (e) => e.status === 403)
  })
})
