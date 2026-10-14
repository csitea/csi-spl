// SPL-1559 (owner HUM-10, t1 7edebc75 msg 7d76ce22): an issue its assignee
// has not opened yet carries the unread row's mark. The hub's per-viewer
// `unopened` survives normalizeIssue, a tenant-wide live frame keeps a row's
// mark while it stays the same assignee's open issue, and the mock hub plays
// the rule (assigned to me, by someone else, open, never opened) and clears
// it on POST .../opened.
// Run: node tests/unit/issue-unopened.test.mjs
import { MOCK_ISSUES_NEW_KEY, createMockIssues, normalizeIssue, unopenedCandidate } from '../../src/utils/issues.mjs'
import { applyIssueFrame } from '../../src/utils/issues-view.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'
import { MOCK_DEFAULT_TOPIC } from '../../src/utils/issue-discussions.mjs'

/* SPL-1593 (rdb 0194): the mock hub, like the hub, refuses an issue with no discussion */
const LINK = { discussions: [MOCK_DEFAULT_TOPIC] }

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('issue-unopened: the row model')
ok('the hub\'s unopened is kept', normalizeIssue({ key: 'SPL-2', unopened: true }).unopened === true)
ok('CONTROL: none, or not a true, reads as opened', normalizeIssue({ key: 'SPL-2' }).unopened === false && normalizeIssue({ key: 'SPL-2', unopened: 'yes' }).unopened === false)
const mineNew = { key: 'SPL-2', kind: 'issue', status: 'todo', assignee: 'HUM-1', created_by: 'HUM-2' }
ok('a teammate\'s open issue for me can be new', unopenedCandidate(mineNew, 'HUM-1'))
ok('CONTROL: not mine, my own, done, discarded, an epic, no viewer', !unopenedCandidate(mineNew, 'HUM-3')
  && !unopenedCandidate({ ...mineNew, created_by: 'HUM-1' }, 'HUM-1') && !unopenedCandidate({ ...mineNew, status: 'done' }, 'HUM-1')
  && !unopenedCandidate({ ...mineNew, status: 'diss' }, 'HUM-1') && !unopenedCandidate({ ...mineNew, kind: 'epic' }, 'HUM-1')
  && !unopenedCandidate(mineNew, ''))

console.log('issue-unopened: live frames')
const row = normalizeIssue({ ...mineNew, unopened: true, updated_at: '2026-10-12T10:00:00Z' })
const frame = (patch) => ({ type: 'issue', op: 'update', issue: { ...mineNew, updated_at: '2026-10-12T11:00:00Z', ...patch } })
ok('a title change keeps the mark', applyIssueFrame([row], frame({ title: 'renamed' }))[0].unopened === true)
ok('done clears it', applyIssueFrame([row], frame({ status: 'done' }))[0].unopened === false)
ok('a reassignment clears it (the page asks the hub)', applyIssueFrame([row], frame({ assignee: 'HUM-3' }))[0].unopened === false)
ok('CONTROL: a new row from a frame has no mark of its own', applyIssueFrame([], frame({}))[0].unopened === false)
ok('CONTROL: an opened row stays opened', applyIssueFrame([{ ...row, unopened: false }], frame({ title: 'x' }))[0].unopened === false)

console.log('issue-unopened: the mock hub')
const store = new Map([[MOCK_ISSUES_NEW_KEY, '2']])
globalThis.localStorage = { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) }
const m = createMockIssues({ me: 'HUM-1', now: () => '2026-10-12T10:00:00Z' })
const marks = () => Object.fromEntries(m.list('').issues.map((i) => [i.key, i.unopened]))
{ const k = marks(); ok('the teammate\'s two issues for me are new, the epic is not', k['SPL-1'] === false && k['SPL-2'] === true && k['SPL-3'] === true && Object.keys(k).length === 3, JSON.stringify(k)) }
ok('the single read carries it', m.get('SPL-2').issue.unopened === true)
ok('opened answers the key', JSON.stringify(m.opened('SPL-2')) === JSON.stringify({ key: 'SPL-2', unopened: false }))
ok('opening clears it for that issue only', marks()['SPL-2'] === false && marks()['SPL-3'] === true)
const mine = m.create({ ...LINK, title: 'mine', assignee: 'HUM-1' }).issue
ok('CONTROL: an issue I create for myself is not new', marks()[mine.key] === false)
let threw = ''
try { m.opened('SPL-99') } catch (e) { threw = e.token || String(e.status) }
ok('CONTROL: an unknown issue is not_found', threw === 'not_found', threw)
delete globalThis.localStorage

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll issue-unopened checks passed.')
