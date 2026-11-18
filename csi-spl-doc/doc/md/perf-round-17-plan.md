# Perf round 17 (p17) - plan (2 rows, v0.1)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5872  
Topic: f758f973-8036-409d-8f83-53536dc310f2  

This is the eleventh round under section 4 of [rounds-rulebook.md](rounds-rulebook.md)
(perf rounds). The plan points to the rules and does not copy them:

- Sections 1 to 3: at most 10 rows; per row, aim for 1 push, up to 3, never
  more than 5; R1-R16.
- Sections 4.1 to 4.5: every row is measured first and lands with a counting or
  timing test and its red control. A candidate with no measured gain is
  dropped.

Owner orders that bind this round:

- Owner HUM-10 msg 3d22fcea: rounds need no owner go (rulebook 1.4, 4.2).
- Owner HUM-10 msg 98dedfc4: under the 20% perf floor, the holder requests the
  next perf round's planner instead of refactor round N+1's (rulebook 4.4).
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows, and a row on
  `csi-spl-wui/` never goes to mistral (developer guide 5.1). **Every row's
  vendor is claude.**

**Status: v0.1, draft for the panel.** Editor: c-705 (claude).

**Why now.** The holder's brief (c-002, 2026-11-18 09:0xZ, on
`cb9902b0f`):

- Perf round 16 is served: p16-01 `48b44328b` and p16-02 `0905076cc` are on
  `origin/master`.
- The 4.4 check on `8de44d393` (09:27:35Z), re-run by this seat (n=1):
  `perf 25 refactor 91 perf-share 21.6% floor-met`.

The slug, read at 09:27:35Z on `8de44d393`:
`git log origin/master --oneline -E --grep='\(p17-' | wc -l` -> `0`;
`git ls-remote origin 'refs/heads/*p17*' | wc -l` -> `0`.

**One sha.** Every row baseline below is measured on **`e5f867463`**
(`origin/master` at 09:16Z, 2026-11-18), on the desk box (16 cpus; the
1-minute load is named next to each timed number). `origin/master` moved to
`8de44d393` at 09:27Z; no row file changed (editor 1). Row 01's CI numbers
come from runs whose heads are older than `e5f867463`; every file that row
reads is the same on those heads and on `e5f867463` (editor 2.7). Raw
commands and outputs: [perf-round-17/editor.md](perf-round-17/editor.md).

**Retro.** There is no `perf-round-16-retro.md` on `origin/master` (only
`perf-round-16-plan.md` and `perf-round-16/{editor,seat-mistral}.md`). This
plan does not stand in for it and does not guess its content. It reads
`perf-round-16-plan.md` (its section 6 first), `perf-round-16/`,
`perf-round-15-plan.md` and `lesson-speed-up-measure-first.md`.

<a id="p17-how-to-read"></a>

## 1. How to read this

