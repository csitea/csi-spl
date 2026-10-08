// Fleet load card (rdb 0118): the reader, the PATCH body (null resets a
// field), the operator.workspaces gate, the mock hub, and the nav entry
// that appears only after the probe succeeds.
// Run: node tests/unit/fleet-load.test.mjs
import { readFileSync } from 'node:fs'
import {
  FLEET_AGENT_KINDS,
  FLEET_BAD_SETTING,
  FLEET_OPERATOR_KEY,
  applyFleetPatch,
  boxLoadPct,
  fleetBandList,
  fleetBandMap,
  fleetBandOk,
  fleetBoxBandOf,
  fleetBoxBandPatch,
  fleetKindList,
  fleetKindsOk,
  fleetPauseList,
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

// t1 05e0fa03: the Boxes view sets ONE box's band. Only that entry changes;
// the other bands, the fleet band and the box order are untouched.
const many = normalizeFleetLoad({
  low: 40, high: 80, box_order: ['box-c', 'box-s'], boxes: { 'box-s': { low: 30, high: 60 }, 'box-z': { low: 10, high: 20 } }, source: 'hub',
  stored: { low: 40, high: 80, box_order: ['box-c', 'box-s'], boxes: { 'box-s': { low: 30, high: 60 }, 'box-z': { low: 10, high: 20 } } },
  defaults: { low: 50, high: 75, box_order: [] },
})
ok('box band: a box without one uses the fleet band (null)', fleetBoxBandOf(many, 'box-c') === null)
ok('box band: a box with one reads it', JSON.stringify(fleetBoxBandOf(many, 'box-s')) === '{"low":30,"high":60}')
const setC = fleetBoxBandPatch(many, 'box-c', { low: 40, high: 70 })
ok('box band: set sends only boxes, with this box added and the others as they were',
  JSON.stringify(Object.keys(setC)) === '["boxes"]' &&
  JSON.stringify(fleetBandList(setC.boxes)) === '[{"box":"box-c","low":40,"high":70},{"box":"box-s","low":30,"high":60},{"box":"box-z","low":10,"high":20}]', JSON.stringify(setC))
const editS = fleetBoxBandPatch(many, 'box-s', { low: 35, high: 65 })
ok('box band: editing one box keeps every other band',
  editS.boxes['box-s'].low === 35 && editS.boxes['box-s'].high === 65 && editS.boxes['box-z'].low === 10 && !('low' in editS) && !('box_order' in editS), JSON.stringify(editS))
const resetS = fleetBoxBandPatch(many, 'box-s', null)
ok('box band: reset removes only this box',
  JSON.stringify(resetS) === JSON.stringify({ boxes: { 'box-z': { low: 10, high: 20 } } }), JSON.stringify(resetS))
ok('box band: an unchanged band sends nothing', Object.keys(fleetBoxBandPatch(many, 'box-s', { low: 30, high: 60 })).length === 0)
ok('CONTROL: resetting a box with no band sends nothing', Object.keys(fleetBoxBandPatch(many, 'box-c', null)).length === 0)
ok('CONTROL: a bad box id sends nothing', Object.keys(fleetBoxBandPatch(many, 'Bad Box', { low: 1, high: 2 })).length === 0)
const onlyOne = normalizeFleetLoad({ low: 50, high: 75, box_order: [], boxes: { 'box-c': { low: 40, high: 70 } }, stored: { boxes: { 'box-c': { low: 40, high: 70 } } } })
ok('box band: resetting the last band sends an empty map (the hub stores unset)', JSON.stringify(fleetBoxBandPatch(onlyOne, 'box-c', null)) === '{"boxes":{}}')
// the mock hub plays it end to end: set box-c, the other band stays; reset box-c, gone
const boxStore = mem({ [FLEET_OPERATOR_KEY]: '1' })
mockFleetWrite({ boxes: { 'box-s': { low: 30, high: 60 } }, low: 45 }, boxStore)
const afterSet = normalizeFleetLoad(mockFleetWrite(fleetBoxBandPatch(normalizeFleetLoad(mockFleetRead(boxStore)), 'box-c', { low: 40, high: 70 }), boxStore))
ok('mock: setting box-c keeps box-s and the fleet low', JSON.stringify(afterSet.boxes) === '[{"box":"box-c","low":40,"high":70},{"box":"box-s","low":30,"high":60}]' && afterSet.low === 45, JSON.stringify(afterSet))
const afterReset = normalizeFleetLoad(mockFleetWrite(fleetBoxBandPatch(afterSet, 'box-c', null), boxStore))
ok('mock: resetting box-c leaves box-s only', JSON.stringify(afterReset.boxes) === '[{"box":"box-s","low":30,"high":60}]', JSON.stringify(afterReset))
let refused = ''
try { mockFleetWrite(fleetBoxBandPatch(afterReset, 'box-c', { low: 70, high: 40 }), boxStore) } catch (e) { refused = e.token }
ok('CONTROL: low >= high on one box is refused (bad_setting)', refused === 'bad_setting', refused)
ok('box load %: load5 / cpus as box-pick reads it', boxLoadPct({ load5: 0.9, cpus: 8 }) === 11 && boxLoadPct({ load5: 4, cpus: 4 }) === 100)
ok('CONTROL: box load % without a sample or cpus is null', boxLoadPct(null) === null && boxLoadPct({ load5: 1, cpus: 0 }) === null)
const page = readFileSync(new URL('../../src/pages/boxes/[id].vue', import.meta.url), 'utf8')
ok('the Boxes page loads the band block lazily', /defineAsyncComponent\(\(\) => import\('@\/components\/BoxLoadBand\.vue'\)\)/.test(page) && !/^import .*BoxLoadBand/m.test(page))

// rdb 0149: agent kinds off, and the timed pauses a box reports.
ok('kinds: the five kinds, in the hub order (spec 110)', FLEET_AGENT_KINDS.join() === 'claude,grok,agy,qwen,mistral')
ok('kinds: a list keeps known kinds, distinct, in order', fleetKindList(['qwen', 'gpt', 'grok', 'grok']).join() === 'grok,qwen')
ok('kinds: every kind off is refused, three off is fine', !fleetKindsOk(FLEET_AGENT_KINDS) && fleetKindsOk(['claude', 'grok', 'agy']))
ok('CONTROL kinds: the old four off leaves mistral on, so it is fine', fleetKindsOk(['claude', 'grok', 'agy', 'qwen']) && fleetKindList(['mistral', 'qwen']).join() === 'qwen,mistral')
const kinds = normalizeFleetLoad({
  low: 50, high: 75, box_order: [], agent_kinds_off: ['grok'],
  agent_kinds_paused: { agy: { until: '2026-10-08T01:00:00Z', reason: 'usage limit', box: 'box-t' }, gpt: { until: 'x' } },
  stored: { agent_kinds_off: ['grok'] },
})
ok('reader: kinds off and the paused kinds (junk dropped)',
  kinds.kindsOff.join() === 'grok' && kinds.paused.length === 1 && kinds.paused[0].kind === 'agy' && kinds.paused[0].box === 'box-t', JSON.stringify(kinds))
ok('reader: nothing off and nothing paused by default', fresh.kindsOff.length === 0 && fresh.paused.length === 0)
ok('pause list: {kind: {until}} only', fleetPauseList({ grok: { until: '' }, qwen: { until: 't' } }).map((p) => p.kind).join() === 'qwen')
const kindDraft = { low: 50, high: 75, boxOrder: [], resetLow: false, resetHigh: false, resetOrder: false }
ok('patch: switching grok off sends the whole set', JSON.stringify(fleetLoadPatchBody(fresh, { ...kindDraft, kindsOff: ['grok'] })) === '{"agent_kinds_off":["grok"]}')
ok('patch: switching it back on sends an empty set', JSON.stringify(fleetLoadPatchBody(kinds, { ...kindDraft, kindsOff: [] })) === '{"agent_kinds_off":[]}')
ok('CONTROL: an unchanged set, or a draft with no kinds, sends nothing',
  Object.keys(fleetLoadPatchBody(kinds, { ...kindDraft, kindsOff: ['grok'] })).length === 0 && Object.keys(fleetLoadPatchBody(kinds, kindDraft)).length === 0)
ok('patch: resume sends null for that kind only', JSON.stringify(fleetLoadPatchBody(kinds, { ...kindDraft, kindsOff: ['grok'], lift: ['agy', 'qwen'] })) === '{"agent_kinds_paused":{"agy":null}}')
const kindStore = mem({ [FLEET_OPERATOR_KEY]: '1' })
const kOff = normalizeFleetLoad(mockFleetWrite({ agent_kinds_off: ['grok', 'qwen'] }, kindStore))
ok('mock: kinds off are stored and read back', kOff.kindsOff.join() === 'grok,qwen' && normalizeFleetLoad(mockFleetRead(kindStore)).kindsOff.join() === 'grok,qwen')
let allOff = ''
try { mockFleetWrite({ agent_kinds_off: FLEET_AGENT_KINDS }, kindStore) } catch (e) { allOff = e.token }
ok('CONTROL: every kind off is refused (bad_setting), the row stays', allOff === 'bad_setting' && normalizeFleetLoad(mockFleetRead(kindStore)).kindsOff.join() === 'grok,qwen', allOff)
let bogus = ''
try { mockFleetWrite({ agent_kinds_off: ['gpt'] }, kindStore) } catch (e) { bogus = e.token }
ok('CONTROL: an unknown kind is refused', bogus === 'bad_setting', bogus)
kindStore.setItem('spool.mock.fleet_load', JSON.stringify({ agent_kinds_off: ['grok'], agent_kinds_paused: { agy: { until: '2099-01-01T00:00:00Z', reason: 'usage limit', box: 'b' } } }))
const lifted = normalizeFleetLoad(mockFleetWrite({ agent_kinds_paused: { agy: null } }, kindStore))
ok('mock: resume lifts the pause and keeps the kinds off', lifted.paused.length === 0 && lifted.kindsOff.join() === 'grok', JSON.stringify(lifted))

// rdb 0152 (t1 338e5258): runner_cpu_pct, fleet-wide and per box. The hub
// replaces the whole boxes map, so a band save must carry a box's own cap.
const cpuView = normalizeFleetLoad({ low: 50, high: 75, runner_cpu_pct: 70, boxes: { 'box-s': { low: 30, high: 60, runner_cpu_pct: 60 }, 'box-z': { low: 10, high: 20 } } })
ok('cpu: the view reads the fleet cap and a per-box cap', cpuView.runnerCpuPct === 70 &&
  JSON.stringify(cpuView.boxes) === '[{"box":"box-s","low":30,"high":60,"runnerCpuPct":60},{"box":"box-z","low":10,"high":20}]', JSON.stringify(cpuView))
ok('cpu: the fleet cap defaults to 80', normalizeFleetLoad({}).runnerCpuPct === 80 && normalizeFleetLoad({}).defaults.runnerCpuPct === 80)
const keepCpu = fleetBoxBandPatch(cpuView, 'box-s', { low: 35, high: 65 })
ok('cpu: saving a box band keeps its own runner_cpu_pct', JSON.stringify(keepCpu) === '{"boxes":{"box-z":{"low":10,"high":20},"box-s":{"low":35,"high":65,"runner_cpu_pct":60}}}', JSON.stringify(keepCpu))
const otherCpu = fleetBoxBandPatch(cpuView, 'box-c', { low: 40, high: 70 })
ok('cpu: saving another box band keeps box-s\'s cap', Boolean(otherCpu.boxes) && otherCpu.boxes['box-s'].runner_cpu_pct === 60 && !('runner_cpu_pct' in otherCpu.boxes['box-c']), JSON.stringify(otherCpu))
const cpuDraft = (extra) => ({ low: 50, high: 75, boxOrder: [], resetLow: false, resetHigh: false, resetOrder: false, ...extra })
ok('cpu: an unchanged draft sends nothing', Object.keys(fleetLoadPatchBody(cpuView, cpuDraft({ boxes: cpuView.boxes, runnerCpuPct: 70 }))).length === 0)
ok('cpu: a fleet cap edit sends runner_cpu_pct; a reset sends null',
  fleetLoadPatchBody(cpuView, cpuDraft({ runnerCpuPct: 90 })).runner_cpu_pct === 90 &&
  fleetLoadPatchBody(cpuView, cpuDraft({ runnerCpuPct: 80, resetCpu: true })).runner_cpu_pct === null)
const clearCpu = fleetLoadPatchBody(cpuView, cpuDraft({ boxes: [{ box: 'box-s', low: 30, high: 60, runnerCpuPct: null }, { box: 'box-z', low: 10, high: 20 }] }))
ok('cpu: clearing a box cap sends that band without runner_cpu_pct', JSON.stringify(clearCpu) === '{"boxes":{"box-s":{"low":30,"high":60},"box-z":{"low":10,"high":20}}}', JSON.stringify(clearCpu))
ok('cpu: a box cap 1..100 passes; 0, 101 and 1.5 do not', fleetBandOk({ box: 'b', low: 1, high: 2, runnerCpuPct: 100 }) &&
  !fleetBandOk({ box: 'b', low: 1, high: 2, runnerCpuPct: 0 }) && !fleetBandOk({ box: 'b', low: 1, high: 2, runnerCpuPct: 101 }) &&
  !fleetBandOk({ box: 'b', low: 1, high: 2, runnerCpuPct: 1.5 }))
const cpuStore = mem({ [FLEET_OPERATOR_KEY]: '1' })
mockFleetWrite({ runner_cpu_pct: 70, boxes: { 'box-s': { low: 30, high: 60, runner_cpu_pct: 60 } } }, cpuStore)
const cpuSaved = normalizeFleetLoad(mockFleetWrite(fleetBoxBandPatch(normalizeFleetLoad(mockFleetRead(cpuStore)), 'box-s', { low: 35, high: 65 }), cpuStore))
ok('mock: a band save keeps the box cap and the fleet cap', cpuSaved.runnerCpuPct === 70 && cpuSaved.boxes[0].runnerCpuPct === 60 && cpuSaved.boxes[0].low === 35, JSON.stringify(cpuSaved))
let cpuBad = ''
try { mockFleetWrite({ runner_cpu_pct: 0 }, cpuStore) } catch (e) { cpuBad = e.token }
ok('CONTROL: mock refuses a fleet cap of 0', cpuBad === 'bad_setting', cpuBad)
ok('mock: runner_cpu_pct null resets the fleet cap to 80', normalizeFleetLoad(mockFleetWrite({ runner_cpu_pct: null }, cpuStore)).runnerCpuPct === 80)

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll fleet-load checks passed.')
