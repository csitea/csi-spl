# 131: Why trunk stays red for hours (CI L6)

Status: **proposed** (c-199, 2026-10-11). Refactor rule 3d22fcea: the
dispatch holder's agreement is enough; no owner go.

## 0. The owner's ask

prd t1 topic f67e3656, msg c908bfaa, HUM-10: "The CI/CD is once again failing
all of the time. Special effort for fixing it and refactoring it is needed."
Lanes L1..L5 fix today's reds. This spec (L6) is the refactor: why a red job
stays on master for hours with nobody owning it.

## 1. Measured

Tree `6b1141c36`, wf 10 (`10_ci-quality.yml`) on master, the last 100 runs,
2026-10-11T07:30Z..14:54Z (n=100 runs, 124 jobs that started). Sources:
`CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (iac), and
`gh api .../actions/runs/<id>/jobs` plus `.../check-runs/<job>/annotations`
for every run.

### 1.1 Cadence: one verdict per ~40 min, pushes every ~2 min

| fact | value |
|---|---|
| commits on master in the window | 103, median gap **2.3 min** |
| runs that never started a job (pending, superseded by design: `cancel-in-progress: false` keeps one pending run per ref) | 89 of 100 |
| runs that started | 11 (4 failure, 3 "cancelled" by a job timeout, 1 cancelled by hand, 1 timeout + manual, 2 running) |
| green runs | **0** |
| wall time of a started run | 42..88 min (2,521..5,279 s) |

### 1.2 Job wall time and queue wait (finished success/failure jobs only)

| job | n | median s | max s | timeout | median queue s |
|---|---|---|---|---|---|
| wui e2e 3/3 | 4 | 1,971 | 2,317 | 45 min | 17 |
| wui e2e 2/3 | 4 | 1,895 | 2,150 | 45 min | 174 |
| wui e2e 1/3 | 5 | 1,730 | 1,856 | 45 min | 69 |
| hub (go test, Postgres, GCS) | 7 | 948 | 1,554 | 35 min | 36 |
| orc hermetic 1/2 | 5 | 918 | 1,025 | **20 min** | 263 |
| orc hermetic 2/2 | 5 | 520 | 1,167 | **20 min** | 75 |
| wui unit + typecheck | 8 | 422 | 586 | 15 min | 2 |
| iac | 8 | 362 | 551 | 20 min | 336 |
| orc features | 7 | 317 | 471 | 15 min | 12 |
| wui nuxt generate | 7 | 302 | 387 | 15 min | 2 |

Critical path: generate (5 min), then the slowest e2e shard (33 min): ~38 min
before any queueing. Six runners (`sat-spl-01..06`) serve ~15 jobs per run.

### 1.3 A timeout reads "cancelled", and nothing counts it

GitHub concludes a job that hits `timeout-minutes` as **cancelled**, with the
annotation "The job has exceeded the maximum execution time of <N>m0s". Of the
22 jobs that started and ended cancelled, **18 were timeouts** and 4 were a
manual cancel (annotations, n=22):

| job | timeouts |
|---|---|
| orc hermetic (1/2 + 2/2) | **8** |
| wui e2e (3 shards) | 3 |
| orc features | 2 |
| wui nuxt generate | 2 |
| wui unit, iac, hub | 1 each |

3 of the 11 started runs (38133432048, 38141214928, 38143189651) read
"cancelled" only because of a timeout. `do_report_ci_gate` reads failed runs
only, so it showed none of these 18 reds. The run list puts them among the 89
superseded runs.

### 1.4 How long L1..L5 stayed red, and why pre-push let them through

| lane | red | introduced | fixed | red for | why pre-push missed it |
|---|---|---|---|---|---|
| L1 | e2e `/login links row` | 462bc14f9 06:59Z | 01ef0f649 11:11Z | **4.2 h** | e2e is CI only (`check-pre-push.func.sh:144`: the wui part never runs e2e) |
| L2 | e2e `390px print and TOC buttons` | 83849bda4 06:41Z | 3521a38d5 13:57Z | **7.3 h** | the same: a page change broke an existing e2e assert |
| L3 | orc `RS-HANDOFF FAIL (never OK)` | none | none | 0 | never red: the report counted a PASS line (a fix is queued in another lane) |
| L4 | hub `internal/store 1200.8s` | n/a (grew) | open (c-831) | >= 3.5 h | `hub-pg` is CI only (fast tier) |
| L5 | orc features `tail is oldest-first` | a flake, 16 of 40 | 878c78f13 14:45Z | ~6 h | a flake: pre-push passes it about half the time |

For L1 and L2 the report names run 38126169430 (`c9af31f4`, 08:49Z) as the
first red, **1.8 h after** the introducing push: the runs in between were
superseded or cancelled. The sha of the first red run is therefore not the
sha that broke it. It is the end of a range.

### 1.5 Why nobody owned it

Nothing turns a red job on master into a message. Each red was found by a
lane reading the run list by hand. L1 and L2 were noticed after ~2 h and
fixed after 4.2 h and 7.3 h.

## 2. Changes (at most 5), each with its counting test

### C1. A timeout counts as a red in `do_report_ci_gate`

The report reads every started run (success, failure **and cancelled**). A
job whose annotation says "exceeded the maximum execution time" counts as a
red job, `timeout` on its own line, and its run counts as `timeout`, not
`cancelled`. Superseded runs (no job started) stay `cancelled`.

- Files: `csi-spl-iac/src/bash/run/report-ci-gate.func.sh` and its test.
- Test (`report-ci-gate.tst.sh`, stubbed `gh`): a fixture with one cancelled
  run whose job carries the timeout annotation -> the report prints
  `1 timeout` and lists the job under failures per JOB. CONTROL: the same
  fixture through the old failed-runs-only reader -> 0 red jobs.

### C2. ONE note per red job on master, with the suspect range

A new action, `do_report_ci_red_note` (iac). For each job that is red
(failure or timeout) on the newest finished wf 10 run on master, it takes the
range `<last green sha of that job>..<first red sha of that job>` (both are
already found by `_rcg_last_green` / `_rcg_first_red`). It lists the commits in
that range that touch the job's inputs. The first cut is the top dir:
`csi-spl-wui/` for wui, `csi-spl-orc/` for orc, `csi-spl-api/` for hub,
`csi-spl-iac/` for iac. It sends ONE spool note (kind `blocker`) to the
current dispatch lease holder on task `dispatch-ci-red`, keyed by the
job's red streak. A red that is still red on the next tick sends nothing. A job that turns green sends one `green` line on the same key. The
dispatcher routes the note to the lane that landed the suspect commit. The
dispatch sweep cron runs the action every 10 min.

- Files: `csi-spl-iac/src/bash/run/report-ci-red-note.func.sh` and its test;
  the box cron row `ci-red-note` (`csi-spl-orc/cnf/box-crons/box-crons.manifest`,
  `csi-spl-orc/src/bash/scripts/ci-red-note-cron.sh`). Every box runs it;
  only the box of the lease holder sends. A gate-fail-fast stopped job is no
  verdict. Dispatch holder (2026-10-11): one note per red streak, never into
  an owner topic.
- Test (counting, stubbed `gh` and `SPOOL_SEND`): the same red over three
  ticks -> exactly **1** send; a second red job -> 2; the first job green ->
  one `green` send; the range lists only commits that touch that job's dir.
  CONTROL: with the state file disabled -> 3 sends for 3 ticks, so the key is
  what removes the duplicates.

### C3. orc hermetic: 2 shards -> 4

orc hermetic timed out 8 times in 11 started runs. Its median of 918 s
against a 1,200 s limit is 1.3x headroom, and a loaded runner doubles the
time. Split the job into 4 shards by the file timings the suite already
logs, so that each shard's median is <= 50 % of its timeout.

- Files: `.github/workflows/10_ci-quality.yml` (the `orc-suite` matrix only),
  plus the orc runner's shard selector if it needs a 4-way split.
- Test (orc, reads the workflow): the `orc-suite` matrix has 4 shards, and the
  shard selector puts every `*.tst.sh` in exactly one shard (files over all
  shards == count of `*.tst.sh`, no duplicates). CONTROL: the 2-shard matrix
  fails the shard-count assert.

### C4. Print the timeout headroom, so the next timeout is seen coming

`do_report_ci_gate` adds one section: for each job, the p90 of its finished
wall times in the window against its `timeout-minutes` (read from the
workflow). A job over 75 % prints `AT RISK <job> p90 <s> of <timeout> s`.

- Files: `report-ci-gate.func.sh` and its test.
- Test: fixture jobs with p90 at 80 % of the timeout -> one `AT RISK` line;
  at 70 % -> none. CONTROL: on today's data, orc hermetic 1/2 (p90 > 1,000 s
  of 1,200 s) is flagged.

### C5. `host-spool-no-rebuild.tst.sh` never writes the caller's repo (c-829 leftover)

The test runs `git -C "$A" init/add/commit` on a fixture. With `GIT_DIR`
exported (a git hook exports it, so the pre-push hook does), `-C` does not
choose the repository, and the fixture commits land in the CALLER's repo.
The fix: the test unsets `GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE` first.

- Files: `csi-spl-orc/src/bash/tests/host-spool-no-rebuild.tst.sh`.
- Test (a guard around the same file): run it with
  `GIT_DIR=<a throwaway repo>/.git` exported -> that repo's
  `rev-list --count HEAD` is unchanged. CONTROL: without the unset, the count
  grows (the leak).

## 3. Not in this spec

- L1..L5 themselves (their own lanes), and `internal/store` speed (c-831, L4).
- e2e in pre-push: a nuxt generate (5 min) plus Chrome on every push is the
  cost the fast tier was built to remove (`pre-push-gate.md` section 1). C2
  shortens the time until a red reaches an owner instead of moving e2e
  earlier. Revisit, with a measurement, if C2 does not bring red-to-owner
  under 30 min.
- `cancel-in-progress` or more runners: the pending-run supersede is by
  design and costs no runner time.

## 4. Done when

- C1..C5 have landed with their tests and controls green in wf 10.
- Re-measured over the next 100 master runs: every timeout shows in the
  report, every red job has exactly one note, and the note goes out <= 15 min
  after the first finished red run.
