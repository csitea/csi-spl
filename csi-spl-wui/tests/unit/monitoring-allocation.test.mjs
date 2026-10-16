// SPL-2031 (owner HUM-10, t1 dbf2f39b, msgs d8f64bc3, d4cdda5f, 22472356,
// 6cab186b): Monitoring -> Boxes shows each box's system facts and every
// admin-set allocation READ-ONLY, each set value with a "(planned)" marker.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { normalizeFleetLoad } from '../../src/utils/fleet-load.mjs'
import {
  ALLOCATION_EDIT_PATHS, SPLIT_VENDORS, agentKindRows, boxAllocationRows, boxBandRows, boxOrderRows,
  editControlsIn, fleetAllocationRows, splitRows,
} from '../../src/utils/monitoring-allocation.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const READ_ONLY = ['src/components/MonitoringAllocation.vue', 'src/components/MonitoringAllocRows.vue', 'src/components/MonitoringBoxFacts.vue', 'src/pages/monitoring/boxes/index.vue']

/* SPL-2075: the boxes list's filter (from the old Boxes section) reads, never writes */
const BOX_FILTER = /<input\s+v-model="filter"\s+class="boxes-filter"\s+type="search"[^>]*>/

const VIEW = normalizeFleetLoad({
  low: 40, high: 70, box_order: ['box-b', 'box-a'], runner_cpu_pct: 80, ci_overflow: false, runner_cpus: 4,
  boxes: { 'box-a': { low: 20, high: 60, runner_cpu_pct: 50 } }, agent_kinds_off: ['qwen'],
})
const SPLIT = { claude: 40, grok: 50, agy: 10, qwen: 0, mistral: 0 }

describe('monitoring allocation rows', () => {
  it('the fleet rows: band, runner CPU cap, CI overflow, runner cores', () => {
    const rows = fleetAllocationRows(VIEW)
    assert.deepEqual(rows.map((r) => r.id), ['fleet-band', 'runner-cpu', 'ci-overflow', 'runner-cpus'])
    assert.deepEqual(rows[0].params, { low: 40, high: 70 })
    assert.equal(rows[2].valueKey, 'tenant_settings.fleet_load_kind_off')
    assert.equal(rows[3].text, '4')
  })
  it('the box order, the per-box bands, the agent types and the split', () => {
    assert.deepEqual(boxOrderRows(VIEW).map((r) => [r.label, r.text]), [['1.', 'box-b'], ['2.', 'box-a']])
    const bands = boxBandRows(VIEW)
    assert.equal(bands.length, 1)
    assert.equal(bands[0].label, 'box-a')
    assert.equal(bands[0].valueKey, 'monitoring.alloc.band_cpu_val')
    assert.deepEqual(bands[0].params, { low: 20, high: 60, n: 50 })
    const kinds = agentKindRows(VIEW)
    assert.equal(kinds.find((r) => r.label === 'qwen').valueKey, 'tenant_settings.fleet_load_kind_off')
    assert.equal(kinds.find((r) => r.label === 'claude').valueKey, 'tenant_settings.fleet_load_kind_on')
    assert.deepEqual(splitRows(SPLIT).map((r) => r.params.n), [40, 50, 10, 0, 0])
    assert.deepEqual(SPLIT_VENDORS, ['claude', 'grok', 'agy', 'qwen', 'mistral'])
  })
  it("a box's allocation: its own band or the fleet's, its own cap, its place in the order", () => {
    const a = boxAllocationRows(VIEW, 'box-a')
    assert.deepEqual(a.map((r) => r.id), ['box-band', 'box-cpu', 'box-place'])
    assert.equal(a[0].valueKey, 'monitoring.alloc.band_own_val')
    assert.deepEqual(a[0].params, { low: 20, high: 60 })
    assert.deepEqual(a[2].params, { n: 2, total: 2 })
    const b = boxAllocationRows(VIEW, 'box-b')
    assert.equal(b[0].valueKey, 'monitoring.alloc.band_fleet_val')
    assert.deepEqual(b[0].params, { low: 40, high: 70 })
    assert.deepEqual(b[1].params, { n: 1, total: 2 })
    assert.equal(boxAllocationRows(VIEW, 'box-z').at(-1).valueKey, 'monitoring.alloc.place_none')
  })
  it('no access, no rows (the fleet-load 403 hides every part)', () => {
    for (const fn of [fleetAllocationRows, boxOrderRows, boxBandRows, agentKindRows]) assert.deepEqual(fn(null), [])
    assert.deepEqual(boxAllocationRows(null, 'box-a'), [])
    assert.deepEqual(splitRows(null), [])
  })
  it('every set value is planned; measured is reserved and empty (6cab186b)', () => {
    const all = [
      ...fleetAllocationRows(VIEW), ...boxOrderRows(VIEW), ...boxBandRows(VIEW), ...agentKindRows(VIEW),
      ...splitRows(SPLIT), ...boxAllocationRows(VIEW, 'box-a'), ...boxAllocationRows(VIEW, 'box-z'),
    ]
    assert.ok(all.length >= 20, String(all.length))
    for (const r of all) {
      assert.equal(r.planned, true, r.id)
      assert.equal(r.measured, null, r.id)
      assert.ok(r.labelKey || r.label, r.id + ' has a label')
      assert.ok(r.valueKey || r.text, r.id + ' has a value')
    }
  })
})

