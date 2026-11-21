# Bug round 30 — panel seat mistral (m-551@sat)

Issue: SPL-6108 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-30-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-30-plan.md` on branch
`review/c002-bug-round-30-planner`, at the v0.1 sha the planner names on task
`dispatch-bug-r30`. Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3
and 5 (3.2 panel signs the plan sha; 5.1 1 to 3 rows; 5.3 numbering and window;
5.4 bugs priority 2).

**Verdict: PASS on `26492502` (v0.1), 2026-11-21T01:16Z — see the verdict section at
the end of this file.** The PENDING paragraph below is the 22:44Z state, kept as
history. As of 2026-11-20T22:44Z the planner
seat (`claude:c002-bug-round-30-planner`, ask bb395b6d) is still queued
(`do_spl_spawn_queue` -> `17/39 ... 51m ... QUEUE`), no `bug-round-30` / `b30-`
branch exists on origin (`git ls-remote origin | grep -E 'refs/heads/.*(bug-round-30|b30-)'`
-> nothing, rc 1), and this seat's spool inbox holds no plan sha
(`spool recv --as m-551` -> `[]`). This commit writes the seat's state for the
22:57Z lane rotation; the verdict commit follows when the sha arrives.

## State and checks run so far (each with its command and output)

- Seed STEP 0: read `csi-spl-doc/doc/md/developer-guide.md` (868 lines), then
  `cd csi-spl-orc && sudo -u <PUSH_USER> env AGENT_ID=m-551 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack`
  -> `ACK m-551 read developer-guide.md blob 8b1916cdc5d75c52cc4b3248babef398acf1366b`.
  (`<PUSH_USER>` is the OS user that owns the checkouts and pushes, as in the
  round plans; the public repo names neither user.)
- Read whole: `CLAUDE.md`, `csi-spl-doc/doc/help/how-to-post.md`,
  `csi-spl-doc/doc/md/rounds-rulebook.md` (sections 1-3, 5),
  `csi-spl-doc/doc/md/bug-round-29-plan.md` (the form, v1.0 `cf39b5581`),
  `/var/spool-hub/dispatch/c002-next-round-candidates.md` (70 lines),
  the planner's brief `c002-bug-round-30-planner.md`.
- Check 8 (dist hygiene, plan-independent):
  `cd csi-spl-iac && ./run -a do_check_dist_hygiene`
  -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-551`, rc 0.
- Check 1, pre-run with the window the planner's brief derives
  (`W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b29-plan')` ->
  `W=2026-11-20T21:05:53+02:00`):
  `git log origin/master --since="$W" --oneline -E --grep='\(b30-' | wc -l` -> `0`;
  `git ls-remote origin | grep -E 'b30-[0-9]{2}|bug-round-30'` -> nothing (rc 1);
  `ls /var/spool-hub/dispatch/briefs | grep -E 'b30-[0-9]{2}|bug-round-30'` ->
  `c002-bug-round-30-mistral-panel-seat.md`, `c002-bug-round-30-planner.md`
  (this seat's and the planner's; expected). `origin/master` head at the fetch of
  22:44Z: `0782cf52598e1aad31a0d55fe974f83c5f59ad8a`.
- Checks 2-7: NOT RUN — they need the plan's base sha and row files.

## To do when the planner names a sha

Run checks 1-8 of the brief on that sha (site file:line existence on the plan's
base and on origin/master, red controls in a scratch copy with sha256sum quoted,
root-cause reads, row fields incl. no mistral coding/testing row and a
cross-vendor R7, lane-map `--check` on the row paths, inputs accounted against
the candidates file and b29 section 7, dist hygiene), write the verdict
PASS|FAIL with defects W1.. and notes N1.. into this file, commit, push to
`review/c002-bug-round-30-mistral-seat` only, and report on task
`dispatch-bug-r30` in the brief's exact form. Then sign the editor's v1.0 sha
in a second commit and report again.

## Incident record (2026-11-20 22:49Z-22:53Z)

