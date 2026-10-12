# 133: CI gate analysis

Status: **v1.0, signed** (editor c-296, 2026-10-12T07:34Z). All five seats
are folded in (section 3). The axis set is section 4, the ranked fixes are
section 5, and the CI-refactor seat measures every round against them.

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

From [seat A](seat-a.md) (c-298, `e788ef2f5`, the last 100 runs that ran
jobs, 2026-10-09T14:27Z..10-12T05:17Z, sat `gh-runner-cpu-budget` cron.out,
3,819 CAP ticks):

- **4.22 of 6 runners online on average**; the online ones were 76% busy.
- **62% of job-queue minutes fell in minutes with 3 or fewer runners
  online** (3,743 of 6,073). The budget cron parked an idle runner 396 times.
  So most of the queue is parking by the CPU budget, not a shortage of
  runners. The budget keeps CI and agents together under 80% of the cores
  (`grep -n "20% of the cores free" csi-spl-orc/src/bash/run/apply-gh-runner-cpu-budget.func.sh`
  -> line 5).
- **39% of GATE ticks read STARVED** (1,012 of 2,591): the gate was already
  past its own 40 min stale mark.
- **Box load stretches the critical jobs**: an e2e shard takes 27.4 min p50
  with the rest of the box under 3 cores, and 36.0 min at 6 cores or more
  (n=33 / 24, +31%). Hub goes from 19.5 to 29.2 min, but with n<=12 per cell.
  iac and generate barely move.
- **Headroom is thin**: `do_report_ci_gate` (n=12) marks 6 of 13 jobs AT
  RISK (p90 over 75% of the limit); orc hermetic 2/2 sits at 101%. 3 timeout
  reds and 1 runner-lost in those 12 runs: verdicts on load, not on code.

### 2.5 Wall time: the critical path inside one run

From seat A, n=82 completed runs, wall p50 43.0 min:

| part of one run's wall | p50 min | share of summed wall |
|---|---|---|
| before any job exists (previous run holds the slot) | 2.3 | 12% |
| runner queue on the critical path | 6.5 | 23% |
| **run time on the critical path** | **32.9** | **63%** |
| gaps between `needs:` | 0.0 | 2% |

- **An e2e shard is the critical job in 70 of 82 runs.** The path is
  classify -> nuxt generate -> the slowest e2e shard -> gate health.
- Even with a free runner for every job, a run lasts **32.9 min**.
- One run asks for 13 runner jobs, 130.2 runner-min p50. Over 6 runners that
  is 21.7 min, less than the path; at the mean 4.22 online it is 30.9 min,
  about the path. That is why queue shows up as 23%.
- **Push to verdict** (seat A, n=809): p50 72.9, p90 154.2. 53% of it is
  waiting in line behind the run already going, 14% runner queue and 33%
  running. 12.9 pushes an hour against 1.32 verdicts an hour. **Every minute
  cut from the critical path saves a push about two minutes**: one in line,
  one running.

The window differs from the editor's (section 1.1: 48.4 h, push-to-verdict
p50 81); both say the same thing.

### 2.6 The slow suites: where the time inside a job goes

From [seat D](seat-d.md) (a-295, `a1afc5e66`, green run 38207328805 on
`48ed9c131`; per-file times re-checked by the editor from the three e2e shard
logs, `gh api repos/csitea/csi-spl/actions/jobs/<id>/logs | grep -E '\.test\.mjs [0-9]+$'`):

- **wui e2e: the slowest files are phone and calendar tests**:
  phone-composer-target 244 s, phone-back-matrix 210 s, mobile-back-stuck
  162 s, calendar-phone-shell 157 s; four of the top ten are
  `calendar-phone-*`, the same family c-002 named for red runs (K4).
- **The e2e shards are unbalanced**: 2,124 s, 2,050 s and 1,796 s in the
  same run (one green run, n=3 shards), so the slowest shard sets the path
  5.5 min after the fastest. The runner already logs each file's time
  (`run-e2e-tests.mjs` line 260), so weights for the split are on hand.
