// Spec 112 WUI-1: the roadmap's spec rows.
//   - sync-roadmap.mjs on a throwaway repo: one row per spec dir (no-tasks
//     included), the counts and states of do_spl_spec_progress (5.1), the
//     tasks.md commit day; a shallow clone leaves the day empty.
//     CONTROL: a goal.yaml next to the specs (and under csi-spl-doc/goals/)
//     leaves `"goals"` out of roadmap.json; a `goals` key in the action's
//     output is dropped too (the allow-list).
//   - utils/roadmap-rows.mjs: ?when=week|month (5.3 (b)) in an ISO week /
//     calendar month. CONTROL: the toggle changes the row count of a fixture.
//   - outside the repo (the OSS standalone image) the sync writes an empty
//     list; in the repo a failing action fails it.
//   - the page fetches /roadmap.json, never imports it (spec 112 9).
//
// Run: node tests/unit/roadmap.test.mjs
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { roadmapOf, syncRoadmap } from '../../src/node/roadmap/sync-roadmap.mjs'
import { inWindow, roadmapAnchor, roadmapRows, roadmapSpecs, roadmapWhen } from '../../src/utils/roadmap-rows.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const scratch = []
const tmp = (p) => { const d = mkdtempSync(join(tmpdir(), p)); scratch.push(d); return d }

