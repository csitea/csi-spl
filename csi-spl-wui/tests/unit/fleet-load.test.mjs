// Fleet load card (rdb 0118): the reader, the PATCH body (null resets a
// field), the operator.workspaces gate, the mock hub, and the nav entry
// that appears only after the probe succeeds.
// Run: node tests/unit/fleet-load.test.mjs
import { readFileSync } from 'node:fs'
import {
  FLEET_BAD_SETTING,
  FLEET_OPERATOR_KEY,
  applyFleetPatch,
  fleetBandList,
  fleetBandMap,
  fleetBandOk,
  fleetLoadForbidden,
  fleetLoadPatchBody,
  fleetLoadStatusDetail,
  fleetStoredOk,
  mockFleetRead,
  mockFleetWrite,
  normalizeFleetLoad,
  suggestFleetBoxes,
  validFleetBox,
} from '../../src/utils/fleet-load.mjs'
import { tenantSettingsSectionOf, tenantSettingsSections } from '../../src/utils/tenant-settings-nav.mjs'
import { normalizeMe } from '../../src/utils/access.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('fleet-load')

ok('box id: box-a and a single letter', validFleetBox('box-a') && validFleetBox('a'))
ok('CONTROL: box id rejects empty, upper case, a leading hyphen and 33 chars',
  !validFleetBox('') && !validFleetBox('Box') && !validFleetBox('-a') && !validFleetBox('a'.repeat(33)))

const fresh = normalizeFleetLoad({
  low: 50, high: 75, box_order: [], source: 'hub',
  stored: { low: null, high: null, box_order: null },
  defaults: { low: 50, high: 75, box_order: [] },
})
ok('reader: unset stored is the default band and an empty order',
  fresh.low === 50 && fresh.high === 75 && fresh.boxOrder.length === 0 && fresh.stored.low === null && fresh.stored.boxOrder === null)
const set = normalizeFleetLoad({
  low: 40, high: 80, box_order: ['box-b', 'box-a'], source: 'hub',
  stored: { low: 40, high: 80, box_order: ['box-b', 'box-a'] },
  defaults: { low: 50, high: 75, box_order: [] },
})
ok('reader: a stored band and order pass through', set.low === 40 && set.high === 80 && set.boxOrder.join() === 'box-b,box-a')
ok('reader: junk is the defaults', normalizeFleetLoad(null).low === 50 && normalizeFleetLoad(null).boxOrder.length === 0)

const none = fleetLoadPatchBody(fresh, { low: 50, high: 75, boxOrder: [], resetLow: false, resetHigh: false, resetOrder: false })
ok('patch: an unchanged form sends nothing', Object.keys(none).length === 0)
const edited = fleetLoadPatchBody(fresh, { low: 40, high: 80, boxOrder: ['box-a'], resetLow: false, resetHigh: false, resetOrder: false })
ok('patch: only the changed fields', edited.low === 40 && edited.high === 80 && edited.box_order.join() === 'box-a' && !('source' in edited))
const reset = fleetLoadPatchBody(set, { low: 50, high: 80, boxOrder: [], resetLow: true, resetHigh: false, resetOrder: true })
ok('patch: reset sends null, an untouched high is omitted', reset.low === null && reset.box_order === null && !('high' in reset), JSON.stringify(reset))

ok('403 operator.workspaces is the hide signal', fleetLoadForbidden({ status: 403, permission: 'operator.workspaces', token: 'forbidden' }))
ok('CONTROL: a tenant.settings 403 is not this gate', !fleetLoadForbidden({ status: 403, permission: 'tenant.settings', token: 'forbidden' }))
ok('CONTROL: a 500 is not this gate', !fleetLoadForbidden({ status: 500, permission: 'operator.workspaces' }))
ok('bad_setting shows the hub detail', fleetLoadStatusDetail({ token: 'bad_setting', detail: FLEET_BAD_SETTING }) === FLEET_BAD_SETTING)
ok('CONTROL: another token does not borrow that sentence', fleetLoadStatusDetail({ token: 'forbidden', detail: 'no' }) === '')

ok('suggests distinct box ids from rows, then hours', suggestFleetBoxes({
  rows: [{ box: 'box-desk' }, { box: 'Box' }, { box: 'box-desk' }],
  hours: [{ box: 'box-a' }],
}).join() === 'box-desk,box-a')