- **nuxt generate: the build is 225 s of the 298 s step**; prerendering 523
  routes is ~63 s. Its p90 target is set at < 5 min, not lower, because
  Nuxt 3 does not reuse `.nuxt` on its own.
- **hub: two packages dominate** (local, n=1): `internal/store` 137 s and
  `internal/hub` 109 s; the rest are under 20 s each. A migrate costs ~45 ms
  (n=5), so per-package migrations are not the cost. 4 of 4 failed hub jobs
  looked at were test failures, not timeouts (small n).
- **orc hermetic: the slowest files are 4-10 min each** (CI log, both
  shards): spl-lane-mix 582 s, fleet-lease 578 s, peer-poll 482 s,
  parse-metadata-nofork 437 s.

## 3. What the seats found

| seat | file | area | status | sha |
|---|---|---|---|---|
| A | [seat-a.md](seat-a.md) | wall time, queue wait, runners | accepted, folded (2.4, 2.5) | `542870ae9` |
| B | [seat-b.md](seat-b.md) | red causes, flakes, why pre-push missed them | folded (3.2, X8, F1) | `fe55b9b85` |
| C | [seat-c.md](seat-c.md) | per-part selection | v0.2, review fixes in, folded | `15fe61d85` |
| D | [seat-d.md](seat-d.md) | slow suites | folded (2.6) | `f88aa9356` |
| E | [seat-e.md](seat-e.md) | triggers, concurrency, supersede | seat closed; folded with editor corrections (3.1) | `709f4726d` |

### 3.1 Editor corrections over seat-e.md `709f4726d`

Seat E (m-857) closed before its last review round. These corrections stand
over its file; seat-e.md itself is left as it landed.

1. **Its axis commands do not run** (`gh run list` has no `--paginate`, jq
   cannot subtract two date strings, axis 1 takes a mean over successes
   only). The axes are measured from M-RUNS / M-JOBS (section 1.1) instead.
2. **Red minutes per day is 1,339, not 1,498.** 1,498 min is the median push
   to GREEN; red minutes per day is axis X2.
3. **The hourly non-replaceable run guarantees a verdict every hour, not a
   green one.**
4. **"6 runners (3 online, 0 busy)" is one sample** with no output pasted.
   Capacity numbers come from seat A (section 2.4, 3,819 CAP ticks).
5. **The wf 30 jobs are `test`, `plan`, `deploy`, `docs` and `newest`**
   (`grep -n "^  [a-z-]*:$" .github/workflows/30_wui-build-deploy.yml`),
   not publish-docs / sync-blog.
6. Its shard and runner targets (axes 4, 5) are dropped: more shards cannot
   help while about 3 runners are online (seat A).

Kept from seat E: the flow map (triggers and concurrency of wf 10, 20 and
30), the latency model (1.5 x W expected, 2 x W worst), that superseding costs
attribution and latency rather than runner time, the merge-queue trade-off
(F6), and that neither deploy waits for wf 10 (section 2.1).

### 3.2 Seat B: the reds are defects, mostly in suites pre-push cannot run

From seat-b.md `fe55b9b85` (wf 10 master, newest 1000 runs, 2026-10-08T19:50Z
..2026-10-12T06:36Z, n=127 verdicts, 96 of 109 failure runs with jobs):

1. **Red 76.8 of 82.8 h** (92.8 %), 11 streaks; the longest, R9, is 42.51 h
   of overlapping assertion failures.
2. **Non-code reds are rare.** 1 of 96 red verdicts has only timeout or
   runner-lost first-red jobs (1.0 %), 2 of 96 with the one opened e2e flake
   (R8). 95 of 96 carry an assertion failure. Timeouts and lost runners are
   21 of 209 first-red job ROWS (10 %), almost all beside a real failure.
