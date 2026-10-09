// Spec 107 v1.2 T015 (owner R11): the Team and Download tabs of the
// calendar's hours panel - the members x days grid from one GET /v1/hours
// answer, its filters, the decision body, the export path and file name, and
// the mock's approve / return / export as the hub's T008 / T009.
// Run: node tests/unit/hours-team.test.mjs
import {
  HOURS_TEAM_KINDS, hoursDecision, hoursDownloadName, hoursExportPath, hoursPeriodDays, hoursTargetKind, hoursTeamGrid,
  hoursTeamKeeps, hoursTeamTopics,
} from '../../src/utils/hours-team.mjs'
import { decideTeamHours, downloadTeamHours, loadTeamHours } from '../../src/utils/hours-team-api.mjs'
import { mockDecideHours, mockExportHours, mockTeamHours } from '../../src/utils/hours-team-mock.mjs'
import { HOURS_MOCK_TOPIC } from '../../src/utils/hours-calendar-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

ok('target kinds: the hub\'s prefixes, unprefixed = other', hoursTargetKind('t:x') === 't' && hoursTargetKind('ch:lobby') === 'ch' && hoursTargetKind('dm:a') === 'dm' && hoursTargetKind('cal:m') === 'cal' && hoursTargetKind('ws') === 'ws' && hoursTargetKind('') === 'ws')
ok('the filter offers every kind once', HOURS_TEAM_KINDS.join() === 't,ch,dm,cal,ws')
ok('period days: start..end inclusive', hoursPeriodDays({ start: '2026-09-28', end: '2026-10-04' }).join() === '2026-09-28,2026-09-29,2026-09-30,2026-10-01,2026-10-02,2026-10-03,2026-10-04')
ok('period days: a bad period is none', hoursPeriodDays({ start: 'x', end: '2026-10-04' }).length === 0 && hoursPeriodDays(null).length === 0)

const body = {
  period: { start: '2026-10-05', end: '2026-10-11', freezes_at: '2026-10-14T00:00:00Z' },
  members: [
    { member_id: 'HUM-1', name: 'Member A', state: 'frozen', minutes: 330 },
    { member_id: 'HUM-2', name: 'Member B', state: 'returned', note: 'Tuesday twice', minutes: 60 },
    { member_id: 'HUM-3', name: '', state: 'open', minutes: 0 },
  ],
  entries: [
    { member_id: 'HUM-1', day: '2026-10-05', target: 't:aaa', minutes: 240 },
    { member_id: 'HUM-1', day: '2026-10-05', target: 'cal:sync', minutes: 30 },
    { member_id: 'HUM-1', day: '2026-10-06', target: 't:aaa', minutes: 60 },
    { member_id: 'HUM-2', day: '2026-10-06', target: 'ch:lobby', minutes: 60 },
    { member_id: 'HUM-9', day: '2026-10-06', target: 't:aaa', minutes: 15 },
    { member_id: 'HUM-1', day: '2026-12-01', target: 't:aaa', minutes: 15 },
  ],
}
{
  const g = hoursTeamGrid(body)
  ok('grid: one row per member, its state and note', g.rows.map((r) => `${r.member}:${r.state}`).join() === 'HUM-1:frozen,HUM-2:returned,HUM-3:open' && g.rows[1].note === 'Tuesday twice')
  ok('grid: a nameless member shows its id', g.rows[2].name === 'HUM-3')
  ok('grid: approved minutes per cell', g.rows[0].cells.slice(0, 2).join() === '270,60' && g.rows[1].cells[1] === 60, JSON.stringify(g.rows[0].cells))
  ok('grid: totals per row', g.rows.map((r) => r.total).join() === '330,60,0')
  ok('grid: totals per column and overall', g.cols.slice(0, 3).join() === '270,120,0' && g.total === 390, `${g.cols} ${g.total}`)
  ok('grid: an entry of an unknown member or outside the period is not counted', g.total === 390)
  ok('grid: per-target breakdown, most minutes first', g.rows[0].targets.map((t) => `${t.target}=${t.minutes}`).join() === 't:aaa=300,cal:sync=30')
  ok('grid: the frozen count drives Approve all / Return all', g.frozen === 1)
  ok('grid: seven day columns', g.days.length === 7)
}
{
  const g = hoursTeamGrid(body, { member: 'HUM-2' })
  ok('filter member: one row', g.rows.length === 1 && g.rows[0].member === 'HUM-2' && g.total === 60)
  const k = hoursTeamGrid(body, { kind: 'cal' })
  ok('filter kind: every member stays, only meetings count', k.rows.length === 3 && k.total === 30 && k.rows[0].total === 30)
  const t = hoursTeamGrid(body, { target: 't:aaa' })
  ok('filter topic / issue: only that target', t.total === 300 && t.rows[1].total === 0)
  ok('keeps: all three filters together', hoursTeamKeeps(body.entries[0], { member: 'HUM-1', kind: 't', target: 't:aaa' }) && !hoursTeamKeeps(body.entries[1], { member: 'HUM-1', kind: 't' }))
}
ok('topics for the issue filter: each t: target once', hoursTeamTopics(body).join() === 't:aaa')
ok('empty answer: an empty grid', hoursTeamGrid({}).rows.length === 0 && hoursTeamGrid({}).total === 0)

ok('decision: approve one member', JSON.stringify(hoursDecision('2026-10-05', 'approve', ['HUM-1'])) === '{"period":"2026-10-05","action":"approve","members":["HUM-1"]}')
ok('decision: Approve all names nobody', JSON.stringify(hoursDecision('2026-10-05', 'approve', [])) === '{"period":"2026-10-05","action":"approve"}')
ok('decision: a return carries its note, trimmed', JSON.stringify(hoursDecision('2026-10-05', 'return', null, ' fix Tue ')) === '{"period":"2026-10-05","action":"return","note":"fix Tue"}')

