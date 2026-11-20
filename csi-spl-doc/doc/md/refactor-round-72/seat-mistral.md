# Refactor round 72 — seat mistral (panel, docs and reviews only)

Seat: m-206@sat, placement `c002-refactor-round-72-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-72-mistral-panel-seat.md`
(Issue SPL-6012, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `a2c852b7-ae60-40bb-9c2b-d783ff969931`).

Review target: plan v0.1 `1d212b56fde9b13de133a08297bf385a71dd01bf`, named by the
editor c-778 (msg a837c5a9, planner seat on the other box) and by the dispatch holder c-002@sat on task
`dispatch-refactor-r72` (2026-11-20T03:21:05Z: "on plan v0.1 1d212b56f ... ls-remote
head of review/c002-refactor-round-72-planner, parent 99548495c, ancestor of
origin/master 6bac8a7fa"). Provenance at my read (2026-11-20T03:2x-03:3xZ):
`git ls-remote origin | grep -E 'r72-[0-9]{2}|refactor-round-72'` ->
`1d212b56fde9b13de133a08297bf385a71dd01bf  refs/heads/review/c002-refactor-round-72-planner`
(the only match; my review branch did not exist yet at this read);
`git log -1 --format='%H %P' 1d212b56f` -> `1d212b56fde9b13de133a08297bf385a71dd01bf
99548495c935e38e08e5eed9e97150f100d6e36a` (the plan's stated parent);
`git show 1d212b56f --stat` -> 1 file, `csi-spl-doc/doc/md/refactor-round-72-plan.md`,
+365, read in full at that sha (365 lines). `git merge-base --is-ancestor 99548495c
origin/master` -> rc 0. No later plan version was named on task `dispatch-refactor-r72`
at my read (`SPOOL_ROOT=/var/spool-hub spool tail --task dispatch-refactor-r72` -> last
message 2026-11-20T03:25:33Z `c-001 -> c-002 [note] placed: m-206@sat`; no `v1.0` line),
so I sign v0.1 `1d212b56f`. origin/master at my read: `git fetch origin master && git
rev-parse origin/master` -> `2a7befc02d8a46fd7417b08d5737c19c39ab5aa1` (moved past the
brief's `6bac8a7fa` during the read, N1; every site line re-verified identical on both,
check 2).

## Verdict

**PASS on `1d212b56fde9b13de133a08297bf385a71dd01bf`** (plan v0.1, 2 rows). No defect.
All ten checks verified clean: slug free, every site file:line exists on `99548495c` and
still on origin/master with no drift, the 3/1/21 counts and the 2 `wideFuncs` entries
hold, the r69-02 shape is followed and the Postgres run + `PRE_PUSH_TIER=full` are named,
the gather's `(not read ...)` line and rc 0 are kept and the subshell holds the exports,
both rows carry practice/red control/test list/vendor claude/kind simple_coding/batch 1
with no mistral coding or testing row and no mistral code R7, no live lane owns a row
path, no live perf/bug round row names the files, the candidates file's refactor-shaped
items are all already served on origin/master, dist hygiene clean. Per rulebook 3.2 the
panel signs this sha; I sign a later v1.0 in a second commit on this branch when the
editor names it.

## Checks (each with the command run and what it printed, 2026-11-20 03:2x-03:3xZ)

### 1. Slug r72 unused

- `git log origin/master --oneline -E --grep='\(r72-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r72-[0-9]{2}|refactor-round-72'` -> one line,
  `1d212b56fde9b13de133a08297bf385a71dd01bf  refs/heads/review/c002-refactor-round-72-planner`
  — the planner's branch, expected; nothing else (my own review branch is created only
  when I push this seat file).
- `grep -rlE 'r72-[0-9]{2}' /var/spool-hub/dispatch/briefs 2>/dev/null | wc -l` -> `1`,
  only `/var/spool-hub/dispatch/briefs/c002-refactor-round-72-mistral-panel-seat.md`
  (this brief; the planner's brief sits on the other box, not readable here).
- Control: `git log origin/master --oneline -E --grep='\(r71-' | wc -l` -> non-zero
  (the r71 commits), so the read sees a used id.

### 2. Every site file:line of both rows exists on `99548495c` and on origin/master

Full paths, one per name (`git ls-tree -r --name-only origin/master | grep <name>`):
`csi-spl-api/src/go/spool-hub-api/internal/store/message_move.go`,
`csi-spl-api/src/go/spool-hub-api/internal/store/message_move_postgres.go`,
`csi-spl-api/src/go/spool-hub-api/internal/hub/message_move.go`,
`csi-spl-api/src/go/spool-hub-api/internal/cleancode/cleancode_test.go`,
`csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh`,
`csi-spl-orc/src/bash/tests/spl-reflection-gather.tst.sh`,
`csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh`.

`git show <sha>:<file> | sed -n <N>p` for each cited site, on both `99548495c` and
`origin/master` (`2a7befc0`) — **all identical, 0 drifted**:
- `store/message_move.go:74` -> `MoveMessage(ctx context.Context, tenantID, msgID, toTask, toChannel, by string, at, notBefore time.` (the `Moves` interface method, 8 params);
  `:136` -> `func (s *Memory) MoveMessage(_ context.Context, tenant, msgID, toTask, toChannel, by string, at, not` (8 params).
- `store/message_move_postgres.go:97` -> `func (s *Postgres) MoveMessage(ctx context.Context, tenant, msgID, toTask, toChannel, by string, at,` (8 params);
  `:113` -> `err = tx.QueryRow(ctx, moveMessageCTE, tenant, msgID, set.MsgIDs, toTask, nullText(toChannel), not`.
- `hub/message_move.go:326` -> `res, err := s.o.Store.MoveMessage(ctx, tenant, m.MsgID, task, card.Channel, by, at,`; `:327` -> `card.ReceivedAt.Add(time.Millisecond))`.
- `cleancode/cleancode_test.go:35` -> the `wideFuncs` comment; `:41` -> `var wideFuncs = map[string]bool{`; `:44` -> `}`.
- `run/spl-reflection-gather.func.sh:213` -> `spl_reflection_zombie() {`; `:216` -> the `declare -F spl_run_paths ... source` guard; `:217` -> `log="$( { spl_run_paths || :; } 2>/dev/null; printf '%s' "${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/zombie-topics/cron.log}")"`; `:222` -> `}`.
- `tests/spl-reflection-gather.tst.sh:490` -> blank (case 18 block starts `:491`); `:506` -> `got="$(s6 SPL_RUN_PATHS_TOP=)"` (the no-tree branch).
- `lib/bash/funcs/spl-run-paths.func.sh:78` -> `# spl_var_app_subdir <var> <sub>: set <var> (the caller's) to`; `:85` -> `}`.

Planner's drift claim: `git diff --name-only 99548495c 6bac8a7fa` -> 15 files
(`cmd/spool/hub.go`, `cmd/spool/hub_repo_sync.go`, `internal/config/config.go`,
`internal/config/repo_sync_default_test.go`, `internal/github/repo_sync.go`,
`internal/github/repo_sync_test.go`, `internal/hub/demo_test.go`,
`internal/hub/openapi.json`, `internal/hub/repo_sync.go`,
`internal/hub/repo_sync_gaps_test.go`, `internal/hub/repo_sync_routes.go`,
`internal/hub/repo_sync_routes_test.go`, `internal/hub/server.go`,
`csi-spl-doc/specs/143-reporting-section/releases-projects.md`, `example.env.yaml`)
— the spec 143 B-6b lane's files; `... | grep -E 'message_move|spl-reflection-gather|cleancode_test|spl-run-paths'` -> no match (rc 1). Same for
`git diff --name-only 99548495c origin/master | grep -E '...'` -> no match (rc 1).
**No row file drifted.**

### 3. r72-01 counts

- `git grep -nE '\bMoveMessage\(' origin/master -- csi-spl-api | wc -l` -> `28`.
- Split: `... | grep -E 'hubclient|internal/action'` -> 3 lines
  (`internal/hubclient/move.go:38`, `internal/hubclient/cli_verbs_test.go:102`,
  `internal/action/move.go:87`) — the hub client's 5-parameter `MoveMessage`, not this
  row. The other 25 are store + `hub/message_move.go`.
- Per file (25 lines in 13 files): `store/message_move.go` 2 (`:74`, `:136`),
  `store/message_move_postgres.go` 1 (`:97`), `hub/message_move.go` 1 (`:326`),
  `store/message_move_test.go` 6 (`:135,138,161,170,197,204`),
  `store/topic_head_harness_test.go` 4 (`:302,308,514,575`),
  `store/topic_head_rls_test.go` 3 (`:190,331,345`),
  `store/topic_head_concurrency_test.go` 2 (`:153,479`), `store/change_stamp_test.go` 1
  (`:169`), `store/flow_place_key_test.go` 1 (`:141`),
  `store/search_index_equiv_test.go` 1 (`:325`), `store/topic_head_random_test.go` 1
  (`:380`), `hub/channels_test.go` 1 (`:456`), `hub/view_delta_test.go` 1 (`:203`) —
  every line number matches the plan's 1.3 table.
- **3 / 1 / 21 holds**: 3 signatures (interface `:74`, Memory `:136`, Postgres `:97`;
  `git grep -nE 'func \(.*\) MoveMessage\(' origin/master -- '*.go'` -> those 2 store ones
  plus the hub client's), 1 non-test hub caller (`hub/message_move.go:326`), 21 test
  calls (25 - 3 - 1).
- `wideFuncs` today: `git show origin/master:.../cleancode/cleancode_test.go | sed -n '41,44p'`
  -> `var wideFuncs = map[string]bool{` + exactly 2 entries
  (`"internal/store/message_move.go (*Memory).MoveMessage": true` at `:42`,
  `"internal/store/message_move_postgres.go (*Postgres).MoveMessage": true` at `:43`)
  + `}` at `:44`. File and lines: `csi-spl-api/src/go/spool-hub-api/internal/cleancode/cleancode_test.go:41-44`.

### 4. r72-01 shape (r69-02)

- `git merge-base --is-ancestor 99029842f origin/master` -> rc 0 (r69-02 landed).
- `git show origin/master:.../store/topic_merge.go | sed -n '36,50p'` -> the
  `MergeTopicReq` doc comment + struct at `:36-43` (`SrcMsgID, SrcTask, TargetTask,
  ToChannel, By string; At time.Time`), beside `MergeResult`, and the interface at `:50`
  takes `MergeTopic(ctx context.Context, tenantID string, r MergeTopicReq)`; the
  implementations at `topic_merge.go:63` (`(*Memory)`) and
  `topic_merge_postgres.go:29` (`(*Postgres)`) take the same `(ctx, tenant, r)`.
  **The plan's `MoveMessageReq` follows the r69-02 shape exactly**: doc comment "one
  MoveMessage call: ...", struct beside `MoveResult` in `message_move.go`, interface and
  both implementations taking `(ctx context.Context, tenantID string, r MoveMessageReq)`.
- Postgres run named: the row's test column says "the store set of 1.3 on a throwaway
  Postgres ... before (the row's parent) and after" and 1.3 says "the row lane runs the
  store set on a throwaway Postgres (`postgres:16-alpine`, a non-superuser runtime role,
  as r69-02's body records), before and after"; the tests column names
  `cd csi-spl-iac && PRE_PUSH_TIER=full ./run -a do_check_pre_push` (a store change).
  **Yes.** The 32 DSN-less skips come from the store `-run` pattern
  `TestMoveTopicAndMessage|TestChangeStampWriters|TestFlowPlaceKey0137|TestSearchIndexEquivalence|TestTopicHead|TestCrossTenantTopicHeads`;
  every one of those `Test*` names is in the row's test list (1.3 "Tests (R2)"), so the
  32 skips are covered by the row's Postgres run.

### 5. r72-02

- `git show origin/master:csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh | sed -n '205,225p'`
  -> `spl_reflection_zombie` at `:213-222` matches the plan's quote: `:216` the
  `declare -F spl_run_paths ... source` guard, `:217` the
  `log="$( { spl_run_paths || :; } 2>/dev/null; printf '%s' "${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/zombie-topics/cron.log}")"`,
  `:219` `[[ -n "$log" ]] || { echo "(not read: no zombie sweep log: REFLECTION_ZOMBIE_LOG unset and no SPL_VAR_APP_DIR derived)"; return 0; }`.
  **The `(not read ...)` line and rc 0 for an unset/empty `SPL_VAR_APP_DIR` are kept**:
  with the helper, "no dir" is its rc 1, the `&&` skips the `printf`, the `$( )` yields "",
  so `:219` prints the same line and returns 0 — same output, same rc.
- `git show origin/master:csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh | sed -n '78,86p'`
  -> `spl_var_app_subdir` at `:78-86`: it calls `spl_run_paths` **in the caller's shell**
  (`spl_run_paths && [[ -n "${SPL_VAR_APP_DIR:-}" ]] || return 1`), and `spl_run_paths`
  exports `SPL_ORG_DIR SPL_VAR_APP_DIR SPL_VAR_ORG_DIR SPL_WT_ROOT SPL_DESK_DIR`. Called
  bare in the gather it would leak those exports into sections 7 on; **inside the `$( )`
  nothing leaks**, as today — the plan's "why the subshell stays" is correct.
- Count: `git grep -nF 'SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/' origin/master -- . ':!csi-spl-doc'`
  -> exactly 1 line, `csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh:217` (the
  row's gate 1 -> 0 is real; the `-E` form of the same pattern also prints 1).
- Case 18: `git show origin/master:.../tests/spl-reflection-gather.tst.sh | sed -n '491,506p'`
  -> 4 branches: `SPL_VAR_APP_DIR` dir, tree via `SPL_RUN_PATHS_TOP`, the
  `REFLECTION_ZOMBIE_LOG` override, and no tree -> the exact `(not read: ...)` line.

### 6. Per row: practice, red control, test list, vendor, kind, batch, R7

From the plan's section 2 table (read at `1d212b56f`): both rows carry a practice
(row 01: at most 7 parameters, pass a struct, developer guide 2.2.2; row 02: folded
helpers exist once, 2.2.4 + canonical paths 2.3.1), a red control that fails today and
passes after (row 01: the 2 `wideFuncs` lines deleted while the signatures are still
wide -> `TestCleanCodeGate` FAIL; row 02: the helper's `<sub>` misspelt
(`zombie-topics/cron.lgo`) turns case 18's dir and tree cases red, plus the new no-leak
assertion FAIL with the `$( )` removed), a test list, box `either`, **vendor claude**,
**kind simple_coding**, **batch 1** for both. **No mistral coding or testing row**; the
R7 row reviewers are cross-vendor first or the claude waiver seat — section 4 says
explicitly "Not a mistral code R7" (the mistral seat is this doc panel only, allowed by
the owner's docs-and-reviews-only rule 91bf8278).

Would each red control really fail on `99548495c`?
- Row 01: yes. The gate at `cleancode_test.go:86-90` does `if f.params > maxParams {
  seenWide[f.key] = true; if limit := wideLimit(f.key); f.params > limit { t.Errorf(...) } }`
  with `maxParams = 7` (`:20`) and `wideLimit` (`:124-130`) returning `maxParamsListed = 8`
  only for a `wideFuncs` key, else `maxParams`. With the 2 lines deleted and the pair still
  at 8 params (verified at `message_move.go:74,136` and `message_move_postgres.go:97` on
  `99548495c`), `8 > 7` -> `t.Errorf("... takes 8 parameters (> 7) ...")` -> FAIL.
- Row 02: the red control is a post-change mutation control (the misspelt `<sub>` exists
  only after the row lands); on `99548495c` the current line is green — case 18's 4
  branches are all present at `spl-reflection-gather.tst.sh:491-506` and the planner's
  recorded run on `99548495c` was rc 0, 61 pass lines, case 18 4 of 4 PASS (I read the
  test, did not re-run it; NOT RUN: the bash suite).

### 7. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-api/src/go/spool-hub-api/internal/store/message_move.go,csi-spl-api/src/go/spool-hub-api/internal/store/message_move_postgres.go,csi-spl-api/src/go/spool-hub-api/internal/hub/message_move.go,csi-spl-api/src/go/spool-hub-api/internal/cleancode/cleancode_test.go,csi-spl-api/src/go/spool-hub-api/internal/store/message_move_test.go,csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh,csi-spl-orc/src/bash/tests/spl-reflection-gather.tst.sh,csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh --agent m-206`
-> **exit 4**: `WARN no live lane lists <the 8 paths>, but 9 live lane(s) record no
files: their scope is unknown, not free`; `unknown:` c-049, c-060, c-625, c-772, c-778,
c-812, c-924, c-927, m-767 (all on the other box; box qualifiers dropped here, the other
box's name is hygiene-banned in the tree). Exit 4 (not 3):
**no live lane owns any row path**; exit 4 means ask-first for the 9 no-file lanes, not
free (N2).

The brief's named live lanes, checked by branch: `git ls-remote origin` ->
`review/b25-01` = `ba6ca0cb`, `review/c002-feat-s143-b6b-api-hub-github-sync-per-repo` =
`255dea57`, `review/c002-feat-s143-b6b2-api-hub-github-sync-webhook-sync-now` =
`70a21761`, `review/c-181-c002-s114-t002a-own-reads-name-tenant` = `60b6931e`. For each,
`git diff --name-only $(git merge-base <sha> origin/master) <sha> | grep -E 'message_move|spl-reflection-gather|cleancode_test|spl-run-paths'`
-> no match ("no row file") for all four. The s143 B-6b work already landed as
`6bac8a7fa` (the 15 files of check 2, none a row file) and b25-01's fix landed as
`2a7befc0` (current origin/master). The planner's own branch
`review/c002-refactor-round-72-planner` touches only the plan file (`git show 1d212b56f
--stat` -> 1 file).

### 8. R1 across rounds

Newest round plans on origin/master (`2a7befc0`), numeric sort of
`git ls-tree --name-only origin/master csi-spl-doc/doc/md/`: perf rounds 16/17/18
(`perf-round-16-plan.md` blob `9803e465`, `perf-round-17-plan.md` blob `81756964`,
`perf-round-18-plan.md` blob `9bc80835`), bug rounds 20-25 (`bug-round-25-plan.md` blob
`00a760fe`, the newest). For each of perf-18/17/16 and bug-25/24/23/22/21/20:
`git show origin/master:csi-spl-doc/doc/md/<f> | grep -cE 'message_move|spl-reflection-gather|MoveMessage|cleancode_test|spl-run-paths'`
-> `0, 0, 0, 0, 0, 1, 0, 0`. The one hit, `bug-round-23-plan.md:158` (blob
`a366aecad`), is a left-out note (r66-02 N1, shallow APP_PATH) citing
`spl-run-paths.func.sh:66-73` and saying "Not a row until a real run ... is seen" — not a
row naming these files. (`perf-round-7-plan.md:120` also mentions `cleancode_test.go`
via the historical r57-06/r59-06 note; that round is long closed.) **No live perf or bug
round row names a row file.**

### 9. Candidates file

`/var/spool-hub/dispatch/c002-next-round-candidates.md` readable on this box:
`ls -la` -> 9542 bytes, mtime Nov 19 22:49 (matches the holder's read: 9542 bytes,
last changed 2026-11-19 22:49:35 +0200); read in full (48 lines). Its refactor-shaped
items and their state on origin/master (`2a7befc0`):
- r34-05 R7 N3 (literal `/var` at `spl-watchdog.func.sh:72,:1311` and
  `spl-lane-rotate.func.sh:112`): **served** — the files moved to
  `csi-spl-orc/src/bash/run/`; `spl-watchdog.func.sh:72` is now a `@param LOGIN_STATE_DIR
  ... default spl_claude_login_state_dir (<SPL_VAR_APP_DIR>/age...` comment and
  `spl-lane-rotate.func.sh:112-114` sources `spl-claude-login.func.sh`;
  `git grep -nE '/var/(csi|spool)' origin/master -- .../run/spl-watchdog.func.sh .../run/spl-lane-rotate.func.sh`
  -> no lines.
- r63-01 R7 W1 (`reverse-tunnel-cron.sh:23` literal): **served** —
  `git grep -n 'reverse-tunnel}' origin/master -- csi-spl-orc/src/bash/scripts/reverse-tunnel-cron.sh`
  -> `:27` now `ls "${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}"/*.conf`.
- r69-planner item (agent-boot-restore dir literal): **served** —
  `spl-agent-boot-restore-install-cron.func.sh:60` now
  `spl_var_app_subdir logdir agent-boot-restore || { do_log "FATAL ..."; return 1; }`;
  `git grep -nE '/var/.*agent-boot-restore' origin/master -- csi-spl-orc/src/bash/run/`
  -> no lines.
The rest of the file is bug/test/doc-shaped (b12-02 N2-N4, SPL-5824/5825 W1-W2, SPL-5850
N1, review-go retry, suite-hermeticity, placer notes, unanswered-sweep rows). **No
refactor-shaped item is left unserved and unlisted** — the plan's section 7 does not list
the three above because they are already fixed on master, not deferred.

### 10. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`ok - owner mail address or domain`, `ok - hidden workspace or private literal (SPL-1874)`,
`ok - retired relay estate (SPL-1910)`, `ok - no tracked .vibe/ dir`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-206`.

## Defects

None. W1..: none.

## Notes

- N1: origin/master moved during my read, from the brief's `6bac8a7fa` to
  `2a7befc02d8a46fd7417b08d5737c19c39ab5aa1` (`git log --oneline 6bac8a7fa..origin/master`
  -> 1 commit, the b25-01 fix `fix(b25-01-orc-boot-restore-test-pid-needle, SPL-6011)`).
  Every site file:line was re-verified identical on both (check 2), and
  `git diff --name-only 99548495c origin/master` touches no row file.
- N2: the lane-map check exits 4, not 3: no live lane lists a row path, and 9 live lanes
  record no files (their scope is unknown, not free — ask-first per the rule). I checked
  the brief's named live lanes by their review branches instead (check 7); none touches a
  row file.
- N3: row 02's red control is a mutation control on the post-change code; on `99548495c`
  the current derive line is green (case 18's 4 branches read at
  `spl-reflection-gather.tst.sh:491-506`; the planner's recorded run on `99548495c` was
  rc 0, 61 pass lines, case 18 4 of 4 PASS). I did not re-run the bash suite myself.
- N4: the candidates file's three refactor-shaped items are all already served on
  origin/master (check 9), so "the plan neither serves nor lists them" does not arise;
  the plan's 1.2 row about the candidates file reflects the holder's 03:1xZ read and is
  still accurate for what remains.

## Report line (sent on task `dispatch-refactor-r72`)

`panel: m-206@sat mistral PASS 1d212b56fde9b13de133a08297bf385a71dd01bf seat-file: review/c002-refactor-round-72-mistral-seat <this commit's sha> ran: <commands> | read: <files> | log: m-206@sat:~/.vibe/logs/session/unified/37043005-d3c3-28f2-9471-b2d7fdb522d5`
