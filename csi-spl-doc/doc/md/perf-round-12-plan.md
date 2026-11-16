# Perf round 12 (p12) - plan (2 rows)

> Generated from qto doc `3f77b6e8-7e02-470c-9763-9994bd7fe720`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5701  
Topic: 32d81359-7971-4033-92e7-450b1e153424  

This is the sixth round under section 4 of [rounds-rulebook.md](rounds-rulebook.md)
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
- Owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Every row's
  vendor is claude.**

**Status: v1.0, signed** (claude c-616 author, mistral m-676 PASS on `325e0a8ed`). Editor: c-616 (claude).

**Why now.** The holder's brief (c-002@sat, 2026-11-16 08:2xZ):

- Perf round 11 is served: p11-01 `6def8d373`, p11-02 `e6fb29099`, p11-03
  `1e5134ac5` are on `origin/master`.
- The 4.4 check, re-run here at 10:17:33Z on `302ac11ce`, printed
  `perf 16 refactor 108 perf-share 12.9% under-20` (on `a8a54cf44` at 09:2xZ
  it printed the same line). So the planner after the open refactor round is
  a perf round.

The slug, re-read at 10:17:33Z on `302ac11ce`:

- `git log origin/master --oneline -E --grep='\(p12-'` -> 0 lines.
- `git ls-tree -r --name-only origin/master | grep -c perf-round-12` -> 0.

**One sha.** Every row baseline below was measured on **`a8a54cf44`**
(`origin/master` at 09:22Z), on the desk box (16 cpus), 2026-11-16 from
09:2xZ. The row files did not change after it:
`git diff --stat a8a54cf44 302ac11ce -- csi-spl-iac/src/bash/run/check-pre-push.func.sh csi-spl-orc/src/bash/tests/run-all-tests.sh csi-spl-iac/src/bash/tests/run-all-tests.sh`
prints nothing. The 1-minute load is printed beside each run. Both arms of a
pair start together on two clones of the same sha, and the clones swap arms
on every run. Raw commands and outputs: [perf-round-12/editor.md](perf-round-12/editor.md);
probe scripts and result files: `/var/tmp/c616-probe/` on the desk box.

**Retro.** There is no `perf-round-11-retro.md` on `origin/master`, and no p9
or p10 retro
(`git ls-tree -r --name-only a8a54cf44 | grep -cE 'perf-round-(9|10|11)-retro'`
-> 0). This plan does not stand in for them and does not guess their content.
It reads `perf-round-11-plan.md` (its section 6 first), the seat files under
`perf-round-11/`, `perf-round-10-plan.md`, `perf-round-5-retro.md` and
`lesson-speed-up-measure-first.md`.

<a id="p12-how-to-read"></a>

<a id="ws-doc-52d88b4d-dea1-4454-b54e-fdbce5fc5993"></a>
## 1. How to read this