ok('export path: the T009 query', hoursExportPath('2026-10-05', 'xlsx', true) === '/v1/hours/export?period=2026-10-05&format=xlsx&final=true' && hoursExportPath('2026-10-05', 'other', false).endsWith('format=csv&final=false'))
ok('file name from Content-Disposition', hoursDownloadName('attachment; filename="hours-ws-2026-10-05-2026-10-11.csv"', 'x') === 'hours-ws-2026-10-05-2026-10-11.csv')
ok('file name: none or a path falls back', hoursDownloadName('', 'f.csv') === 'f.csv' && hoursDownloadName('attachment; filename="../x"', 'f.csv') === 'f.csv')

// the mock as the hub: the week of 2026-09-28 is frozen on 2026-10-09 (freezes 10-07 00:00)
{
  const today = '2026-10-09'
  const last = mockTeamHours('2026-09-30', today)
  ok('mock: the period holding the day, Monday first', last.period.start === '2026-09-28' && last.period.end === '2026-10-04')
  ok('mock: a passed week is frozen for every member', last.members.every((m) => m.state === 'frozen'), last.members.map((m) => m.state).join())
  ok('mock: this week is open', mockTeamHours(today, today).members.every((m) => m.state === 'open'))
  ok('mock: the entries hold no suggestion or raw minute field', last.entries.every((e) => Object.keys(e).every((k) => ['member_id', 'day', 'target', 'minutes', 'suggested_minutes', 'note'].includes(k))))
  ok('mock: a topic target is the calendar mock\'s topic', last.entries.some((e) => e.target === `t:${HOURS_MOCK_TOPIC}`))
  let refused = null
  try { mockDecideHours({ period: today, action: 'approve', members: ['HUM-1'] }, today) } catch (e) { refused = e }
  ok('mock: an open period is 409 period_state', refused && refused.status === 409 && refused.token === 'period_state')
  try { mockDecideHours({ period: '2026-09-30', action: 'return', members: ['HUM-2'] }, today); refused = null } catch (e) { refused = e }
  ok('mock: a return without a note is 400', refused && refused.status === 400)
  const after = mockDecideHours({ period: '2026-09-30', action: 'return', members: ['HUM-2'], note: 'Tuesday twice' }, today)
  ok('mock: return reopens that member only, with the note', after.changed === 1 && after.members.map((m) => m.state).join() === 'frozen,returned,frozen' && after.members[1].note === 'Tuesday twice')
  const all = mockDecideHours({ period: '2026-09-30', action: 'approve' }, today)
  ok('mock: Approve all moves the frozen rows only', all.changed === 2 && all.members.map((m) => m.state).join() === 'approved,returned,approved')
  const csv = mockExportHours('2026-09-30', 'csv', true, today)
  const lines = csv.bytes.trim().split('\r\n')
  ok('mock export: the spec\'s columns', lines[0] === 'date,member_id,member_name,target_type,target_id,target_name,issue_key,minutes,hours_decimal,suggested_minutes,note,period_state,approved_by,approved_at')
  ok('mock export: Final only = the approved members\' lines', lines.length > 1 && lines.slice(1).every((l) => l.includes(',approved,') && !l.includes('HUM-2')), lines.slice(1, 3).join(' | '))
  ok('mock export: Final off adds the returned member', mockExportHours('2026-09-30', 'csv', false, today).bytes.includes('HUM-2'))
  ok('mock export: the T009 file name and types', csv.disposition.includes('hours-mock-2026-09-28-2026-10-04.csv') && csv.type.startsWith('text/csv') && mockExportHours('2026-09-30', 'xlsx', true, today).type.includes('spreadsheetml'))
}

// the api module: the mock path and the hub path (a fake fetch)
{
  const got = await loadTeamHours({ mock: true }, '2026-09-30', '2026-10-09')
  ok('api: the mock answers GET /v1/hours', got.period.start === '2026-09-28')
  const calls = []
  globalThis.fetch = async (url, init = {}) => {
    calls.push({ url, init })
    if (String(url).includes('/export')) return new Response('a,b\r\n', { status: 200, headers: { 'content-disposition': 'attachment; filename="hours-t1-2026-09-28-2026-10-04.csv"' } })
    if (init.method === 'PUT') return new Response(JSON.stringify({ error: 'period_state' }), { status: 409 })
    return new Response(JSON.stringify(body), { status: 200 })
  }
  const api = { base: 'https://hub.example.com/', token: 'tok', credentials: 'include' }
  const live = await loadTeamHours(api, '2026-10-05', '2026-10-09')
  ok('api: GET /v1/hours?period= with the bearer', calls[0].url === 'https://hub.example.com/v1/hours?period=2026-10-05' && calls[0].init.headers.authorization === 'Bearer tok' && live.members.length === 3)
  let err = null
  try { await decideTeamHours(api, hoursDecision('2026-10-05', 'approve', ['HUM-1']), '2026-10-09') } catch (e) { err = e }
  ok('api: PUT /v1/hours/periods, a 409 carries its token', calls[1].url.endsWith('/v1/hours/periods') && calls[1].init.method === 'PUT' && JSON.parse(calls[1].init.body).members[0] === 'HUM-1' && err && err.status === 409 && err.token === 'period_state')
  const file = await downloadTeamHours(api, '2026-10-05', 'csv', true, '2026-10-09')
  ok('api: the download keeps the hub\'s file name', file.name === 'hours-t1-2026-09-28-2026-10-04.csv' && calls[2].url.endsWith('/v1/hours/export?period=2026-10-05&format=csv&final=true') && (await file.blob.text()) === 'a,b\r\n')
}

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll hours-team checks passed.')
