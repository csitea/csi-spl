# Refactoring round 69 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5995  
Topic: 9ab7cad2-5ca6-4f10-8c11-4af4c2d1ddd7  
Discussion: 9ab7cad2-5ca6-4f10-8c11-4af4c2d1ddd7 (t1 #refactoring, "Refactor round 69", opener msg a6b7f8c4)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r69**, plan `refactor-round-69-plan.md`, rows `r69-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 68 ([refactor-round-68-plan.md](refactor-round-68-plan.md),
v1.0 `a97766b47`) is closed: r68-01 landed `16885dd24` (SPL-5986), r68-02 landed
`45731884d` (SPL-5991). Round 67 is closed too: r67-03 landed `c2f5828b8` (SPL-5975). No
signed row is handed on, so r69 is a fresh round. The perf floor (rulebook 4.4), the
holder's read on `fee2465fd`: `perf 29 refactor 99 perf-share 22.7% floor-met`, so the
next round is a refactor round.

The round takes two of the inputs r68 named for round 69 (its section 7): the last
SC2034 test-code set in `spawn-agents/tests` that r68-02 left, and the `MergeTopic` pair
of the Go `wideFuncs` list, which waited for r67-03 to land.

**Status: v0.2, draft**, for the panel (rulebook 3.2). Editor: **c-606** (claude).

