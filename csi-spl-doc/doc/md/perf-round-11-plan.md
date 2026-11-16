# Perf round 11 (p11) - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/027-spool-performance  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5672  
Topic: 8d4ead86-99f9-4346-a2eb-1b26ec44b179  

This is the fifth round under section 4 of [rounds-rulebook.md](rounds-rulebook.md)
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

**Status: v0.1 draft, not signed. The panel is placed by the dispatch holder
(section 5).** Editor: c-430 (claude).

**Why now.** The holder's brief (c-002@sat, 2026-11-16 02:1xZ) gives two
reasons:

- Perf round 10 is served: p10-01 `70743821c` and p10-02 `4e933d2c5` are on
  `origin/master`.
- The 4.4 check on `97f4df672` printed
  `perf 13 refactor 112 perf-share 10.4% under-20`. So the planner after the
  open refactor round is a perf round, and refactor round 34 waits.

The slug, re-read here at 02:45:45Z on `6fcc711a9`:

- `git log origin/master --oneline -E --grep='\(p11-'` -> 0 lines.
- `git ls-tree -r --name-only origin/master | grep -c perf-round-11` -> 0.

**One sha.** Every row baseline below was measured on **`6fcc711a9`**
(`origin/master` at 02:4xZ), on the desk box (16 cpus), 2026-11-16 02:47Z-03:05Z.
The 1-minute load (16.6..25.8) is printed beside each run in the seat file. Each
before/after pair ran under the same load: either started together, or
alternated AB on odd runs and BA on even ones. The raw commands and outputs are in
[perf-round-11/editor.md](perf-round-11/editor.md). The probe scripts and raw
result files are in `/var/tmp/c430-probe/` on the desk box. The screening runs
that picked the candidates (editor 2.2-2.4) ran on the older `76f65baee` and
`fed9fb69d`. No row file changed between those and `6fcc711a9`
(`git diff --stat fed9fb69d 6fcc711a9` shows only `internal/hub/live_ack_test.go`).

**Retro.** There is no `perf-round-9-retro.md` and no `perf-round-10-retro.md` on
`origin/master`
(`git ls-tree -r --name-only 6fcc711a9 | grep -cE 'perf-round-(9|10)-retro'` -> 0).
This plan does not stand in for them and does not guess their content. Their
rows landed: p9-01 `fd3b0c647`, p9-02 `f24802938`, p9-03 `8a960d204` with its fix
`0d5d699d6`, p10-01 `70743821c` and p10-02 `4e933d2c5`. This plan reads
`perf-round-10-plan.md` (its section 6 first), `perf-round-9-plan.md`,
`perf-round-5-retro.md` and `lesson-speed-up-measure-first.md`.

<a id="p11-how-to-read"></a>
## 1. How to read this

- A row is one logical change made by one lane, with the subject
  `perf(p11-<NN>-<slug>, SPL-<n>): ...` and the review branch `review/p11-<NN>`
  (rulebook 4.5).
- **Baseline** = the command, the number and `n`, on `6fcc711a9`.
- **After (probe)** = the same command on a scratch prototype of the change. The
  prototype is never committed. It shows the gain is real; the lane re-measures
  it on its own tree.
- **Test + red control (C2)**: the counting test the row lands with, and the
  plant that must turn it RED before the fix turns it GREEN. Both outputs go in
  the commit body.
- Paths: `orc/` = `csi-spl-orc/`, `iac/` = `csi-spl-iac/`.
- Why these three. After p10 the always-run `hygiene` part still has a median of
  5 s (n=77 since p10-01 landed), and the parts of one gate run one after the
  other (editor 2.1). Row 03 cuts that part.
- The `orc` part holds the largest sum: 21,802 s over 24 h (n=84), and n=31 with
  a median of 404 s since 21:47Z. Its files also fill CI's four orc shards
  (606..787 s). Rows 01 and 02 remove two fixed waits that its slowest files
  pay on every run. Each wait is the test's own mistake, not a wait the code
  under test needs.

<a id="p11-inputs"></a>
## 2. Where the rows come from

