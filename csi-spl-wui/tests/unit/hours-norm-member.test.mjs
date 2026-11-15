// Spec 107 FR-41 per member (SPL-5558): a member's own average hours per day,
// WUI side - the call the People card makes, the mock as the hub answers it
// (own wins, null falls back, 0 is "no average", a peer keeps the
// workspace's), and the calendar's /v1/me/hours reading the self's
// effective norm.
// Run: node tests/unit/hours-norm-member.test.mjs
import { HOURS_MOCK_SELF, hoursMemberNormCall, mockMemberHoursNorm, mockSetHoursNorm, mockSetMemberHoursNorm } from '../../src/utils/hours-norm.mjs'
import { mockMyHours } from '../../src/utils/hours-calendar-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const mock = { mock: true, base: '' }
const PEER = 'HUM-2'

console.log('hours-norm-member')
mockSetHoursNorm(450)
let n = await hoursMemberNormCall(mock, HOURS_MOCK_SELF)
ok('no override: own null, the workspace\'s in force', n.norm_day_minutes === null && n.workspace_norm_day_minutes === 450 && n.effective_norm_day_minutes === 450 && n.max_minutes === 1440, JSON.stringify(n))

n = await hoursMemberNormCall(mock, HOURS_MOCK_SELF, 360)
ok('PUT 360: own 360 is in force over the workspace\'s 450', n.norm_day_minutes === 360 && n.effective_norm_day_minutes === 360 && n.workspace_norm_day_minutes === 450, JSON.stringify(n))
ok('the calendar (/v1/me/hours) reads the self\'s own norm', mockMyHours('2026-10-05', '2026-10-07').norm_day_minutes === 360)
ok('CONTROL: a peer keeps the workspace\'s', mockMemberHoursNorm(PEER).effective_norm_day_minutes === 450 && mockMemberHoursNorm(PEER).norm_day_minutes === null)

n = await hoursMemberNormCall(mock, HOURS_MOCK_SELF, 0)
ok('PUT 0: no average for this member, not the workspace\'s', n.norm_day_minutes === 0 && n.effective_norm_day_minutes === 0 && mockMyHours('2026-10-05', '2026-10-07').norm_day_minutes === 0, JSON.stringify(n))

n = await hoursMemberNormCall(mock, HOURS_MOCK_SELF, null)
ok('PUT null clears it: the workspace\'s is back', n.norm_day_minutes === null && n.effective_norm_day_minutes === 450 && mockMyHours('2026-10-05', '2026-10-07').norm_day_minutes === 450, JSON.stringify(n))

for (const bad of [-1, 1441, 7.5, '450']) {
  let token = ''
  try { mockSetMemberHoursNorm(HOURS_MOCK_SELF, bad) } catch (e) { token = e.token }
  ok(`CONTROL: the mock refuses ${JSON.stringify(bad)} as the hub does (400 bad_setting)`, token === 'bad_setting' && mockMemberHoursNorm(HOURS_MOCK_SELF).norm_day_minutes === null)
}

/* the real call: the path, the method and the body the hub expects */
const seen = []
const realFetch = globalThis.fetch
globalThis.fetch = async (url, init) => {
  seen.push({ url, method: init.method, body: init.body })
  return new Response(JSON.stringify({ member_id: 'h-1', norm_day_minutes: null, workspace_norm_day_minutes: 0, effective_norm_day_minutes: 0, max_minutes: 1440 }), { status: 200 })
}
await hoursMemberNormCall({ base: 'https://hub.example.com/' }, 'h 1')
await hoursMemberNormCall({ base: 'https://hub.example.com' }, 'h 1', null)
globalThis.fetch = async () => new Response(JSON.stringify({ error: 'forbidden', permission: 'hours.norm' }), { status: 403 })
let refused = null
try { await hoursMemberNormCall({ base: 'https://hub.example.com' }, 'h-1', 60) } catch (e) { refused = e }
globalThis.fetch = realFetch
ok('GET /v1/members/<id>/hours/norm, the id encoded', seen[0]?.url === 'https://hub.example.com/v1/members/h%201/hours/norm' && seen[0]?.method === 'GET' && seen[0]?.body === undefined, JSON.stringify(seen[0]))
ok('PUT with null sends {"norm_day_minutes":null}', seen[1]?.method === 'PUT' && seen[1]?.body === '{"norm_day_minutes":null}', JSON.stringify(seen[1]))
ok('a 403 throws the token tenantSettingsErrorKey reads', refused?.status === 403 && refused?.token === 'forbidden', String(refused))

mockSetHoursNorm(0)
const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll hours-norm-member checks passed.')