3. **46 % of first-red rows (97/209) are suites with no local pre-push
   part:** browser e2e 48, nuxt generate 31, orc feature tests 18. Editor
   re-check on `fe55b9b85`, `csi-spl-iac/src/bash/run/check-pre-push.func.sh`:
   `grep -c test:e2e` 0, `grep -c perf-budget` 0, `grep -c run-ci-tests` 0,
   `grep -c wui-e2e` 7 (the capped e2e part from `744f8d4f8`, after the
   window).
4. **One ceiling, measured: the gzip budget.** 31 of 31 generate first-reds
   failed the step `Initial JS gzip stays within the performance budget`.
   Editor re-check: `gh api repos/csitea/csi-spl/actions/jobs/113792563218/logs
   | grep "FAIL ci_"` -> `FAIL ci_initial_gzip_kb 155.1 > 155` and
   `FAIL ci_home_gzip_kb 352.9 > 352.1` (run 37921855024, sha `9900bfae34`),
   as seat B states. The build sits 0.1 KB over the line and crosses it
   again after each green.
5. **The parts that exist are skipped, by design.** On the 38 failing shas
   with a local PASS, the red CI suite was `SKIP-untouched` locally on 21;
   only 2 rows are a part that ran and passed, then failed in CI.
   `WARN-pre-existing` (orc 20, iac 14, api 2 attempts) lets pushes land on a
   red suite, which is how R9 lasted 42.5 h.
6. **`gate10-fail-fast.tst.sh` was a 3 s clock race, n=3** (runs
   38190838689, 38197054999, 38209222818), fixed by `f3c92877a`; pre-push
   missed it because it only fails on a loaded runner.

**What it changes here:** X8 is redefined (section 4) and F1 becomes
"clear the standing defects", not "fix the flakes" (section 5).

## 4. The axes (ONE set, 5-8)

Each axis: what it measures, the exact command, the baseline now (with sha,
window and n) and the target. Every round of the CI-refactor seat reports its
before and after on every axis.

| # | axis | how it is measured | baseline (window, n) | target |
|---|---|---|---|---|
| X1 | **push to verdict**, p50 / p90 min: each push to the first later run that ended success or failure | M-RUNS (1.1); seat A appendix A, line `push-to-verdict` | 81 / 163 (editor, 48.4 h, n=626); 72.9 / 154.2 (seat A, 62.8 h, n=809) | p50 <= 30, p90 <= 60 |
| X2 | **red minutes per day** on the master tip (time since the newest verdict was a failure) | M-RUNS, verdicts ordered by `updated_at` | 1,339 min/day = 96% (n=51 verdicts) | <= 120 |
| X3 | **verdicts green**, % = success / (success + failure) | M-RUNS | 6% (3 of 51) | >= 80% |
| X4 | **critical-path run time** of a completed run, p50 min | seat A appendix A, line `run_on_path` | 32.9 (n=82) | <= 20 |
| X5 | **code job-minutes per completed run**, median of the per-run sums | M-JOBS; seat C C-X2 | 152.2 (seat C, n=51); 158 (editor, n=66 started) | <= 60 |
| X6 | **runner queue on the critical path**, p90 min | seat A appendix A, line `queue_on_path` | 24.0 (n=82) | <= 3 |
| X7 | **jobs at timeout risk** (p90 over 75% of `timeout-minutes`) | `cd csi-spl-iac && CI_GATE_RUNS=100 ./run -a do_report_ci_gate`, block `timeout headroom` | 6 of 13 (n=12) | 0 of 13 |

| X8 | **first-red job rows on a suite pre-push cannot run** (browser e2e, nuxt generate / budget, orc feature tests), % of first-red rows | seat B section 0 first-red rule (drop jobs annotated `gate fail-fast: stopped`), seat-b.md axis A2 | 97 / 209 = 46 % (96 red runs, 82.8 h to 2026-10-12T06:36Z) | <= 10 % |