- A row is one logical change made by one lane, with the subject
  `perf(p17-<NN>-<slug>, SPL-<n>): ...` and the review branch `review/p17-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number and `n`, on `e5f867463` (row 01:
  and the named CI runs).
- **After** = what the editor's scratch probe left of that number, and how it
  is known, or "computed, not measured" where no second arm ran. The lane
  re-measures both arms on its own named sha.
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `orc/` = `csi-spl-orc/`, `wui/` = `csi-spl-wui/`.

<a id="p17-inputs"></a>

## 2. Where the rows come from

Inputs read (brief step 2). Each carried finding was re-checked on
`e5f867463`, or says it was not:

| input | finding | on the tree | here |
|---|---|---|---|
| new, this seat: wf 10's jobs, 7 green runs | WUI e2e shard 2/8 is the last job of 5 of the 6 runs that ran e2e | mean 1,168 s against 797 s for 1/8 (editor 2.6) | the shard weights (2.7) |
| new, this seat: the e2e weights | 106 of the 367 e2e files CI runs have no weight and take the median | `comm` of the selection and the weights file (editor 2.7); leave-one-out repack on 3 runs: slowest shard 1,064..1,189 -> 909..941 s (editor 2.8) | **row 01** (the carried "CI shard rebalance") |
| new, this seat: strace of the heaviest selected orc tests | `spl-lane-mix.tst.sh` forks `yq` per cnf field | 12-13 `yq` per `do_spl_lane_mix` pick, 31 ms each (editor 2.3, 2.4) | **row 02** |
| `perf-round-16-plan.md` section 6: `spl_spawn_place_brief`'s `\| tail -1` | R1 with refactor round 35 row 04 | r61-04 is not landed (`git log origin/master --oneline -E --grep='\(r61-'` -> r61-01 only) | section 6, carried (R1) |
| `perf-round-16-plan.md` section 6: `dirname` at load in ~182 orc func files | far over 5 sites | a lane-mix pick runs 4 `dirname` (editor 2.4); the strace of `spl-lane-mix.tst.sh` counted 899 before it died, mostly on repo paths (its argv is cut at 32 bytes) | section 6, carried, with this count |
| `perf-round-16-plan.md` section 6: `api` full tier remainder, `lint-gosec` | no faster form probed | 7 days: `api` PASS full n=36, mean 1,868 s; `lint-gosec` PASS full n=95, mean 645 s (editor 2.1); no probe here | section 6, carried |
| `perf-round-16-plan.md` section 6: WUI AC-02 initial download | needs the CI node | not re-measured | section 6, carried |
| `perf-round-16-plan.md` section 6: per-case wait audit, `iac-cross` | carried from p14/p15 | not re-measured | section 6, carried |
| new, this seat: the orc map replay after p16-01 | does a key still over-select? | 257 commits, 4,080 `run` lines; the top keys (`test-lib.inc.sh`, `all.env.yaml`, `spl-dispatch-lease.func.sh`) are files the selected tests source or read (editor 2.2) | section 6, dropped |
| new, this seat: strace of `fleet-lease.tst.sh`, `dispatch-rotate.tst.sh` | the next heaviest selected tests | spread over `rm`, `grep`, `date`, `bash`; no single site (editor 2.3) | section 6, not a row |
| `perf-round-16/editor.md`, `seat-mistral.md` | p16's measurements | read; their numbers are on `2fe3729e3` and not reused | - |
| `perf-round-15-plan.md` | read through p16 section 6 | - | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: the CI jobs (editor 2.6), the per-file lines and the repack (2.8), the exec count and the time (2.4) | - |
| refactor round 35 v1.0, bug round 16 v1.0 | their row files | read for R1/R3 (3.2) | - |

<a id="p17-rows"></a>

## 3. The rows

| # | id | practice | baseline on `e5f867463` (command, number, n) | after | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p17-01-wui-e2e-shard-weights-refresh)` | refresh `e2e-shard-weights.txt` from the per-file lines (`<file> <secs>`, `run-e2e-tests.mjs:260`) of the newest green wf 10 runs, so every file CI runs has a measured weight; add a ratchet that keeps the unweighted count small | editor 2.6-2.8: the 7 newest green wf 10 runs on `master`, per job: e2e shard 2/8 mean **1,168 s** (n=6, 1,064..1,238), 1/8 797 s; 2/8 ends **5 of 6** runs. Cause: **106 of 367** CI e2e files have no weight line (n=1, deterministic). Its file sum in runs 44263008046 / 44265733431 / 44269686338: **1,189 / 1,064 / 1,136 s**, even split 911 / 881 / 890 s | editor 2.8, leave-one-out (weights = median of the other two runs, `packShards` of `e5f867463`, scored by the held-out run's per-file seconds): slowest shard **941 / 909 / 911 s** (mean -209 s, -18.5%, n=3). Computed, not measured: the run span 1,409 / 1,293 / 1,316 -> ~1,158 / 1,265 / 1,095 s, where the hub job becomes the last job | `wui/src/node/test/e2e-shard-weights.txt` (the weight lines and the header's source line); `wui/tests/unit/e2e-shard-pack.test.mjs` (a new case after `:149`); 2 files | **`e2e-shard-pack.test.mjs`**, new case: the CI selection (`run-e2e-tests.mjs --list`, `ci-skip.txt` applied) has at most `UNWEIGHTED_MAX` files with no weight line (the lane sets it, e.g. 10, and says why in the comment: a new e2e file may land before its first CI sample). Red: today's weights file -> **106 > max**, the case fails and names the files. Also run and green: the whole of **`e2e-shard-pack.test.mjs`** and **`e2e-runner-coverage.test.mjs`**, `iac/tests/check-pre-push-e2e.tst.sh`, `check-pre-push-e2e-baseline.tst.sh` (they name the runner); `pnpm run typecheck`. The lane rebuilds the weights from n>=5 green runs whose heads hold the same e2e files, holds the newest one out, and puts the held-out run's max shard sum under today's and the new weights in the commit body | either fleet box | claude / simple_coding | 1 |
| 02 | `perf(p17-02-orc-lane-mix-cnf-read-once)` | `do_spl_lane_mix` reads the `.env.box.agent_split` and `.env.box.agent_split_by_kind.<kind>` values it needs with ONE `yq` per pick, in place of one `yq` per field and per vendor; same pick, same reason text | editor 2.4: one pick on the test's fixture, logging `PATH` stubs: **13 `yq`** per pick (`simple_coding`, `secret`, `complex_coding`), 12 (`specs_and_docs`); n=1 each, deterministic. 10 picks **7.00 s** wall (~0.70 s a pick), one `yq` **31 ms** (130 calls 4.01 s); load 34.8..35.9. The whole test `spl-lane-mix.tst.sh` with the stub: **4,825 `yq`** execs, **387.8 s** wall (167.5 user, 117.2 sys), rc 0, 128 PASS, n=1, load ~35 (editor 2.5) | computed, not measured: 12 fewer `yq` = ~0.37 s of a ~0.70 s pick; the test's 4,825 `yq` at 31 ms are ~150 s of its 387.8 s. One `yq -o=json` of the `.env.box` subtree on the same file: 0.035 s, n=1 | `orc/src/bash/run/spl-lane-mix.func.sh:166-174` (`_spl_lane_mix_target`), `:265` and `:292` (the two `mistral_*_allowed` reads), `:574` (`_spl_lane_mix_cli`), `:600` (`_spl_lane_mix_auth`); `orc/src/bash/tests/spl-lane-mix.tst.sh` (a new case); 2 files | **`spl-lane-mix.tst.sh`**, new case: a logging `yq` stub first on `PATH` inside `mix()`: (a) one `do_spl_lane_mix` pick execs `yq` at most once (the fixture's own transform runs before the stub); (b) CONTROL the pick line is byte-identical to the one without the stub; (c) CONTROL two picks with a cnf edited between them each see their own cnf (no cache across calls). Red: today's file -> (a) fails, 13 execs (the lane puts the exact count per kind in the commit body). Also run and green: the whole of **`spl-lane-mix.tst.sh`** (section 6 compares `MIX_FULL=1` bytes), `dispatch-rotate.tst.sh`, `lane-rotate.tst.sh`, `orch-rotate.tst.sh`, `role-failover.tst.sh`, `spl-i18n-mask.tst.sh`, `spl-security-round-queue.tst.sh`, `watcher-feed.tst.sh`, `check-fleet-rules-drift.tst.sh` (they name the file or the action), **`bash-cleancode.tst.sh`**; the lane re-times the whole `spl-lane-mix.tst.sh`, alternated, n=2 per arm, and puts both arms in the commit body | either fleet box | claude / simple_coding | 1 |

Every row is claude: rulebook R14 (an established vendor), the owner's 10-17
rule (no mistral coding or testing) and developer guide 5.1 (no `csi-spl-wui/`
row to mistral).

<a id="p17-batches"></a>

### 3.1 Batches and disjoint files (R1)

- **Batch 1**: rows 01 and 02, in parallel; no file in common.
  - Row 01: `e2e-shard-weights.txt`, `e2e-shard-pack.test.mjs`.
  - Row 02: `spl-lane-mix.func.sh`, `spl-lane-mix.tst.sh`.
- No row file is a file of an unlanded refactor round 35 or bug round 16 row
  (3.2). Neither row edits `run-e2e-tests.mjs`, `10_ci-quality.yml`,
  `spl-spawn-place.func.sh` or `spl-spawn-enqueue.func.sh`.

<a id="p17-r3"></a>

### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-18, each with its time (editor 3):

- **Lane map, every machine**: 09:24:00Z, `--check` of row 01's files and
  this plan's two files -> exit 4: `0` owned, 3 `unknown:` (two rotate
  seats and the b16-01 row lane, all on the other box); 09:29:06Z, `--check`
  of row 02's files -> exit 4, the same 3, `0` owned. Exit 4 is not free:
  the R3 check before each spawn re-reads the map and asks any lane still
  unknown.
