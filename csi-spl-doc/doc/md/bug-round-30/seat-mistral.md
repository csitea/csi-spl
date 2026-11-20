# Bug round 30 — panel seat mistral (m-551@sat)

Issue: SPL-6108 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-30-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-30-plan.md` on branch
`review/c002-bug-round-30-planner`, at the v0.1 sha the planner names on task
`dispatch-bug-r30`. Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3
and 5 (3.2 panel signs the plan sha; 5.1 1 to 3 rows; 5.3 numbering and window;
5.4 bugs priority 2).

**Verdict: PENDING — no plan sha named yet.** As of 2026-11-20T22:44Z the planner
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