Inputs read (brief step 2). Each carried finding was re-checked on
`6fcc711a9`, or on the screening shas named in the seat file:

| input | finding | on the tree | here |
|---|---|---|---|
| `perf-round-10-plan.md` section 6, "the hygiene part's two drift checks run after the dist sweep, one after the other" | not a p10 row because of R3: queued asks f356b137 and 2a38e34c named `check-pre-push.func.sh` | the drift checks now take 1,046..1,703 ms and 510..731 ms beside a dist sweep of 1,512..2,316 ms (n=5); neither ask is in the queue read at 02:45:29Z (19 queued, none with either id) | **row 03** |
| `perf-round-10-plan.md` section 6, the suite parts (orc the largest sum) | counted, not probed | CI's slowest-10 lists show 8 files whose wall time is 3..11 x their CPU (editor 2.1); `stamp.sh` finds the waits inside them (editor 2.2) | **rows 01, 02**; the rest in section 6 |
| `perf-round-10-plan.md` section 6, `commit-links`' prd key lookup and hub call | a measurement that reads the prd key | still 5 s median (n=77 since p10-01) | section 6, carried: a secret-class lane |
| `perf-round-10-plan.md` section 6, `iac-cross`'s `gcloud-account-pinned.tst.sh` | counted, not probed | the `iac-cross` part has a median of 4 s (n=50); not probed here | section 6, carried |
| `perf-round-10-plan.md` section 6, a-827's inputs 2, 3, 5 | in `check-pre-push.func.sh` | input 2 (fleet-rules drift) is in row 03; inputs 3 and 5 not re-measured | section 6, carried |
| `perf-round-10-plan.md` section 6, `fsync=off`, lab Postgres, p5 inputs, `_spool_bin_stale`, spec 027 rows 2-4 and 7 | carried since p7 | not re-measured: this seat starts no container and reads no prd data | section 6, carried |
| `perf-round-9-plan.md` | its rows 01-03 landed (above); its section 6 inputs went into p10 section 6 | read through p10 | - |
| `perf-round-5-retro.md` section 5 | five inputs | 2 landed as p7-01; 1 and 3 need a lab; 4 and 5 are not perf work (p8 section 6) | - |
| `lesson-speed-up-measure-first.md` | time the real waiting, count the cost, guard it with a counting test | applied: each row starts from the log (pre-push or CI), then a per-case trace, then an A/B under the same load | - |
| new, this seat | the rotation tests poll in whole seconds | dropped, no gain (editor 2.3) | section 6 |
| new, this seat | does a `wait_event` budget run out in the 20 files that call it? | only in `wd-multi-daemon.tst.sh` (row 02); 0 in the other 17 green files (editor 2.4) | section 6 |

<a id="p11-rows"></a>
## 3. The 3 rows

