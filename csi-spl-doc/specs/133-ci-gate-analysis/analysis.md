# 133: CI gate analysis

Status: **draft v0.5** (editor c-296, 2026-10-12). The seats'
findings are folded in here as they land; until then the sections below hold
only the starting facts and the questions each section must answer.

## 1. Starting facts

Source: c-002's 48 h measurement, msg a4348171
(https://spool-hub.ai/m/f98b1b77-d73d-4ccb-9618-68a1cca089af), wf 10
(`10_ci-quality.yml`) on master, runs since 2026-10-10T06:00Z, **n=629**.
To be re-measured by the seats with the command and sha stated.

| fact | value |
|---|---|
| runs cancelled as superseded | 577 (92%) |
| runs failed | 48 |
| runs green | **3** |
| median wall time of a completed run | 47 min |
| push rate on master | ~13 an hour |

Failed runs per job (one run can fail several jobs):

| job | failed runs |
|---|---|
| orc hermetic (`orc-suite`) | 41 |
| hub go (`hub-suite`) | 38 |
| wui e2e (`wui-e2e`) | 33 |
| iac (`iac-suite`) | 22 |
| nuxt generate (`wui-generate`) | 15 |
| orc feature (`orc-features`) | 12 |

Structure, each checked on tree `7d950a8ec`:

- **No per-part job selection in CI.** The only skip is the docs-only
  classify: `grep -n "^  classify:" .github/workflows/10_ci-quality.yml` ->
  line 133; the code jobs it skips are listed in the file's header comment
  (`grep -n "skips the code jobs" .github/workflows/10_ci-quality.yml` -> 1
  line). Its helper is `csi-spl-orc/src/bash/scripts/ci-doc-only.sh`.
- **No `paths:` filter, on purpose**: `grep -n "NO \`paths:\` FILTER"
  .github/workflows/10_ci-quality.yml` -> 1 line (the wrong allow-list
  "fails SILENTLY" argument). Pre-push is selective (touched parts only,
  [pre-push-gate.md](../../doc/md/pre-push-gate.md)); CI deliberately is not.
- **One running + one pending gate per ref**:
  `grep -n -A2 "^concurrency:" .github/workflows/10_ci-quality.yml` ->
  `group: quality-gate-${{ github.ref }}`, `cancel-in-progress: false`.
  So "cancelled" = superseded pending run, not a lost run.
- **13 jobs** in wf 10: `awk '/^jobs:/{j=1;next} /^[a-z]/{j=0} j &&
  /^  [a-z0-9_-]+:$/' .github/workflows/10_ci-quality.yml | wc -l` -> 13
  (includes `classify`, `gate-health`, `distribution-hygiene`,
  the box-reference ban job, `pr-sec-scan`).
- **Runners**: 6 self-hosted runners on sat (16 CPU, shared with agents);
  `gh-runner-cpu-budget` keeps about 3 online.
- **Spec 131** ([131-ci-red-trunk](../131-ci-red-trunk/spec.md)) already
  landed C1..C5.
- **Fleet state now**: every non-CI lane paused by owner order; only CI lanes
  push. c-294 is landing the hourly non-replaceable wf 10 verdict.

### 1.1 Editor re-measure (the axis baselines)

Window 2026-10-10T06:00Z..2026-10-12T06:25Z (48.4 h), master tip at the time
`36c185fec`. Two datasets, every axis below is computed from them:

- **M-RUNS**, n=631 runs:
  `gh api --paginate "repos/csitea/csi-spl/actions/workflows/10_ci-quality.yml/runs?branch=master&event=push&created=>=2026-10-10T06:00:00Z&per_page=100" --jq '.workflow_runs[] | [.id,.head_sha,.status,.conclusion,.created_at,.run_started_at,.updated_at] | @tsv'`
- **M-JOBS**, n=1049 jobs: for each run id,
  `gh api "repos/csitea/csi-spl/actions/runs/<id>/jobs?per_page=100&filter=all"`
  (name, conclusion, created_at, started_at, completed_at, runner_name).

| fact | value | how |
|---|---|---|
| runs | 578 cancelled, 48 failure, **3 success**, 2 running | M-RUNS, count by conclusion (c-002's numbers reproduce) |
| runs that started any job | **66 of 631 (10.5%)** | run ids present in M-JOBS; the other 565 were pending runs replaced before a runner took them |
| started runs by conclusion | 48 failure, 14 cancelled (job timeout or hand), 3 success, 1 running | M-JOBS x M-RUNS |
| wall time of a started run (first job start to last job end) | median **46 min**, failure p90 67 min (n=65) | M-JOBS |
| runner minutes per started run | median **158 job-min**, 15 jobs (n=66) | M-JOBS, sum of completed-started over jobs with a runner |
| job queue wait (started - created) | median 0.0 min, **p90 9.0 min**, max 58 (n=969) | M-JOBS |
| push-to-verdict (run created -> first later run that ended success or failure) | median **81 min**, p90 163 (n=626) | M-RUNS |
| push-to-green | median **1,498 min** (n=626) | M-RUNS, same with success only |
| red minutes on the master tip (time since the newest verdict was a failure) | 2,702 min in 48.4 h = **1,339 min/day, 96% of the time** (n=51 verdicts) | M-RUNS, ordered by updated_at |
| runners seen | 6 (`sat-spl-01..06`) | M-JOBS runner_name |

Per job, from M-JOBS (runs that reached the job; one run can fail several):

| job | success | failure | cancelled | duration median / p90 (min) |
|---|---|---|---|---|
| hub (`hub-suite`) | 19 | **44** | 2 | 16.3 / 29.2 |
| orc hermetic, shard 1 | 13 | **44** | 9 | 10.3 / 23.0 |
| orc hermetic, shard 2 | 13 | **39** | 14 | 9.0 / 21.8 |
| wui e2e 1/3 | 28 | 26 | 8 | 30.2 / 38.9 |
| wui e2e 2/3 | 30 | 24 | 8 | 32.0 / 41.4 |
| wui e2e 3/3 | 24 | **33** | 5 | 28.3 / 40.4 |
| iac (`iac-suite`) | 40 | 25 | 1 | 6.7 / 10.0 |
| wui generate | 48 | 15 | 3 | 5.7 / 8.3 |
| orc features | 51 | 12 | 3 | 5.3 / 8.2 |
| wui unit + typecheck | 63 | 0 | 3 | 6.7 / 9.8 |
| cnf, classify, hygiene, box-ref, gate health | all green | 0 | <=1 | <1.3 |

What each master commit touched, same window, n=682 commits:
`git log --since=2026-10-10T06:00:00Z --format=@%h --name-only origin/master`,
first path component per commit:

| parts touched | commits |
|---|---|
| exactly one top-level dir | **600 (88%)** |
| two | 63 |
| three or four | 19 |
| `csi-spl-doc` only | 220 (32%) |
| `csi-spl-orc` only | 161 (24%) |
| `csi-spl-wui` only | 118 (17%) |
| `csi-spl-api` only | 58 (9%) |
| `csi-spl-iac` only | 33 (5%) |

### 1.2 First editor finding: the docs express lane cannot fire on a red trunk

The classify job diffs against the head of the **last green** push run
(`grep -n "status=success&per_page=1" .github/workflows/10_ci-quality.yml` ->
1 line, in `classify`). With 3 green runs in 48 h the diff from that base
spans hundreds of code commits, so a doc-only push still runs the full gate:
in M-JOBS no started run skipped `hub-suite` (`skipped` count 0 of 66). The
one per-part skip CI has is therefore switched off exactly when the gate is
red, which is nearly always (96%).

## 2. Why the gate almost never gives a verdict

(Folded from the seats. Each cause: the mechanism, the measurement with
command + sha + n, and its share of the lost verdicts.)

### 2.1 Cadence: pushes vs gate wall time

Editor's model, checked against section 1.1. The group
`quality-gate-${{ github.ref }}` keeps one running and one pending run. A
push lands while a run is going, waits for the rest of it, then for its own
(pending, possibly replaced) run to finish. With wall time W = 46 min, the
expected wait is about 1.5 x W = 69 min and the worst case 2 x W = 92 min,
plus queue wait. The measured push-to-verdict median is 81 min (p90 163,
n=626), which fits. I believe, unchecked, that the p90 tail (163) comes from
the 14 started runs that ended cancelled with no verdict, so those pushes
waited a further W.

What superseding costs, and what it does not:

- **No runner time.** 565 of 631 runs never started a job (M-JOBS).
- **Attribution.** One verdict covers ~10 pushes (631 pushes, 51 verdicts),
  so a red cannot be pinned to one commit without a bisect.
- **Latency.** Push-to-verdict is bound to W, so **cutting W (X4) is what
  moves X1**. Selection (2.2) cuts W for most pushes.

**Deploys do not wait for the gate.** wf 20 and wf 30 have no `workflow_run`
trigger and no reference to wf 10 outside comments
(`grep -nE "workflow_run|10_ci-quality" .github/workflows/20_hub-build-deploy.yml .github/workflows/30_wui-build-deploy.yml`
-> lines 100 and 572 of wf 20 and line 92 of wf 30, all comments). The hub
and wui deploy to dev and prd on their own `test` job, while wf 10 is red
96% of the time. wf 20's `test` job is a second hub suite run on every hub
push (seat C, C5).

### 2.2 Selection: every push runs every code job

From [seat C](seat-c.md) (c-297, `2921f95b0`, n=614 push diffs):

- **The owner remembered pre-push, not CI.** Pre-push runs only the parts a
  push touches (`_pp_paths`), and orc picks single test files
  (`changed-tests.sh`). wf 10 runs all 11 code job instances on every push,
  by design (header "NO `paths:` FILTER").
- **The docs express lane fired 0 of 51 completed runs, while 220 of 614
  pushes (35.8%) changed docs only.** Its base is the last green run
  (section 1.2 here). Seat C's fix: a **per-job base**. Job J skips only
  when nothing changed since J's own last success on master touches J's
  inputs. A red job keeps running until it is green; a wui-only push no
  longer waits for a green hub before it can skip hub.
- **wui-e2e is 61% of a gate's job-minutes** (84.6 of 139.4), and only
  27.7% of pushes touch a wui input. It is the cleanest and largest cut.
- **iac and orc are read by almost every part** (whole-tree scanners, cross
  reads: 45 of 138 iac test files name `csi-spl-cnf/`). A part-level rule
  saves little there; test-level selection is the next step.
- **hub-suite runs twice on a hub push**: wf 10 `hub-suite` and wf 20's own
  `test` job (`grep -n "run-all-tests.sh" .github/workflows/20_hub-build-deploy.yml`).
- **Modelled saving** for a green trunk (upper bound): part-level 64.6% of
  job-minutes, file-level 58.2%, today 0.0%.
- **Fail-safe rules** (seat C section 3): workflows, the gate's own code,
  shared libs, lockfiles, `go.mod`, unmapped paths and pull requests run the
  full gate. The **hourly non-replaceable verdict always runs the full
  gate**, which bounds any allow-list miss to one hour and answers wf 10's
  "fails SILENTLY" objection. A drift test keeps the map in step, as
  `hub-deploy-guard.tst.sh` does for wf 20.

### 2.3 Reds: which jobs fail, and why (defect vs flake vs load)

### 2.4 Capacity: runners, queue wait, box load

### 2.5 Wall time: the critical path inside one run

## 3. What the seats found

| seat | file | area | status | sha |
|---|---|---|---|---|
| A | `seat-a.md` | wall time, queue wait, runners | pending | |
| B | `seat-b.md` | red causes, flakes | pending | |
| C | [seat-c.md](seat-c.md) | per-part selection | v0.2, review fixes in, folded | `15fe61d85` |
| D | [seat-d.md](seat-d.md) | slow suites | v0.2 sent back, round 2 (5 points: e2e per-file times from CI logs, exact axis commands) | `4dc3f9a77` |
| E | [seat-e.md](seat-e.md) | triggers, concurrency, supersede | v0.1 sent back (7 points: latency model, supersede cost, merge queue vs red minutes, deploy facts, runnable commands) | `edf2b3fa1` |

## 4. The axes (ONE set, 5-8)

Each axis: what it measures, the exact command, the baseline now (with sha,
window and n) and the target. Every round of the CI-refactor seat reports its
before and after on every axis.

| # | axis | command | baseline (sha, window, n) | target |
|---|---|---|---|---|
| X1 | push-to-verdict, median (min) | M-RUNS, section 1.1 | 81 (p90 163), `36c185fec`, 48.4 h, n=626 | <= 30 |
| X2 | verdicts green, % (success / (success + failure)) | M-RUNS | 6% (3/51) | >= 80% |
| X3 | red minutes per day on the master tip | M-RUNS | 1,339 (96%) | <= 120 |
| X4 | wall time of a started run, median (min) | M-JOBS | 46 | <= 20 |
| X5 | runner minutes per push (job-min of started runs / pushes) | M-JOBS / M-RUNS | 66 x 158 / 631 = ~17; 158 per started run, every part's jobs | per-part: a one-part push <= 40 job-min |
| X6 | job queue wait p90 (min) | M-JOBS | 9.0 (n=969) | <= 3 |

Draft by the editor from section 1.1; the seats confirm, replace or add
(max 8). X1..X3 are what the owner feels; X4..X6 are the levers.

## 5. Candidate fixes, ranked by expected axis gain per effort

| rank | fix | axes it moves (expected) | effort | risk | from seat |
|---|---|---|---|---|---|
| - | (ranking waits for the seats) | | | | |

Input already on the table, unranked: c-002's 7 actions, posted to the
owner (https://spool-hub.ai/m/a3cf1826-933b-4279-9f9d-4d9f207791d1; n=60 runs,
2026-10-11T20:53Z..2026-10-12T06:07Z):

| # | candidate | c-002's measure of success | likely axes |
|---|---|---|---|
| K1 | run only the parts a push touched | runs starting e2e without a WUI change: 100% -> 0% | X4, X5, X1 |
| K2 | stop the replace storm: full gate hourly + a selective gate per push | finished runs per hour: ~1 -> >=4 | X1, X3 |
| K3 | CI gets its own CPU (own box or reserved cores) | runners online 6 of 6; queue wait p50 | X6, X4 |
| K4 | pin the clock in the calendar e2e tests | calendar reds in 20 runs: 0 | X2, X3 |
| K5 | fix the iac fail-fast check and the lane-mix table test | first-red count of these two: 0 | X2, X3 |
| K6 | make the slowest suites faster (e2e 3/3, orc hermetic) | p90 <= 60% of each job's limit | X4 |
| K7 | a master red pings the lane that caused it; pre-push runs touched e2e files | minutes a red stays on master: p50 < 30 | X3 |

Plus **K8**, the editor's and seat C's: a **per-job base** for the skip
(job J skips when nothing since J's own last success touches its inputs),
with the hourly full verdict as the backstop (sections 1.2 and 2.2). It
generalises K1 and revives the docs express lane on a red trunk.

## 6. Open questions

## 7. Sign-off

| version | date | by | what |
|---|---|---|---|
| v0.1 | 2026-10-12 | c-296 | skeleton |
| v0.2 | 2026-10-12 | c-296 | editor re-measure (1.1), express-lane finding (1.2), draft axes X1..X6 |
| v0.3 | 2026-10-12 | c-296 | panel roster; candidates K1..K8 (c-002 7 actions + express base) |
| v0.4 | 2026-10-12 | c-296 | seat C folded (2.2) |
| v0.5 | 2026-10-12 | c-296 | 2.1 latency model, deploys do not wait for the gate; D, E in review |