- **Worktrees on this box** (09:24:14Z): no live worktree has a change to
  a row 01 file, `run-e2e-tests.mjs`, `10_ci-quality.yml`,
  `orc-shard-weights.txt` or `changed-tests.sh`.
- **Briefs** changed since 2026-11-17T09:00Z: none names a row 01 file; one
  names `spl-lane-mix` (the r60-03 reviewer, round 34, all landed), to run
  its test only.
- **Spawn queue** (09:20:15Z): the b16-01 row (`spl-spawn-fill.func.sh` and
  its test) and a cnf bug lane (`spl-tenant-host-*.func.sh`,
  `pre-push-gate.md`). No p17 row file.
- **Refactor round 35** (v1.0): r61-01 landed; r61-02..06 not landed. Their
  15 files (editor 3) hold no p17 row file. Row 02 does not edit
  `spl-spawn-place.func.sh` (r61-04), which calls
  `spl_lane_mix_mistral_ui_off` and `spl_lane_mix_mistral_code_off`
  (`spl-lane-mix.func.sh`): those two keep their arguments and still work
  when called outside a pick (no per-pick read in scope).
- **Bug round 16** (v1.0): b16-01 not landed; its files are not p17 row
  files.

<a id="p17-per-row"></a>

## 4. Per row: what the lane does