**Why X8 is not the non-code share.** The draft reserved X8 for the share of
red verdicts that are flake, timeout or lost runner. Seat B measured it at
1.0 % (2.1 % with the R8 flake, n=96), already under its 2 % target, so it
cannot steer a round. It stays as a guard indicator below. The lever that
does move the red is the share of reds that no local gate could have caught.

- **What the owner feels: X1..X3. The levers: X4..X8.** Each refactor round
  reports before and after on all of them, from the same window length.
- **Supporting indicators**, not targets: non-code red verdicts (seat B
  X8, 1.0 %, guard under 2 %), generate budget breaches (seat B A3, 31/31),
  local PASS then the same suite red in CI (seat B A5, 2 rows), share of runs that ran wui-e2e
  (seat C C-X4: 100% today vs 27.7% of pushes touching wui), docs-only pushes
  with a verdict and no code job (C-X3: 0 of 220), queue minutes with 3 or
  fewer runners online (seat A A4: 62%), and per-suite job duration p50 / p90
  (seat D).
- **Superseded runs are not an axis.** Cancelling a pending run costs no
  runner time (565 of 631 never started a job); its cost already shows in X1.
- **One command for all of them.** Today they come from three scripts.
  Fix F0 below turns them into one named action, as the owner's "nothing ad
  hoc" rule asks.

## 5. Candidate fixes, ranked by expected axis gain per effort

Signed ranking (v1.0). Effort: S = one
lane, under a day; M = one lane, a few rounds; L = several lanes or a policy
change. One fix per refactor round, each measured on X1..X8.

| rank | fix | axes it moves (expected) | effort | risk | from |
|---|---|---|---|---|---|
| F0 | **`do_report_ci_axes`**: one named action that prints X1..X8 from M-RUNS + M-JOBS (+ sat cron.out for queue), with its test | none itself; every later round is measured with it | S | none | editor ("nothing ad hoc") |
| F1 | **Clear the standing defects, and close the suites pre-push cannot run**: get the initial JS back under the gzip budget with headroom, or reset the budget with the owner (31/31 generate first-reds); give orc feature tests and the budget a local part, next to the new capped e2e part; fix the known clocks (calendar e2e K4, gate10 done in `f3c92877a`); orc hermetic headroom (done in part, `94cd17be3`) | X3 6% -> most verdicts green; X2; X8 46% -> <=10%; X7 6 -> <=2 | S..M | low | c-002, seat A, seat B |
| F2 | **Per-job selection with a per-job base** (K8 = K1 done safely): job J skips when nothing since J's own last success touches its inputs; fail-safe full gate on workflows, shared libs, lockfiles, unmapped paths; the **hourly verdict always full**; a drift test keeps the map in step | X5 152 -> ~55 job-min (seat C models 58-65% saved on a green trunk); X4 on non-wui pushes drops to the slowest non-e2e path (hub ~15-29 min); X1 follows X4 (about two minutes per minute cut, seat A) | M | an allow-list miss, bounded to one hour by the full hourly verdict | seat C, editor |
| F3 | **Do not park runners while a gate job is queued**, within the 80% CPU ceiling (budget policy in `apply-gh-runner-cpu-budget.func.sh`) | X6 24 -> <=5 min (62% of queue minutes fell with <=3 online); X4 a little | S | agents get less CPU while the gate runs | seat A |
| F4 | **Shorten the e2e shard** (the critical job in 70 of 82 runs): rebalance the shards on the per-file times the runner already logs (5.5 min spread today), then speed up the phone and calendar files, reuse one browser per shard, cut fixed sleeps | X4 32.9 -> ~25; X7; X1 | M | flakes from shared browser state | seat D |
| F5 | **Name the lane that caused a red, at once** (K7), and time-box `WARN-pre-existing` so a waiver cannot keep a suite red for a day (R9: 42.5 h) | X2 (time a red stays) | S | noise if attribution is wrong (one verdict covers ~10 pushes) | c-002, seat B |
| F6 | **Merge queue** (K9): the verdict runs before the land | X2 -> ~0 | L | every land waits ~W; a flaky gate blocks all lands, so only after F1..F4 | seat E |

