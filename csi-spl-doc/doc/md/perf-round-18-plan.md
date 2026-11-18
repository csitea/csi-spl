# Perf round 18 (p18) - plan (2 rows, v0.1)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5903  
Topic: 5535ab88-d12b-4203-a24d-b82600a872a5  

This is the twelfth round under section 4 of [rounds-rulebook.md](rounds-rulebook.md)
(perf rounds). The plan points to the rules and does not copy them:

- Sections 1 to 3: at most 10 rows; per row, aim for 1 push, up to 3, never
  more than 5; R1-R16.
- Sections 4.1 to 4.5: every row is measured first and lands with a counting or
  timing test and its red control. A candidate with no measured gain is
  dropped.
- Section 5: aim at 2 rows; 1 row is a round.

Owner orders that bind this round:

- Owner HUM-10 msg 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- Owner HUM-10 msg 98dedfc4: under the 20% perf floor, the holder requests the
  next perf round's planner instead of refactor round N+1's (rulebook 4.4).
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Every row's
  vendor is claude.**

**Status: v0.1, draft for the panel.** Editor: c-856 (claude).

**Why now.** The holder's brief (c-002, 2026-11-18 14:5xZ, on
`405fe0885`):

- Perf round 17 is served: p17-01 `b97a764ff` and p17-02 `a58cc3434` are on
  `origin/master`.
- The 4.4 check on `897e67e13` (15:10:21Z), re-run by this seat (n=1):
  `perf 27 refactor 93 perf-share 22.5% floor-met`.

The slug (rulebook 5.3), read at 15:10:21Z on `897e67e13`: `Window:
W=2026-11-18T11:38:14+01:00` (the newest `docs(p17-plan` commit);
`git log origin/master --since="$W" --oneline -E --grep='\(p18-' | wc -l` ->
`0`; `git ls-remote origin 'refs/heads/review/p18-*' 'refs/heads/wip/*p18*'
'refs/heads/*-p18-*' | wc -l` -> `0`.

**One sha.** Every row baseline below is named on **`897e67e13`**
(`origin/master` at 15:10Z, 2026-11-18). The CI numbers come from the 8
newest green wf 10 runs after p17-01 landed, heads `17f9cc2d2` ..
`a58cc3434`; every file the rows read (`10_ci-quality.yml`,
`run-all-tests.sh`, `cli-cross-build.tst.sh`, `build-stripped.tst.sh`,
`ci-disk-guard.sh`) is the same on those heads and on `897e67e13` (`git log
--oneline 17f9cc2d2..897e67e13 -- <them>` -> 0 lines). Raw commands and
outputs: [perf-round-18/editor.md](perf-round-18/editor.md).

**Retro.** There is no `perf-round-17-retro.md` on `origin/master` (only
`perf-round-17-plan.md` and `perf-round-17/editor.md`). This plan does not
stand in for it and does not guess its content. It reads
`perf-round-17-plan.md` (its section 6 first), `perf-round-17/`,
`perf-round-16-plan.md` and `lesson-speed-up-measure-first.md`.

<a id="p18-how-to-read"></a>

## 1. How to read this