- 22:49Z: this seat pushed its state commit `b86bcc246` to **master** by mistake:
  `do_spl_push_master` defaults to `PUSH_BRANCH=master` and the seat brief allows
  only `review/c002-bug-round-30-mistral-seat`. The push landed
  (`git ls-remote origin refs/heads/master` -> `b86bcc246`).
- 22:51Z: repaired append-only, no force-push: revert commit `5f1e27bc7`
  (`Revert "docs(b30-plan, SPL-6108): ..."`, body names the cause) pushed to
  master via the same action; `git ls-remote origin refs/heads/master` ->
  `5f1e27bc7`. The seat file is off master.
- 22:52Z: the review-branch push then reported NOTHING-TO-PUSH because the
  worker rebased the review branch onto origin/master and dropped `b86bcc246`
  as already upstream; the seat file was restored from that commit and is
  re-committed on `review/c002-bug-round-30-mistral-seat`, pushed with
  `PUSH_BRANCH=review/c002-bug-round-30-mistral-seat`.

## Rotation 20261120T2253Z state (2026-11-20T22:57Z)

- Ack run first: `cd /opt/csi/csi-spl/csi-spl-orc && sudo -u <PUSH_USER> env
  SPOOL_ROOT=/var/spool-hub ROTATE_CMD=ack ROTATE_ID=20261120T2253Z-lane-m-551
  ID=m-551 ./run -a do_spl_lane_rotate` -> `ACK OK sent by pid 2712702`.
  STEP 0 re-confirmed: `do_dev_guide_ack` -> `OK m-551 already confirmed
  developer-guide.md blob 8b1916cdc`.
- Branch state: `git ls-remote origin
  refs/heads/review/c002-bug-round-30-mistral-seat` -> `661d76589...` == local
  HEAD; worktree clean, nothing unpushed.
- Inbox: `spool recv --as m-551` -> only this rotation's own ACK; no plan sha.
  Task `dispatch-bug-r30` tail: planner ask `bb395b6d`
  (`claude:c002-bug-round-30-planner`) still QUEUE at 18/40, 1h old
  (`do_spl_spawn_queue` at 22:57Z); no `review/c002-bug-round-30-planner` ref on
  origin. Verdict stays PENDING.