Not ranked, for the owner (section 6): **deploys do not wait for the gate**
(section 2.1). Gating prd on a green wf 10 would trade deploy speed for
safety while the gate is red 96% of the time; today that would stop every
deploy.

Why this order: F1 first, because a per-job base (F2) keeps re-running a red
job until it is green, so selection pays off only once the reds are not
permanent. Seat B confirms it: 95 of 96 red verdicts are assertion failures,
and almost half of the red rows come from suites no local gate runs. F3 is a small policy change with a large queue cut. F4 is the
largest single run-time cut but takes several rounds. F6 is last because it
amplifies whatever red rate is left.

### 5.1 Already landed before v1.0

The owner ordered CI actions directly (t1 f67e3656, msg 52474112) while the
panel was still writing, so parts of the list are built. Check:
`git log --oneline 8c4f2c4fe..fe55b9b85` and `git log -1 8a79c19c1`.

| commit | what | fix |
|---|---|---|
| `8a79c19c1` | wf 10 runs only the parts a push touched, each from its own last green run; schedule run = full gate | F2 (lane L1) |
| `744f8d4f8` | pre-push runs the e2e files a WUI change touches, at most 6, 240 s | F1, part of X8 |
| `94cd17be3` | orc hermetic shards packed by measured time (worst shard -15 %) | F1 headroom / X7 |
| `f3c92877a` | gate10-fail-fast test ordered by events, not a 3 s clock | F1 |

Their effect is not measured yet: the CI-refactor seat's first job is F0, then
the before/after of these four on X1..X8.

### 5.2 The candidates as they came in

c-002's 7 actions, posted to the owner
(https://spool-hub.ai/m/a3cf1826-933b-4279-9f9d-4d9f207791d1; n=60 runs,
2026-10-11T20:53Z..2026-10-12T06:07Z): K1 run only the touched parts (-> F2);
K2 full gate hourly + selective per push (-> F2, hourly verdict); K3 CI gets
its own CPU (-> F3, the cheap half); K4 pin the calendar e2e clock (-> F1);
K5 fix the iac fail-fast and lane-mix tests (-> F1); K6 make the slowest
suites faster (-> F4); K7 a red names its lane (-> F5). K8 per-job base
(editor, seat C) -> F2. K9 merge queue (seat E) -> F6.

## 6. Open questions

1. **For the owner: should prd deploys wait for a green gate?** Today wf 20
   and wf 30 deploy on their own `test` job (section 2.1). While the gate is
   red 96% of the time, gating would stop every deploy, so this comes up
   after F1/F2 at the earliest.
   **Owner decision** (HUM-10, msg `a6f36b11`): "yes, but not now, and per
   job, not the whole gate". After F1 + F2, a prd deploy waits only for the
   green jobs that test its inputs, on its own sha: wf 20 for the hub job,
   wf 30 for the wui jobs. dev never waits. The switch goes on when the
   master red share is under 20 % over 48 h (`do_report_ci_axes`); it is
   scheduled as the CI-refactor round after F2, and every round reports the
   red share until then.
2. ~~For seat B: the share of non-code reds.~~ Answered: 1.0 % (2.1 %),
   section 3.2.
3. ~~For the builders of F2: the per-job base needs the last success per
   job, not per run. Is the jobs API enough, or does the gate write it?~~
   Answered by `8a79c19c1`: the jobs API. wf 10's classify step reads the
   jobs of the newest 15 finished push/schedule runs on master; a part with
   no all-green run in that window runs in full (the safe side). How often
   that fallback fires: section 7.2.

## 7. Editor state (2026-10-12, at v1.0)

- All seats folded: A `542870ae9`, B `fe55b9b85`, C `15fe61d85`, D
  `f88aa9356`, E `709f4726d` with editor corrections (3.1).