function git(repo, args, date) {
  const env = { ...process.env, GIT_AUTHOR_NAME: 'FirstName LastName', GIT_AUTHOR_EMAIL: 'dev@example.com', GIT_COMMITTER_NAME: 'FirstName LastName', GIT_COMMITTER_EMAIL: 'dev@example.com' }
  if (date) Object.assign(env, { GIT_AUTHOR_DATE: date, GIT_COMMITTER_DATE: date })
  const r = spawnSync('git', ['-C', repo, ...args], { env, encoding: 'utf8' })
  if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`)
  return r.stdout
}
function put(repo, rel, text) {
  mkdirSync(dirname(join(repo, rel)), { recursive: true })
  writeFileSync(join(repo, rel), text)
}

console.log('roadmap')
try {
  /* ── sync-roadmap on a fixture repo, one spec per state ───────────────── */
  const repo = tmp('roadmap-repo-')
  git(repo, ['init', '-q'])
  const S = 'csi-spl-doc/specs'
  put(repo, `${S}/001-done/spec.md`, '# Spec 001: all done\n')
  put(repo, `${S}/001-done/tasks.md`, '- [x] a\n- [X] b\n')
  put(repo, `${S}/002-partial/spec.md`, '# Spec 002: one partial\n')
  put(repo, `${S}/002-partial/tasks.md`, '- [x] a\n- [x] b\n- [~] c\n')
  put(repo, `${S}/003-planned/spec.md`, '# Spec 003: planned\n')
  put(repo, `${S}/003-planned/tasks.md`, '- [ ] a\n')
  put(repo, `${S}/004-table/spec.md`, '# Spec 004: a task table\n')
  put(repo, `${S}/004-table/tasks.md`, '| T1 | done |\n')
  put(repo, `${S}/005-none/spec.md`, '# Spec 005: no tasks\n')
  /* CONTROL: goals next to the specs never reach roadmap.json */
  put(repo, `${S}/002-partial/goal.yaml`, 'id: G01-x\nworkspace: "a"\ndeadline: 2026-12-31\n')
  put(repo, 'csi-spl-doc/goals/G01-x/goal.yaml', 'id: G01-x\nworkspace: "a"\ndeadline: 2026-12-31\n')
  git(repo, ['add', '-A'])
  git(repo, ['commit', '-q', '-m', 'one'], '2026-09-01T10:00:00Z')
  put(repo, `${S}/003-planned/tasks.md`, '- [ ] a\n- [ ] b\n')
  git(repo, ['commit', '-q', '-am', 'two'], '2026-10-07T10:00:00Z')

  const out = join(tmp('roadmap-out-'), 'roadmap.json')
  const doc = syncRoadmap({ repo, out })
  const text = readFileSync(out, 'utf8')
  const byId = Object.fromEntries(doc.specs.map((s) => [s.id.slice(0, 3), s]))
  ok('one row per spec dir, no-tasks included', doc.specs.length === 5 && Boolean(byId['005']), JSON.stringify(doc.specs.map((s) => s.id)))
  ok('states by the one rule (5.1)', ['done', 'in-progress', 'planned', 'no-boxes', 'no-tasks'].every((st, i) => byId[`00${i + 1}`]?.state === st), JSON.stringify(doc.specs.map((s) => s.state)))
  ok('a [~] is open: 2 x + 1 ~ reads 66 %', byId['002'].pct === 66 && byId['002'].p === 1, JSON.stringify(byId['002']))
  ok('pct is null without boxes', byId['004'].pct === null && byId['005'].pct === null)
  ok('the title comes from spec.md', byId['001'].title === 'Spec 001: all done', byId['001'].title)
  ok('tasks_changed is the tasks.md commit day', byId['003'].tasks_changed.startsWith('2026-10-07') && byId['001'].tasks_changed.startsWith('2026-09-01'), `${byId['003'].tasks_changed} ${byId['001'].tasks_changed}`)
  ok('no tasks.md, no day', byId['005'].tasks_changed === '')
  ok('totals count every row', doc.totals.specs === 5 && doc.totals.done === 1 && doc.totals['no-tasks'] === 1, JSON.stringify(doc.totals))
  ok('the sha is named', /^[0-9a-f]{40}/.test(doc.sha), doc.sha)
  ok('CONTROL: a goal.yaml leaves "goals" out of roadmap.json', (text.match(/"goals"/g) || []).length === 0)
  ok('the file holds only sha, rule, totals, specs', JSON.stringify(Object.keys(JSON.parse(text))) === '["sha","rule","totals","specs"]', Object.keys(JSON.parse(text)).join(','))

  const planted = roadmapOf({ sha: 'x', specs: [{ id: '001-a', state: 'done', x: 1, p: 0, o: 0, pct: 100, goals: ['G01'] }], goals: [{ id: 'G01' }] })
  ok('CONTROL: a goals key in the action output is dropped', !JSON.stringify(planted).includes('goals'), JSON.stringify(planted))
  let threw = false
  try { roadmapOf({ specs: [{ id: '001-a', state: 'half' }] }) } catch { threw = true }
  ok('an unknown state fails the sync', threw)

  const shallow = tmp('roadmap-shallow-')
  rmSync(shallow, { recursive: true, force: true })
  spawnSync('git', ['clone', '-q', '--depth', '1', `file://${repo}`, shallow], { encoding: 'utf8' })
  const sdoc = syncRoadmap({ repo: shallow, out: join(tmp('roadmap-out-'), 'roadmap.json') })
  ok('a shallow clone dates no tasks.md', sdoc.specs.length === 5 && sdoc.specs.every((s) => s.tasks_changed === ''), JSON.stringify(sdoc.specs.map((s) => s.tasks_changed)))

  const lone = syncRoadmap({ repo: tmp('roadmap-lone-'), out: join(tmp('roadmap-out-'), 'roadmap.json'), action: '/nonexistent/spl-spec-progress.func.sh' })
  ok('outside the repo (the standalone image): an empty spec list, not a failed build', lone.specs.length === 0 && lone.totals.specs === 0)
  const bad = join(tmp('roadmap-bad-'), 'spl-spec-progress.func.sh')
  writeFileSync(bad, 'do_spl_spec_progress() { echo broken >&2; return 1; }\n')
  let red = false
  try { syncRoadmap({ repo, out: join(tmp('roadmap-out-'), 'roadmap.json'), action: bad }) } catch { red = true }
  ok('in the repo, a failing action still fails the sync', red)

  /* ── the this-week / this-month filter (5.3 (b)) ───────────────────────── */
  ok('?when= reads week / month, else all', roadmapWhen('week') === 'week' && roadmapWhen(['month']) === 'month' && roadmapWhen('year') === '' && roadmapWhen(undefined) === '')
  const today = '2026-10-09' /* a Friday; its ISO week starts 2026-10-05 */
  ok('week: Monday of the same ISO week is in', inWindow('2026-10-05', 'week', today))
  ok('week: the Sunday before is out', !inWindow('2026-10-04', 'week', today))
  ok('month: the 1st is in, the month before is out', inWindow('2026-10-01', 'month', today) && !inWindow('2026-09-30', 'month', today))
  ok('no window: every day is in', inWindow('', '', today))
  const fixture = roadmapSpecs({ specs: [
    { id: '001-a', tasks_changed: '2026-10-08T09:00:00Z' },
    { id: '002-b', tasks_changed: '2026-10-02T09:00:00Z' },
    { id: '003-c', tasks_changed: '2026-08-02T09:00:00Z' },
    { id: '004-d', tasks_changed: '' },
    { id: 'bad', tasks_changed: '2026-10-08T09:00:00Z' },
  ] })
  const day = (iso) => iso.slice(0, 10)
  const counts = ['', 'week', 'month'].map((w) => roadmapRows(fixture, w, today, day).length)
  ok('all / week / month show 4 / 1 / 2 rows', JSON.stringify(counts) === '[4,1,2]', JSON.stringify(counts))
  ok('CONTROL: the toggle changes the visible row count', new Set(counts).size === 3)
  ok('a row anchors as spec-NNN', roadmapAnchor('089-calendar') === 'spec-089')

  /* ── the page fetches, never imports, roadmap.json (spec 112 9) ────────── */
  const page = readFileSync(join(WUI, 'src/pages/roadmap.vue'), 'utf8')
  const table = readFileSync(join(WUI, 'src/components/RoadmapSpecTable.vue'), 'utf8')
  ok('roadmap.vue fetches /roadmap.json', /fetch\('\/roadmap\.json'/.test(page))
  ok('nothing imports roadmap.json', ![page, table].some((s) => /import[^\n]*roadmap\.json/.test(s)))
  ok('the table is a lazy chunk', /defineAsyncComponent\(\(\) => import\('~\/components\/RoadmapSpecTable\.vue'\)\)/.test(page))

  /* ── wiring ─────────────────────────────────────────────────────────── */
  const pkg = JSON.parse(readFileSync(join(WUI, 'package.json'), 'utf8'))
  ok('pnpm run generate runs sync-roadmap before nuxt generate', /node src\/node\/roadmap\/sync-roadmap\.mjs && .*nuxt generate$/.test(pkg.scripts.generate), pkg.scripts.generate)
  ok('src/public/roadmap.json is git-ignored', /^src\/public\/roadmap\.json$/m.test(readFileSync(join(WUI, '.gitignore'), 'utf8')))
  const s = runsInUnitSuite(import.meta.url)
  ok('pnpm test runs this suite', s.ok, s.why)
} finally {
  for (const d of scratch) rmSync(d, { recursive: true, force: true })
}

if (failed) { console.log(`roadmap: ${failed} failed`); process.exit(1) }
console.log('roadmap: all passed')