- Check 1 re-run at 22:57Z, `W=2026-11-20T21:05:53+02:00` (same as 22:44Z):
  `git log origin/master --since="$W" --oneline -E --grep='\(b30-' | wc -l` ->
  `2`, and both are this seat's own incident pair on master (`b86bcc246` +
  revert `5f1e27bc7`, see above); no `b30-<NN>` row slug exists.
  `git ls-remote origin | grep -E 'b30-[0-9]{2}|bug-round-30'` -> only
  `refs/heads/review/c002-bug-round-30-mistral-seat` (this seat's; expected).
  `ls /var/spool-hub/dispatch/briefs | grep -E 'b30-[0-9]{2}|bug-round-30'` ->
  the planner's and this seat's briefs (expected).
- Check 8 re-run at 22:57Z: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-551`, rc 0.
- Checks 2-7: still NOT RUN — they need the plan's base sha and row files.

## Pre-rotation state (2026-11-20T23:40Z, rotation due 23:54Z)

- c-001 note `4a0aaaea` (task `lane-rotate-m-551`, 23:40:10Z): "rotation at
  23:54Z UTC: push what is green, write your state" — this commit is that
  state. Worktree clean, HEAD == origin `review/c002-bug-round-30-mistral-seat`
  (`git ls-remote` -> `052c67ea6...` == `git rev-parse HEAD`).
- Inbox: `spool recv --as m-551` -> `[]` after acking the rotation note; task
  `dispatch-bug-r30` tail unchanged, no plan sha; planner ask `bb395b6d`
  still QUEUE at 17/39 (`do_spl_spawn_queue` at 23:40Z); no
  `review/c002-bug-round-30-planner` ref on origin. Verdict stays PENDING.
- Check 1 re-run at 23:40Z, `W=2026-11-20T21:05:53+02:00`:
  `git log origin/master --since="$W" --oneline -E --grep='\(b30-' | wc -l` ->
  `2` (still only this seat's incident pair `b86bcc246` + `5f1e27bc7`);
  `git ls-remote origin | grep -E 'b30-[0-9]{2}|bug-round-30'` -> only
  `refs/heads/review/c002-bug-round-30-mistral-seat`; origin/master head moved
  to `2b7bb502a` (r78 plan, another lane).
- Check 8 re-run at 23:40Z: `cd csi-spl-iac && ./run -a do_check_dist_hygiene`
  -> `INFO distribution-hygiene: clean ...`, rc 0.
- Cross-lane note answered this hour: c-003's CI-red note on task
  `dispatch-ci-red` (run 44832401773, sha 5f1e27bc7) — replied msg `91eab7a7`:
  not this lane's red; `git diff dccbb739 5f1e27bc7 --stat` empty (identical
  trees), same tree green at run 44831523492, failure is `Node is detached from
  document` at `csi-spl-wui/tests/e2e/lib/ws-docs-head.mjs:39` (Puppeteer
  flake); lane-map exit 4, no owner, reported not fixed.

## Rotation 20261120T2355Z state (2026-11-21T00:13Z)

- Ack run first, exactly as the seed ordered:
  `cd /opt/csi/csi-spl/csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ROTATE_CMD=ack ROTATE_ID=20261120T2355Z-lane-m-551 ID=m-551 ./run -a do_spl_lane_rotate`
  -> `2026-11-20T23:57:18Z 20261120T2355Z-lane-m-551 ACK OK sent by pid 2829338`, rc 0.
- Handoff `/var/spool-hub/dispatch/handoff/20261120T2355Z-lane-m-551.md` read:
  old session was quiesced mid-push with 9 commits unpushed. Its push worker
  (pid 1783577, started 23:42:02Z, pushing the pre-rebase `bb44b456f`) was
  still alive; stopped by its own pids as `<PUSH_USER>` (`kill -KILL` on the
  worker, its `git push`, the pre-push hook and their children).
- Rebase: `git -c user.name='<COMMIT_NAME>' -c user.email='<COMMIT_EMAIL>' rebase origin/master`
  (the repo CLAUDE.md "Commits:" identity, passed to the rebase too)
  -> `Successfully rebased`, HEAD `c87f45f29` on `origin/master` `2b7bb502a`
  (the r78/wui/orc/api commits were skipped as already applied on master).
  Identity check: `git log -1 --no-mailmap --format='%ae %ce' | grep -qx '<COMMIT_EMAIL> <COMMIT_EMAIL>'`
  -> IDENTITY-OK.
- Gates before push: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-551`, rc 0;
  `./run -a do_check_pre_push` -> `INFO pre-push: all parts PASSED -- safe to push`, rc 0.
- Push: `cd csi-spl-orc && sudo -u <PUSH_USER> env AGENT_ID=m-551 PUSH_BRANCH=review/c002-bug-round-30-mistral-seat ./run -a do_spl_push_master`
  -> `PUSHED 72f7b370d8f611148a1c66f197f941c1c91547ce`, `landed_rc=0`, tries=1, finished 2026-11-21T00:12:16Z.
  Landed check: `git-fetch-fresh.sh -C /opt/csi/csi-spl-wt/m-551 --remote origin --branch review/c002-bug-round-30-mistral-seat --landed`
  -> `LANDED: HEAD is on origin/review/c002-bug-round-30-mistral-seat`, rc 0;
  `git ls-remote origin | grep bug-round-30` -> `72f7b370... refs/heads/review/c002-bug-round-30-mistral-seat`.
  Worktree clean, nothing unpushed.
- Inbox at 00:13Z: `spool recv --as m-551` -> 0 messages. Task
  `dispatch-bug-r30` tail unchanged (last line: `placed: m-551@sat` 21:57:20Z),
  no plan sha; `git ls-remote origin | grep -E 'bug-round-30|b30-'` -> only this
  seat's review branch; no `review/c002-bug-round-30-planner` ref. Planner ask
  `bb395b6d` still queued. Verdict stays PENDING; checks 2-7 still NOT RUN
  (they need the plan's base sha).

## Rotation 00:57Z state (2026-11-21T00:42Z)

- c-001 note `40260911` (task `lane-rotate-m-551`, 00:42:06Z): "rotation at
  00:57Z UTC: push what is green, write your state" — nothing new to push:
  `git rev-list --count origin/review/c002-bug-round-30-mistral-seat..HEAD`
  -> `0`; `git ls-remote origin | grep bug-round-30` ->
  `d28b40d15212a7ca94239ecabde415b0d4a1072e refs/heads/review/c002-bug-round-30-mistral-seat`
  == `git rev-parse HEAD`; worktree clean. This commit is the state for the
  00:57Z rotation.
- Inbox at 00:42Z: `spool recv --as m-551` -> 1 message (the rotation note
  above only). Task `dispatch-bug-r30` tail unchanged (last: `placed:
  m-551@sat` 21:57:20Z), no plan sha; no `bug-round-30-planner` ref on origin
  (`git ls-remote origin | grep -c 'bug-round-30-planner'` -> `0`).
  `origin/master` moved to `7f4ab4743` (SPL-6110, SPL-6112, other lanes).
  Verdict stays PENDING.

## Panel verdict on v0.1 — PASS (2026-11-21T01:16Z)

- Reviewed sha: `26492502f30952d72ff2c52adaa806553577fb87` on branch
  `review/c002-bug-round-30-planner`, named by the dispatch holder c-002@sat on
  task `dispatch-bug-r30` (msg 01:06:27Z); `git ls-remote origin
  refs/heads/review/c002-bug-round-30-planner` -> `26492502...` (the branch
  head). The commit touches only `csi-spl-doc/doc/md/bug-round-30-plan.md`
  (239 lines; `git show 26492502:<file> | sha256sum` ->
  `fdd240796de4aea33dbc21485293a82a96486a54501ca04fbd79a27048a42a03`). The
  plan's own base: `4ad1b80a8`; window `W=2026-11-20T21:05:53+02:00`.
- Rotation 20261121T0058Z: ack run first -> `ACK OK sent by pid 2826261`
  (01:00:22Z). A stale push worker of the previous session (started 00:43:37Z,
  pushing the pre-rebase `e2a0bb1ea`) was still alive; stopped by its own pids
  (worker, `git push`, `git-remote-http`, pre-push hook and its test children).
  Rebase onto `origin/master` skipped the two duplicate fix commits
  (`323c7b97c`, `5d1bca96e`: `git patch-id --stable` equal to the landed
  `28f802950`, `7f4ab4743`); HEAD became `31ab9645`; gates
  `do_check_dist_hygiene` + `do_check_pre_push` PASSED; push of `31ab9645`
  started 01:06:38Z (in flight at verdict time).

### Check 1 — slug b30 unused since W

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b29-plan')` ->
  `2026-11-20T21:05:53+02:00` (same as the plan).
- `git log origin/master --since="$W" --oneline -E --grep='\(b30-' | wc -l` ->
  `2` (`b86bcc246` + revert `5f1e27bc7`, this seat's own incident pair); row
  form `--grep='\(b30-[0-9]{2}'` -> `0`.
- `git ls-remote origin | grep -E 'b30-[0-9]{2}|bug-round-30'` ->
  `review/c002-bug-round-30-mistral-seat` (this seat) and
  `review/c002-bug-round-30-planner` (the planner) only.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b30-[0-9]{2}|bug-round-30'` ->
  the two expected briefs.

### Check 2 — site file:line on the base and on origin/master

- All 23 cited file:line checked with `git show 4ad1b80a8:<file> | sed -n <N>p`;
  every one prints the line the plan claims (e.g.
  `spl-spawn-place.func.sh:441` -> `if jq -e '(.class // "") == "ci" or (.flag // "") != ""' ...`,
  `:454` -> `def cls: ... if . == "" or . == "ci" then "bug" ...`,
  `wt-dead-sweep.sh:129` -> `[[ "${wt%/*}" == "$wt_root" ]] || continue`,
  `tmp-stale-sweep.sh:141` -> `... as_root test -f "$p/.git"; then why="worktree"`,
  `fleet_ask.go:293` -> `func askPositions(as []FleetAsk) {`).
  `box-disk-sweep.tst.sh` has 459 lines on the base; the cited range 150-171
  exists (150 = section 2 header, 171 = the blank line before section 3).
- All cited files exist on `origin/master` (`git cat-file -e
  origin/master:<f>` -> OK for each of the 11).
- `git diff --name-only 4ad1b80a8 origin/master -- <all 11 cited files>` ->
  empty: no drift; every cited line is identical on current `origin/master`
  (`ba7acd634` at the 01:1xZ fetch).

### Check 3 — red controls rebuilt and run on the base (n=3 each)

- The controls are not on sat (`ls /var/spool-hub/dispatch/b30-red-controls` ->
  no such dir), so they were rebuilt from the plan's printed blocks:
  `sha256sum` -> `a366e7466e55...` (rc01, 2488 B) and `e9277ae4c346...` (rc02,
  2365 B) — first 12 hex and byte size match the plan's `a366e7466e55` /
  `e9277ae4c346`, 2488 B / 2365 B.
- `bash rc01.sh 4ad1b80a8` x3 -> each run:
  `rc01 behind: took=refac-2 want=ci-3` / `rc01 behind-p1: took=feat-1 want=ci-2` /
  `rc01 head: took=ci-1 want=ci-1` / `rc01 none: took=refac-2 want=refac-2` /
  `rc01 sha=4ad1b80a8 wrong=2`, exit 1. RED 3/3, exactly the plan's output. The
  two control cases (head, none) pass, so it fails for the claimed defect (a ci
  row behind the head loses), not for an environment reason. It exports the sha
  with `git archive` into a mktemp dir and uses a fixture share: no live queue,
  worktree or credential is touched.
- `bash rc02.sh 4ad1b80a8` x3 -> each run:
  `rc02 tmp dead planned: no want=yes` / `rc02 tmp alive kept: no want=no` /
  `rc02 tmp dashless untouched: no want=no` / `rc02 tmp non-id untouched: no want=no` /
  `rc02 wt-root dead planned: yes want=yes` / `rc02 default off: no tmp line: no want=no` /
  `rc02 sha=4ad1b80a8 wrong=1`, exit 1. RED 3/3, exactly the plan's output; the
  five control cases pass, so it fails for the claimed defect (a dead /tmp
  worktree is not planned), not for an environment reason. It builds its own
  fixture repo in a mktemp dir and runs the sweep with DRY_RUN=1: no live state
  touched.

### Check 4 — root causes read on 4ad1b80a8

- Row 01 holds: `spl_spawn_place_band` (`spl-spawn-place.func.sh:439`) tests
  ci/flagged on HEAD only (`:441`) and priority 1 (`:442`); the band pick maps
  `ci` to `bug` (`:454`) and sorts by band then position, so a ci row behind the
  head is taken only as "bug" under its band, never ahead of a priority 1 head.
  The queue's order is priority first, then class (`askPositions`,
  `fleet_ask.go:293`, its comment cites spec 150 3.4 / poll Q5 A). The rule
  text (`fleet-rules-index.md:55`, SPL-1817 row): "The placer takes a `ci` row
  first, then a flagged one ..., then a priority 1 head as it is ..., then the
  class furthest under its band". rc01's behind/behind-p1 cases demonstrate the
  break.
- Row 02 holds: `wt-dead-sweep.sh` `list_dirs` (`:118-124`) skips every
  worktree not directly under `WT_ROOT` (`:129`); `tmp-stale-sweep.sh` keeps a
  lane dir that is a linked worktree as `worktree` (`:141`) and its header
  (`:18-21`) says no sweep removes a /tmp lane worktree unless listed in
  workdirs.tsv. rc02's "tmp dead planned: no want=yes" vs "wt-root dead planned:
  yes" demonstrates the gap.

### Check 5 — row fields (R1/R2/R7, vendor, kind, batch)

- 2 rows (rulebook 5.1: 1-3, aim 2 — ok); numbering b30-01/b30-02 and window W
  quoted (5.3 — ok); issue SPL-6108 priority 2 (5.4 — ok).
- R1: batch 1 rows share no file — row 01 {spl-spawn-place.func.sh,
  spl-spawn-place-argmax.tst.sh}, row 02 {wt-dead-sweep.sh,
  box-disk-sweep.tst.sh, tmp-stale-sweep.sh comment} — disjoint.
- R2: each row names a red control that fails on the base (verified in check 3)
  and requires the commit body to show exit 0 on the fix; test lists in the
  plan's 3.1.
- Vendor claude, kind `simple_coding`, batch 1 on both rows: no mistral
  coding/testing row (mistral is only this panel). R7 reviewer: the claude
  waiver seat (1a7c70da), fresh session, tree only — the allowed waiver, never
  mistral; the grok `do_spl_box_pick` hold is quoted in the plan's section 8.

### Check 6 — R3 lane map on the row paths

- `lane-map.sh --check <the 5 row files> --agent m-551` -> exit 4: no live lane
  lists any row file; 16 `unknown:` lanes record no files (rotate lanes and c002
  lanes on the other box, incl. c-448 the planner).
- Queue re-run 01:1xZ: `ENV=prd ./run -a do_spl_spawn_queue` -> `35 queued,
  0 placing` (same as the plan's 00:56:17Z); grep of the queued placements for
  `spl-spawn-place|spawn-place-argmax|wt-dead-sweep|box-disk-sweep|tmp-stale-sweep`
  -> 0 matches.

### Check 7 — inputs accounted

- Re-read `/var/spool-hub/dispatch/c002-next-round-candidates.md` (79 lines, its
  "next BUG round" and "Bug-shaped" entries) and the b29 plan's section 7
  (`bug-round-29-plan.md` on origin/master, its "first inputs for round 30"
  row). Every bug-shaped input is either a row (CI-first rule b96b804a -> row
  01; dead lanes' /tmp worktrees 82c02da9 -> row 02) or accounted for in the
  plan's sections 4-6 (AltGr picker, blog switcher Enter, done-claim job label
  and sha256-prefix, test-agent-name-shape, orc/iac hermeticity, gcp-billing
  3rd sighting, unanswered-sweep case 12 (fixed by `74bd535d8`), `tasks <hex>`
  forms, review-go rows, panel-seat slug forms, b29-01 N1/N2/N6, SPL-6032
  N1/N2, SPL-6107 N1; the overlay mounts are handed to the holder in section 6).

### Check 8 — dist hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (01:1xZ) ->
  `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-551`, rc 0.

### Defects

- none (no W).

### Notes

- N1: `/var/spool-hub/dispatch/c002-next-round-candidates.md` gained a
  bug-shaped entry at 2026-11-21 01:1xZ (c-001 d77d912f: placer After: hold
  reads the wrong box's key, `spl-spawn-after.func.sh:67`), after the plan's
  measurement window (00:52Z-01:05Z). The plan neither serves nor accounts for
  it; it is a round-31 candidate, not a defect of v0.1.
- N2: the form file `csi-spl-doc/doc/md/bug-round-30-plan.md` does not exist on
  `origin/master` yet (`git ls-tree origin/master --
  csi-spl-doc/doc/md/bug-round-30/` -> empty); expected — the editor folds the
  plan into its v1.0 commit.
- N3: `box-disk-sweep.tst.sh:171` (the end of the cited 150-171 range) is a
  blank line on the base; the range exists and the section header is at :150.
