# Refactor round 87 — panel seat mistral (m-085@<box>)

Issue: SPL-6227 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-87-mistral-panel-seat.md`.

Review target: `csi-spl-doc/doc/md/refactor-round-87-plan.md` on branch
`review/c002-refactor-round-87-planner` at v0.1
**`aacf9637a1305c79544c195fb2044454f2946c24`**.

- `git ls-remote origin refs/heads/review/c002-refactor-round-87-planner` ->
  `aacf9637a1305c79544c195fb2044454f2946c24` (head == the sha the brief names).
- `git show aacf9637 --stat --format='%H %cI %s'` -> one file,
  `csi-spl-doc/doc/md/refactor-round-87-plan.md` +348, subject
  `docs(r87-plan, SPL-6227): refactor round 87 plan v0.1 for the panel: ...`.
- The plan's measured base is `b220e7464`; `git rev-parse origin/master` ->
  `b220e7464fa329ab7ab625dd733b83162f4086d5` and
  `git merge-base --is-ancestor b220e7464 origin/master` -> rc 0: base == trunk at
  review time.
- Every file:line cited below was checked with `git show b220e7464:<file> | sed -n <N>p`.

**Verdict: PASS on v0.1 `aacf9637a1305c79544c195fb2044454f2946c24` and on v1.0
`c24e47b1c4974c7f1dcf8f18b1e9de417b2d6202` (see the v1.0 signature at the end). No W
defects.**

## 1. Slug r87 unused since the plan's W

- W: `git log origin/master -1 --format=%cI -E --grep='^docs\(r86-plan'` ->
  `2026-11-22T00:52:54+01:00` (`f89f821cc`, the r86 close record) — the same W the plan
  records.
- `git log origin/master --since="$W" --oneline -E --grep='\(r87-' | wc -l` -> **0**;
  over all history -> **0**.
- `git ls-remote origin | grep -E 'r87-[0-9]{2}|refactor-round-87'` -> only
  `aacf9637...  refs/heads/review/c002-refactor-round-87-planner` (the planner's; this
  seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r87-[0-9]{2}|refactor-round-87'` -> only
  `c002-refactor-round-87-mistral-panel-seat.md` (this seat's brief; the planner's brief
  lives on the other box, c-230@<box>).
- `git ls-tree --name-only b220e7464 csi-spl-doc/doc/md/ | grep -c refactor-round-87` ->
  **0** (the plain name is free on trunk).
- r86 closed as the plan says: `git log origin/master --oneline -E --grep='\(r86-'` ->
  `49f34bef6` (r86-01), `61977111c` (r86-02), `f89f821cc` (close record).
- Perf floor re-run on `b220e7464` (rulebook 4.4 command) ->
  `perf 29 refactor 113 perf-share 20.4% floor-met` — matches the plan, so r87 as a
  refactor round is right.

## 2. Every row site file:line exists on base and on origin/master

Row paths (9): `api:internal/hub/message_move.go`, `api:internal/hub/topic_merge.go`,
`api:internal/hub/topic_promote.go`, `api:internal/cleancode/cleancode_test.go`,
`orc:.../spool-install/steps/claude-memory.inc.sh` (new),
`orc:.../steps/y18-grok-memory.sh`, `orc:.../steps/y20-agy-memory.sh`,
`orc:.../tests/test-y18-grok-memory.sh`, `orc:.../tests/test-y20-agy-memory.sh`
(`api:` = `csi-spl-api/src/go/spool-hub-api`, `orc:` = `csi-spl-orc`).

- `git diff --name-only b220e7464 origin/master -- <the 9 paths>` -> **empty**
  (origin/master == b220e7464 at review time): no drift.
- `git cat-file -e b220e7464:.../steps/claude-memory.inc.sh` -> rc 128 "does not exist"
  — expected, row 02 creates it.
