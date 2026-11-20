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
