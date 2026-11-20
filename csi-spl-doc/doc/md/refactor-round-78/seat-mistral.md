# Refactor round 78 — panel seat mistral (m-555@sat)

Issue: SPL-6109 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-78-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/refactor-round-78-plan.md` on branch
`review/c002-refactor-round-78-planner`, at the v0.1 sha the planner names when it
asks for the panel (the holder sends it on task `dispatch-refactor-r78`). Rules:
`csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2 panel signs the
plan sha; 5.1 1 to 3 rows; 5.3 numbering and window). Form:
`csi-spl-doc/doc/md/refactor-round-77-plan.md` (on origin/master).

**Verdict: PENDING — no plan sha named yet.** As of 2026-11-20T22:54:26Z the planner
seat (`claude:c002-refactor-round-78-planner`, ask d0de88ef) is still queued
(`do_spl_spawn_queue` -> `17/40 ... 51m ... QUEUE`), no `r78-` / `refactor-round-78`
ref exists on origin (`git ls-remote origin | grep -E 'r78-[0-9]{2}|refactor-round-78'`
-> nothing, rc 1), and this seat's spool inbox holds no plan sha
(`spool recv --as m-555` -> only the lane-rotate note f6427103). This commit writes
the seat's state for the 23:07Z lane rotation; the verdict commit follows when the
sha arrives.

## State and checks run so far (each with its command and output)

- Seed STEP 0: read `csi-spl-doc/doc/md/developer-guide.md` (868 lines), then
  `cd csi-spl-orc && sudo -u <PUSH_USER> env AGENT_ID=m-555 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack`
  -> `ACK m-555 read developer-guide.md blob 8b1916cdc5d75c52cc4b3248babef398acf1366b`.
  (`<PUSH_USER>` is the OS user that owns the checkouts and pushes, as in the
  round plans; the public repo names neither user.)
- Read whole: `CLAUDE.md`, `csi-spl-doc/doc/help/how-to-post.md`,
  `csi-spl-doc/doc/md/rounds-rulebook.md` (sections 1-3, 5),
  `csi-spl-doc/doc/md/refactor-round-77-plan.md` (the form, 436 lines),
  `/var/spool-hub/dispatch/c002-next-round-candidates.md` (70 lines),
  the planner's brief `c002-refactor-round-78-planner.md`.
- Check 8 (dist hygiene, plan-independent), 2026-11-20T22:1xZ:
  `cd csi-spl-iac && ./run -a do_check_dist_hygiene`
  -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-555`, rc 0.
- Check 1, pre-run with the window the planner's brief derives
  (`W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(r77-plan')` ->
  `W=2026-11-20T23:56:41+02:00`, commit `0782cf525`), re-run 2026-11-20T22:54:26Z on
  `origin/master` `5f1e27bc7b57627b37714704dc78ff37908f8a64`:
  `git log origin/master --since="$W" --oneline -E --grep='\(r78-' | wc -l` -> `0`;
  the same grep over all history -> `0`;
  `git ls-remote origin | grep -cE 'r78-[0-9]{2}|refactor-round-78'` -> `0`;
  `ls /var/spool-hub/dispatch/briefs | grep -E 'r78-[0-9]{2}|refactor-round-78'` ->
  `c002-refactor-round-78-mistral-panel-seat.md`, `c002-refactor-round-78-planner.md`
  (this seat's and the planner's; expected).
- Checks 2-7: NOT RUN — they need the plan's base sha and row files.

## To do when the planner names a sha

Run checks 1-8 of the brief on that sha (site file:line existence on the plan's base
and on origin/master with `git show <sha>:<file> | sed -n <N>p`, red controls in a
scratch copy with sha256sum quoted and last line + exit code, equivalence reads at
the cited lines, row fields incl. no mistral coding/testing row and a cross-vendor
or claude-waiver R7, R1 batch disjointness, lane-map `--check` on the row paths,
inputs accounted against the candidates file and r77 plan section 7, dist hygiene),
write the verdict PASS|FAIL with defects W1.. and notes N1.. into this file, commit,
push to `review/c002-refactor-round-78-mistral-seat` only, and report on task
`dispatch-refactor-r78` in the brief's exact form. Then sign the editor's v1.0 sha
in a second commit and report again.
