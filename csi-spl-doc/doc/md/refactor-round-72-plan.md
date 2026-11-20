# Refactoring round 72 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6012  
Topic: a2c852b7-ae60-40bb-9c2b-d783ff969931  
Discussion: a2c852b7-ae60-40bb-9c2b-d783ff969931 (t1 #refactoring, "Refactor round 72", opener msg 3e786f3e)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r72**, plan `refactor-round-72-plan.md`, rows `r72-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 71 ([refactor-round-71-plan.md](refactor-round-71-plan.md))
is closed (`99548495c`): r71-01 landed `82f0e0b0f` (SPL-6008), r71-02 landed `f589257ba`
(SPL-6010). Round 69's r69-02 (the `MergeTopic` parameter object) landed `99029842f`, so
the `MoveMessage` pair, which r70 and r71 left out only because of R3, is free now. No
signed row is handed on: r72 is a fresh round. The perf floor (rulebook 4.4), the
holder's read on `99548495c`: `perf 29 refactor 101 perf-share 22.3% floor-met`, so this
is a refactor round.

Both rows come from r71 section 7: row 01 takes the `MoveMessage` pair (the last 2
`wideFuncs` lines of the Go gate), row 02 the left-out `spl-reflection-gather.func.sh:217`
derive line (the last hand-written `SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/` line outside
`csi-spl-doc`).

**Status: v0.1, draft**, not signed. Editor: **c-778** (claude).

**One sha:** every count is measured on **`99548495c`** (`origin/master`
99548495c935e38e08e5eed9e97150f100d6e36a, committed 2026-11-20T05:01:31+02:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`; the tests ran
on this lane's worktree at that sha (go1.26.10, `GOFLAGS=-mod=mod GOPROXY=off`; the bash
test as the push user with `SPOOL_TEST=1`). Queue, lane map, brief and worktree readings
are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-20T05:01:31+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r71-plan'` -> commit
  `99548495c` "refactor round 71 plan records the round closed, rows 01-02 landed".
  Every later read of r72 uses this W.
- **`r72` is free** (2026-11-20T03:08:36Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r72-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r72-*' 'refs/heads/wip/*r72*' 'refs/heads/*-r72-*' 'refs/heads/*refactor-round-72*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r72-[0-9]{2}|refactor-round-72' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (as root) on this lane's box (03:10Z) -> **1 file**, this planner's own brief. The
    holder's read of the other box: 1, the same brief (c-002 msg ab5b46d6).
  - Control: the same log read with `(r71-` since W -> 1 line, `99548495c` (the r71
    close record, whose body names the rows), so the read sees a used id.
- **No `refactor-round-72*` file** exists under `csi-spl-doc/doc/md` on `99548495c`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-72` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The candidates, re-measured

`api:` = `csi-spl-api/src/go/spool-hub-api/internal/`, `orc:` = `csi-spl-orc/src/bash/`,
`lib:` = `csi-spl-orc/lib/bash/funcs/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`.

| input | source | on `99548495c` | here |
|---|---|---|---|
| Go `wideFuncs` `MoveMessage` pair | r71 section 7 (left out by R3 only: r69-02 unlanded) | r69-02 landed `99029842f`; `api:cleancode/cleancode_test.go:41-44` lists exactly the 2 `MoveMessage` lines; 25 store call lines in 13 files (1.3) | **row 01** |
| `orc:run/spl-reflection-gather.func.sh:217` subshell derive | r71 section 7 | `git grep -nE 'SPL_VAR_APP_DIR:\+' 99548495c -- . ':!csi-spl-doc'` -> **1 line**, this one; r71's anchored gate already reads 0 | **row 02** (1.4 says what an empty value does) |
| the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, on the holder's box) | the brief | not on this lane's box; the holder (c-002 msg ab5b46d6, 03:1xZ): unchanged since r71 read it (9542 bytes, last changed 2026-11-19 22:49:35 +0200); its refactor items (a)-(d) served, (e) left out, the rest bug-shaped (r71 1.2) | nothing new |
| `.shellcheck-warning-baseline.txt` | the brief | `grep -vcE '^\s*(#\|$)'` -> **68 lines**, unchanged since r71's read on `6fedc5bbb` (`git log 6fedc5bbb..99548495c -- .shellcheck-warning-baseline.txt` -> 0) | nothing taken: r71 section 7's reasons hold (section 7) |
| `no-literal-paths.baseline` | the brief | 1 line, `spl-file-erase.func.sh` (a deny list r66 to r71 ruled a behaviour change) | left out (section 7) |
| r71 R7 findings | the brief | `82f0e0b0f` (c-751) and `f589257ba` (c-764) each carry one `review:` line and no N or W note (`git log -1 --format=%B <sha> \| grep -nE '^(N[0-9]\|W[0-9])'` -> 0 each); both PASS with counts identical before and after. The seat files were not read | nothing taken |
| spec 011 tasks | the brief | the spec folder unchanged since W (`git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0) | left out (section 7), r65 to r71's reasons hold |

### 1.3 Row 01: the `MoveMessage` pair

The store's `MoveMessage` takes 8 parameters (`ctx` + 7), 6 of them one move request;
`maxParams` is 7 and the pair is all that is left in `wideFuncs`:

| file:line | what |
|---|---|
| `api:store/message_move.go:74` | the `Moves` interface method: `MoveMessage(ctx context.Context, tenantID, msgID, toTask, toChannel, by string, at, notBefore time.Time) (MoveResult, error)` |
| `api:store/message_move.go:136` | `(*Memory).MoveMessage`, the same 8 |
| `api:store/message_move_postgres.go:97` | `(*Postgres).MoveMessage`, the same 8; `:113` passes `tenant, msgID, set.MsgIDs, toTask, nullText(toChannel), notBefore, at, by` to `moveMessageCTE` |
| `api:hub/message_move.go:326-327` | the one non-test caller, `storeMessageMove` |
| `api:cleancode/cleancode_test.go:35-44` | the `wideFuncs` comment ("The Memory / Postgres pair (MoveMessage) implements one interface and leaves the list together") and its 2 lines |

**The shape, as r69-02 did for `MergeTopic`** (`99029842f`, `MergeTopicReq` in
`api:store/topic_merge.go:36-42`): a `MoveMessageReq` struct beside `MoveResult` in
`api:store/message_move.go`,

```go
// MoveMessageReq is one MoveMessage call: re-home MsgID under ToTask on
// channel ToChannel, received_at at least NotBefore, the move columns
// stamped with By and At.
type MoveMessageReq struct {
	MsgID, ToTask, ToChannel, By string
	At, NotBefore                time.Time
}
```

and the interface and both implementations take `(ctx context.Context, tenantID string, r MoveMessageReq)`.
The bodies read `r.MsgID`, `r.ToTask`, ... where they read the parameters; the
Postgres query string and its argument order do not change. The 2 `wideFuncs` lines
leave `cleancode_test.go`: the map becomes `map[string]bool{}` (as `longFuncs` is) and
its comment drops the pair's sentence.

**Call sites** (`git grep -nE '\bMoveMessage\(' 99548495c -- '*.go'` -> 28 lines; 3 of
them are the other `MoveMessage`, the hub client's 5-parameter one:
`api:hubclient/move.go:38`, its test `api:hubclient/cli_verbs_test.go:102` and its caller
`api:action/move.go:87`; not this row). The store's 25 lines in 13 files:

| file | lines |
|---|---|
| `api:store/message_move.go` | 2 (interface `:74`, Memory `:136`) |
| `api:store/message_move_postgres.go` | 1 (`:97`) |
| `api:hub/message_move.go` | 1 (`:326`) |
| `api:store/message_move_test.go` | 6 (`:135,138,161,170,197,204`) |
| `api:store/topic_head_harness_test.go` | 4 (`:302,308,514,575`) |
| `api:store/topic_head_rls_test.go` | 3 (`:190,331,345`) |
| `api:store/topic_head_concurrency_test.go` | 2 (`:153,479`) |
| `api:store/change_stamp_test.go` | 1 (`:169`) |
| `api:store/flow_place_key_test.go` | 1 (`:141`) |
| `api:store/search_index_equiv_test.go` | 1 (`:325`) |
| `api:store/topic_head_random_test.go` | 1 (`:380`) |
| `api:hub/channels_test.go` | 1 (`:456`) |
| `api:hub/view_delta_test.go` | 1 (`:203`) |

No other type implements the method (`git grep -nE 'func \(.*\) MoveMessage\(' 99548495c -- '*.go'`
-> the 2 store ones and the hub client's). No `csi-spl-doc/` spec names its parameters
(`git grep -n 'MoveMessage' 99548495c -- csi-spl-doc/specs` -> 5 lines, each the method's
name only), so no doc changes.

**Tests (R2):** the 10 test files above; the `Test*` functions holding a call:
`TestMoveTopicAndMessage`, `TestChangeStampWriters`, `TestFlowPlaceKey0137`,
`TestSearchIndexEquivalence`, `TestTopicHeadRaceInsertVsMove`,
`TestTopicHeadSameTaskTwoTenants`, `TestTopicHeadRandomSequences`,
`TestCrossTenantTopicHeads`, `TestTopicHeadRuntimeRole` and the `TestTopicHead*` cases of
the harness (store); `TestBoxReplyInheritsCardlessChannel`, `TestViewTopicsSinceDelta`
(hub); **`TestCleanCodeGate`** (reads the source). Most store cases run on Postgres only.

**Before** (this lane, worktree at `99548495c`, 2026-11-20T03:1xZ, n=1, NO Postgres DSN):
`go test -count=1 -v ./internal/cleancode/` -> `--- PASS: TestCleanCodeGate`, ok;
`go test -count=1 -v -run 'TestMoveTopicAndMessage|TestChangeStampWriters|TestFlowPlaceKey0137|TestSearchIndexEquivalence|TestTopicHead|TestCrossTenantTopicHeads' ./internal/store/`
-> ok, 2 PASS, 0 FAIL, 32 SKIP (the Postgres cases skip without `SPOOL_TEST_PG_DSN`);
`go test -count=1 -v -run 'TestBoxReplyInheritsCardlessChannel|TestViewTopicsSinceDelta|Move' ./internal/hub/`
-> ok, 56 PASS, 0 FAIL, 38 SKIP. Because of the 32 store skips, the row lane runs the
store set on a throwaway Postgres (`postgres:16-alpine`, a non-superuser runtime role,
as r69-02's body records), before and after. This lane did not run them on Postgres.

### 1.4 Row 02: the reflection gather's derive line

`orc:run/spl-reflection-gather.func.sh:213-222`, `spl_reflection_zombie` (section 6 of
the gathered file):

```text
local log="${REFLECTION_ZOMBIE_LOG:-}" out
if [[ -z "$log" ]]; then
  declare -F spl_run_paths >/dev/null || source ".../lib/bash/funcs/spl-run-paths.func.sh"
  log="$( { spl_run_paths || :; } 2>/dev/null; printf '%s' "${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/zombie-topics/cron.log}")"
fi
[[ -n "$log" ]] || { echo "(not read: no zombie sweep log: ...)"; return 0; }
```

It is r71's derive block in another shape: in a `$( )`, so `spl_run_paths`' exports do
not reach the gather's shell, its stderr dropped, no FATAL. The change keeps the
subshell and takes r71-01's helper inside it (`lib:spl-run-paths.func.sh:78-85`,
`spl_var_app_subdir`):

```text
  declare -F spl_var_app_subdir >/dev/null || source ".../lib/bash/funcs/spl-run-paths.func.sh"
  log="$(spl_var_app_subdir log zombie-topics/cron.log 2>/dev/null && printf '%s' "$log")"
```

- **What an empty value does downstream** (the brief's ask): `log` empty -> the next
  line prints one `(not read: no zombie sweep log: REFLECTION_ZOMBIE_LOG unset and no
  SPL_VAR_APP_DIR derived)` line and returns 0; section 7 runs on. With the helper,
  "no dir" is its rc 1: `&&` skips the `printf`, the `$( )` yields "", the same line,
  the same rc 0.
- **Why the subshell stays:** the helper runs `spl_run_paths` in its caller's shell
  (r71 1.3); called bare here it would export `SPL_ORG_DIR`, `SPL_WT_ROOT`, ... into the
  gather for sections 7 on, which today they do not see. Inside the `$( )` nothing
  leaks, as now. `log` in the subshell is the function's local, copied in and printed
  back.
- **The guard line** tests `spl_var_app_subdir`, as r71's 5 callers do
  (`orc:run/setup-reverse-tunnel.func.sh:48`).
- **Read on this lane's box** (2026-11-20T03:1xZ, n=1; the old and the new line on the
  lib at `99548495c`, with `REFLECTION_ZOMBIE_LOG`, `APP_PATH`, `PROJ_PATH` unset, in a
  scratch dir): `SPL_VAR_APP_DIR=<dir>` -> both read `<dir>/zombie-topics/cron.log`;
  `SPL_RUN_PATHS_TOP=<tree>` -> both read `<tree's var>/zombie-topics/cron.log`;
  `SPL_RUN_PATHS_TOP=` (no tree) -> both the `(not read` line; rc 0 in all 6 runs;
  `SPL_WT_ROOT` unset in the caller after both forms.
- **Gate:** `git grep -nE 'SPL_VAR_APP_DIR:\+\$SPL_VAR_APP_DIR/' -- . ':!csi-spl-doc'`
  -> 1 on `99548495c`, **0** after the row: no hand-written derive line left outside
  the round plans.

**Tests (R2):** `git grep -lE 'spl-reflection-gather|spl_reflection_|do_spl_reflection_gather' 99548495c -- '*tests/*' '*.tst.sh' .github/workflows`
-> `orc:tests/spl-reflection-gather.tst.sh` and `orc:tests/orc-shard-weights.txt` (a
weight, not a test). Its case 18 (`:490-506`, r65-01) reads all 4 branches of the
section: the `SPL_VAR_APP_DIR` dir, the tree, the override, no tree. Plus
`csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` (a line count). No new function, so
`orc:tests/run-eager-files.tst.sh` is not in the column.

**Before** (this lane, worktree at `99548495c`, 2026-11-20T03:1xZ, n=1, `SPOOL_TEST=1`,
as the push user): `bash orc:tests/spl-reflection-gather.tst.sh` -> rc 0,
`spl-reflection-gather: all passed`, 61 pass lines (`grep -ciE '^ *(ok|pass)'`), case 18
4 of 4 PASS, 0 SKIP lines (case 13 ran on Postgres).

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r72-01-api-move-message-req)` | at most 7 parameters, pass a struct (developer guide 2.2.2); the gate's list only shrinks | the store's `MoveMessage` pair takes 8, 6 of them one move request; the last 2 `wideFuncs` lines | `api:store/message_move.go:74,136` (+ new `MoveMessageReq`)<br>`api:store/message_move_postgres.go:97`<br>`api:hub/message_move.go:326`<br>`api:cleancode/cleancode_test.go:35-44`<br>the 21 test call lines of 1.3 | 3 signatures, 1 caller, 21 test calls, 2 gate lines | the change of 1.3. **Gate:** `wideFuncs` 2 -> 0 lines; `TestCleanCodeGate` PASS after. **Red control:** the 2 lines deleted while the signatures are still wide -> FAIL (`... takes 8 parameters (> 7)`), output in the body. **Behaviour:** the same SQL text and argument order (`git diff` of `message_move_postgres.go` changes no query string); the store set of 1.3 on a throwaway Postgres and the hub set, before (the row's parent) and after, PASS/FAIL/SKIP counts identical, both in the body; `git grep -nE '\bMoveMessage\(' -- '*.go'` -> 28 lines after (the same), every store call building `MoveMessageReq`. Tests: 1.3's column, `bash csi-spl-api/src/bash/tests/run-all-tests.sh`, `cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push` (a store change). | either | claude | simple_coding | 1 |
| 02 `refactor(r72-02-orc-reflection-zombie-subdir)` | folded helpers exist once (developer guide 2.2.4); canonical paths (2.3.1) | r71 folded the derive block into `spl_var_app_subdir` and left this one line, another shape (a subshell, no FATAL); it takes the helper inside its subshell | `orc:run/spl-reflection-gather.func.sh:216-217`<br>`orc:tests/spl-reflection-gather.tst.sh` (case 18) | 1 line (+ the guard's function name) | the change of 1.4. **Gate:** `git grep -nE 'SPL_VAR_APP_DIR:\+\$SPL_VAR_APP_DIR/' -- . ':!csi-spl-doc'` 1 -> **0**. **Behaviour:** case 18's 4 cases PASS on the parent and on the change, the test's pass count the same (61 on `99548495c`, plus the new assertion), both outputs in the body. **Red control (mutation):** the helper's `<sub>` misspelt (`zombie-topics/cron.lgo`) turns case 18's dir and tree cases red; restored, green. **New assertion** in case 18: after `spl_reflection_zombie` derives from the tree in a shell with `SPL_WT_ROOT` unset, `SPL_WT_ROOT` is still unset there (the subshell holds); PASS on the parent and the change, FAIL with the `$( )` removed. Tests: `orc:tests/spl-reflection-gather.tst.sh` (`SPOOL_TEST=1`), `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs the `git grep` reads of 1.3 or 1.4 on the
`origin/master` it starts from, and says in its result if the sites moved.

**Subject** (R6 reads it): `<type>(r72-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r72-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01: the struct's doc comment carries what the fields mean; no
`csi-spl-doc/` spec names the method's parameters (1.3). Row 02: the function's comment
and the action's `@param REFLECTION_ZOMBIE_LOG` help line say the default is
`<SPL_VAR_APP_DIR>/zombie-topics/cron.log` and do not change. Each row carries
`Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, disjoint: row 01 is under `csi-spl-api/` only, row 02
  under `csi-spl-orc/src/bash/` only. They may place together.
- No row edits a migration, `csi-spl-cnf/`, a workflow, terraform or `csi-spl-wui/`;
  row 02 does not edit `lib:spl-run-paths.func.sh`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-778`, one call per
  path, 2026-11-20T03:09:27Z, n=1: **exit 4 on all 16 row paths** (the 14 Go files of
  row 01, the func and test of row 02): no live lane lists them; 2 live lanes record no
  files: c-046 (spec 143 B-6b part 2, SPL-6006) and c-168 (`rotate`).
- **c-046's files, read from its review branch** (03:10Z):
  `git diff --name-only $(git merge-base origin/master 70a217610) 70a217610`, branch
  `review/c002-feat-s143-b6b2-api-hub-github-sync-webhook-sync-now` -> 15 paths:
  `cmd/spool/hub.go`, `cmd/spool/hub_repo_sync.go`, `internal/config/` (2),
  `internal/github/` (2), `internal/hub/` `demo_test.go`, `repo_sync.go`,
  `repo_sync_gaps_test.go`, `repo_sync_routes.go`, `repo_sync_routes_test.go`,
  `server.go`, `openapi.json`, a spec 143 doc and `example.env.yaml`: **none** is a row
  path. Its first-half branch `review/c002-feat-s143-b6b-api-hub-github-sync-per-repo`
  holds none either. c-168's scope was not read: the holder's R3 check before the spawn
  governs.
- **This box's lane worktrees** (03:10:37Z, 304 entries in `git worktree list`):
  `git -C <wt> diff --name-only origin/master...HEAD` and `git -C <wt> diff --name-only HEAD`,
  restricted to the row files -> 2 hits, both stale: m-738 (`change_stamp_test.go`; its
  head `d4aacd76f` of 2026-10-23 landed as `a63179997`) and g-542's r59-06 scratch
  (`cleancode_test.go`; landed as `5d4d08910`); neither has a live window. The live
  agents the brief names (c-772 b25-01 `sa:tests/test-agent-boot-restore.sh`, c-625 spec
  181 doc only) hold no row file. The other box's worktrees were not read by this lane.
- **Commits since W** on the 16 row paths (`git log origin/master --since="$W" -- <paths>`) -> **0**.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-20T03:10:4xZ):
  **0 queued, 0 placing**. Live share `refactor 1 7% (band 40-60%: UNDER)`; last 24 h
  `refactor 18% (band 20-30%: UNDER)`; `phase night`.
- **Briefs on this lane's box** naming a row symbol or path
  (`grep -rlE 'message_move(_postgres)?\.go|MoveMessage|spl-reflection-gather|cleancode_test\.go'`
  over `/var/spool-hub/dispatch/briefs` and `/var/spool-hub/spawn-remote/briefs`, as root,
  03:10Z): this brief, then the r71 row and reviewer briefs (landed), then older.
- **Unlanded round rows:** none known to this lane; b25-01 (c-772) is
  `sa:tests/test-agent-boot-restore.sh`, not a row file.

## 3. Per row: what the lane does

- **r72-01:** `MoveMessageReq` joins `message_move.go`; the `Moves` interface, the
  Memory and the Postgres implementations take `(ctx, tenantID, r MoveMessageReq)`; the
  hub's `storeMessageMove` and the 21 test calls build it; `wideFuncs` empties. The
  Postgres query and its arguments do not change.
- **r72-02:** the reflection gather's section 6 derives its log with
  `spl_var_app_subdir` inside its `$( )`; nothing it prints changes, and no `SPL_*`
  export reaches the gather's shell. Case 18 gains the no-leak assertion.

## 4. Panel and reviewers (R7)

- Editor: c-778 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r72`):
  one **agy** doc seat, the main vendor for spec and plan reviews, with mistral as its
  backup, as r62 to r71 had (the brief: no agy CLI on one box, agy quota out on the other
  until ~11-24, so mistral is the likely seat). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2), the holder's call when the row
  is queued (a fresh claude seat under the claude waiver, as r63 to r71). Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 or 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r72-01 | `c002-r72-01-api-move-message-req` | `refactor(r72-01-api-move-message-req, SPL-<row issue>): ...` | `review/r72-01` | 1 |
| r72-02 | `c002-r72-02-orc-reflection-zombie-subdir` | `refactor(r72-02-orc-reflection-zombie-subdir, SPL-<row issue>): ...` | `review/r72-02` | 1 |

**r72-01 brief, Files: ONLY** `api:store/message_move.go`, `api:store/message_move_postgres.go`,
`api:hub/message_move.go` (`storeMessageMove` only), `api:cleancode/cleancode_test.go`
(`wideFuncs` and its comment only), and the 10 test files of 1.3 (their `MoveMessage`
call lines only). NOT `api:hubclient/` or `api:action/` (the other `MoveMessage`). Do:
plan section 2 row 01 verbatim, the struct as 1.3 writes it, beside `MoveResult`; the
query string and its argument order unchanged; the gate's red control and the before /
after counts (store set on a throwaway Postgres, hub set, cleancode) in the body. Gates:
1.3's column, `bash csi-spl-api/src/bash/tests/run-all-tests.sh`,
`cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push`. `Docs: none (...)`.
Kind `simple_coding`, vendor claude.

**r72-02 brief, Files: ONLY** `orc:run/spl-reflection-gather.func.sh` (lines 216-217
only) and `orc:tests/spl-reflection-gather.tst.sh` (case 18 only). NOT
`lib:spl-run-paths.func.sh`. Do: plan section 2 row 02 verbatim, the two lines as 1.4
writes them, the `$( )` kept; the gate (1 -> 0), case 18 on the parent and the change,
the mutation control and the new no-leak assertion's outputs in the body. Run the test
with `SPOOL_TEST=1`. Gates: `orc:tests/spl-reflection-gather.tst.sh`,
`bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Go store + gate 1, Bash action 1) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: rows 01 and 02 |
| Go `wideFuncs` lines (`api:cleancode/cleancode_test.go`) | 2 today -> 0 after r72-01 |
| hand-written `SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/` lines outside `csi-spl-doc` | 1 today -> 0 after r72-02 |
| measured on | `99548495c`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| SC2034 baseline: `sa:lib/spool-env.inc.sh`, `sa:lib/spool-mirror-hooks.inc.sh`, `sa:scripts/` (spawn, restore, chain, task families, `agent-top.sh:77`, `trust-workdir.sh:368`), `orc:run/spl-spec-import-issues.func.sh:300-304` | upper-case globals or vars a sourcer, launcher or called function may read: each needs the per-variable read check across every sourcer (r68, r70, r71 section 7); the baseline is unchanged since r71's read | 1.2 |
| iac test SC2034: `check-pre-push.tst.sh:53`, `check-weekly-full-scan.tst.sh:29` (`APP_PATH`), `satellite-actions.tst.sh:46` (`GCP_ACCOUNT`) | set for the sourced action under test to read (r67 1.3) | r71 section 7 |
| `iac:tests/workflow-tool-checksums.tst.sh:33` `naked` | a guard computed and never asserted: a bug row (r67 1.3) | r71 section 7 |
| `.github/workflows/10_ci-quality.yml:444-445` comment wording (p18-02 N1) | a workflow edit for one clause of a comment; fits a CI or perf row that touches the file anyway | the candidates file (the holder's read) |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | 63 positional caller lines in 35 files (r67's read, not re-read here), a WUI row with its e2e gate; a candidate for a later round now that the Go list empties | r68 1.2 |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66 to r71) | 1.2 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour (T028's assertions), terraform layout (T026) or docs (T031); the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-778): first draft. A fresh round: the `MoveMessage` pair, free since r69-02
  landed `99029842f`, re-measured on `99548495c` (25 store call lines in 13 files, as r70
  read); the reflection gather's derive line re-read with what an empty value does
  downstream, and the subshell kept so no export leaks. Window W and the r72 slug proof
  recorded.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-778 (claude): v0.1.
- Panel reviewer seat: requested (section 4), not yet signed.
- Row R7 seats: section 4.
