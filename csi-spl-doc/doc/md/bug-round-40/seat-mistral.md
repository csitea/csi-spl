# Bug round 40 — panel seat mistral (m-048@<box2>)

Issue: SPL-6288 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/spawn-remote/briefs/5da20e67-045a-4e5f-8130-a4888a1e849e.md`.
Review target: `csi-spl-doc/doc/md/bug-round-40-plan.md` on branch
`review/c002-bug-round-40-planner`, at the plan version sha
`699e09331c2cad79008a74b45431e6e45e3f7355` (v0.1), named by the brief (planner
c-591@sat). `git ls-remote origin refs/heads/review/c002-bug-round-40-planner`
-> exactly that sha, still the branch head at my check (2026-11-23T09:3xZ). The
branch is one docs commit on `2286c85ce`:
`git diff origin/master 699e0933 --stat` ->
`csi-spl-doc/doc/md/bug-round-40-plan.md | 278 +++...`, 1 file changed,
278 insertions — the "+278" the brief names. `origin/master` at my fetch:
`2286c85ce` (the plan's measurement sha).
Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the
panel signs the plan sha). Model: `csi-spl-doc/doc/md/bug-round-38-plan.md` on
origin/master; seat form: `csi-spl-doc/doc/md/bug-round-39/seat-mistral.md`.

**Verdict: PASS on `699e09331c2cad79008a74b45431e6e45e3f7355` (v0.1), 2 rows.**
Both defects are real on `2286c85ce` and both red controls reproduce red on
that sha when I run them myself. No defect W found. All checks run by me on
<box2> on 2026-11-23, ending 09:47:47Z (`date -u +%Y-%m-%dT%H:%M:%SZ`), unless a
line says otherwise. Every command below was run by me; its output is quoted as
printed. Every file:line cited was printed with
`git show <sha>:<file> | sed -n <N>p` first.

## Check 1 — slug b40 unused since the plan's `Window: W=`

- Plan line 24 records `Window: W=2026-11-22T09:15:08+02:00` (commit `e6de4e229`).
  My re-read: `git log origin/master -1 --format=%cI -E --grep='^docs\(b39-plan'`
  -> `2026-11-22T09:15:08+02:00`. Matches.
- `W=2026-11-22T09:15:08+02:00; git log origin/master --since="$W" --oneline -E --grep='\(b40-' | wc -l`
  -> `0`.
- `git ls-remote origin | grep -E 'b40-[0-9]{2}|bug-round-40'` ->
  `699e09331c2cad79008a74b45431e6e45e3f7355\trefs/heads/review/c002-bug-round-40-planner`
  only — the planner's branch, expected; this seat's review branch did not exist
  yet at this check. Nothing else.
- The plan's own patterns: `git ls-remote origin 'refs/heads/review/b40-*' 'refs/heads/wip/*b40*' 'refs/heads/*-b40-*'`
  -> empty, rc 0.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b40-[0-9]{2}|bug-round-40'` ->
  no match (rc 1) on this box: the dir is readable here (3280 entries) but holds
  no b40-named brief; the planner's brief (`c002-bug-round-40-planner.md`, per
  the plan's slug proof) lives on sat. This seat's brief:
  `ls /var/spool-hub/spawn-remote/briefs | grep 5da20e67` ->
  `5da20e67-045a-4e5f-8130-a4888a1e849e.md` — this brief, expected.
