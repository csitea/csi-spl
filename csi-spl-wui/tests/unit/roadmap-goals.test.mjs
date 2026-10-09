// Spec 112 WUI-3 (5.3 (a), 6, 12.6): the goal rows, the workspace filter and
// the goal page's numbers, pure (utils/roadmap-goals.mjs), and the mock's
// synced-event fixtures (utils/roadmap-goals-mock.mjs).
//   - goal:<id>: events -> goals (deadline, milestones, specs, done-lines);
//     share-done and mean pct over roadmap.json's spec rows (6);
//   - 5.3 (a): a spec row matches a window when a goal it serves has its
//     deadline or a milestone in it; ?goal= keeps that goal's specs;
//   - 12.6: the filter lists the viewer's memberships only; signed out, the
//     host's workspace only when its roadmap is public.
//     CONTROL: workspace B, which the viewer is not in, never appears in the
//     filter, and a ?ws=B is `blocked` (never read); the mock refuses B's
//     events to a member of A only (403).
//     CONTROL: signed out, an `internal` roadmap answers no goal event.
//
// Run: node tests/unit/roadmap-goals.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  goalCalendarHref, goalDaysLeft, goalInWindow, goalProgress, roadmapGoalId, roadmapGoalSpecRows,
  roadmapGoals, roadmapPickWs, roadmapWorkspaces, roadmapWs,
} from '../../src/utils/roadmap-goals.mjs'
import { MOCK_GOAL_WS, MOCK_ROADMAP_PUBLIC_KEY, mockGoalEvents, mockGoalFixture, mockPublicGoalEvents } from '../../src/utils/roadmap-goals-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

const today = '2026-10-08' // a Thursday
const day = (iso) => String(iso).slice(0, 10)

/* ── events -> goals ─────────────────────────────────────────────────── */
const events = [
  { id: 'e1', source_key: 'goal:G01:deadline', title: 'G01 big', starts_at: '2026-11-20T12:00:00Z', audience: 'internal', roadmap_url: '/roadmap?ws=a&goal=G01#spec-089', specs: ['089', '112-goals', 7], done_lines: ['one', ' ', 'two'] },
  { id: 'e2', source_key: 'goal:G01:m:beta', title: 'beta', starts_at: '2026-10-09T12:00:00Z' },
  { id: 'e3', source_key: 'goal:G02:deadline', title: 'G02', starts_at: '2027-03-01T12:00:00Z', specs: ['003'] },
  { id: 'e4', source_key: 'spec:089:done', title: 'not a goal', starts_at: '2026-10-08T12:00:00Z' },
  { id: 'e5', source_key: 'goal:G03:deadline', title: 'no date', starts_at: '' },
]
const goals = roadmapGoals(events)
ok('one goal per goal id, goal: keys only, a bad date dropped', JSON.stringify(goals.map((g) => g.id)) === '["G01","G02"]', JSON.stringify(goals.map((g) => g.id)))
const g1 = goals[0]
ok('the deadline event gives title, deadline, event id, roadmap link', g1.title === 'G01 big' && g1.deadline === '2026-11-20T12:00:00Z' && g1.eventId === 'e1' && g1.roadmapUrl.startsWith('/roadmap?ws=a'))
ok('specs read as three-digit ids', JSON.stringify(g1.specs) === '["089","112","007"]', JSON.stringify(g1.specs))
ok('done-lines drop blanks', JSON.stringify(g1.doneLines) === '["one","two"]', JSON.stringify(g1.doneLines))
ok('a milestone joins its goal', g1.milestones.length === 1 && g1.milestones[0].key === 'beta')

/* ── progress (6) ────────────────────────────────────────────────────── */
const specRows = [
  { id: '003-c', state: 'planned', pct: 0 },
  { id: '007-a', state: 'done', pct: 100 },
  { id: '089-b', state: 'in-progress', pct: 45 },
  { id: '120-z', state: 'done', pct: 100 },
]
const p = goalProgress(g1, specRows)
ok('share-done = done linked / linked found (1 of 2 = 50)', p.shareDone === 50 && p.done === 1 && p.linked.length === 2, JSON.stringify(p))
ok('mean pct = floor of the mean (100+45)/2 = 72', p.meanPct === 72, String(p.meanPct))
ok('no linked spec -> null, not 0', goalProgress({ specs: ['999'] }, specRows).shareDone === null)
ok('countdown: 43 days left', goalDaysLeft(g1.deadline, today, day) === 43, String(goalDaysLeft(g1.deadline, today, day)))
ok('countdown: passed reads negative', goalDaysLeft('2026-10-01T00:00:00Z', today, day) === -7)