describe('the read-only render', () => {
  it('no input, select, textarea, button or form, no PATCH or save call (d4cdda5f, 22472356)', () => {
    for (const f of READ_ONLY) assert.deepEqual(editControlsIn(read(f).replace(BOX_FILTER, '')), [], f)
  })
  it('the one input on Monitoring -> Boxes is the list filter (SPL-2075), a search box that saves nothing', () => {
    const src = read('src/pages/monitoring/boxes/index.vue')
    assert.equal((src.match(/<input/g) || []).length, 1)
    assert.match(src, BOX_FILTER)
  })
  it('CONTROL: the check finds the edit controls of the settings card and of a planted input', () => {
    const card = editControlsIn(read('src/components/FleetLoadCard.vue'))
    assert.ok(card.includes('<input') && card.includes('<button') && card.includes('save('), card.join(' '))
    const planted = read('src/components/MonitoringAllocRows.vue').replace('<dl ', '<input type="number"><dl ')
    assert.deepEqual(editControlsIn(planted), ['<input'])
  })
  it('every value cell carries the planned marker inside the row loop', () => {
    const src = read('src/components/MonitoringAllocRows.vue')
    const loop = src.slice(src.indexOf('v-for="r in rows"'), src.indexOf('</template>\n  </dl>'))
    assert.match(loop, /data-test="alloc-value"/)
    assert.match(loop, /v-if="r\.planned"[^>]*data-test="alloc-planned"[^>]*>\(\{\{ t\('monitoring\.alloc\.planned'\) \}\}\)/)
  })
  it('the allocation block links to the settings pages that edit it', () => {
    const src = read('src/components/MonitoringAllocation.vue')
    assert.match(src, /ALLOCATION_EDIT_PATHS\.fleet/)
    assert.match(src, /ALLOCATION_EDIT_PATHS\.split/)
    assert.deepEqual({ ...ALLOCATION_EDIT_PATHS }, { fleet: '/tenant-settings/fleet-load', split: '/tenant-settings/split' })
    for (const p of Object.values(ALLOCATION_EDIT_PATHS)) assert.ok(read('src/pages' + p + '.vue').length > 0, p)
  })
  it('the Boxes tab loads both parts lazily (the 027 initial-chunk budget)', () => {
    const page = read('src/pages/monitoring/boxes/index.vue')
    assert.match(page, /defineAsyncComponent\(\(\) => import\('@\/components\/MonitoringAllocation\.vue'\)\)/)
    assert.match(page, /defineAsyncComponent\(\(\) => import\('@\/components\/MonitoringBoxFacts\.vue'\)\)/)
    assert.match(page, /<MonitoringAllocation v-if="fleet"/, 'shown only when the fleet-load read answered')
  })
  it('every new key is in every locale', () => {
    const keys = ['title', 'hint', 'planned', 'edit', 'fleet_band', 'band_val', 'band_cpu_val', 'pct_val', 'share_val', 'band_own_val', 'band_fleet_val', 'place', 'place_val', 'place_none']
    const locales = ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']
    for (const loc of locales) {
      const cat = JSON.parse(read('i18n/locales/' + loc + '.json'))
      for (const k of keys) {
        const v = cat.monitoring && cat.monitoring.alloc && cat.monitoring.alloc[k]
        assert.ok(typeof v === 'string' && v.length > 0, loc + ': monitoring.alloc.' + k)
      }
    }
  })
})