ok('stored: 40/80 and two boxes', fleetStoredOk({ low: 40, high: 80, boxOrder: ['box-a', 'box-b'] }))
ok('stored: low 99 high 100', fleetStoredOk({ low: 99, high: 100, boxOrder: null }))
ok('CONTROL stored: low >= high, low 0, duplicate, 33 boxes',
  !fleetStoredOk({ low: 80, high: 70, boxOrder: null }) &&
  !fleetStoredOk({ low: 0, high: 75, boxOrder: null }) &&
  !fleetStoredOk({ low: 40, high: 80, boxOrder: ['box-a', 'box-a'] }) &&
  !fleetStoredOk({ low: 40, high: 80, boxOrder: Array.from({ length: 33 }, (_, i) => `b${i}`) }))

const applied = applyFleetPatch({ low: 40, high: 80, boxOrder: ['box-a'] }, { low: null })
ok('apply: null low resets, high and order stay', applied && applied.low === null && applied.high === 80 && applied.boxOrder.join() === 'box-a')
ok('apply: an empty order is stored as unset', applyFleetPatch({ low: null, high: null, boxOrder: ['box-a'] }, { box_order: [] }).boxOrder === null)
ok('CONTROL apply: low above high is refused and a string is not an int',
  applyFleetPatch({ low: 40, high: 80, boxOrder: null }, { low: 90, high: 70 }) === null &&
  applyFleetPatch({ low: null, high: null, boxOrder: null }, { low: '40' }) === null)

function mem(init = {}) {
  const m = new Map(Object.entries(init))
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)) },
  }
}
const guest = mem()
let threw = false
try { mockFleetRead(guest) } catch (e) { threw = fleetLoadForbidden(e) }
ok('mock: a workspace admin is 403 operator.workspaces', threw)
const op = mem({ [FLEET_OPERATOR_KEY]: '1' })
const opened = normalizeFleetLoad(mockFleetRead(op))
ok('mock: the operator admin reads the defaults', opened.low === 50 && opened.stored.low === null && opened.source === 'hub')
let bad = ''
try { mockFleetWrite({ low: 90, high: 60 }, op) } catch (e) { bad = fleetLoadStatusDetail(e) }
ok('mock: a bad band is 400 bad_setting with the hub sentence', bad === FLEET_BAD_SETTING && normalizeFleetLoad(mockFleetRead(op)).low === 50)
const saved = normalizeFleetLoad(mockFleetWrite({ low: 40, high: 80, box_order: ['box-b', 'box-a'] }, op))
ok('mock: a good patch is stored and read back', saved.low === 40 && saved.high === 80 && saved.boxOrder.join() === 'box-b,box-a' && saved.stored.low === 40)
const opThrows = { getItem: (k) => { if (k === FLEET_OPERATOR_KEY) return '1'; throw new Error('denied') } }
ok('mock: a throwing getItem on the stored row reads the defaults', normalizeFleetLoad(mockFleetRead(opThrows)).stored.low === null)
const opNull = { getItem: (k) => (k === FLEET_OPERATOR_KEY ? '1' : null) }
const opJsonNull = { getItem: (k) => (k === FLEET_OPERATOR_KEY ? '1' : 'null') }
ok('mock: an unset (null) or JSON-null stored row reads the defaults',
  normalizeFleetLoad(mockFleetRead(opNull)).stored.low === null && normalizeFleetLoad(mockFleetRead(opJsonNull)).stored.low === null)
const cleared = normalizeFleetLoad(mockFleetWrite({ low: null }, op))
ok('mock: null low is the default again, the rest stays', cleared.low === 50 && cleared.stored.low === null && cleared.high === 80 && cleared.boxOrder.join() === 'box-b,box-a')

// rdb 0134: per-box bands. A patch replaces the whole map, a bad entry is
// refused and leaves the row, null resets it, and the PATCH body sends the
// map only when it changed.
const banded = normalizeFleetLoad(mockFleetWrite({ boxes: { 'box-t': { low: 20, high: 40 }, 'box-s': { low: 60, high: 90 } } }, op))
ok('bands: a per-box band is stored and read back sorted by box',
  JSON.stringify(banded.boxes) === '[{"box":"box-s","low":60,"high":90},{"box":"box-t","low":20,"high":40}]' && banded.low === 50)