/* ── 5.3 (a) and ?goal= ──────────────────────────────────────────────── */
const specs = [
  { id: '003-c', tasks_changed: '' },
  { id: '007-a', tasks_changed: '2026-01-01T00:00:00Z' },
  { id: '089-b', tasks_changed: '' },
  { id: '120-z', tasks_changed: '2026-10-07T09:00:00Z' },
]
const ids = (rows) => rows.map((s) => s.id.slice(0, 3)).join(',')
ok('G01 has a milestone this week', goalInWindow(g1, 'week', today, day) && !goalInWindow(goals[1], 'month', today, day))
ok('week: (b) 120 changed + (a) G01 specs 007, 089', ids(roadmapGoalSpecRows(specs, goals, { when: 'week', goal: '', today, dayOf: day })) === '007,089,120')
ok('CONTROL: without goals the week is 120 only (WUI-1 rule b)', ids(roadmapGoalSpecRows(specs, [], { when: 'week', goal: '', today, dayOf: day })) === '120')
ok('?goal=G02 keeps its specs only', ids(roadmapGoalSpecRows(specs, goals, { when: '', goal: 'G02', today, dayOf: day })) === '003')
ok('?goal= of an unknown goal shows none', roadmapGoalSpecRows(specs, goals, { when: '', goal: 'G09', today, dayOf: day }).length === 0)
ok('?goal= parses G01 and G01-first-million; junk is ""', roadmapGoalId('G01') === 'G01' && roadmapGoalId(['g01-first-million']) === 'G01' && roadmapGoalId('x') === '')
ok('?ws= parses a slug only', roadmapWs('Demo') === 'demo' && roadmapWs('../x') === '')

/* ── 12.6: the workspace filter ──────────────────────────────────────── */
const memberA = { hum: 'HUM-1', t: 'demo', tenants: [{ tenant_id: 'demo', name: 'Demo' }] }
const inA = roadmapWorkspaces({ signedOut: false, claims: memberA, tenant: 'demo', hostPublic: false })
ok('member of A: the filter lists A', JSON.stringify(inA.options) === '[{"id":"demo","label":"Demo"}]' && inA.active === 'demo', JSON.stringify(inA))
ok('CONTROL: workspace B never appears in the filter', !inA.options.some((o) => o.id === MOCK_GOAL_WS.b))
ok('CONTROL: ?ws=B is blocked and A is shown', JSON.stringify(roadmapPickWs(inA, MOCK_GOAL_WS.b)) === '{"ws":"demo","blocked":"beta-ws"}')
const two = roadmapWorkspaces({ signedOut: false, claims: { active_tenant: 'b2', tenants: [{ tenant_id: 'a1' }, { tenant_id: 'b2', display_name: 'Bee' }] }, tenant: '', hostPublic: false })
ok('two memberships: both, the active one picked', two.options.length === 2 && two.active === 'b2' && roadmapPickWs(two, 'a1').ws === 'a1')
ok('no claims (mock): the client workspace', roadmapWorkspaces({ signedOut: false, claims: null, tenant: 'demo', hostPublic: false }).active === 'demo')
ok('signed out, internal roadmap: nothing listed', roadmapWorkspaces({ signedOut: true, claims: null, tenant: 'demo', hostPublic: false }).options.length === 0)
ok('signed out, public roadmap: the host only', JSON.stringify(roadmapWorkspaces({ signedOut: true, claims: memberA, tenant: 'demo', hostPublic: true }).options.map((o) => o.id)) === '["demo"]')
ok('calendar link /calendar?d=&event=, none without an id', goalCalendarHref('2026-11-20T12:00:00Z', 'e1', day) === '/calendar?d=2026-11-20&event=e1' && goalCalendarHref('2026-11-20T12:00:00Z', '', day) === '')

/* ── the mock's synced-event fixtures ────────────────────────────────── */
const store = new Map()
globalThis.localStorage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) }
ok('A has G01 (deadline + milestone) and G02', JSON.stringify(roadmapGoals(mockGoalFixture('demo', today)).map((g) => g.id)) === '["G01","G02"]')
ok('every fixture event names no audience but the switch sets it', mockGoalFixture('demo', today).every((e) => e.audience === 'internal'))
ok('member of A reads A', mockGoalEvents('demo', ['demo']).events.length === 3)
let refused = 0
try { mockGoalEvents(MOCK_GOAL_WS.b, ['demo']) } catch (e) { refused = e.status }
ok('CONTROL: a member of A only is refused B (403)', refused === 403, String(refused))
ok('CONTROL: signed out, an internal roadmap answers no goal event', mockPublicGoalEvents('demo').events.length === 0)
store.set(MOCK_ROADMAP_PUBLIC_KEY, JSON.stringify(['demo']))
const pub = mockPublicGoalEvents('demo').events
ok('signed out, a public roadmap answers its goal events', pub.length === 3 && pub.every((e) => e.source_key.startsWith('goal:')))
ok('the public read carries no id (the hub sends none)', pub.every((e) => !('id' in e)))
ok('B stays internal when A is public', mockPublicGoalEvents(MOCK_GOAL_WS.b).events.length === 0)
delete globalThis.localStorage

/* ── wiring: chunks and fetches ──────────────────────────────────────── */
const page = readFileSync(join(WUI, 'src/pages/roadmap.vue'), 'utf8')
const goalPage = readFileSync(join(WUI, 'src/pages/goals/[id].vue'), 'utf8')
ok('the goal part is a lazy chunk', /defineAsyncComponent\(\(\) => import\('~\/components\/RoadmapGoals\.vue'\)\)/.test(page))
ok('the goal page fetches /roadmap.json, never imports it', /fetch\('\/roadmap\.json'/.test(goalPage) && !/import[^\n]*roadmap\.json/.test(goalPage))
const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

if (failed) { console.log(`roadmap-goals: ${failed} failed`); process.exit(1) }
console.log('roadmap-goals: all passed')