| # | id | practice | baseline on `6fcc711a9` (command, number, n) | after (probe, same n) | sites (file:line) | test + red control (C2) | box | vendor / kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `perf(p11-01-orc-standby-bench-case8-sleep)` | case 8's fixture stops all it started: today `sleep 30 \| <stub> &` and `kill "$ctl"` kill only the stub, and the `sleep 30` outlives the case, so the next case pays for it | `abpair.sh spl-standby-bench.tst.sh` arm A (editor 2.5): `bash orc/src/bash/tests/spl-standby-bench.tst.sh` over a tracked-file export: **54.2 s (median, n=5; 52.4..57.5)**, cpu 15.3..17.2 s, 41 PASS, rc 0 | arm B (the stub reads a fifo fed by `sleep 30 &`, and both pids are killed): **25.2 s (median, n=5; 22.4..29.0), -54%**, B faster than its paired A 5 of 5, cpu unchanged, 41 PASS, rc 0 | `orc/src/bash/tests/spl-standby-bench.tst.sh:177-183` (case 8); 1 edit range | the same file, new assert at the end of case 8: no process the case started is left (no `sleep` child of the test shell, e.g. `pgrep -P $$ -x sleep` prints nothing, or `env_idle` on the case's own sandbox value) -> **0** left (today **1**). Red: today's case 8 -> 1 `sleep` left, FAIL. Every existing case still passes (41 PASS), and case 8 still sees the live stub (`CONTROL: a live stub is seen`) | either fleet box | claude / simple_coding | 1, after R3 (below: ask about 64ca-t7 first) |
| 02 | `perf(p11-02-orc-wd-multi-daemon-s9-settle)` | the S9 control waits on the event that ends the case (every detached restart it launched is gone), not on a count of 2 that the race makes 1 on most runs | `abpair.sh wd-multi-daemon.tst.sh` arm A (editor 2.6): **26.2 s median, 35.9 s mean (n=5; 22.7..55.2)**. The `settle 2` budget runs out in **8 of 12** arm-A runs across editor 2.2, 2.4 and 2.6, each about 30 s longer (51.9..80.5 s against 22.7..26.8 s); CI 59.1 s | arm B (`settle 1` on `:220`, the probe only): **23.5 s median and mean (n=5; 21.9..26.2)**; expected gain ~30 s x 8/12 = **~20 s per run**; 31 PASS, rc 0, both arms | `orc/src/bash/tests/wd-multi-daemon.tst.sh:220` (the S9 control's `settle 2`), and `settle` / `done_n` `:121-126` if the wait is rebuilt there; at most 2 edit ranges | the same file: every `settle` in the file fails the test when its budget runs out (`settle ... \|\| fail "<case>: settle timed out"`), so a wasted budget can no longer pass silently -> **0** timeouts over n=5 runs on the fixed file. Red: today's `settle 2` on the S9 control -> FAIL in the runs where one restart happens (8 of 12 here); the deterministic red is a planted `settle 3` on the same line -> FAIL every run. Unchanged and green: cases 1-5 (31 PASS); the comment at `:121-124` (gate run 37969307772, a restart still running when the next case resets) still holds | either fleet box | claude / simple_coding | 1, after R3 (below) |
| 03 | `perf(p11-03-iac-hygiene-drift-beside-sweep)` | `_pp_part_hygiene` starts the two drift checks (`do_check_fleet_rules_drift`, `do_check_qto_doc_drift`) in the background, each writing its output and rc to its own temp file, runs `do_check_dist_hygiene` in the foreground, then waits and prints the two outputs in today's order. The part's rc folds the three as today. The three read the tree only, and none reads another's result | `hygab.sh <worktree> 7` arm A (editor 2.7): the three pieces one after the other, as today: **3,766 ms (median, n=7; 3,088..5,558)** | arm B: the two drift checks in the background beside the dist sweep: **2,002 ms (median, n=7; 1,663..2,512), -47%**, B below its paired A 7 of 7, ranges not overlapping, all pieces rc 0 | `iac/src/bash/run/check-pre-push.func.sh:492-508` (`_pp_part_hygiene`), its comment `:482-486` (its "~1 s", "under a second" and "~0.1 s" no longer hold: editor 2.7 measured 1.5..2.3 s, 1.0..1.7 s and 0.5..0.7 s, so the lane corrects them, C5); 1 edit range | new `iac/src/bash/tests/check-pre-push-hygiene-concurrent.tst.sh`: the three checks stubbed to a 3-way barrier (each waits, bounded, until 3 are in flight) -> **3** in flight, **0** timeouts (today **1**, every stub times out); one drift stub fails -> the part's rc is 1 and its output comes after the dist output, as today; a TERM to the part leaves no drift job running and no temp file. Red: today's part -> 1 in flight, FAIL. Also run and green: `check-commit-msg-hygiene.tst.sh` (its `part()` drives `_pp_part_hygiene`), `check-pre-push-override.tst.sh`, `check-pre-push-errexit.tst.sh`, `check-pre-push-orphan-pipe.tst.sh` (no background job may hold the part's tee pipe, SPL-3907), `check-pre-push.tst.sh` | either fleet box | claude / simple_coding (R9: a gate, so `PRE_PUSH_TIER=full` and once with `PRE_PUSH_*` unset) | 1, after R3 (below: ask c-396 first) |