- v1.0 signed here and in spec.md; ACCEPTED goes to the live seats (A c-298,
  B g-858@sat, C c-297, D a-295) only after this commit landed.
- Next: the CI-refactor seat (this editor), one ranked fix per round, F0
  first, then the before/after of section 5.1 on X1..X8.

### 7.1 CI-refactor seat state (2026-10-12 08:10Z, for a successor)

Seat brief: c-001@sat msg 294f6453 (inline, task ci-gate-analysis); report
each round to c-001@sat on task `ci-refactor-seat`, cc the dispatch holder.

- **Round 1 = F0, landed `70976ffe4`**: `cd csi-spl-iac && ./run -a
  do_report_ci_axes` (window `CI_AXES_SINCE` / `CI_AXES_UNTIL`, cache
  `~/.cache/csi-spl/ci-axes`), test `report-ci-axes.tst.sh`. On the editor
  window 2026-10-10T06:00Z..10-12T06:25Z it reads X1 81.4 / 163.1, X2 1384
  min/day (96 %), X3 3 of 52, X4 38.4, X5 154.6, X6 22.3, X7 6 of 14,
  X8 61 % (71 of 116), guard 1 of 49. Not yet reported to c-001.
- **Round 1 reported** to c-002 (dispatch holder) on `ci-refactor-seat`,
  2026-10-12T08:13Z.
- **X8 cross-check, settled** (round 2): on seat B's exact window
  (2026-10-08T19:50:22Z..10-12T06:36:15Z, n=963 runs, 109 failure runs
  read) the tool reads 57 % = 111 of 195; `X8 by kind: failure 98, timeout
  11, runner-lost 2`. Seat B's 97 counts the failure rows only (seat-b.md
  line `A2`: "timeouts on those jobs are extra"), so the numerators agree
  (98 vs 97). The denominators differ by seat B counting a cancelled job
  whose annotation never loaded as a first red (seat-b.md section 0); the
  tool skips such a job. Both readings now come from one command: the
  `X8 by kind` line, landed with this state.
- **Round 2 = before / after of 5.1** (`do_report_ci_axes`, cache warm,
  measured 2026-10-12T08:15Z on tip `9704d4cb2`):

  | axis | before: 10-11T06:59:49Z..10-12T06:59:49Z (n=290 runs, 23 verdicts) | after: 10-12T06:59:49Z..08:15:15Z (n=17 runs) |
  |---|---|---|
  | X1 p50 / p90 | 93.8 / 274.8 | no verdict yet: 15 pushes waiting, 13 runs cancelled, 4 running |
  | X2 | 1,298 min/day (90 %) | n/a |
  | X3 | 13 % (3 of 23) | n/a (0 of 0) |
  | X4 | 40.9 | n/a |
  | X5 | 190.9 | n/a |
  | X6 | 29.3 | n/a |
  | X7 | 3 of 12 (hub go test 81 %, orc hermetic 1/2 85 %, 2/2 84 %) | n/a |
  | X8 | 53 % (31 of 58; failure 27, timeout 3, runner-lost 1) | n/a |

  The after window has **no verdict at all** in 75 min: every run either
  was superseded or is still running. The four fixes cannot be judged
  until runs finish; the read is due again once c-294's hourly
  non-replaceable verdict has produced >= 3 verdicts after 06:59:49Z
  (`CI_AXES_SINCE=2026-10-12T06:59:49Z ./run -a do_report_ci_axes`).
- **Also landed, 2026-10-12 08:28Z: `054bf5ee5`**, c-001's unowned red
  (wf 10 run 38219467553, sha `d36a4e647`, orc feature tests,
  test-spool-poke-queue "they sort oldest-first"): the poke file name read
  the clock twice; now once. The new boundary check fails with the old
  writer (103 / 1) and passes with the fix (104 / 0). At 09:00Z its scanners
  (61, 64, 67) were green and wf 10 run 38223810797 was still in progress.