- A row is one logical change made by one lane, with the subject
  `perf(p12-<NN>-<slug>, SPL-<n>): ...` and the review branch `review/p12-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number and `n`, on `a8a54cf44`.
- **After (probe)** = the same command on a scratch prototype of the change.
  The prototype is never committed. It shows the gain is real; the lane
  re-measures it on its own tree.
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `orc/` = `csi-spl-orc/`, `iac/` = `csi-spl-iac/`. `cpp` =
  `iac/src/bash/run/check-pre-push.func.sh`.
- **Why these two.** Over 24 h on the desk box (editor 2.1), a failed `orc`
  part costs much more than a green one: PASS n=51, mean 258 s;
  WARN-pre-existing n=15, mean 1,405 s (928..2,318 s). Over 7 days the
  WARN-pre-existing runs of four parts took 75,773 s: `iac` 33 runs
  (24,742 s), `wui` 27 (22,930 s), `orc` 15 (21,081 s), `orc-features` 11
  (7,020 s). This is the waiting the holder's brief relayed from c-426@sat
  (SPL-5683): orc 1,645..3,206 s per try, every try lost the race to trunk.
- **The cause** (read in `cpp` on `a8a54cf44` and `302ac11ce`): when a part
  fails, `_pp_run` (`:1067-1078`) runs the **whole** part again on the base
  ref, only to tell a pre-existing red from a new one. `_pp_compare`
  (`:1265-1286`) then asks one question: does every item that fails on the
  tree also fail on the base? The base run only needs the items that failed on
  the tree. The other files are re-run to no purpose: a file that passed on
  the tree is not compared at all.

<a id="p12-inputs"></a>
<a id="ws-doc-3b3b51ea-5890-44c8-9bc9-e5d6f47a6a92"></a>
## 2. Where the rows come from

Inputs read (brief step 2). Each carried finding was re-checked on
`a8a54cf44`:

| input | finding | on the tree | here |
|---|---|---|---|
| holder's brief: c-426@sat's pre-push log (SPL-5683, n=4) | orc part 1,645..3,206 s per try, rc=1 recorded as WARN-pre-existing every try | re-measured on the desk box's own log (n=15 orc WARN-pre-existing in 24 h, mean 1,405 s) and traced to the whole-part base re-check (section 1) | **rows 01, 02** |
| `perf-round-11-plan.md` section 6, "the suite parts beyond rows 01 and 02 (`wui`, `api`, `wui-e2e`, `iac`, `orc-features`, `lint-gosec`)", counted, not probed | sums over 24 h | the largest cost in them is the red runs' re-check, not the green runs (editor 2.1) | **rows 01, 02** (orc, iac); wui and orc-features in section 6 |
| `perf-round-11-plan.md` section 6, a per-case wait audit of `lane-rotate`, `wd-fence`, `desk-move`, `orch-rotate`, `wd-self-update` | input for round 12 | `stamp.sh`, n=1 per file: the largest single gap is 4.0..13.4 s, among many 5..10 s case waits of the code under test; no wait stands out (editor 2.4) | section 6, dropped |
| `perf-round-11-plan.md` section 6, `commit-links`' prd key lookup, `iac-cross`, a-827's inputs 3 and 5, `fsync=off`, lab Postgres, p5 inputs, `_spool_bin_stale`, spec 027 rows | carried | not re-measured: this seat reads no key, starts no container and reads no prd data | section 6, carried |
| `perf-round-11/seat-agy.md`, `seat-grok.md` | notes on p11 rows 01-03 | all three rows landed; no note names a new candidate | - |
| `perf-round-10-plan.md` | read through p11 section 6 | - | - |
| `perf-round-5-retro.md` section 5 | five inputs | as p11 says: 2 landed as p7-01; 1 and 3 need a lab; 4 and 5 are not perf work | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: the log first (editor 2.1), then the code path, then an A/B under the same load (editor 2.2, 2.3) | - |
| new, this seat | CI workflow 10's slowest shards | 11 green runs on master: wui e2e shards 692..1,166 s, orc shards 581..1,054 s; the slowest shard differs from run to run, so a rebalance has no measured gain | section 6, dropped |

<a id="p12-rows"></a>
<a id="ws-doc-c8e76c73-62d9-498b-817e-c51c2960d0ac"></a>
## 3. The 2 rows

| # | id | practice | baseline on `a8a54cf44` (command, number, n) | after (probe, same n) | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p12-01-orc-recheck-failed-files)` | when the `orc` part fails on the tree, its base re-check runs only the orc test files the tree run named `FAILED:` (the `suite <file>` items of the tree signature, `_pp_sig`, `cpp:1246`), not the whole `--changed` plan again; with no such item (e.g. only `bash-cleancode` failed) it re-runs the whole part as today | `abpp.sh <clone> A` (editor 2.2): c-324's change set (50 orc tests), one planted red in `unanswered-sweep.tst.sh`; the base re-check: **672, 553, 415 s (n=3)**; the whole failed part: **1,574, 1,222, 1,023 s (n=3)**; load 12.7..39.5 | arm B (base re-check with `ORC_TEST_FILES=<failed> ORC_TEST_ALWAYS=`): base re-check **26, 23, 67 s (n=3)**, the whole failed part **927, 693, 674 s (n=3), -41%, -43%, -34%**, B below its paired A 3 of 3. B's base ran the failed files only (runs 1-2: 1 file, the plant; run 3: 2 files, the plant and `spl-role-failover-drill.tst.sh`, which failed on its own in all four outputs) where A's ran 50, and named the same failures, so the verdict is WARN-pre-existing in both arms every run | `cpp:1067-1078` (`_pp_run`, hand the tree signature's suite files to the base run) and `cpp:713-731` (`_pp_part_orc`, on the base tree run only those); 2 edit ranges | new `iac/src/bash/tests/check-pre-push-recheck-narrow.tst.sh`: a stub orc runner records the files each run is asked to run; the tree run fails 1 of 3 files -> the base run is asked for **1** file (today **3**), and the verdict is WARN-pre-existing when the base fails it too, FAIL when the base passes it, as today. A tree failure with no `suite` item (only `bash-cleancode`) -> the base runs the whole part (today's behaviour kept). Red: today's `_pp_run` -> 3 files on the base, FAIL. Also run and green: **`check-pre-push-baseline.tst.sh`**, **`check-pre-push-verdict-forks.tst.sh`**, **`check-pre-push-timeout-red-trunk.tst.sh`**, **`check-pre-push-budget-table.tst.sh`**, `check-pre-push.tst.sh`, `check-pre-push-errexit.tst.sh`, `check-pre-push-orphan-pipe.tst.sh`, `bash-cleancode.tst.sh` | either fleet box | claude / simple_coding (R9: a gate, so `PRE_PUSH_TIER=full` and once with `PRE_PUSH_*` unset) | 1, after R3 (below) |
| 02 | `perf(p12-02-iac-recheck-failed-files)` | the same for the `iac` part: its base re-check runs only the iac files the tree run named `FAILED:`, through the runner's own filter `IAC_TEST_ONLY` (`iac/src/bash/tests/run-all-tests.sh:28,58-64`) | `abiac.sh <clone> A` (editor 2.3): the iac suite, fast tier, one planted red in `gh-box-token.tst.sh`, run twice as today: the base re-check **203, 189 s (n=2)**; the whole failed part **533, 390 s (n=2)**; load 12.8..23.7. The tree run fails 3 files: the plant, and `check-weekly-full-scan.tst.sh` and `hub-payment-030.tst.sh` (the latter skips a check: no tpl-gen venv on the desk box); neither is the planted file | arm B (`IAC_TEST_ONLY=<failed>`): base re-check **2, 1 s (n=2)**, the whole failed part **332, 203 s (n=2), -38% and -48%**; B ran the 3 failed files and named the same 3 in both arms, both runs | `cpp:671-676` (`_pp_part_iac`); 1 edit range, using the hand-over row 01 adds to `_pp_run` | the same new test, an iac case: the tree run fails 1 iac file -> the base run is asked for **1** file (today the whole suite). Red: today's `_pp_part_iac` -> the whole suite on the base, FAIL. Same column as row 01 | either fleet box | claude / simple_coding (R9) | **2**, after row 01 lands (R1: both edit `cpp`) |

Rows 01-02 are both claude. Two rules require it: rulebook R14 (an established
vendor for every row) and the owner's 10-17 rule (no mistral coding or
testing).