Rows 01-03 are all claude. Two rules require it: rulebook R14 (an established
vendor for every row) and the owner's 10-17 rule (no mistral coding or
testing).

<a id="p11-batches"></a>
### 3.1 Batches and disjoint files (R1)

- **Batch 1**: rows 01, 02, 03. No path is in two rows:
  - 01: `spl-standby-bench.tst.sh`.
  - 02: `wd-multi-daemon.tst.sh`.
  - 03: `check-pre-push.func.sh` and the new `check-pre-push-hygiene-concurrent.tst.sh`.
- No row file is a file of an unlanded round row. r58-08 holds
  `iac/src/bash/tests/bash-cleancode.tst.sh`. r59-06 holds
  `csi-spl-api/src/go/spool-hub-api/internal/cleancode/cleancode_test.go` and
  the WUI cleancode list.
- No row file is a file of the live ci50 lanes the holder's brief names:
  - `hub-pg*.tst.sh`, `*-pg-groups.inc.sh` (SPL-5654)
  - `report-ci-gate.func.sh` (SPL-5659)
  - `check-pre-push-features.func.sh` (SPL-5669)
  - `spl-review-go.func.sh` (SPL-5670)
  - `spl-spawn-enqueue.func.sh`, `spl-spawn-queue.func.sh` (c-427)

  Row 03 edits `check-pre-push.func.sh`, not `check-pre-push-features.func.sh`.

<a id="p11-r3"></a>
### 3.2 Off every live lane, every queued row and every open round row (R3)

Read on 2026-11-16, each with its time:

- **Lane map, every machine** (02:45:22Z-02:45:25Z, one call):
  `lane-map.sh --check <the three row files, check-pre-push.tst.sh, this plan
  and its seat file> --agent c-430` -> exit 4. It printed `0` lines `owned by`
  and `13` lines `unknown:`, all lanes on sat that record no files:
  - 10 rotation seats: c-193, c-197, c-664, c-762, g-293, g-367, g-374, g-376,
    g-386, g-393.
  - c-326 (`64ca-t10-fewer-rollouts-one-login`).
  - c-361 (`bug-live-ack-test-fixed-sleep`, the Go test that landed in
    `6fcc711a9`).
  - c-396 (`bug-ppf-parts-drops-unreadable-rc`). Its slug names the pre-push
    parts, so it is asked before row 03 spawns.

  Exit 4 is not free. The R3 check before each spawn re-reads the map and asks
  any lane that is still unknown.
- **Spawn queue** (02:45:29Z, `ENV=prd SPAWN_QUEUE_SHARE=0 ./run -a
  do_spl_spawn_queue`) -> `19 queued, 1 placing`. None of the queued briefs is
  on this box, so their files were not readable here. Two slugs may touch a row
  file:
  - `c002-64ca-t7-bench-back-one-post` (ask `2f9a191e`): "bench" may mean
    `spl-standby-bench`, row 01's file.
  - `c002-64ca-t9-cpu-overload-measure` (ask `64c788e8`).

  The holder reads both briefs on sat before rows 01 and 03 spawn. A row whose
  file a queued brief names waits for that lane.
- **Unlanded round rows** (02:45:45Z, `git log origin/master --format=%s -E
  --grep='\(<r>-[0-9]{2}-'` for r57, r58, r59, r60, p10 and p11, on
  `6fcc711a9`):
  - landed: r57-01..06, r58-01..07, r59-01..05, p10-01..02.
  - not landed: r58-08 (`bash-cleancode.tst.sh`) and r59-06 (the Go and WUI
    cleancode lists). No row here touches them (3.1).
- **Slug** (02:45:45Z): `git log origin/master --oneline -E --grep='\(p11-'` -> 0
  lines.

<a id="p11-per-row"></a>
## 4. Per row: what the lane does

