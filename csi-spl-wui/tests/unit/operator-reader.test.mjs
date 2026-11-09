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
import { normalizeMe, operatorReads } from '../../src/utils/access.mjs'
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
