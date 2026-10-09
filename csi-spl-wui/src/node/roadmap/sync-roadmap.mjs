// Spec 112 WUI-1 (5, 5.1, 5.2): the roadmap's build-time copy. Run INSIDE
// `pnpm run generate`, before `nuxt generate`, so the copy is made by the
// build that ships and is never committed (src/public/roadmap.json is
// git-ignored). It calls the ONE rule, csi-spl-orc's do_spl_spec_progress
// --json, and writes what it printed:
//
//   src/public/roadmap.json   {sha, rule, totals, specs: [{id, title, state,
//                              x, p, o, pct, tasks_changed}]}
//
// - Spec rows ONLY, never a goal: a goal's audience is a runtime
//   per-workspace switch (12.5) that a build-time file cannot honour. The
//   output is rebuilt from an allow-list of keys, so a `goals` key the action
//   might print one day never reaches the file.
// - Nothing re-counts boxes here (5.1): the action is sourced and called, with
//   the two run-time helpers it needs (do_log, do_require_bin) as shims.
// - A shallow clone (the CI mock generate) cannot date a tasks.md: every file
//   reads the one fetched commit. tasks_changed is then "" (unknown), never a
//   wrong day that the this-week filter would match.
//
// Usage (in csi-spl-wui):
//   node src/node/roadmap/sync-roadmap.mjs        # write the copy (pnpm run generate)
import { spawnSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, '../../..')
/* ROADMAP_REPO_ROOT / ROADMAP_OUT: for tests/unit/roadmap-sync.test.mjs */
export const ROADMAP_REPO = process.env.ROADMAP_REPO_ROOT || join(WUI, '..')
export const ROADMAP_OUT = process.env.ROADMAP_OUT || join(WUI, 'src/public/roadmap.json')
export const ROADMAP_ACTION = join(WUI, '../csi-spl-orc/src/bash/run/spl-spec-progress.func.sh')

const STATES = ['done', 'in-progress', 'planned', 'no-boxes', 'no-tasks']
const ROW_KEYS = ['id', 'title', 'state', 'x', 'p', 'o', 'pct', 'tasks_changed']

/** The action's --json output for `repo`, parsed. Throws with its stderr. */
export function specProgressJson(repo = ROADMAP_REPO, action = ROADMAP_ACTION) {
  const script = [
    'set -o pipefail',
    'do_log() { printf "%s\\n" "$*" >&2; }',
    'do_require_bin() { command -v "$1" >/dev/null || { do_log "FATAL $1 is required"; return 1; }; }',
    'source "$1" || exit 1',
    'do_spl_spec_progress --json',
  ].join('\n')
  const r = spawnSync('bash', ['-c', script, 'sync-roadmap', action], {
    env: { ...process.env, SPEC_PROGRESS_ROOT: repo },
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  })
  if (r.status !== 0) throw new Error(`do_spl_spec_progress --json failed (${r.status}): ${(r.stderr || '').trim()}`)
  return JSON.parse(r.stdout)
}

/** True when `repo` is a shallow clone (its tasks.md dates are not real). */
export function isShallow(repo = ROADMAP_REPO) {
  const r = spawnSync('git', ['-C', repo, 'rev-parse', '--is-shallow-repository'], { encoding: 'utf8' })
  return r.status === 0 && r.stdout.trim() === 'true'
}

/**
 * The roadmap.json object: spec rows only, each row rebuilt from ROW_KEYS.
 * Throws on a row the page could not show (no id, an unknown state).
 */
export function roadmapOf(progress, { shallow = false } = {}) {
  if (!progress || !Array.isArray(progress.specs)) throw new Error('do_spl_spec_progress --json printed no specs[]')
  const specs = progress.specs.map((s) => {
    if (!s || !/^\d{3}-/.test(String(s.id || ''))) throw new Error(`bad spec row: ${JSON.stringify(s)}`)
    if (!STATES.includes(s.state)) throw new Error(`spec ${s.id}: unknown state ${s.state}`)
    const row = {}
    for (const k of ROW_KEYS) row[k] = s[k] ?? null
    row.title = String(row.title || '')
    row.tasks_changed = shallow ? '' : String(row.tasks_changed || '')
    return row
  })
  const totals = { specs: specs.length }
  for (const st of STATES) totals[st] = specs.filter((s) => s.state === st).length
  return { sha: String(progress.sha || ''), rule: String(progress.rule || ''), totals, specs }
}

/** Write roadmap.json; returns the object written. */
export function syncRoadmap({ repo = ROADMAP_REPO, out = ROADMAP_OUT, action = ROADMAP_ACTION } = {}) {
  const shallow = isShallow(repo)
  const doc = roadmapOf(specProgressJson(repo, action), { shallow })
  mkdirSync(dirname(out), { recursive: true })
  writeFileSync(out, JSON.stringify(doc) + '\n')
  console.log(`sync-roadmap: ${doc.specs.length} spec row(s) at ${doc.sha || '?'}${shallow ? ' (shallow clone: no tasks.md dates)' : ''} -> ${out}`)
  return doc
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    syncRoadmap()
  } catch (err) {
    console.error(`sync-roadmap: ${err.message}`)
    process.exit(1)
  }
}
