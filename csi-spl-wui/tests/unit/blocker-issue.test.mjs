// Blocker -> issue, WUI side (owner HUM-10, csitea e48433ef msg 2512ff1f;
// t1 de3c2cf5 msg 26c89f60): the workspace setting "blocker to issue after N
// minutes" (the hub's registered key, default 3, 0 = off, at most 1440), the
// mock hub's check of it, and the Issues rail count of the viewer's open
// assigned issues.
// Run: node tests/unit/blocker-issue.test.mjs
import { BLOCKER_KEY_MINUTES, BLOCKER_MINUTES_DEFAULT, BLOCKER_MINUTES_RANGE, blockerMinutesOf, blockerMinutesPatch, blockerMinutesValid } from '../../src/utils/blocker-settings.mjs'
import { ISSUE_OPENED_EVENT, OPEN_ISSUE_STATUSES, newIssueCount, openIssueCount, startMyIssuesCount } from '../../src/utils/my-issues-count.mjs'
import { createMockTenant } from '../../src/utils/tenant-settings-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const throws = (fn, token) => { try { fn(); return false } catch (e) { return e.token === token } }
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)

console.log('blocker-issue: the setting')
ok('the key is the hub registry (store/blocker_issue.go)', BLOCKER_KEY_MINUTES === 'blocker.issue_after_minutes')
ok('default 3, range 0..1440', BLOCKER_MINUTES_DEFAULT === 3 && same(BLOCKER_MINUTES_RANGE, { min: 0, max: 1440 }))
ok('no settings map = the default', blockerMinutesOf(undefined) === 3)
ok('a stored value is read', blockerMinutesOf({ [BLOCKER_KEY_MINUTES]: 10 }) === 10)
ok('0 (off) is read as 0, not the default', blockerMinutesOf({ [BLOCKER_KEY_MINUTES]: 0 }) === 0)
ok('CONTROL: junk reads as the default', blockerMinutesOf({ [BLOCKER_KEY_MINUTES]: 'x' }) === 3 && blockerMinutesOf({ [BLOCKER_KEY_MINUTES]: 5000 }) === 3)
ok('valid: 0, 1, 1440', blockerMinutesValid(0) && blockerMinutesValid(1) && blockerMinutesValid(1440))
ok('CONTROL: invalid: -1, 1441, 2.5, "3"', !blockerMinutesValid(-1) && !blockerMinutesValid(1441) && !blockerMinutesValid(2.5) && !blockerMinutesValid('3'))
ok('patch: a change', same(blockerMinutesPatch(3, 10), { [BLOCKER_KEY_MINUTES]: 10 }))
ok('patch: the input as text', same(blockerMinutesPatch(3, '0'), { [BLOCKER_KEY_MINUTES]: 0 }))
ok('CONTROL: patch: unchanged or out of range sends nothing', same(blockerMinutesPatch(3, 3), {}) && same(blockerMinutesPatch(3, 2000), {}) && same(blockerMinutesPatch(3, ''), {}))

console.log('blocker-issue: the mock hub')
const m = createMockTenant()
ok('the mock reads the default of blocker-settings.mjs', m.settings().settings[BLOCKER_KEY_MINUTES] === BLOCKER_MINUTES_DEFAULT)
m.patch({ settings: { [BLOCKER_KEY_MINUTES]: 0 } })
ok('the mock stores 0 (off)', m.settings().settings[BLOCKER_KEY_MINUTES] === 0)
ok('CONTROL: the mock refuses 1441 as bad_setting', throws(() => m.patch({ settings: { [BLOCKER_KEY_MINUTES]: 1441 } }), 'bad_setting'))
ok('CONTROL: the mock refuses -1 as bad_setting', throws(() => m.patch({ settings: { [BLOCKER_KEY_MINUTES]: -1 } }), 'bad_setting'))
m.patch({ settings: { [BLOCKER_KEY_MINUTES]: BLOCKER_MINUTES_RANGE.max } })
ok('the mock takes the top of the range (its copy of the range is blocker-settings.mjs\'s)', m.settings().settings[BLOCKER_KEY_MINUTES] === BLOCKER_MINUTES_RANGE.max)
m.patch({ settings: { [BLOCKER_KEY_MINUTES]: null } })
ok('null resets it to the default', m.settings().settings[BLOCKER_KEY_MINUTES] === 3)

console.log('blocker-issue: the Issues rail count')
ok('open = every status but done and diss', same([...OPEN_ISSUE_STATUSES].sort(), ['blocked', 'eval', 'onhold', 'qas', 'todo', 'wip']))
const rows = [
  { key: 'SPL-1', status: 'todo', kind: 'issue', unopened: true },
  { key: 'SPL-2', status: 'wip', kind: 'issue', unopened: true },
  { key: 'SPL-3', status: 'done', kind: 'issue', unopened: true },
  { key: 'SPL-4', status: 'diss', kind: 'issue', unopened: true },
  { key: 'SPL-5', status: 'todo', kind: 'epic', unopened: true },
  { key: 'SPL-6', status: 'todo', kind: 'issue', unopened: false },
]
ok('counts the open issues, not done / diss / an epic', openIssueCount(rows) === 3)
ok('CONTROL: nothing to count is 0', openIssueCount(undefined) === 0 && openIssueCount([]) === 0)
// SPL-1559 (owner t1 7edebc75): the tab counts exactly the rows the list marks new
ok('SPL-1559: counts only the open issues not opened yet', newIssueCount(rows) === 2, String(newIssueCount(rows)))
ok('SPL-1559 CONTROL: an opened open issue is not counted', newIssueCount([rows[5]]) === 0 && newIssueCount(undefined) === 0)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let list = rows.slice(0, 1)
const asked = []
const api = { listIssues: async (opts) => { asked.push(opts); return { issues: list } } }
const listeners = []
const live = { onIssue: (fn) => { listeners.push(fn); return () => listeners.splice(listeners.indexOf(fn), 1) }, onReconnected: () => () => {} }
const count = { value: 0 }
const hadWindow = 'window' in globalThis
if (!hadWindow) globalThis.window = new EventTarget()
const stop = startMyIssuesCount({ api, live, count, delay: 5 })
await sleep(20)
ok('the first read asks for the viewer\'s issues', same(asked[0], { filter: { assignee: ['me'] } }))
ok('the first read sets the count', count.value === 1, String(count.value))
list = rows
listeners.forEach((fn) => fn())
listeners.forEach((fn) => fn())
await sleep(30)
ok('an issue frame re-reads it', count.value === 2, String(count.value))
ok('a burst of frames is one re-read', asked.length === 2, String(asked.length))
list = rows.map((r) => (r.key === 'SPL-1' ? { ...r, unopened: false } : r))
globalThis.window.dispatchEvent(new Event(ISSUE_OPENED_EVENT))
await sleep(30)
ok('SPL-1559: an issue opened in this tab re-reads it', asked.length === 3 && count.value === 1, `${asked.length} ${count.value}`)
stop()
ok('stop drops the frame listener', listeners.length === 0)
globalThis.window.dispatchEvent(new Event(ISSUE_OPENED_EVENT))
await sleep(30)
ok('CONTROL: stop drops the opened listener', asked.length === 3, String(asked.length))
if (!hadWindow) delete globalThis.window

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll blocker-issue checks passed.')