- **Reports, where they go:** every round result and fix goes to the
  lease-show dispatch holder on task `dispatch-f67e3656`, cc c-001
  (`--to orchestrator`; c-001 msg 94ced2c0). When c-002 sends the id of the
  standing #refactoring topic (msg 3edf80ba), post each round there:
  the X1..X8 before and after, what changed, the next target. Round 1, the
  fix and round 2 have been reported; never send them again.
- Next round: watch wf 10 run 38223810797 (a red in orc feature tests is
  this seat's), re-read the after window (above), then F1 from section 5.

### 7.2 How often a part falls back to the full run (Q3, measured 13:10Z)

Asked by c-002 (msg `f6d8c4c1`). Since `8a79c19c1` wf 10's classify step
lists the newest 15 push/schedule runs that ended `success` or `failure`
(`10_ci-quality.yml`, `per_page=15`, `awk 'NR <= 15'`), and a part with no
all-green run among them prints `no green <part> run listed: run it`
(`ci-doc-only.sh` line 178).

- **Window:** wf 10 master push runs created 2026-10-12T07:05:52Z
  (`8a79c19c1`) .. 12:54:02Z (`8a625588f`): n=38 runs, 26 cancelled before
  any job, so **12 classify logs** = 60 part decisions (5 parts each).
  Command: `gh run list --workflow 10_ci-quality.yml --branch master
  --event push --limit 300`, then per run `gh api
  repos/<repo>/actions/jobs/<classify job id>/logs | grep 'ci-doc-only:'`.
- **Window fallbacks: 0 of 60** (`grep -l 'no green' log.*` -> 0 of 12).
- **Margin:** the oldest base any part used was wui's `b49e2580a9b2`
  (4 runs in a row, 07:44Z..09:51Z, while wui stayed red); at the deepest it
  sat at **position 8 of 15** in the window (run 38232567250; position =
  its rank among the success/failure runs with a smaller run id, so +-1 for
  runs finishing during classify). Every other base sat at 3..5.
- **The full runs come from elsewhere:** 5 of 12 runs ran every part
  because their ranges read `parts=all` (a gate script, `.github` or an
  unmapped path) or touched all five parts, not because a base was
  missing. One run (`889abb940`, docs only) skipped all five parts; 6 more
  skipped wui (one of them also cnf).

Reading: at today's verdict rate (17 success/failure runs 05:40Z..12:54Z,
~2.4 an hour) a part has to stay red for ~6 h before its green base leaves
the window. The safe-side fallback
has not cost a run yet; `parts=all` from the range is the larger lever.
Re-measure when a part stays red for more than 4 h.

## 8. Sign-off

| version | date | by | what |
|---|---|---|---|
| v0.1 | 2026-10-12 | c-296 | skeleton |
| v0.2 | 2026-10-12 | c-296 | editor re-measure (1.1), express-lane finding (1.2), draft axes X1..X6 |
| v0.3 | 2026-10-12 | c-296 | panel roster; candidates K1..K8 (c-002 7 actions + express base) |
| v0.4 | 2026-10-12 | c-296 | seat C folded (2.2) |
| v0.5 | 2026-10-12 | c-296 | 2.1 latency model, deploys do not wait for the gate; D, E in review |
| v0.6 | 2026-10-12 | c-296 | seat A folded (2.4, 2.5); K9 merge queue |
| v0.7 | 2026-10-12 | c-296 | folded axis set X1..X7 (X8 for seat B); draft ranking F0..F6 |
| v0.8 | 2026-10-12 | c-296 | seat D folded (2.6) |
| v0.9 | 2026-10-12 | c-296 | seat E folded with editor corrections (3.1) |
| **v1.0** | 2026-10-12 | c-296 | seat B folded (3.2); X8 = first-red rows with no local part; F1 = standing defects; 5.1 landed fixes. **Signed.** |
| v1.1 | 2026-10-12 | c-296 | 6 Q1 owner decision (`a6f36b11`), Q3 answered (`8a79c19c1`), 7.2 window fallback 0 of 60 |