- **01**:
  - The weights are the median of each file's `<file> <secs>` lines over at
    least 5 green wf 10 runs on `master` (the lane names their ids in the
    header, as today's header does), whose heads hold the same e2e files; a
    file whose test changed inside the window takes the runs after the
    change, as the header already says. A retry's time is not a sample
    (`run-e2e-tests.mjs:259`).
  - The packer, the shard count (8) and the workflow do not change. The
    existing pack check (`:133-149`, within 0.05 of even on the file's own
    weights) stays.
  - The new case reads the CI selection through the runner (`--list`), not
    `ls`, so `ci-skip.txt` applies. It prints the unweighted files when it
    fails, and its comment says how to refresh.
  - Docs: the header of `e2e-shard-weights.txt` is the doc; the lane says
    so in a `Docs: none (...)` line or adds one line to the WUI e2e part of
    `pre-push-gate.md` if it names the weights (it does not on `e5f867463`:
    `grep -c weights csi-spl-doc/doc/md/pre-push-gate.md` -> 0).
- **02**:
  - One `yq -r` per pick prints the values the pick needs (tolerance,
    window, the kind's row, the two `mistral_*_allowed` flags, the auth
    markers) in one pass; bash reads them into the variables the functions
    use today. A missing key keeps today's default (`// 5`, `// 20`, `// 0`,
    `// ""`).
  - The read is per call of `do_spl_lane_mix`, never cached across calls or
    in a file: a cnf edit is seen by the next pick (case (c)).
  - `spl_lane_mix_mistral_ui_off`, `spl_lane_mix_mistral_code_off` and
    `spl_lane_mix_brief_kind` keep their arguments and output for their
    callers in other files (`spl-spawn-place.func.sh`,
    `spl-spawn-enqueue.func.sh`, `spl-spawn-review-notify.func.sh`,
    `spl-token-burn-by-kind.func.sh`, `spl-watcher-feed.func.sh`), which are
    not edited.
  - `LANE_MIX_SPLIT_KIND` / `LANE_MIX_SPLIT` still override the cnf row, as
    today (`:176-184`).