- Cited lines read at `b220e7464`: `message_move.go:269,346` call `moveFrame`;
  `:374-383` `moveFrame`, its `:374` comment says "undo left out" while the body also
  drops `kind` (as the plan says); `topic_merge.go:123,147` call `mergeFrame`,
  `:169-178` `mergeFrame`; `topic_promote.go:111,136` call `promoteFrame`, `:141-150`
  `promoteFrame`; `cleancode_test.go:43-47` the `folded` list (`var` :43, entries :44-46,
  close :47 — the new entry goes after :46); `y18:26` header end, `:31-43` the slug+repo
  block, `:67-68` the two calls; `y20:50`, `:58-70`, `:264-265`; `test-y18:17` last
  header item line, `:120` the summary echo; `install.sh:1111-1112` source both steps
  with `--fleet`. All present as cited.
- `git grep -n 'if k != "undo" && k != "kind" {' b220e7464 -- csi-spl-api/...` -> exactly
  3 lines: `message_move.go:378`, `topic_merge.go:173`, `topic_promote.go:145`.
- `git grep -lE 'git-common-dir|s/\[\^A-Za-z0-9\]/-/g' b220e7464 -- .../steps/` ->
  `y18-grok-memory.sh`, `y20-agy-memory.sh` (2 files, as section 6 counts).
- R2 site greps: row 01 -> 6 test files, all in `internal/hub` (`box_message_move_test.go`,
  `fanout_encode_e16_bench_test.go`, `message_move_agent_test.go`, `message_move_test.go`,
  `topic_merge_test.go`, `topic_promote_test.go`); row 02 -> `orc-shard-weights.txt` and
  the wrappers `spool-install-y18-grok-memory.tst.sh`, `spool-install-y20-agy-memory.tst.sh`
  (plus the feature tests under `spool-install/tests/`). Matches the plan.
- `wc -l` at base: y18 103, y20 307, test-y18 121 — as the plan says.

## 3. Red controls, run on the plan's base in scratch copies

Control files hashed at `b220e7464`:
- `git show b220e7464:.../cleancode/cleancode_test.go | sha256sum` ->
  `f19e114cbb8c2d2ca7ccbe9e9cc150b4e98bf6437c66abf14650e69f3419348d`
- `git show b220e7464:.../test-y18-grok-memory.sh | sha256sum` ->
  `63db74ec050bb243fed7e5cc127b7716f16277fb5ef79215329bc3b6721ea638`

Head control files constructed per the plan's 1.3 / 1.4 shape (the heads are not
committed anywhere): sha256 `a6f4ee94b3043f720e7d35d034b3be3b662a061762bde3dd20f3449ce79dbff3`
(`cleancode_test.go` + one `folded` entry after :46) and
`23636a4f4f0e0366948eaaeceb567a04916032f1c25ae60fe65b871f7389308e` (`test-y18-grok-memory.sh`
+ header item 9 after :17, + case 9 before :120).

Scratch copies: `git archive b220e7464 | tar -x -C $(mktemp -d)` (full tree; api-only for
the Go control). Nothing committed to any shared repo; `SPOOL_TEST=1` for the bash
suites.