<a id="p12-batches"></a>
<a id="ws-doc-e43189f7-72c0-47c1-8088-ff53a210939e"></a>
### 3.1 Batches and disjoint files (R1)

- **Batch 1**: row 01. Files: `cpp` and the new
  `check-pre-push-recheck-narrow.tst.sh`.
- **Batch 2**: row 02, spawned within 30 min of row 01 landing (R16). It edits
  `cpp` and the same new test, so it cannot run beside row 01.
- No row file is a file of an unlanded round row: on `302ac11ce` (10:17:33Z)
  p11-01..03 have landed and r60, r61 have 0 lines
  (`git log origin/master --format=%s -E --grep='\(<r>-[0-9]{2}-'`).

<a id="p12-r3"></a>
<a id="ws-doc-5ad7663d-bd75-4aa1-9f80-494afc53731b"></a>
### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-16, each with its time:

- **Lane map, every machine** (10:17:34Z, one call): `lane-map.sh --check <cpp,
  orc run-all-tests.sh, iac run-all-tests.sh, this plan, its seat file> --agent
  c-616` -> exit 4. It printed `0` lines `owned by` and `10` lines `unknown:`,
  all lanes on sat that record no files:
  - 3 rotation seats: c-193, c-197, c-762.
  - c-326 (`64ca-t10-fewer-rollouts-one-login`), c-433
    (`64ca-t7-bench-back-one-post`), c-515
    (`bug-rotate-open-takes-archived-answered`), c-519
    (`feat-s143-b4-api-store-release-projects`), c-521
    (`feat-invited-inactive-member`), c-523
    (`feat-member-phone-first-last-name`), c-525 (`s155-b11-note-on-ask-store`).
  - None of these slugs names the pre-push gate. Exit 4 is not free: the R3
    check before each spawn re-reads the map and asks any lane still unknown.
  - The earlier read (09:24:37Z) had 8 unknown, c-426 (SPL-5683, the lane
    whose log the brief relayed) not among them.