- A row is one logical change made by one lane, with the subject
  `perf(p18-<NN>-<slug>, SPL-<n>): ...` and the review branch `review/p18-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number and `n`, on `897e67e13` and the
  named CI runs.
- **After** = what the editor's probe left of that number, and how it is
  known, or "computed, not measured" where no second arm ran. The lane
  re-measures both arms.
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `iac/` = `csi-spl-iac/`, `wf10` = `.github/workflows/10_ci-quality.yml`.

<a id="p18-inputs"></a>

## 2. Where the rows come from

Inputs read (brief step 2). Each carried finding was re-checked on
`897e67e13`, or says it was not:

| input | finding | on the tree | here |
|---|---|---|---|
| new, this seat: wf 10's jobs after p17-01, 8 green runs | the hub-suite job is now the slowest job | mean 1,040 s, n=8; the e2e shards 876..998 s (editor 2.1) | rows 01, 02 |
| new, this seat: the last 100 green wf 10 runs | how often the hub-suite job ends the run | 16 of 73, by 6..244 s; 13 of the 16 ran no e2e (editor 2.2) | row 01 |
| new, this seat: the hub-suite logs, n=8 | it builds cold: no `GOCACHE` restore in the job | the spool build of the host target after a warm one 2..5 s, the 3 cold targets 49..76 s each (editor 2.3) | **row 01** |
| new, this seat: the hub-pg logs, n=8 | its disk free-up is no longer needed | 100 s mean (58..145); 88 GB free before it, cache 2.2 GB unpacked, guard needs 10 GB (editor 2.5) | **row 02** |
| `perf-round-17-plan.md` section 6: `spl_spawn_place_brief`'s `\| tail -1` | R1 with refactor round 62 row 02 and SPL-5897 | r62-02 not landed (`git log origin/master --oneline -E --grep='\(r62-'` -> r62-01 and plan commits) | section 6, carried (R1) |
| p17 section 6: the `dirname` calls at load | far over 5 sites | not re-measured | section 6, carried |
| p17 section 6: the hub job | "the next critical path once row 01 lands" | confirmed: editor 2.1 to 2.3 | rows 01, 02 |
| p17 section 6: `api` full tier remainder, `lint-gosec` | no faster form probed | not re-measured | section 6, carried |
| p17 section 6: WUI AC-02 initial download | needs the CI node | not re-measured | section 6, carried |
| p17 section 6: per-case wait audit, `iac-cross` | carried from p14..p16 | e2e file tail read (editor 2.6): no fixed per-file cost; top file 243 s | section 6, carried |
| `perf-round-17/editor.md` | p17's measurements | read; its numbers are on `e5f867463` and not reused | - |
| `perf-round-16-plan.md` | read through p17 section 6 | - | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: the job and step times (editor 2.1, 2.5), the in-run warm/cold control (2.3), the box A/B (2.4) | - |
| refactor round 62 v1.0, bug round 18 (planner queued) | their row files | read for R1/R3 (3.2) | - |

<a id="p18-rows"></a>

## 3. The rows

| # | id | practice | baseline (command, number, n) | after | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p18-01-ci-hub-suite-go-build-cache)` | the `hub-suite` job restores a Go build cache before `run-all-tests.sh`, with its own key prefix (`go-hub-suite-v1-`, keyed like `hub-pg`'s on go version, `go.sum` and the Go sources, with restore-keys), and saves it on an exact miss only, never from a pull request, after the same trim (mark 61 min before the restore) and size cap (`ci-cache-save-cap.sh`) `hub-pg` uses | editor 2.1, 2.3: the 8 newest green wf 10 runs after p17-01, `gh api .../jobs/<id>` and its log: job mean **1,040 s** (872..1,192, n=8); in its log, `./cmd/spool` for linux/amd64 right after a warm host build **2..5 s**, each of the 3 cold targets **49..76 s** (n=8); cold sections: `build-stripped` 51..82, the 3 cold cross targets 150..225 together, `go vet` 69..106, `go test -race` 330..422 (with the tests themselves). Editor 2.2: the job ends 16 of 73 green runs, by 6..244 s | editor 2.4, box A/B on `897e67e13`, n=2 per arm, cold -> warm `GOCACHE` of the same sources: spool linux/arm64 build **69.4 / 108.0 -> 4.4 / 6.5 s**, `go vet ./...` **100.3 / 139.7 -> 1.9 / 2.4 s**, the `-race -coverprofile` test build **273.1 / 360.5 -> 25.2 / 17.6 s** (load 17..40). Computed, not measured: the 3 cross targets fall to the host target's 2..5 s each (-140..-215 s) and `build-stripped` and `go vet` to their warm share; the lane measures it | `wf10:263-347` (`hub-suite`: the steps after "Set up Go", which gets an `id`); `iac/src/bash/tests/ci-hub-suite-gocache.tst.sh` (new); 2 files | **`ci-hub-suite-gocache.tst.sh`** (new; reads `wf10` with python `yaml`, as `ci-build-once.tst.sh` does): (a) `hub-suite` has an `actions/cache/restore` step on `GOCACHE` whose key starts `go-hub-suite-` and that runs before `run-all-tests.sh`; (b) its save step runs only on an exact miss and not on `pull_request`, after a trim step; (c) CONTROL: `hub-pg`'s restore key prefix is still `go-race-pg-v2-` (no shared entry); (d) CONTROL: a copy of `wf10` with the restore step moved after `run-all-tests.sh` is reported. Red: today's `wf10` -> (a) fails, "hub-suite restores no Go build cache". Also run and green: **`ci-build-once.tst.sh`**, `gate10-fail-fast.tst.sh`, `gate10-concurrency.tst.sh`, `ci-one-gate.tst.sh`, `ci-doc-only.tst.sh`, `gh-prune-actions-caches.tst.sh` (they read `wf10` or its caches), `do_check_pre_push_lint` (actionlint, zizmor on `wf10`). Timing: the lane dispatches wf 10 twice on its throwaway branch (`gh workflow run 10_ci-quality.yml --ref <branch>`; run 1 fills the branch's cache, run 2 restores it) and puts both runs' `hub-suite` section times (the editor 2.3 columns) and the saved entry's size in the commit body | either fleet box | claude / simple_coding | 1 |
| 02 | `perf(p18-02-ci-hub-pg-free-disk-when-short)` | `hub-pg`'s "Free disk on a hosted runner" runs only when the runner is short of disk: the disk guard runs first in a mode that reports, and the free-up runs when free space is under `CI_DISK_NEED_GB` plus the cache's unpacked size (the lane names the margin and why); a run still short after the free-up fails at the guard, as today | editor 2.5, the same 8 runs: the step **100 s** mean (58..145, n=8) of a job mean 724 s; before it **88 GB** free in 8 of 8; the restored cache ~410 MB compressed, **2.2..2.3 GB** unpacked; the guard needs 10 GB | computed, not measured: the step is skipped on every one of the 8 runs (88 GB > 10 + 2.3 GB), -100 s a `hub-pg` job. Not the run's span: `hub-pg` ends none of the 8 runs (runner time and the job's own wall time). The lane measures it | `wf10:378-389` (`hub-pg`: the free-up and the guard); `csi-spl-orc/src/bash/scripts/ci-disk-guard.sh` and its test `csi-spl-orc/src/bash/tests/ci-disk-guard.tst.sh` only if the report mode needs a flag (the lane says); `iac/src/bash/tests/ci-hub-pg-disk.tst.sh` (new); 2 or 3 files | **`ci-hub-pg-disk.tst.sh`** (new): (a) `hub-pg`'s free-up step carries a condition on a measured free-space output, not only `runner.environment`; (b) the hard guard (no report mode) still runs before the cache restore; (c) CONTROL: a copy of `wf10` with today's unconditional step is reported. Red: today's `wf10` -> (a) fails. If `ci-disk-guard.sh` changes: its test, with a red control (a fixture `df` under the need -> the free-up output is set). Also run and green: **`ci-build-once.tst.sh`**, `gate10-*.tst.sh`, `do_check_pre_push_lint`. Timing: one dispatched wf 10 run on the throwaway branch; its `hub-pg` step time and `df` lines in the commit body | either fleet box | claude / simple_coding | 2 |

Every row is claude: rulebook R14 (an established vendor) and the owner's
10-17 rule (no mistral coding or testing).

<a id="p18-batches"></a>

### 3.1 Batches and disjoint files (R1)

- **Batch 1**: row 01. **Batch 2**: row 02, after row 01 lands (R16: within
  30 minutes). Both rows edit `wf10`, so they never run at once (R1); row 02
  rebases on row 01's `wf10`.
  - Row 01: `wf10` (`hub-suite`), `ci-hub-suite-gocache.tst.sh`.
  - Row 02: `wf10` (`hub-pg`), `ci-hub-pg-disk.tst.sh`, maybe
    `ci-disk-guard.sh` and its test.
- Neither row edits `run-all-tests.sh`, a Go file, `spl-spawn-place.func.sh`
  or any file of refactor round 62 or of a live bug lane (3.2).

<a id="p18-r3"></a>

### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-18, each with its time (editor 3):

- **Lane map, every machine**, 15:07:19Z: `--check` of `wf10` and this
  plan's two files -> `free`, rc 0.
- **Spawn queue**, 15:07:33Z: 8 queued, 1 placing (two bug rows, the bug
  round 18 planner, 5 feature or doc lanes). None names `wf10`.
- **Briefs** changed since 2026-11-17T15:00Z, 15:07:47Z: 4 name
  `run-all-tests.sh` or `wf10`; each only runs the suite.
- **Refactor round 62** (v1.0): r62-01 landed (`b36b20577`); r62-02 not
  landed, its files (`spl-spawn-place.func.sh` and tests) are no p18 row
  file.
- **Bug round 18**: planner queued (ask ddda5638), no plan yet. The R3 check
  before each spawn re-reads the map, the queue and the b18 plan if it has
  landed by then.

<a id="p18-per-row"></a>

## 4. Per row: what the lane does

- **01**:
  - Copy `hub-pg`'s pattern (`wf10:392-481`): the "Go build cache path" step,
    the restore, the mark, the trim, the cap, the save. Own key prefix
    `go-hub-suite-v1-`: `hub-suite` builds 4 cross targets, `go vet` and a
    `-race -coverprofile` test, not `hub-pg`'s set, so a shared entry would
    trim each other's builds.
  - `build-warm-mod-cache.tst.sh` keeps its throwaway `GOCACHE`
    (`:40`): it proves a cold box, and the row must not warm it.
  - The repo's actions cache: the lane reads `gh api
    repos/<owner>/<repo>/actions/caches` before and after, and names the new
    entry's size; `do_gh_prune_actions_caches` (its 8 GB mark) still holds.
  - The hosted runner had 87.1 GB (6 runs) or 90.5 GB (2 runs) free in
    `hub-suite` (its disk guard line, `ok - disk free ...`, in the 8 job
    logs of editor 2.3); no free-up step is added.
  - Docs: the step comments are the doc, as for `hub-pg`; the lane writes a
    `Docs: none (...)` line or one line in `pre-push-gate.md` if that page
    names the hub job's cache (it does not on `897e67e13`: `grep -c
    'go-race-pg' csi-spl-doc/doc/md/pre-push-gate.md` -> `0`).
- **02**:
  - The free-up stays for a short runner; only its condition changes. The
    SPL-4777 reason (the restore filled the disk at 6.2 GB) stays in the
    comment, with today's size.
  - The hard guard before the restore does not change: a short runner after
    the free-up still fails with its one line (SPL-4790).

<a id="p18-panel"></a>

## 5. Panel and reviewers (R7)

Read on 2026-11-18 15:11:55Z (editor 4):

- `do_spl_box_pick`: grok `pick=hold` (weekly 99% on both boxes); agy
  `pick=hold`; claude `pick=hold`; mistral `pick=<the other box>`.
- `ENV=prd ./run -a do_spl_hub_agent_kinds` -> `off [qwen], paused []`.
- Dispatch lease holder: `c-002`.

- **Plan panel (rulebook 3.2)**: editor c-856 (claude) and **one mistral
  seat**, as in p12 to p17: grok and agy are on hold at this reading, qwen is
  off. Asked of the holder with the v0.1 sha. The seat signs only a sha this
  editor names, sent to it and the holder.
- **Row reviewers (2.7.2)**: the row authors are claude. Code R7 is the
  holder's pick at placement (grok or agy when one places; otherwise the
  seat the holder names), never a plan seat. A row never pushes without its
  R7 PASS.

<a id="p18-left-out"></a>

## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| `spl_spawn_place_brief`'s `\| tail -1` (`csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`) | **not a row in p18 (R1)**: refactor round 62 row 02 and SPL-5897 edit the same file and are not landed; a later perf round takes it once both land | p16 editor 2.5; not re-measured |
| the e2e long tail (`monitoring-costs.test.mjs` 243 s, `section-strip-scroll-hide` 223 s) | **not a row**: no fixed per-file cost; one file's cut is ~1/8 a shard once the weights follow (computed) | editor 2.6, n=1 run |
| the `dirname` calls at load | carried: over 5 sites | p17 editor 2.3, 2.4 |
| `api` full tier remainder, `lint-gosec` | carried: no faster form probed | p17 editor 2.1 |
| WUI AC-02 initial download | carried: needs a probe on the CI node | p13 section 2, n=1 |
| per-case wait audit; `commit-links`' prd key; `iac-cross`; p5/p6 inputs | carried from p14..p17 section 6 | not re-measured here (no key, no lab) |

No finding of this seat is non-perf work, so no ask went to the orchestrator.

<a id="p18-counts"></a>

## 7. Counts

- Rows: 2 in v0.1 (rulebook 5.1: aim at 2; 1.1: at most 10).
- Every row aims for one push (1.2) and lands with a counting test and its red
  control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --since=2026-11-18T11:38:14+01:00 --grep='(p18-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --since=2026-11-18T11:38:14+01:00 --grep='p18-' --format=%B | grep -c '^review: '` must reach the row count.

<a id="p18-changes"></a>

## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel
signs and the plan lands on `master`, not from the review branch, as in rounds
8 to 17. From then on the Qto doc is the primary copy.

- v0.1 (c-856, 2026-11-18 15:26Z): first draft on `897e67e13`.

<a id="p18-consensus"></a>

## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-856 (editor) | claude | v0.1 | author |
| mistral seat (asked of the holder) | mistral | v0.1 | pending |