- `git worktree list | grep -E 'b40|bug-round-40'` ->
  `/opt/csi/csi-spl-wt/m-048 2286c85ce [m-048-c002-bug-round-40-mistral-panel-seat]`
  (this seat's, expected) only. The planner's worktree is on sat, not listed
  here.

## Check 2 — the two defects are real on `2286c85ce` (every cited file:line printed)

b40-01 (`csi-spl-api/src/go/spool-hub-api/internal/hub/`):

- `issue_backlog.go:51` -> `// #lobby. It reports whether this call wrote it; a second call is a no-op`
  and `:52` -> `// insert.` — the comment the plan quotes. Matches.
- `issue_backlog.go:53` -> `func (s *Server) postIssueBacklog(ctx context.Context, tenant string) (bool, error) {`.
  Matches.
- `issue_backlog.go:58` -> `now := s.o.Now().UTC().Truncate(time.Second)` — a fresh
  envelope stamped `now` every call. Matches.
- `issue_backlog.go:76` -> `inserted, sentInOne, err := s.insertRow(ctx, row)`. Matches.
- `issue_discussions.go:174` -> `if ie := s.checkDiscussion(ctx, tenant, actor, def); ie != nil {`.
  Matches.
- `issue_discussions.go:236-242` -> `:236 func (s *Server) checkDiscussion(...)`,
  `:237 if task == store.IssueDiscussionDefault(tenant) {`, `:238 if task == store.IssueBacklogID(tenant) {`,
  `:239 if _, err := s.postIssueBacklog(ctx, tenant); err != nil {`,
  `:240 s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("issue backlog")`,
  `:241-242` closing braces. Matches: every link of the backlog topic calls
  `postIssueBacklog` and logs any error at error level.
- `internal/store/postgres.go:510` -> `return false, ErrConflict` (context 505-510:
  `if bytes.Equal(old, m.Env) { return false, nil }` then `return false, ErrConflict`).
  `internal/store/memory.go:404` -> `return false, ErrConflict` (same shape, 400-404).
  Matches: a byte-equal envelope is a no-op, a different one conflicts.
- `internal/hub/issue_discussions_test.go:177` -> `func TestIssueBacklogPostedOnce(t *testing.T) {`.
  Matches.
- The SPL-6212 premise: `git log -1 --format='%h %s' 645718660` ->
  `645718660 feat(rdb, SPL-6212): t1 links its Issue backlog topic by default, like every workspace; its 222 open issues move there from fcf09921`.
  Matches.

b40-02 (`csi-spl-orc/src/bash/run/spl-lane-issue.func.sh`):

- `:305` -> `spl_lane_issue_place() {`. Matches.
- `:314` -> `spl_lane_issue_assign update --ref "$key" --status wip >/dev/null || return 1`
  and `:315` -> `spl_lane_issue_hub comment --ref "$key" --body "Lane $id placed on $key, status wip...."`.
  Matches: every keyed placement sets `wip` whatever the status, then comments.
- `csi-spl-orc/src/bash/features/spawn-agents/lib/lane-issue.inc.sh:543` ->
  `li_review_lane() {`. Matches.
- `spl_lane_issue_shared` is at `spl-lane-issue.func.sh:182`
  (`git grep -n 'spl_lane_issue_shared' 2286c85ce -- csi-spl-orc` ->
  `spl-lane-issue.func.sh:138`, `:175` comment, `:182 spl_lane_issue_shared() {`);
  the plan's ":182" attaches to that function in `spl-lane-issue.func.sh`, and
  SPL-6099 is referenced at `spl-lane-issue.func.sh:53,176` and
  `lane-issue.inc.sh:531,536`. Matches in substance.
- `csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh:120-125` -> the case
  `# A key: linked, never a second issue.` / `run AGENT_ID=c-123 BRIEF="$T/brief.md" LANE_ISSUE_KEY=SPL-7 DRY_RUN=0`
  / assertions including `grep -qx 'update|--ref|SPL-7|--status|wip|--assignee|c-123|' "$T/calls.log"`
  and `pass "a key: wip, the lane assigned, a comment; ..."`. Matches — the
  owning-lane control case. The file's last two lines are
  `echo "spl-lane-issue: $fails failure(s)"` / `exit "$fails"` (924 lines total),
  which is what rc02.sh's `head -n -2` / `tail -n 2` splice relies on.

Both defects are real on the tree as the plan describes them.

## Check 3 — red controls extracted, hashed, run on `2286c85ce`

Extracted from plan section 4 with awk over the fenced `bash` blocks:

- `sha256sum` -> `9372763ce891555866b6156c615c7901be1d5aa93a707c2df291c0aca16f5357  rc01-b40.sh`
  (2690 B, first 12 hex `9372763ce891` — matches the plan) and
  `53354825dcaa056920d330aa5b8cf382991035e74905883773a464054c9276ea  rc02.sh`
  (1962 B, first 12 hex `53354825dcaa` — matches).
- `bash rc01-b40.sh 2286c85ce` (run from this worktree as the push user, Go
  1.26.10) -> `b40_rc01_test.go:51: rc01 issue-backlog error lines: 1 (clock step 1 s)` /
  `--- FAIL: TestB40IssueBacklogSecondLinkLogsNoError (0.07s)` /
  `rc01 sha=2286c85ce same_second=0 rc=1`, exit 1. Matches the plan's table.
- `RC01_SAME_SECOND=1 bash rc01-b40.sh 2286c85ce` ->
  `rc01 issue-backlog error lines: 0 (clock step 0 s)` / `--- PASS` /
  `rc01 sha=2286c85ce same_second=1 rc=0`, exit 0. Matches: the envelope
  timestamp is the cause.
- `bash rc02.sh 2286c85ce` -> `rc02 calls: 3 status-writes: 1` /
  `rc02 review-on-done: got=reopened-wip want=left-done` /
  `rc02 sha=2286c85ce suite: spl-lane-issue: 39 failure(s)`, exit 1. The rc02
  lines match the plan's table exactly; the suite tail differs (39 vs the
  plan's 0 failures) — see N1: environmental on this box, not a plan defect.
- Live state: neither script touches the hub, prd, a real issue or the live
  spool. Both extract the sha's tree with `git archive` into a `mktemp -d` dir
  with a trap cleanup and change nothing in the checkout. rc01 runs `go test` on
  the Memory store (no `SPOOL_TEST_PG_DSN` set). rc02 runs the suite under
  `SPOOL_TEST=1` with the hub stubbed (`test-lib.inc.sh:35 export SPOOL_TEST=1`,
  `:70 STUB_LOG="$T/calls.log"`, own spool root under `$T`); the appended case
  writes only under `$S/g-777` in that test root and removes it.

## Check 4 — prd evidence, re-read read-only

All reads were read-only (`do_spl_db_query` SELECTs and `do_gcp_tail_logs`
against ENV=prd); nothing was written to prd.

- `select count(*) ..., count(distinct e.number) ..., min(e.at), max(e.at) from issue_events e where e.tenant_id='t1' and e.field='status' and e.old_value='done' and e.new_value='wip' and e.actor='c-002' and e.at > now() - interval '30 days'`
  -> `114 | 57 | 2026-10-25 16:23:51.925814+00 | 2026-11-22 22:51:51.078361+00`.
  Matches the plan's "114 events on 57 issues, first 2026-10-25, last
  2026-11-22T22:51Z".
- Same set joined to `issues` where `status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null`
  -> `still_open = 21`. Matches.
- `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=26h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs | grep -c 'issue backlog'`
  -> `6` at 09:4xZ (the plan saw 4 at 08:59Z; two more in the moved window).
  Each line carries `"error": "conflict"`, `"level": "error"`,
  `"message": "issue backlog"`, `"tenant": "t1"`, versions `3.2.3`, `3.3.2`,
  `3.4.1`. Consistent with the plan's source 1.

## Check 5 — rows

- Disjoint (R1): row 01's files are `csi-spl-api/.../internal/hub/issue_backlog.go`
  and its test `issue_discussions_test.go` (read-only refs `issue_discussions.go`,
  `store/postgres.go`, `store/memory.go`); row 02's are
  `csi-spl-orc/src/bash/run/spl-lane-issue.func.sh`,
  `csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh`,
  `csi-spl-doc/doc/md/lane-issue-and-docs.md`. No shared file; both batch 1.
  Matches the plan's R1 line.
- Narrow fix scope: row 01 "`issue_backlog.go` and its test only; no store, no
  migration"; row 02 "the place op only", its test, the doc's place bullet, and
  explicitly not the 21 stuck issues (a prd write, the holder's). Both narrow.
- Red controls prove the defects and would turn green on a correct fix: rc01
  red (1 error line) with the same-second control green (0) — I ran both; rc02
  red (`got=reopened-wip`) with the owning-lane case at
  `spl-lane-issue.tst.sh:120-125` as the in-suite control — I ran it.
- Section 6 (owned elsewhere) checked with R3 below (check 7): exit 4, the
  unknown lanes named, none lists the plan or the row files.
- No row should be cut or merged: 2 rows, within the 1..3 owner order, each with
  prd evidence and a reproduced red control.

## Check 6 — inputs accounted for

- Plan 3.3 (R7 notes since W): the named notes check out where checkable on this
  box — SPL-6286's N1-N3 are fixed by `2286c85ce` (`git log -1 origin/master`
  -> `2286c85ce fix(orc, SPL-6286): ...`); SPL-6277 N2's no-instance claim I
  re-ran: `git ls-remote --tags origin 'v*' | grep -v '\^{}' | awk '{print $1}' | sort | uniq -d | wc -l`
  -> `0` (2930 tags now; the plan read 2929). The full 45-message inbox scan is
  sat's; this box's `c-00{1,2,3}` copies are the <box2> hub's, so I did not
  re-run the count here.
- Plan 3.4 (round 39's first inputs) against round 39's plan on origin/master
  (`csi-spl-doc/doc/md/bug-round-39-plan.md`, section 6 row "first inputs for
  round 40"): every item is accounted in the b40 plan — the selector's composed
  testids (3.4 row 1; `git log origin/master --since="$W" --oneline -- csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh`
  -> only `03c463f15`, as the plan says), SPL-6174's relay hash (3.4 row 2;
  `git log origin/master --since="$W" --format='%h %s' | grep -iE 'SPL-6174|relay hash'`
  -> nothing, rc 1), b34-01 N2 and SPL-6212 N2 (3.4 row 3, test-shaped, carried),
  the SPL-6212/6226 notes (3.4 row 4; `git log origin/master --since="$W" --format=%h -E --grep='SPL-(6212|6226)'`
  -> `2513d45d9`, `645718660`, `a2ab946ed` — landed), r87-01 N2 (3.4 row 5,
  carried). The recursive "items round N carried" chain bottoms out in the same
  carried test-shaped/flake items the plan's section 7 lists for round 41.
- `git log --oneline e6de4e229..2286c85ce | wc -l` -> `103`, as the plan's
  section 1 says.
- `/var/spool-hub/dispatch/c002-next-round-candidates.md` (sections "next BUG
  round" and "Bug-shaped"): **NOT RUN** — the file is sat-only and is absent on
  this box (`ls` -> No such file or directory;
  `find /var/spool-hub -maxdepth 3 -name '*next-round-candidates*'` -> nothing).
  No bug-shaped input I could read here is left unserved and unaccounted.

## Check 7 — R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-doc/doc/md/bug-round-40-plan.md,csi-spl-api/src/go/spool-hub-api/internal/hub/issue_backlog.go,csi-spl-api/src/go/spool-hub-api/internal/hub/issue_discussions.go,csi-spl-api/src/go/spool-hub-api/internal/hub/issue_discussions_test.go,csi-spl-orc/src/bash/run/spl-lane-issue.func.sh,csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh,csi-spl-doc/doc/md/lane-issue-and-docs.md,csi-spl-doc/doc/md/bug-round-40/seat-mistral.md --agent m-048`
-> exit 4:
`WARN no live lane lists <the paths>, but 3 live lane(s) record no files: their scope is unknown, not free`
and `unknown: c-547@sat c-547-rotate has no files recorded; ask it or read its brief`,
`unknown: c-578@sat c-578-c002-s149-google-sync-label ...`,
`unknown: c-591@sat c-591-c002-bug-round-40-planner ...`.
No live lane lists the plan or any row file; c-591 is the planner (owns the plan
by its brief, not the row files). No collision with this seat's file.

## Check 8 — distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`ok - owner mail address or domain` ... `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-048`, exit 0.

## Defects

None. No W.

## Notes

- **N1**: rc02.sh's suite tail on this box prints `spl-lane-issue: 39 failure(s)`
  where the plan records `0 failure(s)` on sat. Environmental: the suite's
  `done` cases need the cnf repo map and `/opt/csi/dvn-web` does not exist on
  this box (`ls -d /opt/csi/dvn-web` -> No such file or directory), so they fail
  with `FATAL LANE_LANDED_REPO 'dvn-web' is no repo the cnf knows (src_dir names: none)`
  (`spl-lane-issue.func.sh:793`). The rc02 case lines themselves
  (`calls: 3 status-writes: 1`, `got=reopened-wip want=left-done`, exit 1)
  reproduce exactly.
- **N2**: plan 3.3 cites `store/repo_sync.go:311` for the hub's string `<`
  version compare; on `2286c85ce` that file is 273 lines and the version key
  lives in `store/release_note.go:205` (`releaseVersionKey`) with
  `sortReleaseNotes` at `:250-272`. The note's conclusion holds — I measured 0
  duplicate release tags — but the file:line does not exist on the sha.
- **N3**: `/var/spool-hub/dispatch/c002-next-round-candidates.md` is sat-only
  and absent on this box, so check 6's candidates-file read is NOT RUN here (see
  check 6).
- **N4**: on this box `/var/spool-hub/dispatch/briefs` (3280 entries) holds no
  b40-named brief; the planner's brief is on sat and this seat's brief is
  `/var/spool-hub/spawn-remote/briefs/5da20e67-045a-4e5f-8130-a4888a1e849e.md`.

## Review line

`review: m-048@<box2> mistral PASS 699e09331c2cad79008a74b45431e6e45e3f7355 ran: git ls-remote origin refs/heads/review/c002-bug-round-40-planner; git log origin/master --since="2026-11-22T09:15:08+02:00" --oneline -E --grep='\(b40-' | wc -l; git ls-remote origin | grep -E 'b40-[0-9]{2}|bug-round-40'; ls /var/spool-hub/dispatch/briefs | grep -E 'b40-[0-9]{2}|bug-round-40'; git show 2286c85ce:<file> | sed -n <N>p (each cited line); sha256sum rc01-b40.sh rc02.sh; bash rc01-b40.sh 2286c85ce; RC01_SAME_SECOND=1 bash rc01-b40.sh 2286c85ce; bash rc02.sh 2286c85ce; ENV=prd do_spl_db_query (2 SELECTs); ENV=prd do_gcp_tail_logs | grep 'issue backlog'; lane-map.sh --check <paths> --agent m-048; cd csi-spl-iac && ./run -a do_check_dist_hygiene | read: csi-spl-doc/doc/md/bug-round-40-plan.md at 699e0933, csi-spl-doc/doc/md/bug-round-39-plan.md and bug-round-38-plan.md on origin/master, the cited api/orc files at 2286c85ce; seat-file review/c002-bug-round-40-mistral-seat <sha> | log: m-048@<box2>:~/.vibe/logs/session/unified/9c42903b-8478-5964-ae0e-e9f7a1a37068`

The verdict stands: **PASS, 2 rows, on `699e09331c2cad79008a74b45431e6e45e3f7355` (v0.1).**
