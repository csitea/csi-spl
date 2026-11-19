# Refactor round 69 (r69): mistral panel seat (m-079)

Seat: m-079, placement `c002-refactor-round-69-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-69-mistral-panel-seat.md`
(Issue SPL-5995, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `9ab7cad2-5ca6-4f10-8c11-4af4c2d1ddd7`).

Review target: plan v0.2 `36833e5593588fd4065e17b7f598ce0ac3a9df17`, named by the
editor c-606 (msg 39dc1e85) and by the dispatch holder on task `dispatch-refactor-r69`
(msg 2026-11-19T20:25:52Z: "Sign 36833e559, not d73f0f702; your brief file now says
so"); the brief file names v0.2 at its line 15. Provenance:
`git ls-remote origin | grep refactor-round-69` ->
`36833e5593588fd4065e17b7f598ce0ac3a9df17  refs/heads/review/c002-refactor-round-69-planner`;
`git log --oneline origin/master..36833e559` -> `36833e559 docs(r69-plan, SPL-5995): ... v0.2 ...`
over `d73f0f702 ... v0.1 ...` over `79b22fa06` (fast-forward, one file,
`csi-spl-doc/doc/md/refactor-round-69-plan.md`, +9/-3, section 7 + status only, rows
01/02 unchanged: `git diff --stat d73f0f702 36833e559` -> `1 file changed, 9 insertions(+), 3 deletions(-)`).
`git show 36833e559:csi-spl-doc/doc/md/refactor-round-69-plan.md` -> 324 lines, read in
full at that sha (v0.1 read in full too, 318 lines). origin/master at my read:
`79b22fa0669b452578735ed4c64159fce8b80f22` (unchanged from the plan's base, N1).
No later plan version was named on task `dispatch-refactor-r69` at my read
(`spool tail --task dispatch-refactor-r69` -> 7 messages, last 20:25:52Z), so I sign
v0.2 `36833e559`.

## Verdict

**PASS on `36833e5593588fd4065e17b7f598ce0ac3a9df17`** (plan v0.2, 2 rows, both
verified on `79b22fa06` = origin/master at read time). Defects: W1 (a wrong premise in
the section 7 measurement of the agent-boot-restore item; it does not touch either
row, the editor should correct the text in v1.0). Notes N1..N7 below.

## Checks (each with the command run and what it printed, 2026-11-19 21:0x-21:3xZ)

### 1. Slug r69 unused

- `git log origin/master --oneline -E --grep='\(r69-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r69-[0-9]{2}|refactor-round-69'` -> one line,
  `36833e5593588fd4065e17b7f598ce0ac3a9df17  refs/heads/review/c002-refactor-round-69-planner`
  — the planner's branch, expected; nothing else (my review branch did not exist yet
  at this read).
- `grep -rlE 'r69-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/dispatch/asks 2>/dev/null | wc -l`
  -> `1`, the one file
  `/var/spool-hub/dispatch/briefs/c002-refactor-round-69-mistral-panel-seat.md` (this
  seat's own brief; the planner read only the other box's).
- Control: `git log origin/master --oneline -E --grep='\(r68-' | wc -l` -> `5` (the
  read sees a used id); `git ls-tree --name-only 79b22fa06 csi-spl-doc/doc/md/ | grep -c refactor-round-69`
  -> `0`; `git log origin/master -1 --format=%cI -E --grep='^docs\(r68-plan'` ->
  `2026-11-19T18:52:32+01:00` = the plan's recorded W.

### 2. Every site file:line of both rows exists on `79b22fa06` and on origin/master

`git show <sha>:<file> | sed -n <N>p` for each of the 30 cited sites (row 01:
`test-agent-identity-reconcile.sh:54,55,75`, `test-agent-identity-restore.sh:95`,
`test-spool-poke-queue.sh:254,269`; row 02: `topic_merge.go:42,55`,
`topic_merge_postgres.go:30`, `hub/topic_merge.go:108`, `cleancode_test.go:39,40,44,45`,
`store.go:336`, `hub/fallback_test.go:370`, `store/flow_place_key_test.go:150`,
`store/topic_head_concurrency_test.go:190,223`, `store/topic_head_harness_test.go:320,326,564`,
`store/topic_head_random_test.go:399`, `store/topic_head_rls_test.go:335`,
`store/topic_head_sql_test.go:558`, `store/topic_merge_test.go:69,72,77,158`,
`store/write_batch_rt_test.go:135`) -> **30 OK, 0 MISSING on `79b22fa06`; 30 OK, 0
MISSING on origin/master** (the two shas are equal, so nothing drifted). Spot lines:
`topic_merge.go:42` -> `MergeTopic(ctx context.Context, tenantID, srcMsgID, srcTask, targetTask, toChannel, by string, at time.Time) (MergeResult, error)`;
`hub/topic_merge.go:108` -> `res, err := s.o.Store.MergeTopic(r.Context(), c.t.ID, c.m.MsgID, c.m.TaskID, task, card.Channel, c.from, at)`;
`cleancode_test.go:44-45` -> the two `MergeTopic` `wideFuncs` lines. Full paths:
`git ls-tree -r --name-only origin/master | grep <name>` -> each name resolves to
exactly the cited path under `csi-spl-orc/src/bash/features/spawn-agents/tests/` or
`csi-spl-api/src/go/spool-hub-api/internal/...` (17 files listed, all present).

### 3. r69-01 baseline and shellcheck

- `git show origin/master:.shellcheck-warning-baseline.txt | grep -vcE '^\s*(#|$)'` ->
  **73** (the plan's 73).
- The row's 3 lines are in it today:
  `SC2034|csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-identity-reconcile.sh|2`,
  `...test-agent-identity-restore.sh|1`, `...test-spool-poke-queue.sh|2`; the 4th
  `spawn-agents/tests` SC2034 line is `tests/lib.inc.sh|1`, and 4 iac lines — as the
  plan's 1.2 says.
- `shellcheck --version` -> 0.10.0 (present, not installed by me). For each row file,
  `git show origin/master:<file> > /tmp/sc-file.sh; shellcheck -S warning -f gcc /tmp/sc-file.sh | grep SC2034`
  -> reconcile: `:55:25 pane appears unused`, `:75:1 before appears unused` (2);
  restore: `:95:1 RUNNER appears unused` (1); poke-queue: `:254:1 i appears unused`,
  `:269:1 A_PANE appears unused` (2). **5 warnings, exactly the row's 5**, at the
  cited lines.

### 4. r69-02 scope

- The plan's own command: `git grep -nE '\bMergeTopic\(' 79b22fa06 -- '*.go' | wc -l` ->
  **19**, `git grep -lE ... | wc -l` -> **12 files** — exactly the plan's 19 in 12, and
  the 19 lines are the plan's list: contract `topic_merge.go:42`, impls `:55` and
  `topic_merge_postgres.go:30`, hub caller `hub/topic_merge.go:108`, and the 15 test
  calls in 9 files (listed in check 2). Every caller the plan lists is all of them.
- The brief's looser command: `git grep -n 'MergeTopic' origin/master -- csi-spl-api` ->
  33 lines in 16 files; the 14 extra are comments, `openapi.json`, the two
  `cleancode_test.go` gate lines and the `TestMergeTopic` decl — not callers (N6).
- `wideFuncs`: `git show origin/master:.../cleancode_test.go | sed -n '42,46p'` -> 4
  `true` lines: the `MoveMessage` pair and the `MergeTopic` pair (the plan's 4 -> 2
  after row 02); the comment at `:39-40` names both pairs.
- `git grep -nE '\bTopicMerge\b' origin/master -- '*.go'` -> 4 lines (`store.go:336`,
  `topic_merge.go:36,37`, `fallback_test.go:370`); the plan said 3 — the extra is the
  doc comment at `topic_merge.go:36` (N7). No other implementer: only `(*Memory)` and
  `(*Postgres)` declare `MergeTopic`.

### 5. Row fields (practice, R2 control, tests, vendor, kind, batch, R7)

Read in the plan's section 2 table and section 4 at `36833e559`: row 01 — practice
"bash that fails safely (developer guide 2.4.3)", red control (sites fixed, baseline
lines left -> `do_sec_shellcheck` FAILS; lines dropped -> PASS), test list (the three
files, `run-all-tests.sh`, `sec-shellcheck.tst.sh`, `do_check_pre_push_lint`), box
either, vendor **claude**, kind **simple_coding**, batch 1. Row 02 — practice "clean
code (2.2.2)", three red-control outputs, test list (12 files + 3 packages + full
pre-push), vendor **claude**, kind **simple_coding**, batch 1 **held by R3**. No
mistral coding or testing row. Section 4: row R7 reviewers are cross-vendor first or
the claude waiver seat, "Not a mistral code R7" — the mistral seat here is the doc
panel only, which the owner's rule allows. All fields present.

### 6. Behaviour

- r69-01, each removed variable never read in its file on origin/master:
  `git show origin/master:<f> | grep -nE '\$pane\b|\$\{pane\}'` (reconcile) -> only the
  assignments `:54` (local) and `:55` (read), no read of `$pane`;
  `grep -nE '\$before\b|\$\{before\}'` -> none (`:75` is the assignment; other `before`
  hits are comments/words); restore `grep -n RUNNER` -> `:95` only; poke-queue
  `grep -nE '\$i\b|\$\{i\}'` -> **0** lines, `grep -n A_PANE` -> `:269` only. All five
  confirmed dead.
- r69-02: the interface takes 8 parameters (`ctx, tenantID, srcMsgID, srcTask,
  targetTask, toChannel, by, at`); the proposed `MergeTopicReq{SrcMsgID, SrcTask,
  TargetTask, ToChannel, By string; At time.Time}` keeps all 6 non-ctx/tenant
  parameters 1:1, and the Memory impl body (read at `topic_merge.go:55-88`) uses each
  of the six in the same role — order of use preserved; `UnmergeTopic` (4 params) and
  `MergedRowHomes` (3) untouched, as the plan says.
- The red controls would really fail today — verified by reading the gate code (not
  run: running them needs the code change, which this seat must not make, N4):
  `sec-baseline.func.sh:67` -> `FATAL ... fewer findings than baselined ... rc=1` when a
  count drops below its baseline line (row 01's "sites fixed, baseline left" case);
  `cleancode_test.go:88-91` -> `t.Errorf("%s takes %d parameters (> %d)")` for an
  unlisted function over `maxParams` 7, and `:98-99` ->
  `t.Logf("wideFuncs: %q no longer takes more than %d parameters - delete its line")`
  for a stale listed one (row 02's log-then-fail sequence), `:126-132` -> listed keys
  get `maxParamsListed` 8, others 7.

### 7. R3 lane map

`bash .../spawn-agents/scripts/lane-map.sh --check <row 01's 4 paths, comma-separated> --agent m-079`
-> **exit 4**; same for row 02's 13 paths, and per-path for
`topic_head_harness_test.go`, `topic_merge.go`, `cleancode_test.go`,
`test-spool-poke-queue.sh`, `.shellcheck-warning-baseline.txt` -> **exit 4** each.
Output: `unknown:` 8 live lanes record no files — c-049, c-060, **c-521**
(`c-521-c002-s179-b1-rdb-store-topic-pauses`), c-592, c-606, c-812, c-924, c-927 (all
`@<box>`) — "ask it or read its brief". `lane-map.sh --all` -> 22 live rows; c-521
live 19m (spec 179 B1, SPL-5980), its R7 seat c-608 live, c-946, c-592, c-606 (the
planner) live; c-038 no longer live at my read. Exit 4 means not free, ask first —
so the plan's hold on r69-02 until c-521 lands (plan 2.2) is **right**: c-521 is live
and the plan records its worktree editing `topic_head_harness_test.go` (I cannot read
that worktree from this box; the lane map's exit 4 is the conservative read).

### 8. R1 across rounds

Newest plans on origin/master: `perf-round-18-plan.md` (last touched `da68ad993`),
`bug-round-23-plan.md` (`e7627fc85`). `git show origin/master:csi-spl-doc/doc/md/<f> | grep -cE 'MergeTopic|topic_merge|test-agent-identity-reconcile|test-agent-identity-restore|test-spool-poke-queue|shellcheck-warning-baseline|cleancode_test'`
-> perf-18/17/16 and bug-23/22/21 each **0**. Over all 15 perf + 23 bug plans on
origin/master, only 3 hits, all in closed rounds: `perf-round-4-plan.md:37` (p4 row 9
measured `MergeTopic`'s sequential statements — landed perf work),
`perf-round-7-plan.md:120` and `perf-round-11-plan.md:135` (name `cleancode_test.go`
as their own rows' gate file; p7/p11 rows landed per
`git log origin/master -E --grep='\((p7|p11)-[0-9]{2}-'`). **No live perf or bug round
row names these files.**

### 9. Candidates (this box) and the agent-boot-restore claim

- `ls -la /var/spool-hub/dispatch/c002-next-round-candidates.md` -> 9439 bytes,
  mtime Nov 19 22:25; read in full (48 lines). Refactor-shaped items in it: the r34-05
  R7 N3 literal-path item (`spl-watchdog.func.sh:72,1311`, `spl-lane-rotate.func.sh:112`)
  and the reverse-tunnel literal (`reverse-tunnel-cron.sh:23`) are **already fixed on
  origin/master**: `git grep -nE '/var/(csi|csitea)' origin/master -- csi-spl-orc`
  finds only test fixtures; `spl-watchdog.func.sh:72` now documents the default as
  `spl_claude_login_state_dir` (`<SPL_VAR_APP_DIR>/agent-login-check`),
  `spl-lane-rotate.func.sh:112-116` derives via `spl_claude_login_state_dir`, and
  `reverse-tunnel-cron.sh:27` gates on `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`.
  The rest of the file is bug-shaped (b12-02, SPL-5824/5825/5828, SPL-5850, review-go,
  hermetic suites, placer notes, sha256sum, Reflection rows A/B). **No open
  refactor-shaped item is left unserved by the plan.**
- The `/var/<org>/<org>-<app>/agent-boot-restore` literal recorded for r69 by r68's
  planner: **r69 v0.2 section 7 serves it** (plan line 302: measured, ruled "not a
  refactor: a behaviour change", bug/feature row). Verified on origin/master: the
  literals exist — `spl-watchdog.func.sh:539` ->
  `echo "${BOOT_CRON_LOG_DIR:-/var/${oa%%-*}/$oa/agent-boot-restore}/retired"` and
  `spl-agent-boot-restore-install-cron.func.sh:57` ->
  `logdir="${BOOT_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/agent-boot-restore}"`;
  `spl-run-paths.func.sh:66-71` sets `SPL_VAR_APP_DIR=<var>/<org>/<main checkout basename>`;
  `ls /var/<org>/<org>-<app>/agent-boot-restore` -> `cron.out` (the installed @reboot
  writes there). **But the measurement's key premise is false on this box — see W1.**

### 10. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of <this worktree>`
(all `ok -` lines, rc 0); re-run after this file is committed -> clean again.

## Defects

- **W1** — plan v0.2 `csi-spl-doc/doc/md/refactor-round-69-plan.md:302` (section 7 row)
  and `:312` (section 8 v0.2 entry): the measurement claims "the desk-cron checkout
  ... is its own clone (`test -d <desk-cron>/.git` -> true, 2026-11-19T20:3xZ), so there
  the swap gives `/var/<org>/<org>-<app>-desk-cron/agent-boot-restore`". On this box
  that premise is false: `ls -la <org dir>/<app>-desk-cron/.git` -> a 58-byte **file**
  (`gitdir: <org dir>/<app>/.git/worktrees/<app>-desk-cron`), so `test -d` is false;
  `spl_main_checkout` (`spl-run-paths.func.sh`) resolves a worktree `.git` file back to
  the main clone; and sourcing `spl-run-paths.func.sh` from the desk-cron tree, from a
  lane worktree and from the main checkout all print
  `SPL_VAR_APP_DIR=/var/<org>/<org>-<app>` and `main=<org dir>/<app>`. So on this box
  `$SPL_VAR_APP_DIR/agent-boot-restore` **equals** the literal dir and the swap would be
  path-identical here; writer and reader would not part. The swap parts only on a box
  where the desk-cron is a standalone clone (`.git` a directory) under a different
  basename. The ruling "not a refactor row this round" still stands (the swap is not
  guaranteed path-identical across boxes), but the stated measurement is wrong for
  this box and should be corrected in v1.0 (name the box, or re-measure). W1 does not
  touch rows 01/02.

## Notes

- N1: origin/master was still `79b22fa0669b452578735ed4c64159fce8b80f22` at my read
  (`git fetch origin master` then `git rev-parse origin/master`), equal to the plan's
  base — no drift between the plan's measurements and my checks 2-4, 6.
- N2: the planner branch head moved from v0.1 `d73f0f702` to v0.2 `36833e559` after the
  brief was first written; the holder's task message (2026-11-19T20:25:52Z) and the
  updated brief line 15 name v0.2, so I signed `36833e559`, not the moving head.
- N3: lane-map exits 4 (not 3) on every row path — 8 live lanes record no files, so
  per the seed exit 4 means "ask first, never free"; the plan's R3 hold on r69-02 is
  the correct conservative reading while c-521 is live.
- N4: the red controls of both rows were verified by reading the gate code
  (`sec-baseline.func.sh:67`, `cleancode_test.go:88-99,126-132`), not by running them:
  running them requires making the row's code change, which this read-only seat must
  not do.
- N5: the candidates file's two literal-path items are already fixed on origin/master
  (check 9), so they are not open refactor inputs; the agent-boot-restore item is
  served by v0.2 section 7 (with W1).
- N6: the brief's looser grep `git grep -n 'MergeTopic' origin/master -- csi-spl-api`
  -> 33 lines / 16 files vs the plan's 19 / 12: the plan's own pattern
  `\bMergeTopic\(` reproduces its 19/12 exactly; the 14 extra lines are comments,
  `openapi.json`, the gate list and the test-func decl, not callers.
- N7: `git grep -nE '\bTopicMerge\b' origin/master -- '*.go'` -> 4 lines, the plan said
  3; the extra is the doc comment `topic_merge.go:36`. No other implementer exists.

## Report line (sent on task `dispatch-refactor-r69`)

`panel: m-079@<box> mistral PASS 36833e5593588fd4065e17b7f598ce0ac3a9df17 seat-file: review/c002-refactor-round-69-mistral-seat <commit sha> ran: <commands> | read: <files> | log: m-079@<box>:.vibe/logs/session/unified/27b5922b-5a5d-a028-b5a5-f403a0da2125`

## v1.0 signature (second commit on this branch)

The editor c-606 named plan v1.0 `17f0d7b004ba0a3b61019022f671bffb7873be0f` (msg
bc4eaf16, 2026-11-19T20:47:49Z, task `dispatch-refactor-r69`): "folded in v1.0
17f0d7b00 (landed)". Provenance at my read: `git ls-remote origin | grep
refactor-round-69-planner` ->
`17f0d7b004ba0a3b61019022f671bffb7873be0f  refs/heads/review/c002-refactor-round-69-planner`;
`git fetch origin master` then `git rev-parse origin/master` ->
`17f0d7b004ba0a3b61019022f671bffb7873be0f` (v1.0 has landed on master).
`git diff 36833e559 17f0d7b00 --stat` -> 1 file, +20/-6, the plan only;
`git diff 36833e559 17f0d7b00 | grep -cE '^[+-].*\| 0[12] `refactor'` -> **0** (the row
table is untouched). v1.0 folds W1: section 7's agent-boot-restore row now reads
"refactor-shaped, input for round 70", records that the desk-cron checkout is a
worktree on both boxes (`<desk-cron>/.git` a 58-byte pointer file) and that
`spl_run_paths` there prints `SPL_VAR_APP_DIR=/var/<org>/<org>-<app>`, the same dir as
the literal — matching this seat's W1 read; N7 folded (TopicMerge is 4 grep lines).
Re-run of the row checks on the new origin/master (`17f0d7b00`, docs-only over
`79b22fa06`: `git diff 79b22fa06 origin/master --stat` -> the plan file only, +338):
30/30 sites OK, 0 MISSING; baseline `grep -vcE '^\s*(#|$)'` -> 73;
`git grep -nE '\bMergeTopic\(' origin/master -- '*.go'` -> 19 lines / 12 files.

**PASS on `17f0d7b004ba0a3b61019022f671bffb7873be0f`** (plan v1.0, signed). Rows 01 and
02 unchanged from v0.2 and verified as above; W1 and N7 folded by the editor; no new
defect, no new note.