<a id="p17-panel"></a>

## 5. Panel and reviewers (R7)

Read on 2026-11-18 09:26:35Z..09:26:38Z (editor 4):

- `do_spl_box_pick`: grok `pick=hold` (weekly 99% on both boxes); agy
  `pick=hold` (no box below its overflow mark); mistral and claude
  `pick=<the other box>` (74% < 80%).
- `ENV=prd ./run -a do_spl_hub_agent_kinds` -> `off [qwen], paused []`.
- Dispatch lease holder: `c-002` (09:26:35Z).

- **Plan panel (rulebook 3.2)**: editor c-705 (claude) and **one mistral
  seat**, as in p12 to p16: grok and agy are on hold at this reading, qwen is
  off. Asked of the holder with the v0.1 sha. The seat signs only a sha this
  editor names, sent to it and the holder.
- **Row reviewers (2.7.2)**: the row authors are claude. Code R7 is the
  holder's pick at placement (grok or agy when one places; otherwise the
  claude waiver seat the holder names), never a plan seat. A row never pushes
  without its R7 PASS.

<a id="p17-left-out"></a>

## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| `spl_spawn_place_brief`'s `\| tail -1` (`orc/src/bash/run/spl-spawn-place.func.sh`) | **not a row in p17 (R1)**: refactor round 35 row 04 edits the same file and is not landed; a later perf round takes it once r61-04 lands | p16 editor 2.5 (`tail` 2,716 times in one perturbed run of `spl-spawn-queue.tst.sh`); not re-measured |
| the orc map's top keys after p16-01 | **dropped**: the selected tests source or read the changed file | editor 2.2: 257 commits, 4,080 `run` lines, 145,200 weighted s; `test-lib.inc.sh` 749 (2 commits), `all.env.yaml` 450 (9), `spl-dispatch-lease.func.sh` 357 (8; 29 tests name the file) |
| `fleet-lease.tst.sh`, `dispatch-rotate.tst.sh` hot spots | **not a row**: no single site in the exec counts | editor 2.3 (partial strace, top `rm` 2,276 / `grep` 1,191) |
| the `dirname` calls at load | carried: over 5 sites | p15 editor 2.4; here, 4 per lane-mix pick and 899 in the partial strace of `spl-lane-mix.tst.sh` (editor 2.3, 2.4) |
| the hub job (`gofmt, vet, test, smoke, GCS`) | carried: the next critical path once row 01 lands; no faster form probed | editor 2.6: mean 1,070 s, n=7 |
| `api` full tier remainder, `lint-gosec` | carried: no faster form probed | 7 days: `api` PASS full n=36, mean 1,868 s; `lint-gosec` PASS full n=95, mean 645 s (editor 2.1) |
| WUI AC-02 initial download | carried: needs a probe on the CI node | p13 section 2, n=1 |
| per-case wait audit; `commit-links`' prd key; `iac-cross`; p5/p6 inputs | carried from p14..p16 section 6 | not re-measured here (no key, no lab) |

No finding of this seat is non-perf work, so no ask went to the orchestrator.

<a id="p17-counts"></a>

## 7. Counts

- Rows: 2 in v0.1 (rulebook 1.1: at most 10).
- Every row aims for one push (1.2) and lands with a counting test and its red
  control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p17-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p17-' --format=%B | grep -c '^review: '` must reach the row count.

<a id="p17-changes"></a>

## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel
signs and the plan lands on `master`, not from the review branch, as in rounds
8 to 16. From then on the Qto doc is the primary copy.

- v0.1 (c-705, 2026-11-18 09:4xZ): first draft on `e5f867463`.

<a id="p17-consensus"></a>

## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-705 (editor) | claude | v0.1 | author |
| mistral seat (asked of the holder) | mistral | - | - |
