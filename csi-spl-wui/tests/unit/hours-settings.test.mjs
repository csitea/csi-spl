// Spec 107 T016: the hours settings, WUI side - the four workspace keys read
// from the 098 `settings` map with the hub's defaults and ranges, the PATCH
// map of what changed, the mock hub's rule (every key checked before any is
// written, null resets), and the "Count my reading time" claim (null = on).
// Run: node tests/unit/hours-settings.test.mjs
import { HOURS_DEFAULTS, HOURS_KEY_GRACE, HOURS_KEY_IDLE, HOURS_KEY_PERIOD, HOURS_KEY_TZ, HOURS_PERIOD_OPTIONS, hoursReadingOn, hoursSettingsOf, hoursSettingsPatch, hoursSettingValid } from '../../src/utils/hours-settings.mjs'
import { createMockTenant } from '../../src/utils/tenant-settings-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const throws = (fn, token) => { try { fn(); return false } catch (e) { return e.token === token } }
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

console.log('hours-settings')
ok('the keys are the hub registry (store/hours.go)', [HOURS_KEY_PERIOD, HOURS_KEY_GRACE, HOURS_KEY_IDLE, HOURS_KEY_TZ].join() === 'hours.period,hours.freeze_grace_days,hours.idle_minutes,hours.tz')
ok('the period choices', HOURS_PERIOD_OPTIONS.join() === 'week,two_weeks,month')
ok('no settings map = the hub defaults', same(hoursSettingsOf(undefined), { period: 'week', graceDays: 2, idleMinutes: 10, tz: 'UTC' }))
const read = hoursSettingsOf({ 'hours.period': 'month', 'hours.freeze_grace_days': 0, 'hours.idle_minutes': 30, 'hours.tz': 'Europe/Helsinki', 'other.key': 1 })
ok('a full map is read as is', same(read, { period: 'month', graceDays: 0, idleMinutes: 30, tz: 'Europe/Helsinki' }), JSON.stringify(read))
const junk = hoursSettingsOf({ 'hours.period': 'year', 'hours.freeze_grace_days': 8, 'hours.idle_minutes': 4.5, 'hours.tz': ' ' })
ok('CONTROL: junk and out-of-range values are the defaults', same(junk, { ...HOURS_DEFAULTS }), JSON.stringify(junk))

const stored = hoursSettingsOf({})
ok('an unchanged form patches nothing', same(hoursSettingsPatch(stored, { ...stored }), {}))
ok('the period alone', same(hoursSettingsPatch(stored, { ...stored, period: 'month' }), { 'hours.period': 'month' }))
ok('number inputs arrive as strings and patch as integers', same(hoursSettingsPatch(stored, { ...stored, graceDays: '3', idleMinutes: '15' }), { 'hours.freeze_grace_days': 3, 'hours.idle_minutes': 15 }))
ok('the zone is trimmed', same(hoursSettingsPatch(stored, { ...stored, tz: ' Europe/Stockholm ' }), { 'hours.tz': 'Europe/Stockholm' }))

ok('valid: month', hoursSettingValid('hours.period', 'month'))
ok('CONTROL: year is no period', !hoursSettingValid('hours.period', 'year'))
ok('grace 0..7', hoursSettingValid('hours.freeze_grace_days', 0) && hoursSettingValid('hours.freeze_grace_days', 7) && !hoursSettingValid('hours.freeze_grace_days', 8))
ok('idle 5..30, integers', hoursSettingValid('hours.idle_minutes', 5) && !hoursSettingValid('hours.idle_minutes', 31) && !hoursSettingValid('hours.idle_minutes', 10.5))
ok('an unknown key is refused', !hoursSettingValid('hours.nope', 1))

const m = createMockTenant()
ok('the mock answers the four keys at their defaults', same(hoursSettingsOf(m.settings().settings), { ...HOURS_DEFAULTS }))
m.patch({ settings: { 'hours.period': 'month' } })
ok('the mock stores month and reads it back', m.settings().settings['hours.period'] === 'month')
ok('CONTROL: a bad value is 400 bad_setting', throws(() => m.patch({ settings: { 'hours.idle_minutes': 99 } }), 'bad_setting'))
ok('... and writes no field of that PATCH', throws(() => m.patch({ settings: { 'hours.freeze_grace_days': 5, 'hours.idle_minutes': 99 } }), 'bad_setting') &&
  m.settings().settings['hours.freeze_grace_days'] === 2)
ok('CONTROL: an unregistered key is refused', throws(() => m.patch({ settings: { 'hours.nope': 1 } }), 'bad_setting'))
m.patch({ settings: { 'hours.period': null } })
ok('null resets a key to its default', m.settings().settings['hours.period'] === 'week')

ok('reading: never picked (null / undefined) is on', hoursReadingOn(null) && hoursReadingOn(undefined))
ok('reading: true is on', hoursReadingOn(true))
ok('CONTROL: reading false is off', !hoursReadingOn(false))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll hours-settings checks passed.')