**One sha:** every count is measured on **`79b22fa06`** (`origin/master`
79b22fa0669b452578735ed4c64159fce8b80f22, committed 2026-11-19T21:08:58+01:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`, shellcheck
0.10.0, go from `/usr/local/go/bin`, and the tests on this lane's worktree at that sha.
Queue, lane map, brief and worktree readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-19T18:52:32+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r68-plan'` -> commit
  `a97766b47` "refactor round 68 plan records the v1.0 signature, m-028 mistral PASS on
  2d9900128". Every later read of r69 uses this W.
- **`r69` is free** (2026-11-19T20:12Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r69-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r69-*' 'refs/heads/wip/*r69*' 'refs/heads/*-r69-*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r69-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (run as root) on this lane's box -> **0 files**. The other box's briefs were not read
    by this lane (the holder read them all 0 at 20:1xZ).
  - Control: the same log read for `r68` -> 3 lines (`45731884d` r68-02, `16885dd24`
    r68-01, `a97766b47` the plan), so the read sees a used id.
- **No `refactor-round-69*` file** exists under `csi-spl-doc/doc/md` on `79b22fa06`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-69` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The candidates, re-measured

| input | source | on `79b22fa06` | here |
|---|---|---|---|
| `.shellcheck-warning-baseline.txt` | the ratchet (developer guide 2.4.3), r68 section 7 | `grep -vcE '^\s*(#\|$)'` -> **73 lines**. SC2034 lines in test files: 4 iac, 4 `spawn-agents/tests` (`lib.inc.sh` 1, `test-agent-identity-reconcile.sh` 2, `test-agent-identity-restore.sh` 1, `test-spool-poke-queue.sh` 2) | **row 01** (1.3); `lib.inc.sh` and iac: section 7 |
| Go clean-code gate `wideFuncs` | r68 section 7, "the first candidate of round 69 once r67-03 lands" | r67-03 landed (`c2f5828b8`); `wideFuncs` holds 4 lines (`api:internal/cleancode/cleancode_test.go:42-45`): the `MoveMessage` and `MergeTopic` Memory / Postgres pairs | **row 02** `MergeTopic` (1.4); `MoveMessage`: section 7 |
| `no-literal-paths.baseline` | the brief | `git show 79b22fa06:csi-spl-orc/src/bash/tests/no-literal-paths.baseline \| grep -vE '^\s*(#\|$)'` -> **1** line, `spl-file-erase.func.sh`: a deny list r66 to r68 ruled a behaviour change | left out (section 7) |
| r67 and r68 R7 findings | the brief | the r68 plan's panel notes N1-N5 asked no change (its section 8); the row commits' bodies (`16885dd24`, `45731884d`, `c2f5828b8`) carry their `review:` PASS line and no N or W note (`git log -1 --format=%B <sha> \| grep -iE '^(N[0-9]\|W[0-9]\|note)'` -> 0 each). The seat files were not read by this lane | nothing taken |
| the dispatcher's candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`) | the brief | on the other box; this lane cannot read it (`ls` -> No such file on this box). r68 section 7 recorded its two refactor-shaped items as served | the holder checks it for a new refactor-shaped item |
| spec 011 tasks | the brief | the spec folder unchanged since W (`git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0) | left out (section 7), r65 to r68's reasons hold |

### 1.3 Row 01: the SC2034 sites

`shellcheck -S warning -i SC2034 -f gcc <file>` on each file as `git show 79b22fa06:<path>`
writes it; `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`:

| file:line | variable | read anywhere? | here |
|---|---|---|---|
| `sa:tests/test-agent-identity-reconcile.sh:55` | `pane` in `while IFS='\|' read -r pane pid wname` inside `drift()` (and in its `local` at `:54`) | the loop body reads `pid` and `wname` only; `grep -nE '\$pane\b\|\$\{pane'` in the file -> **0** | **row 01** |
| `sa:tests/test-agent-identity-reconcile.sh:75` | `before="$(names)"` | `grep -nE '\$before\b\|\$\{before'` -> **0**; `names()` (`:48`) is one `tm list-windows ... \| tr`, a read with no side effect | **row 01** |
| `sa:tests/test-agent-identity-restore.sh:95` | `RUNNER="$(t_window 'other' "...--resume s-89'")"`: the live CLI window is the point (case "its session is running already"), its pane id is not | `grep -n RUNNER` -> `:95` only | **row 01** |
| `sa:tests/test-spool-poke-queue.sh:254` | `i`, the counter of `for i in $(seq 1 25)` (a bounded wait) | the loop body reads `$r97` only; `grep -nE '\$i\b\|\$\{i\}'` -> **0** | **row 01** |
| `sa:tests/test-spool-poke-queue.sh:269` | `A_PANE="$(t_window CLE-94 'sleep 600')"`: the throwaway agent window is the point | `grep -n A_PANE` -> `:269` only | **row 01** |

The changes, as r68-01 and r68-02 made them: `read -r _ pid wname`, and `pane` leaves the
`local` list at `:54`; the `before=` line goes (a read nobody uses); `t_window ... >/dev/null`
for `RUNNER` and `A_PANE` (`t_window()`, `sa:tests/lib.inc.sh:86-88`, is one
`tmux new-window -P -F '#{pane_id}'` and keeps no caller state); `for _ in $(seq 1 25)`.
Each file runs under `set -uo pipefail` (no `-e`: reconcile `:31`, restore `:40`, poke
`:11`), so the exit status of a bare call is not acted on, as the assignment's was not.

The gate: `do_sec_shellcheck` (`iac:run/sec-shellcheck.func.sh`) holds the count per
(code, file) **equal** to the baseline, so the row drops its 3 lines
(`SC2034|<file>|2`, `|1`, `|2`) in the same commit; the red control is that drop left out
(r67-01, r68-01, r68-02).

**Before**, on `79b22fa06` (this lane, n=1, `SPOOL_TEST=1`, as the box user):
`test-agent-identity-reconcile.sh` rc 0 `46 passed, 0 failed`; `test-agent-identity-restore.sh`
rc 0 `35 passed, 0 failed`; `test-spool-poke-queue.sh` rc 0 `110 passed, 0 failed`.
The row's after counts match these.

**Tests (R2):** `for n in test-agent-identity-reconcile test-agent-identity-restore test-spool-poke-queue; do git grep -lE "\b$n(\.sh)?([^a-z0-9_-]|$)" 79b22fa06 -- 'csi-spl-orc/**' 'csi-spl-iac/**' '.github/workflows/*'; done`
-> the reconcile file names itself, the other two no file; `sa:tests/run-all-tests.sh`
runs all three by its `test-*.sh` glob. The gate's readers of the baseline
(`sec-shellcheck.tst.sh`, `sec-shellcheck-par.tst.sh`, `check-pre-push-lint.tst.sh`) write
their own fixture baseline (r68 1.4). The column: the three files and
`iac:tests/sec-shellcheck.tst.sh`.

### 1.4 Row 02: the `MergeTopic` pair

`api:` = `csi-spl-api/src/go/spool-hub-api/`.
`git grep -nE '\bMergeTopic\(' 79b22fa06 -- '*.go'` -> **19 lines** in **12 files**:

- **Contract:** the `TopicMerge` interface, `api:internal/store/topic_merge.go:42`
  `MergeTopic(ctx, tenantID, srcMsgID, srcTask, targetTask, toChannel, by string, at time.Time) (MergeResult, error)`:
  8 parameters (`maxParams` 7). `TopicMerge` is embedded in the store contract
  (`api:internal/store/store.go:336`); `git grep -nE '\bTopicMerge\b'` -> 3 lines, no other
  implementer.
- **Implementations:** `(*Memory).MergeTopic` `api:internal/store/topic_merge.go:55`,
  `(*Postgres).MergeTopic` `api:internal/store/topic_merge_postgres.go:30`.
- **Production caller:** `api:internal/hub/topic_merge.go:108`.
- **Test calls (15 lines, 9 files):** `hub/fallback_test.go:370` (through
  `e.st.(store.TopicMerge)`), `store/flow_place_key_test.go:150`,
  `store/topic_head_concurrency_test.go:190,223`, `store/topic_head_harness_test.go:320,326,564`,
  `store/topic_head_random_test.go:399`, `store/topic_head_rls_test.go:335`,
  `store/topic_head_sql_test.go:558`, `store/topic_merge_test.go:69,72,77,158`,
  `store/write_batch_rt_test.go:135`.
- **The gate lines:** `api:internal/cleancode/cleancode_test.go:44-45` (the pair) and the
  list's comment `:39-40` ("The Memory / Postgres pairs (MoveMessage, MergeTopic)
  implement one interface and leave the list together"), which then names
  `MoveMessage` only.

The change, as r67-03 made it for `CASFleetLease`: `MergeTopicReq{SrcMsgID, SrcTask,
TargetTask, ToChannel, By string; At time.Time}` beside `MergeResult` in
`topic_merge.go`; the interface and both implementations take
`(ctx, tenantID string, r MergeTopicReq)`; the hub caller and the 15 test calls build the
struct; the 2 `wideFuncs` lines go and the comment drops `MergeTopic`.
`UnmergeTopic` and `MergedRowHomes` (4 and 3 parameters) do not change.

**Before**, on `79b22fa06` (this lane, n=1, no Postgres DSN): `go test -count=1 ./internal/store/ -run Merge -v`
-> `ok`, `TestMergeTopic` and `TestSharedMemoryAddMerge` PASS, the 3 `TestTopicHeadRace*Merge`
SKIP (Postgres only); `go test -count=1 ./internal/cleancode/` -> `ok`. The Postgres
half (`topic_head_*`, `flow_place_key`, `write_batch_rt`, `topic_merge_test` on pg) runs
only with a DSN, so the row runs `cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`
(developer guide 2.12.4) and records the PASS list before and after.

**Tests (R2):** the 12 files above, `api:internal/cleancode/cleancode_test.go`, and the
packages `./internal/store/ ./internal/hub/ ./internal/cleancode/` (`go vet` included).

## 2. The 2 rows

Paths: `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`, `iac:` = `csi-spl-iac/src/bash/`,
`api:` = `csi-spl-api/src/go/spool-hub-api/`, `base:` = `.shellcheck-warning-baseline.txt`
(repo root).

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r69-01-spawn-tests-shellcheck-dead-vars)` | bash that fails safely (developer guide 2.4.3): the shellcheck WARNING ratchet only shrinks | three spawn-agents tests keep a read field, a capture or a loop counter no line reads; each file's baseline line would hide a real new SC2034 there | `sa:tests/test-agent-identity-reconcile.sh:54-55,75`<br>`sa:tests/test-agent-identity-restore.sh:95`<br>`sa:tests/test-spool-poke-queue.sh:254,269`<br>`base:` its 3 SC2034 lines | 3 files, 5 warnings | the changes of 1.3. The 3 lines `SC2034\|<file>\|<n>` leave `base:`. **Red control:** sites fixed, baseline left -> `do_sec_shellcheck` FAILS (a count below its line) on the 3 pairs; lines dropped -> PASS. **Behaviour:** each test's `N passed, 0 failed` the same before and after (1.3: 46, 35, 110), both in the body. Tests: the three files (`SPOOL_TEST=1`), `bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh` (a test red on the parent too is named, not fixed), `iac:tests/sec-shellcheck.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push_lint`. | either | claude | simple_coding | 1 |
| 02 `refactor(r69-02-api-merge-topic-req)` | clean code (developer guide 2.2.2, Go clean-code gate): the `wideFuncs` ratchet only shrinks | the Memory / Postgres `MergeTopic` pair takes 8 parameters; 6 of them are one merge request, and the pair's 2 lines in `wideFuncs` let either grow to 8 again | `api:internal/store/topic_merge.go:42,55`<br>`api:internal/store/topic_merge_postgres.go:30`<br>`api:internal/hub/topic_merge.go:108`<br>`api:internal/cleancode/cleancode_test.go:39-40,44-45`<br>(and the 15 test calls of 1.4) | 13 files, 19 grep lines + 2 gate lines | the change of 1.4. **Red control:** with the struct in, `go test -v -run . ./internal/cleancode/` LOGS the 2 `no longer takes more than 7` lines while the gate lines stay; lines dropped -> no such log; then one implementation put back at 8 parameters with the lines dropped -> the gate FAILS (`takes 8 parameters (> 7)`). All three outputs in the body. **Behaviour:** the same SQL text and arguments (`git diff` shows no change inside a query string); the store and hub merge tests pass before and after with the same PASS list, on Postgres too. Tests: 1.4, `cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`. | either | claude | simple_coding | 1, **held by R3** until c-521 lands (2.2) |

**Re-measure first:** each row lane re-runs its count (row 01 the shellcheck and the
baseline grep of 1.2, row 02 the `git grep` of 1.4) on the `origin/master` it starts from,
and says in its result if they moved. A fix that unmasks another warning is reported, and
the editor records it.

**Subject** (R6 reads it): `<type>(r69-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r69-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** no documented behaviour changes: row 01 is test code only, row 02 an internal
Go signature. Each row carries `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, file sets disjoint (row 01: three orc test files and
  `base:`; row 02: twelve api files and `cleancode_test.go`). No `SPAWN_AFTER` between them.
- Row 02's spawn waits for the R3 hold of 2.2 only, not for row 01.
- No row edits an action, a lib, a migration, `csi-spl-cnf/`, a workflow, terraform or a
  file under `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-606`, one call per
  path, 2026-11-19T20:14:34Z, n=1:
  - **row 01's 4 paths -> exit 4** each: no live lane lists them; 3 live lanes record
    no files. The holder's R3 check before the spawn governs.
  - **row 02: exit 4 for 12 of its 13 paths, exit 3 for
    `api:internal/store/topic_head_harness_test.go`:** "owned by c-521@<box>
    c-521-c002-s179-b1-rdb-store-topic-pauses (changed in its worktree; no files
    recorded)". Its worktree diff against `origin/master`
    (`git -C <c-521 worktree> diff origin/master -- <that file>`, 20:15Z): one hunk at
    `:68-74`, the `refTopicsSQL` reference query gains three `topic_pauses` columns.
    Row 02 edits `:320,326,564` of the same file: other lines, but R3 is per file, so
    **row 02 is not spawned until c-521 (spec 179 B1, SPL-5980) lands** and the holder's
    R3 check before the spawn reads the file free. c-521's other files
    (`git diff --stat origin/master`, 18 files: store `topic_pause*`, `view*`,
    `channels_postgres.go`, `fallback_*.go`, `channel_humans.go`, `change_stamp_test.go`,
    `crosstenant_test.go`, `rls_test.go`, `channel_move_plan_test.go`,
    `testdata/view_topics_sql.golden`, `channelmove/catalogue.go`, rdb
    `0297_topic_pauses.sql`) are none of row 02's.
- **The live lanes the brief names** (20:1xZ): c-046 spec 143 B-6b (api `internal/hub`
  GitHub sync), c-946 SPL-5963 (api `internal/hub/calendar*`), c-592 (orc desk reply),
  c-038 SPL-5987 (`csi-spl-wui/tests/e2e/issues-ctxmenu.test.mjs`): none holds a row
  path by the lane map; c-521: above.
- **Commits:** `git log origin/master --since="$W" -- <the 17 row paths>` -> **3**:
  `45731884d` (r68-02) and `16885dd24` (r68-01), both `base:` only, and `c2f5828b8`
  (r67-03, `cleancode_test.go`). All landed.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-19T20:17:02Z):
  **0 queued, 1 placing** (ask 23cc4e60, the spec 179 B1 R7 reviewer seat; a review seat
  commits no code, 2.7.6). Live share `refactor 2 14% (band 40-60%: UNDER)`;
  last 24 h `refactor 14% (band 20-30%: UNDER)`; `phase night`.
- **Briefs on this lane's box** that name a row path or symbol
  (`grep -rlE 'MergeTopic|topic_merge|test-agent-identity-reconcile|test-agent-identity-restore|test-spool-poke-queue|shellcheck-warning-baseline|cleancode_test'`
  over `/var/spool-hub/dispatch/briefs` and `/var/spool-hub/spawn-remote/briefs`, as
  root, 2026-11-19T20:17:13Z): 15 files. The r67 and r68 row, reviewer and planner
  briefs (all landed or closed); the spec 179 B1 brief and the b23 planner brief name
  `cleancode_test` only as "stay off r67-03" (landed); the SPL-4992 brief names
  `topic_merge.go` (landed `102e8bfc6`, 2026-11-17); and this planner's brief.
- **Unlanded round rows:** none (r67 and r68 closed; b23-01 `7b6cd900e` and b23-02
  `a6f5a723d` landed, orc paths, none of the rows').

## 3. Per row: what the lane does

- **r69-01:** three spawn-agents tests stop keeping a read field, a capture or a loop
  counter no line reads; their 3 SC2034 baseline lines go.
- **r69-02:** once c-521 has landed: the store's `MergeTopic` pair takes one
  `MergeTopicReq`; its 2 `wideFuncs` lines go.

## 4. Panel and reviewers (R7)

- Editor: c-606 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r69`):
  one **agy** doc seat, the main vendor for spec and plan reviews, with mistral as its
  backup, as r62 to r68 had (the brief: no agy CLI on one box, agy quota out on the other
  until ~11-24, so mistral is the likely seat). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2), the holder's call when the row
  is queued (a fresh claude seat under the claude waiver, as r63 to r68). Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r69-01 | `c002-r69-01-spawn-tests-shellcheck-dead-vars` | `refactor(r69-01-spawn-tests-shellcheck-dead-vars, SPL-<row issue>): ...` | `review/r69-01` | 1 |
| r69-02 | `c002-r69-02-api-merge-topic-req` | `refactor(r69-02-api-merge-topic-req, SPL-<row issue>): ...` | `review/r69-02` | 1, once c-521 (SPL-5980) has landed and R3 reads the file free |

**r69-01 brief, Files: ONLY** `sa:tests/test-agent-identity-reconcile.sh`,
`sa:tests/test-agent-identity-restore.sh`, `sa:tests/test-spool-poke-queue.sh`,
`.shellcheck-warning-baseline.txt` (its 3 SC2034 lines). Do: plan section 2 row 01
verbatim; red control the sites fixed with the baseline lines left (`do_sec_shellcheck`
FAIL on the 3 pairs) then dropped (PASS), both outputs in the body; each test's
`N passed, 0 failed` before and after in the body (plan 1.3). Run the tests with
`SPOOL_TEST=1`. Gates: the three files,
`bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh`,
`bash csi-spl-iac/src/bash/tests/sec-shellcheck.tst.sh`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r69-02 brief, Files: ONLY** `api:internal/store/topic_merge.go`,
`api:internal/store/topic_merge_postgres.go`, `api:internal/hub/topic_merge.go`,
`api:internal/cleancode/cleancode_test.go` (the 2 `MergeTopic` lines and the comment) and
the 9 test files of 1.4 (`hub/fallback_test.go`, `store/flow_place_key_test.go`,
`store/topic_head_concurrency_test.go`, `store/topic_head_harness_test.go`,
`store/topic_head_random_test.go`, `store/topic_head_rls_test.go`,
`store/topic_head_sql_test.go`, `store/topic_merge_test.go`, `store/write_batch_rt_test.go`).
Do: plan section 2 row 02 verbatim; the three red-control outputs in the body; the same
SQL and arguments; the PASS list before and after, on Postgres. Gates: `go vet` and
`go test -count=1 ./internal/store/ ./internal/hub/ ./internal/cleancode/`,
`cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`. `Docs: none (...)`.
Kind `simple_coding`, vendor claude. Spawn only after c-521 (SPL-5980) has landed.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash test code 1, Go 1) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: rows 01 and 02 (02 held by R3) |
| `.shellcheck-warning-baseline.txt` lines | 73 today -> 70 after r69-01 |
| SC2034 lines in `spawn-agents/tests` | 4 -> 1 (`lib.inc.sh`, section 7) |
| SC2034 warnings removed | 5 |
| Go `wideFuncs` lines | 4 today -> 2 after r69-02 (the `MoveMessage` pair) |
| measured on | `79b22fa06`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| Go `wideFuncs`: the `MoveMessage` pair (interface `api:internal/store/message_move.go:74`, Memory `:136`, Postgres `message_move_postgres.go:97`) | 8 parameters, the same shape as row 02; 25 store call lines in 13 files, among them `store/topic_head_harness_test.go` and `store/change_stamp_test.go` (both changed in c-521's worktree), and 5 files row 02 also edits (`flow_place_key`, `topic_head_concurrency`, `topic_head_harness`, `topic_head_random`, `topic_head_rls`) plus `cleancode_test.go`. A 3rd row would be serialised behind row 02 on 6 files: the first row of round 70 (rulebook 5.1) | `git grep -nE '\bMoveMessage\(' 79b22fa06 -- '*.go' \| grep -v hubclient \| grep -v action/move.go` -> 25 (the 3 left out are `hubclient.(*Client).MoveMessage`, 5 parameters, and its callers) |
| `sa:tests/lib.inc.sh:10` `T_SCRIPTS` (1 SC2034) | set in a file every spawn-agents test sources and reads (`$T_SCRIPTS/agent-top.sh`, `$T_SCRIPTS/spool-poke-retry.sh`, ...): the baseline's "read by a sourcing caller" case, not dead code | shellcheck, 1.3 |
| iac SC2034 in tests (4 lines) | r67 section 7: read by a sourcing caller or a test (3), a dead guard, a bug row (1) | r67 1.3 |
| the orc SC2034 in actions and scripts (`spl-spec-import-issues.func.sh`, `trust-workdir.sh`, `agent-top.sh`, the spawn and restore script families) | vars a sourced lib, a called function or a launcher may read; each needs the per-variable read check (r68 section 7) | `.shellcheck-warning-baseline.txt` |
| SC2154, SC2120, SC1090, SC2088, SC2046, SC2319, SC2164, SC2155 | the baseline's header names these kinds deliberate | the baseline's header |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | 63 positional caller lines in 35 files (r67's read), a WUI row with its e2e gate: input for a later round | r68 1.2 |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66 to r68) | 1.2 |
| computed `/var/<org>/<org>-<app>/agent-boot-restore` default: `orc:run/spl-agent-boot-restore-install-cron.func.sh:57` (`logdir`, the writer), `orc:run/spl-watchdog.func.sh:535-539` (`spl_wd_boot_retired`, the reader) | **not a refactor: a behaviour change** (r68 section 7's input, served by this measurement; the holder's note de244afc). Both build the dir from the app name (`SPL_ORG_APP`, the basename of `PROJ_PATH` minus `-orc`), so every checkout of the app reads the same `/var/<org>/<org>-<app>/agent-boot-restore`. `$SPL_VAR_APP_DIR` is built from the checkout's own name instead: `spl_run_paths` (`csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh:66-71`) sets it to `<var>/<org>/<main checkout basename>`, and `spl_main_checkout` returns the clone itself when its `.git` is a directory. The desk-cron checkout (`<org dir>/<app>-desk-cron`, the one `spl_desk_cron_src` installs the boot cron from) is its own clone (`test -d <desk-cron>/.git` -> true, 2026-11-19T20:3xZ), so there the swap gives `/var/<org>/<app>-desk-cron/agent-boot-restore`, not the dir the installed `@reboot` line writes `cron.out` to today (`ls /var/<org>/<app>/agent-boot-restore` -> `cron.out`). The reader and the writer would part, and a `retired` marker already on a box would no longer be seen. A row for it is a bug or feature row (pick one dir, move the live markers), not a refactor row | `git show 79b22fa06:<the 3 files>`; `sed -n 63,76p` of `spl-run-paths.func.sh` |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour (T028's assertions), terraform layout (T026) or docs (T031); the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-606): first draft. A fresh round: 2 rows found on `79b22fa06`, the last
  SC2034 test-code set in `spawn-agents/tests` and the `MergeTopic` `wideFuncs` pair.
  Window W and the r69 slug proof recorded. Row 02 held by R3 on c-521's
  `topic_head_harness_test.go`.
- v0.2 (c-606, the holder's note c-002 msg de244afc): section 7 only. The
  agent-boot-restore default r68 named for round 69 measured: `$SPL_VAR_APP_DIR` takes the
  checkout's name, the literal takes the app's, and the desk-cron checkout is its own
  clone, so the swap moves the dir: a behaviour change, not a refactor row. The
  candidates file's newest entries are bug-shaped (the holder's read). Rows 01 and 02
  unchanged.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-606 (claude): v0.1, v0.2.
- Panel reviewer seat: requested of the holder (section 4).
- Row R7 seats: section 4.