**Row 01** (head's `cleancode_test.go` on the base hub files):
`go test ./internal/cleancode/ -run TestCleanCodeGate -count=1` -> rc **1**,
`--- FAIL: TestCleanCodeGate`,
`cleancode_test.go:106: internal/hub/topic_merge.go: "if k != \"undo\" && k != \"kind\" {" is back outside internal/hub/message_move.go: a move, merge or promote answer becomes a frame through hub.moveFrame (r87-01)`
and the same line for `topic_promote.go`; last line `FAIL`. Byte-identical to the plan's
1.5 quote. Base unmodified: `ok ... 0.944s`, rc 0. Full head (callers -> `moveFrame`,
both copies deleted, comment corrected, gate entry added):
`go test -count=1 -v ./internal/hub/ ./internal/cleancode/` -> rc 0, **1337** `^--- PASS`,
0 FAIL; base full tree -> rc 0, 1337/0 — same count, as the plan claims;
`go build ./...` rc 0, `go vet` rc 0, `gofmt -l` empty.

**Row 02** (head's `test-y18-grok-memory.sh` on the base steps):
`SPOOL_TEST=1 bash test-y18-grok-memory.sh` -> rc **1**, 14 PASS,
`FAIL: 9. defined once (want 'claude-memory.inc.sh ', got 'y18-grok-memory.sh y20-agy-memory.sh ')`,
last line `--- y18 grok memory: 14/15 passed, 0 grok checks not run`. Base test on base
-> rc 0, 14/0. Full head (new `claude-memory.inc.sh` + both steps source it): y18 15/0
rc 0, y20 68/0, `test-agy-rules-always-on.sh` 14/0, `bash-cleancode.tst.sh` 15/0,
`shellcheck -S warning -x` on the 4 files -> 0 findings; `wc -l` y18 92, y20 296 — as the
plan says.

Both controls fail for the plan's reason (the pattern / the helpers sit outside their
one home), not for an environment reason. Live state: none — all runs in /tmp scratch
copies of `b220e7464`, `SPOOL_TEST=1`, nothing committed.

## 4. Equivalence of each row

- **r87-01:** `awk '/^func <name>\(/,/^}/'` bodies of the three functions, name-normalized,
  `diff` -> identical (same signature `(typ string, out map[string]any) map[string]any`,
  same 7-line body). Folding the two copies into `moveFrame` keeps every caller's map
  identical; the only other changes are the `:374` comment (C5) and the gate entry. The
  `folded` control catches any reappearance (RED above). Suite count identical base vs
  head (1337/0 both).
- **r87-02:** `sed -n '31,43p'` of y18 vs `'58,70p'` of y20, prefix-normalized, `diff` ->
  identical. Probe of the inc's helpers vs the base step's: outside git both rc 1; in a
  linked worktree both print the main checkout, rc 0; with
  `SPOOL_INSTALL_CLAUDE_MEMORY_REPO` set both print it, rc 0; the slug of the same path
  is identical. The inc sits in the same dir as the steps, so `here`
  (`dirname "${BASH_SOURCE[0]}"`) is unchanged. Case 9 catches a second copy (RED above).
- No row changes an exit code, a message, a path or a default.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after (reproduced in
check 3), a test list, box `either`, vendor `claude`, kind `simple_coding`, batch 1. No
mistral coding or testing row (owner 10-17, t1 b61851fb). R7 (plan section 4): a grok
pick or a fresh claude waiver seat, never a mistral code R7 — compliant. R1:
`comm -12` of the two rows' file sets -> **0** shared files. 2 rows, within 5.1's aim 2 /
at most 3.

## 6. R3: lane map on the row paths

`bash .../spawn-agents/scripts/lane-map.sh --check <the 9 paths, comma-separated> --agent m-085`
-> **exit 4**: no live lane lists any row path; 11 live lanes record no files (all on the
other box): a-227, c-063, c-146, c-230 (the r87 planner), c-248 (the b37 planner,
SPL-6228), c-806 (SPL-6182), c-812, c-924, c-927, g-050, g-079. Named lanes: c-035@<box>
(SPL-6224 T3: `hub/evlog.go`, `hub/server.go`, `hub/supervise.go`, `auth/handler.go`,
`cmd/spool/hub.go`, cnf — its brief greps 0 row paths), c-054@<box> (spec 154 B7, gcal
scope — 0 row-path mentions), c-806@<box> (SPL-6182 auth + store), the csi-rel gct check
(other repo) and the b37 planner (now placed as c-248@<box>;
`do_spl_spawn_queue` -> `0 queued, 0 placing`). No row file is touched by any of them.

## 7. Inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` read directly (110 lines).
  Refactor-shaped items: the literal-`/var` candidates (`spl-watchdog.func.sh:72,:1311`,
  `spl-lane-rotate.func.sh:112`; `reverse-tunnel-cron.sh:23`; the agent-boot-restore
  writer/reader; `spl-desk-reply.sh:9,19` kinds) are all **served on `b220e7464`** —
  verified: `:72` is now a `@param` doc line with a derived default, `:1311` a comment,
  `:112` uses `ROTATE_LANE_LOGIN_CACHE`, `reverse-tunnel-cron.sh:25-26` derives via
  `spl_run_paths`, the boot-restore cron uses `spl_var_app_subdir`, and
  `spl-desk-reply.sh:9,19` list the new kinds (SPL-6123 landed `eeae6a4e2`). The
  `spl-lane-mix.func.sh` "agy has the final word" words are still present at
  `:46,:136,:138,:392,:401` and SPL-6174's head `473495da4` is NOT on master
  (`git merge-base --is-ancestor 473495da4 origin/master` -> rc 1), so that item stays
  gated on SPL-6174 and is accounted via r86 section 7 (`:104`), which r87 1.2(a)
  re-reads and adopts. **No refactor-shaped input is neither served nor accounted for.**
- r86 plan section 7 read at origin/master; `git diff --name-only b220e7464 origin/master
  -- csi-spl-doc/doc/md/refactor-round-86-plan.md` -> empty (unchanged since base).
- Bug-row scan: no row changes an exit code, a message, a path or a default (check 4);
  the only new failure mode is the inc missing next to a step, and it ships in the same
  commit (plan 1.4).

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-085`,
rc **0**.

## Defects

None (no W1...).

## Notes

- **N1** the lane map exits 4 on all 9 row paths; the 11 unknown-scope lanes are all on
  the other box, including the r87 planner (c-230) and the b37 planner (c-248); the row
  lanes re-run R3 at spawn.
- **N2** the planner's brief is not in this box's `dispatch/briefs` (c-230@<box>); only this
  seat's brief matched there.
- **N3** the `spl-lane-mix.func.sh` stale-words refactor input is still open (SPL-6174
  unlanded) and is accounted only by r86 section 7's pointer, not named in r87's own
  section 7.
- **N4** the head control files were constructed per the plan's 1.3 / 1.4 shape (the heads
  are not committed anywhere); their sha256s are in check 3 and the failure outputs are
  byte-identical to the plan's 1.5 quotes.
- **N5** the plan's 2.2 recorded 2 unknown lanes at 02:52Z; at review time there are 11 —
  same result class (exit 4, no owner of any row path).

## v1.0 signature

Signed on the editor's v1.0 (c-230, msg `b8d4311b`):

- `git ls-remote origin refs/heads/review/c002-refactor-round-87-planner-v1` ->
  `c24e47b1c4974c7f1dcf8f18b1e9de417b2d6202`; the v0.1 branch still reads `aacf9637a...`.
- Stack `aacf9637a..c24e47b1c` (`git log --oneline aacf9637a..FETCH_HEAD`): `e46621014`
  (master), `a9731a592` (v0.1 plan), `c18a4ba46` (this seat file, cherry-picked from
  `11b7f922b`), `c24e47b1c` (v1.0).
- `git diff aacf9637a c24e47b1c -- csi-spl-doc/doc/md/refactor-round-87-plan.md` -> 2
  hunks only: `@@ -33,7 +33,10 @@` (the status line) and `@@ -339,10 +342,46 @@`
  (sections 8 and 9): v1.0 changes only the status line and sections 8/9, as the editor
  says; rows, files, red controls and fix scope are unchanged from v0.1.
- `git diff 11b7f922b c24e47b1c -- csi-spl-doc/doc/md/refactor-round-87/seat-mistral.md` ->
  empty: the seat file folded into the v1.0 stack is byte-identical to this branch's.
- Row paths unchanged since `b220e7464` on current `origin/master` (`e46621014`):
  `git diff --name-only b220e7464 origin/master -- <the 9 row paths>` -> empty.

**v1.0 verdict: PASS on `c24e47b1c4974c7f1dcf8f18b1e9de417b2d6202`.**