- **Spawn queue** (10:17:41Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`) -> `4 queued, 2 placing`:
  `s179-pause-agents-of-a-discussion-spec` (agy, a spec),
  `bug-hubclient-sendframe-unkeyed-error`, `agy-memory-edit-after-review-gap`,
  `955ab0bd-event-types-causes`; placing `spl5704-open-takes-claude-waiver-reviewer`,
  `spl4835-lane-console-keep-clear`. The one brief readable here
  (`c002-s179-pause-agents-of-a-discussion-spec.md`) names `check-pre-push` 0
  times. The holder (c-002@sat, msg 8a969a4c, 10:3xZ) read the other five on
  sat: `grep -c check-pre-push <brief>` -> 0 for each of
  `c002-spl4835-lane-console-keep-clear`,
  `c002-spl5704-open-takes-claude-waiver-reviewer`,
  `c002-bug-hubclient-sendframe-unkeyed-error`,
  `hand-<box>-c002-agy-memory-edit-after-review-gap` and
  `c002-955ab0bd-event-types-causes`. Briefs only, not their diffs: the R3
  check before each spawn re-reads the map.
- **Unlanded round rows** (10:17:33Z, on `302ac11ce`): p11-01..03 landed; r60
  and r61 have 0 lines.

<a id="p12-per-row"></a>
<a id="ws-doc-f16dcad0-ab6b-4206-ae1a-6ef8e887c0d5"></a>
## 4. Per row: what the lane does

- **01**:
  - `_pp_run` already has the tree signature (`tsig`, `cpp:1071`) before it
    builds the base tree. The lane takes its `suite <file>` items and hands
    them to the base run of the same part, e.g. in a variable the part reads
    only when it runs on `_PP_BASE_WT` (the name is the lane's; it is unset
    again after the base run, so the next part never sees it).
  - `_pp_part_orc`, on the base tree with that list set, runs
    `run-all-tests.sh --changed` with `ORC_TEST_FILES=<the failed files>` and
    `ORC_TEST_ALWAYS=` (empty), so the always-run list is not added again; the
    probe did exactly this (editor 2.2, arm B). It still runs
    `bash-cleancode.tst.sh` on the base as today, so a cleancode red keeps its
    re-check.
  - With no `suite` item in `tsig` the base runs the whole part, as today.
  - The verdict code (`_pp_compare`, `_pp_timed_out`) is not changed. A
    TIMED OUT tree run is refused as today (`cpp:1083-1084`); its base run is
    not narrowed (its signature is cut).
  - The comment above `_pp_run` (`cpp:1022-1025`) and above `_pp_part_orc`
    (`cpp:686-688`, "the trunk re-check runs the same files") change to say the
    base runs only the files that failed, and why: the verdict compares only
    those (C5).
  - The lane re-runs `abpp.sh` (n=3) on its tree and states the base re-check
    seconds and the verdict line of both arms.
- **02**: after row 01 lands, `_pp_part_iac` on the base tree with the list
  set runs `IAC_TEST_ONLY="<the failed basenames>"`. The runner exits 2 when a
  name is not a file there (`run-all-tests.sh:60`); a file the tree added does
  not exist on the base, so the lane drops names that are not files on the
  base tree before it sets `IAC_TEST_ONLY` (a dropped name is NEW by
  `_pp_compare`, which is right: it cannot fail on trunk). The lane re-runs
  `abiac.sh` (n=3).
- **Both rows**, the gain per red push: the base re-check falls from the whole
  part (orc 415..672 s, iac 189..203 s here) to the failed files (orc 23..67 s, iac 1..2 s). The pre-push log
  shows how often that runs: 15 orc and 33 iac WARN-pre-existing runs in 7
  days (editor 2.1). The plan does not multiply those into a weekly saving: the
  red runs' plans differ in size from the probe's.

<a id="p12-panel"></a>
<a id="ws-doc-78619ad8-ad9b-4718-99db-b3a72c2d30f8"></a>
## 5. Panel and reviewers (R7)

Read on 2026-11-16 10:1xZ: `ENV=prd ./run -a do_spl_hub_agent_kinds` ->
`off [qwen], paused []`, so grok, agy and mistral may be placed. Mistral is for
docs and reviews only (owner 10-17); its code reviews stay paused (owner 10-30,
cf7a7ee5), as p11 read it. The desk box has agy, grok and vibe
(`command -v agy grok vibe` -> three paths); sat has no agy (the holder's
brief).

- **Plan panel (rulebook 3.2)**: editor c-616 (claude). I asked the dispatch
  holder for one **grok** seat and one **agy** seat on the desk box, so the
  panel signs without needing agy on sat. Each seat signs the plan sha in
  `perf-round-12/seat-<vendor>.md`. The holder's answer (c-002@sat, msg
  8a969a4c):
  - **agy seat**: queued with c-001 (ask 56aade4b), placement
    `agy:hand-<box>-c002-perf-round-12-agy-panel-seat` on the desk box. It reads
    v0.1 and signs the v0.2 sha.
  - **grok seat**: none. `BOX_PICK_KIND=grok do_spl_box_pick` at 10:2xZ ->
    `pick=hold`, grok's weekly use 98% on both boxes (reset 11-21).
  - **mistral seat** in its place: c-001's ruling (msg 99d5ed2f, relayed by the
    holder in msg afafa7c3): seat 2 is mistral until a mistral seat fails
    twice; grok stays on hold. Queued as ask b00e6895 (either box), seat file
    `perf-round-12/seat-mistral.md`, branch
    `review/c002-perf-round-12-mistral-seat`. A plan review is a docs review,
    which mistral may do (owner 10-17).
  - The agy seat was placed as a-675, then quota-locked (agy individual
    quota, resets in about 105 h; c-001's GC note a0856b9c, 14:00Z), so it
    cannot sign.
- **Owner ruling, the panel that signs**: HUM-10 msg e895dea6 (t1 32d81359,
  2026-11-16 14:02:48Z), answer **C** to poll 8ede28e3: "Claude + mistral
  sign, no agy". The poll text of C: "the plan is signed by claude (planner)
  and mistral (m-676) only. That is still two vendors, and mistral reviews
  each claude row." Relayed by the holder c-002@sat in msg 3eff79a4. So the
  panel is **c-616 (claude, editor) + m-676 (mistral)**, two vendors; no agy
  seat file and no replacement seat.
- **Row reviewers (2.7.2)**: both rows' author is claude. By the same owner
  ruling's poll text (e895dea6) the mistral seat reviews each claude row,
  where p11 had read mistral's code reviews as paused (owner 10-30,
  cf7a7ee5). A backup row reviewer, if one is needed, is the holder's to place
  (2.7.3) when the rows spawn. A row never pushes without a cross-vendor PASS.

<a id="p12-left-out"></a>
<a id="ws-doc-c563c92a-f888-4104-a215-6548e686e5ed"></a>
## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| the same narrowed re-check for `wui` (27 WARN-pre-existing in 7 days, 22,930 s) and `orc-features` (11, 7,020 s) | **not probed here**: their runners (vitest and the features runner) take a file filter in another form, and this seat ran no A/B for them | counted in editor 2.1; input for round 13, after rows 01-02 show the hand-over |
| a per-case wait audit of `lane-rotate`, `wd-fence`, `desk-move`, `orch-rotate`, `wd-self-update` (p11's input) | **dropped, no wait stands out** | `stamp.sh`, n=1 per file on `a8a54cf44`: largest single gap 4.0..13.4 s, among many 5..10 s waits of the code under test (editor 2.4) |
| rebalancing CI workflow 10's orc and wui e2e shards | **dropped, no measured gain**: the slowest shard differs from run to run | 11 green master runs: wui e2e 692..1,166 s, orc 581..1,054 s (editor 2.4); counted, not probed |
| `commit-links`' prd key lookup and hub call | **not here**: measuring it reads the prd key | carried from p10 and p11 for a secret-class lane |
| `iac-cross`'s `gcloud-account-pinned.tst.sh`; a-827's inputs 3 and 5 | not re-measured | carried |
| test Postgres `fsync=off` (spec 027 row 6), p5 inputs 1 and 3, p6-08 / p6-09 | need a container, a lab Postgres or a built bundle and Chrome; this seat starts nothing | carried |
| p5 inputs 4 and 5; `_spool_bin_stale`, spec 027 rows 2-4 and 7, p8-03 | not perf work, or no gain (p7, p8 section 6) | not re-measured |

No finding of this seat is non-perf work, so no ask went to the orchestrator.

<a id="p12-counts"></a>
<a id="ws-doc-bed6e5c5-04b0-4570-a620-f6d907e1b8fe"></a>
## 7. Counts

- Rows: 2 (rulebook 1.1: at most 10). Row 01 in batch 1, row 02 in batch 2.
- Every row aims for one push (1.2) and lands with a counting test and its red
  control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p12-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p12-' --format=%B | grep -c '^review: '` must reach 2.

<a id="p12-changes"></a>
<a id="ws-doc-7497746f-b18c-4753-8f9b-4c1b375e5856"></a>
## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`) after the panel
signs and the plan lands on `master`, not from the review branch, as in rounds
8 to 11. From then on the Qto doc is the primary copy.

- v0.1 (c-616, 2026-11-16): first draft, 2 rows on `a8a54cf44`. Row 01's A/B
  at n=2, row 02's not run yet.
- v0.2 (c-616, 2026-11-16): row 01 at n=3, row 02 at n=2 (both A/Bs on
  `a8a54cf44`); R3 with the holder's read of the five sat briefs (3.2); the
  panel per c-001's ruling 99d5ed2f, agy + mistral (5, 9). No row added or
  dropped. The runs still going (orc 4-5, iac 3-5) go into the seat file
  only; the signed numbers stay these, and each lane re-measures on its tree.
  Section 5 then records the owner's ruling e895dea6 (poll 8ede28e3, answer
  C): the panel that signs is claude (c-616) + mistral (m-676), no agy; rows
  unchanged.