for (const b of [{ 'box-s': { low: 90, high: 60 } }, { 'Box-s': { low: 1, high: 2 } }, { 'box-s': { low: 10 } }, { 'box-s': { low: 10, high: 20, x: 1 } }]) {
  let refused = ''
  try { mockFleetWrite({ boxes: b }, op) } catch (e) { refused = fleetLoadStatusDetail(e) }
  ok(`bands: ${JSON.stringify(b)} is 400 bad_setting and leaves the row`,
    refused === FLEET_BAD_SETTING && normalizeFleetLoad(mockFleetRead(op)).boxes.length === 2)
}
ok('bands: fleetBandOk takes 1..99 / 2..100 with low < high',
  fleetBandOk({ box: 'box-s', low: 1, high: 100 }) && !fleetBandOk({ box: 'box-s', low: 50, high: 50 }) && !fleetBandOk({ box: '', low: 1, high: 2 }))
ok('bands: list and map round-trip', JSON.stringify(fleetBandList(fleetBandMap(banded.boxes))) === JSON.stringify(banded.boxes))
const draftOf = (v, extra) => ({ low: v.low, high: v.high, boxOrder: v.boxOrder, resetLow: false, resetHigh: false, resetOrder: false, boxes: v.boxes, ...extra })
ok('bands: an unchanged map (in any order) is left out of the PATCH',
  Object.keys(fleetLoadPatchBody(banded, draftOf(banded, { boxes: banded.boxes.slice().reverse() }))).length === 0)
ok('bands: a changed map is sent whole',
  JSON.stringify(fleetLoadPatchBody(banded, draftOf(banded, { boxes: [{ box: 'box-s', low: 70, high: 95 }] }))) === '{"boxes":{"box-s":{"low":70,"high":95}}}')
ok('bands: reset sends boxes null', fleetLoadPatchBody(banded, draftOf(banded, { resetBoxes: true })).boxes === null)
const unbanded = normalizeFleetLoad(mockFleetWrite({ boxes: null }, op))
ok('bands: null resets the map; the fleet band stays', unbanded.boxes.length === 0 && unbanded.stored.boxes === null && unbanded.high === 80)

const admin = normalizeMe({ human_id: 'HUM-1', role: 'admin', permissions: ['tenant.settings', 'members.invite'] })
const ids = (opts) => tenantSettingsSections(admin, opts).map((s) => s.id).join(',')
ok('nav: fleet load is absent until the probe succeeds', !ids({}).split(',').includes('fleet-load') && !ids({ mock: true }).split(',').includes('fleet-load'))
ok('nav: a successful probe appends Fleet load after the other sections', ids({ fleetLoad: true }).endsWith(',fleet-load') && ids({ mock: true, fleetLoad: true }).endsWith('fleet-load'))
ok('the fleet-load path is a section', tenantSettingsSectionOf('/fi/tenant-settings/fleet-load') === 'fleet-load')
ok('CONTROL: an unknown hyphenated path is still not a section', tenantSettingsSectionOf('/tenant-settings/not-real') === '')

const card = readFileSync(new URL('../../src/components/FleetLoadCard.vue', import.meta.url), 'utf8')
ok('card uses the settings save pattern and shows the hub detail',
  card.includes('useSettingSave') && card.includes('fleetLoadStatusDetail') && card.includes('data-test="tenant-fleet-error"'))
ok('card offers reset, reorder and the box field',
  card.includes('data-test="tenant-fleet-low-reset"') && card.includes('data-test="tenant-fleet-up"') && card.includes('data-test="tenant-fleet-add"'))
const client = readFileSync(new URL('../../src/utils/spool-client.mjs', import.meta.url), 'utf8')
ok('the live client keeps a 403 permission field', client.includes('err.permission = permission'))
const lazy = readFileSync(new URL('../../src/utils/spool-client-lazy.mjs', import.meta.url), 'utf8')
ok('the client calls GET and PATCH /v1/operator/fleet-load',
  lazy.includes("live('/v1/operator/fleet-load')") && lazy.includes("live('/v1/operator/fleet-load',"))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll fleet-load checks passed.')