- **01**: case 8 keeps its purpose: the liveness check sees a live stub. The
  stub needs a stdin that stays open while the check runs.
  - The case must stop every process it started before the next case. One way
    is the probe's: a fifo fed by `sleep 30 &` with its pid kept, and both pids
    killed. Another is to read the pipeline's first pid and kill both. The lane
    picks one and says why in a comment.
  - Today's leftover costs about 30 s: the gap before case 9's PASS line (editor
    2.5). The lane finds what case 9's `$(bench ...)` waits on and names it in
    the comment above case 8.
  - The lane re-runs `abpair.sh` (n=5) on its tree and states 41 PASS in both
    arms.
- **02**: the S9 control (`:218-222`) launches one or two detached restarts,
  depending on how the two instances race without the judge lock (8 of 12 runs:
  one).
  - The case waits on the event that ends it: every restart it launched has
    finished. Use `env_idle` (`orc/src/bash/tests/wait-event.inc.sh`, "every
    process a sandboxed call left behind has ended") on the sandbox's own value,
    or `settle` on the count of `takeover` lines the case wrote. It must not
    wait for a fixed 2.
  - It must still keep the guard the comment at `:121-124` records: a restart
    still running when the next case resets the box lands in the new
    `rotate.log` (gate run 37969307772).
  - The probe's `settle 1` alone does not keep that guard when 2 restarts run,
    so it is the measurement arm, not the fix.
  - The lane re-runs `abpair.sh` (n=5) and states 31 PASS, plus how many of its
    runs had two restarts.
- **03**: inside `_pp_part_hygiene`, the two drift calls (`:499-506`) start
  first, each in a background subshell with stdout and stderr to its own file
  under one `mktemp -d`. Then `do_check_dist_hygiene` runs in the foreground
  with today's arguments (`HYGIENE_TREE`, `HYGIENE_MSG_RANGES`), and its output
  streams as today.
  - After it, the part waits for both jobs, prints the fleet-rules output, then
    the qto output, and sets `rc=1` for a non-zero or missing verdict, as today.
    Then it removes the dir.
  - The jobs write to files, never to the part's stdout. So no background job
    holds the tee pipe that `_pp_capture` drains (SPL-3907,
    `check-pre-push-orphan-pipe.tst.sh`).
  - On HUP, INT or TERM the part stops its own two jobs (its own children only)
    and removes the dir, as p10-01 does for the Sweep step.
  - `do_check_dist_hygiene` stays in the foreground: the caller's
    `HYGIENE_MSG_RANGES` warning line and its output come first, as today.
  - The comment above the part says the three run at once, why (three reads of
    one tree, none reads another's result) and that the output order is kept.
  - The lane re-runs `hygab.sh` (n=7) and also the real part through
    `do_check_pre_push` on its tree, and states the PART line and its verdict.

<a id="p11-panel"></a>
## 5. Panel and reviewers (R7)

Read on 2026-11-16 02:45Z: `ENV=prd ./run -a do_spl_hub_agent_kinds` ->
`off [qwen], paused []`, so grok, agy and mistral may be placed. Mistral is
for docs and reviews only (owner 10-17). Its CODE reviews stay paused (owner
10-30, cf7a7ee5); I found no newer word lifting that. The editor's box (the desk
box) has both agy and grok (`command -v agy grok` -> two paths). sat has no
agy (the holder's brief).

- **Plan panel (rulebook 3.2)**: editor c-430 (claude). I asked the dispatch
  holder c-003@sat for one **grok** seat and one **agy** seat. The agy seat goes
  on the desk box, where agy runs, so the panel signs without needing agy on
  sat. Each seat signs the plan sha in `perf-round-11/seat-<vendor>.md`.
  Placed: none yet.
- **Row reviewers (2.7.2)**: every row's author is claude, so the grok seat is
  the primary reviewer. The backup is the agy seat or a second grok seat (mistral
  code reviews are paused). A row never pushes without that PASS (2.7.3).

<a id="p11-left-out"></a>
## 6. Left out, measured or not measurable here

| candidate | why not a row | measurement |
|---|---|---|
| sub-second polls in the rotation code (`ROTATE_POLL` and fixed `sleep 1` in six `spl-*-rotate` / `*-restart` files) | **dropped, no gain**; B also broke a case | n=1 each, all 8 at once, load 36..48 (editor 2.3). A -> B wall s: `lane-rotate` 238.7 -> 198.2; `dispatch-rotate` 288.4 -> 294.6 with rc 1 (`FAIL: 30. slow hand-back`); `orch-rotate` 205.7 -> 300.0; `agent-restart` 215.8 -> 215.0 |
| a hidden `wait_event` timeout in the other files that call it | **none found**: 0 timeouts in the 17 green files | instrumented `wait_event`, n=1 per file (editor 2.4); `spl-doc-tree-repair`, `workspace-doc-node` and `workspace-docs-migration` need a checkout or the test Postgres and were not covered |
| `fleet-lease-slow-tick.tst.sh`, 2 x ~43 s | the test's design: two real-clock runs of the loop, scaled 1:15 from sat's measured outage; shortening them changes what it proves | editor 2.2, n=1 |
| `dispatch-rotate.tst.sh` case 7, 17.4 s | waits out `ROTATE_ACK_TIMEOUT=15` on purpose (its comment, `:477-479`: the real ack wait must outlast two acks under load) | editor 2.2, n=1 |
| `lane-map.tst.sh`, 15.6 s | the hub-hang case, bound by its 15 s budget on purpose | editor 2.2, n=1 |
| `lane-rotate`, `wd-fence`, `desk-move`, `orch-rotate`, `wd-self-update` (wall 3..7 x cpu) | spread over many 5..11 s case waits of the code under test; no single wait stands out | editor 2.2, n=1; input for round 12: a per-case wait audit of these five |
| `commit-links`' prd key lookup and hub call | **not here**: measuring it reads the prd key, which this seat does not | part median 5 s (n=77 since p10-01); carried from p10 as input for a secret-class measurement lane |
| `iac-cross`'s `gcloud-account-pinned.tst.sh` | counted, not probed | part median 4 s (n=50 since p10-01); carried |
| a-827's inputs 3 and 5: `_pp_wui_external` and the iac `./run` eager start | not re-measured | carried from p9 and p10 |
| the suite parts beyond rows 01 and 02 (`wui`, `api`, `wui-e2e`, `iac`, `orc-features`, `lint-gosec`) | counted, not probed: which files take the time needs each suite's slowest-file list | sums over 24 h in editor 2.1; input for round 12 |
| test Postgres `fsync=off` (spec 027 row 6), p5 inputs 1 and 3, p6-08 / p6-09 | need the hub's Postgres container, a lab Postgres with prd-sized rows, or a built bundle and Chrome; this seat starts nothing | carried |
| p5 inputs 4 and 5 | not perf work (p8 section 6) | not re-measured |
| `_spool_bin_stale`, spec 027 rows 2-4 and 7, p8-03 | no gain or not round rows (p7, p8 section 6) | not re-measured |

No finding of this seat is non-perf work, so no ask went to the orchestrator.

<a id="p11-counts"></a>
## 7. Counts

- Rows: 3 (rulebook 1.1: at most 10). All 3 are in batch 1.
- Every row aims for one push (1.2) and lands with a counting test and its red
  control (4.1).
- Status (R6): `git fetch origin master && git log origin/master --grep='(p11-' --format='%h %cI %s'`.
- Review count (2.7.5): `git log origin/master --grep='p11-' --format=%B | grep -c '^review: '` must reach 3.

<a id="p11-changes"></a>
## 8. Changes

Qto (rulebook 4.5): this file is imported once into the `system` workspace with
`do_spl_doctree_import_md` (`QTO_FS=repo`, `TENANT_ID=t1`). The import happens
after the panel signs and the plan lands on `master`, not from the review
branch, as in rounds 8 to 10. From then on the Qto doc is the primary copy.

- v0.1 (c-430, 2026-11-16): first draft, 3 rows on `6fcc711a9`.

<a id="p11-consensus"></a>
## 9. Consensus

| seat | vendor | plan sha | verdict |
|---|---|---|---|
| c-430 (editor) | claude | v0.1 | author |
| grok seat | grok | - | not placed yet |
| agy seat | agy | - | not placed yet |
