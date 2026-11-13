// Spec 107 FR-41 (SPL-5440, section 22): the workspace's average hours per
// day, WUI side - what a person types becomes minutes, how far a day is
// above the norm, the calendar index carries it per day, the mock keeps it,
// and Tenant settings -> Hours opens for hours.norm (the product owner)
// as well as tenant.settings.
// Run: node tests/unit/hours-norm.test.mjs
import { HOURS_KEY_NORM, HOURS_NORM_MAX, HOURS_NORM_PERM, hoursNormCall, hoursNormOf, hoursNormParse, hoursOverNorm, mockHoursNorm, mockSetHoursNorm } from '../../src/utils/hours-norm.mjs'
import { hoursIndex } from '../../src/utils/hours-calendar.mjs'
import { mockMyHours } from '../../src/utils/hours-calendar-mock.mjs'
import { importTs } from './lib/load-ts.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const { tenantSettingsSections } = await importTs('src/utils/tenant-settings-nav.ts')

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('hours-norm')
ok('the key, the permission and the cap are the hub\'s (store/hours.go, rbac.go)', HOURS_KEY_NORM === 'hours.norm_day_minutes' && HOURS_NORM_PERM === 'hours.norm' && HOURS_NORM_MAX === 1440)

const parsed = { '7:30': 450, '7.5': 450, '7,5': 450, 8: 480, '0:00': 0, '': 0, ' 7:05 ': 425, '24:00': 1440, '7.25': 435 }
for (const [s, want] of Object.entries(parsed)) ok(`parse ${JSON.stringify(s)} = ${want}`, hoursNormParse(s) === want, String(hoursNormParse(s)))
for (const s of ['24:01', '25', '7:60', 'abc', '-1', '7:3', '1.234']) ok(`CONTROL: parse ${JSON.stringify(s)} is refused`, Number.isNaN(hoursNormParse(s)), String(hoursNormParse(s)))

ok('an answer\'s norm: junk and out of range = 0', hoursNormOf(450) === 450 && hoursNormOf('450') === 450 && hoursNormOf(-5) === 0 && hoursNormOf(1441) === 0 && hoursNormOf(7.5) === 0 && hoursNormOf(null) === 0)
ok('over: 8:00 on a 7:30 norm is 0:30', hoursOverNorm(480, 450) === 30)
ok('over: at the norm or under is 0', hoursOverNorm(450, 450) === 0 && hoursOverNorm(300, 450) === 0)
ok('CONTROL: no norm (0) never warns', hoursOverNorm(1440, 0) === 0)

const idx = hoursIndex([{ norm_day_minutes: 450, period: { state: 'open' }, days: [{ date: '2026-10-05', rows: [{ target: 't:a', state: 'approved', minutes: 500 }] }] }])
const d = idx.get('2026-10-05')
ok('the index carries the norm per day', d && d.norm === 450 && hoursOverNorm(d.total, d.norm) === 50, JSON.stringify(d))
ok('CONTROL: an answer without the field reads no norm', hoursIndex([{ days: [{ date: '2026-10-05', rows: [] }] }]).get('2026-10-05').norm === 0)

ok('the mock starts with no norm', mockHoursNorm() === 0 && mockMyHours('2026-10-05', '2026-10-07').norm_day_minutes === 0)
const put = await hoursNormCall({ mock: true, base: '' }, 420)
ok('the mock PUT keeps it and GET /v1/me/hours reads it', put.norm_day_minutes === 420 && mockMyHours('2026-10-05', '2026-10-07').norm_day_minutes === 420, JSON.stringify(put))
let refused = ''
try { mockSetHoursNorm(1441) } catch (e) { refused = e.token }
ok('CONTROL: the mock refuses 1441 as the hub does (400 bad_setting)', refused === 'bad_setting' && mockHoursNorm() === 420)
mockSetHoursNorm(0)

const ids = (perms) => tenantSettingsSections({ permissions: perms }).map((s) => s.id)
ok('the product owner (hours.norm, no tenant.settings) sees Hours alone', ids(['hours.norm']).join() === 'hours', ids(['hours.norm']).join())
ok('an admin still sees Hours', ids(['tenant.settings', 'hours.norm']).includes('hours'))
ok('CONTROL: a developer sees no Hours', !ids(['topics.read']).includes('hours'))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll hours-norm checks passed.')