- v1.0 (c-616, 2026-11-16): m-676 (mistral) PASS on `325e0a8ed`, W none,
  notes N1-N6 (seat file `592948bd9` on
  `review/c002-perf-round-12-mistral-seat`, msg 06c39b4c). Folded: N2, the
  `_pp_run` comment is `cpp:1022-1025` (line 1021 is blank). Record only: N3,
  the editor 2.1 7-day WARN counts are not reproducible from the seat box's pre-push
  log, so the row baselines rest on the A/B probes alone (as section 3
  states); N5, the plan re-reads the lane map before each spawn (3.2). Its
  re-measure of row 01, n=3: base re-check A 511/455/431 s vs B 30/90/65 s,
  verdict unchanged, agrees with section 3. Rows unchanged. The hold
  15:55-20:55Z was the seat box suspended (c-001 msg ebdebe45).

<a id="p12-consensus"></a>
<a id="ws-doc-95377302-4241-4fba-a38a-f2fc913fdf18"></a>
## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-616 (editor) | claude | v0.1, v0.2, v1.0 | author |
| a-675 (ask 56aade4b) | agy | - | not a signer: quota-locked; owner ruling e895dea6 |
| m-676 (ask b00e6895) | mistral | `325e0a8ed` (v0.2) | **PASS**, W none, N1-N6 (seat `592948bd9`); N2 folded in v1.0 |
| m-676 (ask b00e6895) | mistral | `bf6ba7541` (v1.0) | **PASS**, W none, rows byte-identical to 325e0a8ed (seat `9dc3fed8f`, msg 48bf1e6a); the holder sent it ACCEPTED (c-002@sat note ed058669) |
