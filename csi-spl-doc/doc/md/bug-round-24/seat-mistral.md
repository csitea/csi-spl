# Bug round 24 (b24): mistral panel seat (m-636)

Seat: m-636, placement `c002-bug-round-24-mistral-panel-seat` (mistral; docs and
reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/spawn-remote/briefs/31af2fde-1193-4c95-9ba1-6aa274b541ad.md`
(Issue SPL-5998, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `d5a6519e-18d0-4354-9a52-2b7154a8b52a`).

Review target: plan v1.1 `f2563087664e9fa7f4b3b3e55aa62e709f56553c`, named to this
seat by the editor c-629 (msg f64ec16b, 2026-11-19T21:4xZ, task
d82d4fb3-3ee4-5b69-8b63-b90a2084e11d; FWD by the dispatch holder c-002@sat msg
5ecd956b). Provenance: `git ls-remote origin refs/heads/review/c002-bug-round-24-planner`
-> `f2563087664e9fa7f4b3b3e55aa62e709f56553c` (head, 21:4xZ);
`git cat-file -t f25630876` -> `commit`;
`git log -1 --format='%H %s' f25630876` -> `docs(b24-plan, SPL-5998): bug round 24
plan v1.1, R7 is the claude waiver seat`;
`git show f25630876 --stat` -> 1 file, `csi-spl-doc/doc/md/bug-round-24-plan.md`
(236 lines at the sha, read in full at that sha). Earlier versions named by the
editor: v0.1 `8c767953d32224e3af7728577518256fb36f86ad`, v1.0
`e1ad5782402de21dea2a8eb3a082e9af1c59f38e`. origin/master at my read:
`99c0fd73b` (moved past the plan's measurement sha `17f0d7b00` during the read,
N2). All counts below re-measured on `17f0d7b00` unless stated.

## Verdict

**PASS on `f2563087664e9fa7f4b3b3e55aa62e709f56553c`** — both rows are real
defects with red controls that fail on `17f0d7b00` exactly as the plan prints
them (re-run by this seat, outputs below), every cited file:line exists on
`17f0d7b00` and on origin/master, the fix scopes are as written, the rows are
disjoint and unowned as far as the lane map can say, and sections 4-6 carry a
measurement per item. Defects W1..: none. Notes N1..N6 below.

## Checks (each with the command run and what it printed, 2026-11-19 21:2x-21:3xZ)

### 1. Slug b24 unused

- `git log origin/master --oneline -E --grep='\(b24-[0-9]{2}' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b24-[0-9]{2}|bug-round-24'` -> one line:
  `f2563087664e9fa7f4b3b3e55aa62e709f56553c  refs/heads/review/c002-bug-round-24-planner`
  (the planner's branch; this seat's review branch was not pushed yet at the
  check). Nothing else.
- Window (rulebook 5.3): `git log origin/master -1 --format=%cI -E --grep='^docs\(b23-plan'`
  -> `2026-11-19T19:12:42+01:00` (the plan's W). `git rev-list --count 23864a224..17f0d7b00`
  -> `19` (the plan's 19). `git merge-base --is-ancestor 17f0d7b00 origin/master`
  -> exit 0.

### 2. Every cited file:line exists on `17f0d7b00` and on origin/master

29 cited sites checked with `git show <sha>:<file> | sed -n <N>p` for
`<sha>` in {`17f0d7b00`, `origin/master`}: all 29 print a line on both, 0 missing
files, 0 missing lines. Spot content: `hub/flow.go:155` -> `lv, err :=
s.lockViewFor(...)`; `:160` -> `body := map[string]any{"counts": p.Counts,
"unread": p.Unread, "keys": wireFlowKeys(p.Keys)}`; `:164` ->
`if !mod.drops(e.MsgID) && !lv.hiddenByLock(e.FromBox, e.ToBox) {`; `:281` ->
`func (s *Server) pushFlowCounts(...)`; `:240` -> `if !s.locks.hides(...)`;
`hub/flow_fold.go:70` -> `func (s *Server) flowFoldBody(...)` (reads no lock);
`hub/flow_agent.go:47` -> `body, err := s.flowFoldBody(ctx, fe, q, q.Member)`;
`store/flow.go:99` -> `type FlowQuery struct {` (no lock field), `:512` ->
`func (s *Memory) FlowRead(...)`; `store/flow_fold.go:231` / `:369` -> Memory /
Postgres `FlowFoldRead`; `store/flow_postgres.go:341` -> Postgres `FlowRead`,
`:379` -> `func (s *Postgres) FlowFanout(ctx, tenant, msgID string, members []string, now time.`;
`hub/flow_member_test.go:135` -> `func TestFlowMemberRefusedWhileABoxIsLocked(t *testing.T)`;
`hub/box_lock_view_test.go:46` -> `func newViewRig(t *testing.T) *viewRig`;
`specs/130-flow-what-is-happening/spec.md:174-180` -> the reader's-own-rules
paragraph quoting "a folded line names no box to cut it by, and the target's
`counts`, `unread` and `keys` are not cut per box"; `specs/062-flow-per-user-counts/contracts/flow-v1.md`
section 2 -> the `member` row with the 403; `csi-spl-wui/src/stores/flow.ts:74`
-> `/** spec 130: Mine is the hub's folded lines (fold=day) ...`;
`tests/lib.inc.sh:96-103` -> `t_spool_bin()` building into
`$T_REPO/csi-spl-api/src/go/spool-hub-api/bin/spool`; `watcher-read-only.tst.sh:31-33`
-> sources lib.inc.sh, `t_spool_bin || { nok "cannot build spool"; ... }`;
`spool-env.inc.sh:632` -> `spool_agent_spool_bin() {`.
Drift: `git diff --stat 17f0d7b00 origin/master -- <the 9 row files>` -> empty;
`git diff --stat 17f0d7b00 99c0fd73b` -> 4 files, all under
`csi-spl-doc/specs/` (159, 181), no row file.

### 3. Both rows are real defects; red controls re-run in a throwaway dir

Red-control files used from `/var/spool-hub/dispatch/b24-red-controls/` (the
v1.1 msg allows it); `sha256sum` -> `a68448d99d2e...` (2201 B) for
`rc01_flow_own_lock_test.go`, `f971d6719a4c...` (1035 B) for `rc02.sh` — the
plan's printed prefixes and sizes; the sources printed in plan section 3.2
diff clean against both files.

- Row 01, code read: `handleViewFlow` builds `counts`/`unread`/`keys` from the
  store page unchanged (`flow.go:160`) and applies `hiddenByLock` only to the
  unfolded events (`:164`); `flowFoldBody` (`flow_fold.go:70-93`) calls
  `fe.FlowFoldRead(ctx, q)` with the plain query and applies moderation only —
  no lock; `pushFlowCounts` (`flow.go:281-296`) does a plain `FlowRead`.
  Red control: `git archive 17f0d7b00 csi-spl-api | tar -x -C /var/tmp/b24-rc01.920jl4`,
  copy `rc01_flow_own_lock_test.go` into `.../internal/hub/`, there
  `go test ./internal/hub/ -run TestB24FlowOwnCountsCutByLock -count=1`
  (go1.26.10) -> exit 1, `--- FAIL: TestB24FlowOwnCountsCutByLock`, exactly 10
  assertion lines (3 unfolded, 3 `?counts_only=true`, 4 `?fold=day` including
  `a line opens the locked box's topic: map[... text:wombat ping @HUM-2 look
  title:wombat ping @HUM-2 look ...]`), `grep -c CONTROL` -> 0. As the plan says.
- Row 02, code read: `t_spool_bin` (`lib.inc.sh:96-103`) builds into the
  checkout when `bin/spool` is absent. Red control:
  `RC_DEBUG=1 bash /var/spool-hub/dispatch/b24-red-controls/rc02.sh 17f0d7b00
  <PUSH_USER> <AGENT_USER>` -> exit 1, printing
  `mkdir: cannot create directory '<copy>/csi-spl-api/src/go/spool-hub-api/bin': Permission denied`,
  `FAIL - cannot build spool`, `-- watcher-read-only.tst.sh: 0 passed, 1 failed`,
  `FAIL: b24-02: watcher-read-only as <runner> on a read-only 17f0d7b00 tree, rc 1`.
  Control `bash rc02.sh 17f0d7b00 <PUSH_USER> <PUSH_USER>` -> exit 0,
  `PASS: b24-02: ... rc 0`; the script's own `head -4` cuts the summary line, so
  this seat re-ran the control's steps directly (fresh `git archive 17f0d7b00`
  copy owned by `<PUSH_USER>`, `chmod -R go-w`, test as `<PUSH_USER>`):
  `-- watcher-read-only.tst.sh: 81 passed, 0 failed`, exit 0 (N4).
  Users on this box, per the holder's correction (msg 3e468b5a): push user =
  `stat -c %U /opt/csi/csi-spl/.git` -> `<PUSH_USER>`; agent user = this
  session's `id -un` -> `<AGENT_USER>` (the public repo names neither).
- `git grep -l t_spool_bin 17f0d7b00 -- csi-spl-orc | wc -l` -> `24`; the 4
  non-test files: `lib/bash/funcs/spl-cloud-cnf.func.sh`,
  `features/spawn-agents/lib/spool-env.inc.sh`,
  `features/spawn-agents/scripts/spawn-core.inc.sh`, `run/spl-spool-refresh.func.sh`.

### 4. Fix scopes

- Row 01: the cut belongs in the store reads — `FlowQuery` (`store/flow.go:99-107`)
  has no lock field today, so "a new `FlowQuery` field, from `lockViewFor`" is
  the right shape; both drivers are in the row's file list (Memory `FlowRead`
  `:512`, Postgres `FlowRead` `flow_postgres.go:341`, `FlowFoldRead`
  `flow_fold.go:231` and `:369`), and events, folded lines, counts, unread and
  keys are all named. The `?member=` 403 of `52eb8a9e8` stays:
  `git log --oneline -1 52eb8a9e8` -> `fix(hub, SPL-4895): ?member= refuses every
  read of someone else while a box is locked to another`; `flow_member.go:42`
  uses `lockViewFor`. The agent `flow_read` frame (`flow_agent.go:47`) is named
  out of the row (unchanged). `pushFlowCounts` (`flow.go:281-296`) is in the
  hub-fill list; `FlowFanout` (`flow_postgres.go:379`, takes no query) and the
  agent frame are named in plan section 6 as round 25's first input if the row
  leaves them — covered or named, as the brief asks. Postgres `PRE_PUSH_TIER=full`
  is stated (a store change).
- Row 02: `t_spool_bin` keeps the tree's `bin/spool` when present and executable
  (`[ ! -x "$b" ]` guard, `lib.inc.sh:97-99`); a missing one builds outside the
  tree per the plan; the 4 non-test scripts and `spool_agent_spool_bin`
  (`spool-env.inc.sh:632`) are out of the row — verified above.

### 5. Row metadata, vendor, R7

Both rows carry defect, evidence, sites, red control, fix scope, box, vendor,
kind, batch in the plan's table: row 01 vendor `claude`, kind `complex_coding`,
batch 1; row 02 vendor `claude`, kind `tests`, batch 1. No mistral coding or
testing row. R7 in the signed sha: `claude waiver seat (1a7c70da), fresh
session, tree only` for both rows — never mistral, never grok. The v0.1 plan
named grok as R7; grok is off (owner order 2026-11-04; cnf
`csi-spl-cnf/csi-spl/all.env.yaml` agent split -> `grok: 0`). The backup clause
covered it in v1.0 (rulebook 2.7.2 "another non-author seat as backup": R7 became
a mistral seat with the claude waiver seat as backup), and v1.1 then moved R7 to
the claude waiver seat alone (holder msg 7ae6099f, ruling b71016ad: mistral
reviews plans, not row code). Verified: `git diff e1ad57824 f25630876 -- <plan>`
changes only the two rows' R7 cells plus the status line, review history and
consensus table; `git diff 8c767953d f25630876 -- <plan>` row-table lines differ
only in the R7 cells (4 changed lines, all `| 01 `/`| 02 ` rows).

### 6. R1 disjoint, R3 lane map, r69-01

- Row 01 files (hub/flow.go, hub/flow_fold.go, hub/flow_member_test.go or a new
  flow_lock_test.go, store/flow.go, store/flow_fold.go, store/flow_postgres.go,
  specs/130 spec.md, specs/062 flow-v1.md) and row 02 files
  (tests/lib.inc.sh + one new test case) share no path — R1 batch 1 holds.
- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
  --check <the 9 row paths, comma-separated> --agent m-636` -> exit 4:
  `WARN no live lane lists <paths>, but 3 live lane(s) record no files`;
  `unknown: c-046@sat ...`, `c-946@sat ...`, `m-079@sat
  review/c002-refactor-round-69-mistral-seat` — the same three no-file lanes the
  plan recorded at 21:04:56Z. Exit 4 = unknown, not free (N1); the plan says the
  orchestrator re-runs R3 before the spawn.
- r69-01 re-run: `git diff --name-only $(git merge-base origin/master
  origin/review/r69-01) origin/review/r69-01` (head `27cbe099d`) ->
  `.shellcheck-warning-baseline.txt`,
  `csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-identity-reconcile.sh`,
  `.../test-agent-identity-restore.sh`, `.../test-spool-poke-queue.sh` — 4 files,
  `lib.inc.sh` is not one of them.

### 7. Sections 4, 5 and 6: each "not a row" backed by a measurement

Re-ran the git-based ones: `git log origin/master --oneline -E --grep='\(b23-0[12]-'`
-> `7b6cd900e` (b23-01), `a6f5a723d` (b23-02); `git log --oneline 23864a224..17f0d7b00
-- csi-spl-wui/tests/e2e/issues-ctxmenu.test.mjs` -> `31b731d7b`;
`git log --format='%h %cI %s' -S'the author is retired on this machine' --
csi-spl-orc/src/bash/run/spl-review-go.func.sh` -> `2f634fbd4 2026-11-19T11:56:41+01:00
fix(b20-01-...)`, and the comment sits at `spl-review-go.func.sh:832-850` on
`17f0d7b00`; `git log --oneline -1 3e46a758c` -> b22-02; `git log --oneline -1
a6f5a723d` -> b23-02; `grep -an 76098a7b146f /var/csi/csi-spl/done-claim-check/cron.log`
-> line 53027 `940766d4-... c-924 alert 018ec793e5 76098a7b146f` (both ids in one
alert, as the plan says). Section 5's two "not run" items (the AltGr browser
case, `blog.test.mjs:329` alone) say NOT RUN in the plan itself. Section 6 is
backed by the lane-map and queue runs it names; this seat re-ran the lane map
(check 6, same exit 4).

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of <this worktree>`,
exit 0 (2026-11-19T21:37Z).

## Defects

None. W1..: none.

## Notes

- **N1:** lane-map exits 4 on the row paths (three live no-file lanes: c-046@sat,
  c-946@sat, m-079@sat), exactly as the plan recorded at 21:04:56Z. Per the
  rule, exit 4 is "ask first, not free"; the plan hands the re-run to the
  orchestrator before the spawn. Not a plan defect.
- **N2:** origin/master moved to `99c0fd73b` during this read; the plan says the
  same. `git diff --stat 17f0d7b00 origin/master -- <row files>` is empty, so no
  cited line drifted (check 2).
- **N3:** v0.1's R7 was grok, which is off (cnf `grok: 0`, owner 2026-11-04). The
  backup clause (rulebook 2.7.2) covered it in v1.0; the signed v1.1 names the
  claude waiver seat for both rows, so the signed sha has no grok and no mistral
  R7.
- **N4:** `rc02.sh`'s own `head -4` cuts the control's `81 passed` summary line;
  this seat re-ran the control's steps directly and read
  `-- watcher-read-only.tst.sh: 81 passed, 0 failed`, exit 0.
- **N5:** the plan's `<box2>`/`<PUSH_USER>`/`<AGENT_USER>` placeholders resolve
  on this box to: push user = owner of the main checkout's `.git`
  (`stat -c %U /opt/csi/csi-spl/.git`), agent user = this session's `id -un`;
  the public repo names neither, so this file names the roles only.
- **N6:** the red controls were taken from `/var/spool-hub/dispatch/b24-red-controls/`
  (allowed by the v1.1 msg); their sha256 prefixes match the plan's printed ones
  and the printed sources diff clean against them, so "rebuilt from section 3.2"
  and "the files on the box" are the same bytes.
