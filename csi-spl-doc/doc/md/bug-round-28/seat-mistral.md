# Bug round 28 (b28): mistral panel seat (m-021)

Seat: m-021@<box2>, placement `c002-bug-round-28-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/m-021/lifetime/brief.md` (spawn-remote copy
`/var/spool-hub/spawn-remote/briefs/d2b8def8-e97a-438a-989b-6f82274cdf09.md`)
(Issue SPL-6046, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `be1daf61-85bb-4870-8eb4-ffd8d71f51b2`).

Review target: plan v0.1 `b4a015d342339dfc6b79771978343cfe0d62db6d` on
`review/c002-bug-round-28-planner`, named by c-002@sat (then dispatch holder),
msg `96dbdaf6-e9f7-45a9-9755-1d0989633eb2` (task `84dc98b2-0d74-5f93-8d89-3b956f93e6be`,
12:06:19Z): "plan v0.1 b4a015d342339dfc6b79771978343cfe0d62db6d on
review/c002-bug-round-28-planner ... editor c-362@sat, measured on d2f3f3b90".
Provenance, all run now from `/opt/csi/csi-spl-wt/m-021`:
- `git ls-remote origin review/c002-bug-round-28-planner` ->
  `b4a015d342339dfc6b79771978343cfe0d62db6d` (the branch tip IS the named sha).
- `git cat-file -t b4a015d342339dfc6b79771978343cfe0d62db6d` -> `commit`;
  `git merge-base --is-ancestor b4a015d3... origin/review/c002-bug-round-28-planner` -> rc 0.
- `git show b4a015d3 --stat --format='%H %s %P'` -> 1 file, +207,
  `csi-spl-doc/doc/md/bug-round-28-plan.md`, parent `62daca7aa`; NOT on master
  (`git merge-base --is-ancestor b4a015d3 origin/master` -> rc 1).
- Read in full at that sha (207 lines). The plan's one sha: base
  `d2f3f3b90921c79c1e72c8b96944d2b34623d72c` (`git rev-parse d2f3f3b90^{commit}`).
  origin/master at my read: `f17b02d3b` (moved past the plan's 11:56Z `62daca7aa`;
  no row-file drift, check 2).

## Checks (each with the command run and what it printed, 2026-11-20, <box2>)

1. **Slug b28 unused since the plan's `Window: W=`.**
   `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b27-plan')` ->
   `W=2026-11-20T12:33:38+02:00`; `git log origin/master -1 --format='%h %cI' -E --grep='^docs\(b27-plan'`
   -> `d2e4c74eb 2026-11-20T12:33:38+02:00` — the plan's W and commit, reproduced.
   `git log origin/master --since="$W" --oneline -E --grep='\(b28-' | wc -l` -> `0`.
   `git ls-remote origin | grep -E 'b28-[0-9]{2}|bug-round-28'` ->
   `b4a015d342339dfc6b79771978343cfe0d62db6d  refs/heads/review/c002-bug-round-28-planner`
   only — the planner's branch, expected; nothing else (my seat branch did not
   exist yet at this run). `ls /var/spool-hub/dispatch/briefs | grep -E 'b28-[0-9]{2}|bug-round-28'`
   -> empty (rc 1) on <box2>: the b28 briefs here are UUID-named, not slug-named;
   `grep -l 'c002-bug-round-28' /var/spool-hub/spawn-remote/briefs/*.md` ->
   `d2b8def8-e97a-438a-989b-6f82274cdf09.md` (this seat's brief), and no UUID in
   `dispatch/briefs` matches `b28-[0-9]{2}` (the plan's section 4 doc input holds
   on this box too). `git -C /opt/csi/csi-spl worktree list | grep -E 'b28-[0-9]{2}|bug-round-28'`
   -> rc 1 (none registered in the shared clone's list on <box2>). PASS (with N5).

2. **Row sites on `d2f3f3b90` and origin/master.**
   `git diff --name-only d2f3f3b90 origin/master -- csi-spl-orc/src/bash/run/spl-spawn-place.func.sh csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh csi-spl-doc/specs/157-dispatch-automation/spec.md csi-spl-orc/src/bash/run/spl-lane-mix.func.sh csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh csi-spl-orc/src/bash/run/spl-review-go.func.sh csi-spl-doc/doc/md/bug-round-28-plan.md`
   -> empty (no drift; origin/master is now `f17b02d3b`, but no row file changed).
   Each cited line checked with `git show <sha>:<file> | sed -n <N>p` on both
   `d2f3f3b90` and `origin/master`, identical (SAME) in every case:
   - `spl-spawn-place.func.sh:1019` -> `  if spl_spawn_place_review_seat "$2" "$kind" || [[ "$(basename "$2" .md)" == *-panel-seat ]]; then`
   - `:1003` -> `# else to claude. A brief under the data rule (spl_spawn_place_data_rule,`; `:1014` -> `spl_spawn_place_swap() {  # VENDOR BRIEF`;
     `:107` -> `# @description         A review seat (slug ending -reviewer, or Kind: review)`; `:108` -> `# @description         or a panel seat (slug ending -panel-seat, read-only,`; `:111` -> `# @description         author it is refused, handed back to the holder (SPL-3776)`;
     `:1041` -> `spl_spawn_place_review_seat() {  # BRIEF KIND`; `:1044` -> `}`
   - `spl-spawn-queue.tst.sh:1110` -> `# mistral -reviewer seat whose brief names csi-spl-wui/ stays mistral; a`; `:1159` -> `# agy's banner in the watchdog's pane capture (ctx*/a-*/pane, reset = the`
   - `spec.md:258` -> the `- **The reviewed sha off the row's branch** (SPL-5670; ...)` bullet, listing (c) a related origin branch and (a) a local branch/worktree HEAD, "found locally only" — no origin/master case
   - `spl-review-go.func.sh:72` -> `# @description       origin's master ("on origin/master": it landed, b27-01),`; `:790` -> `# branch on origin is not the reviewed sha (SPL-5670). 0, where it was found`; `:816` -> `    echo "is on origin/master (it landed; the row's branch '$1' is no longer on origin)"; return 0`; `:835` -> empty
   - `git show d2f3f3b90:...spec.md | grep -n 'found locally only'` -> `258:`; `git grep -n 'is on origin/master (it landed' d2f3f3b90 -- csi-spl-orc/src/bash/run/spl-review-go.func.sh` -> `:816`; `git log -1 --format=%h d2f3f3b90 -- csi-spl-doc/specs/157-dispatch-automation/spec.md` -> `7b6cd900e` (b23-01) — all as the plan claims. PASS.

3. **Red controls.** The files are on sat only (`ls /var/spool-hub/dispatch/b28-red-controls/` ->
   No such file on <box2>), so I rebuilt them from the code blocks the plan prints in
   section 3.2 (as the plan instructs a `<box2>` seat to do):
   `sha256sum` of the rebuilt scripts -> `ce884e8d30528ed42c657399cdbb4a0136d434b64a69a0f1da049134a37d616e  rc01.sh` (2441 B),
   `1161749de2a63a9d0fa3f545f2b400fa88f5f97c9d1c009cca61cbf0c46fabbd  rc02.sh` (839 B) —
   first 12 hex `ce884e8d3052` / `1161749de2a6` and sizes 2441/839 B, exactly the
   plan's section 3.2 claims. Tools present: `which bash git python3 yq` ->
   `/usr/bin/bash /usr/bin/git /usr/bin/python3 /usr/local/bin/yq`. Run from my
   worktree (a checkout) on the plan's base, in a scratch dir:
   - rc01, n=2: `bash rc01.sh d2f3f3b90 /var/spool-hub/dispatch/briefs/c002-s152-panel-seat-mistral.md /var/spool-hub/spawn-remote/briefs/d2b8def8-e97a-438a-989b-6f82274cdf09.md`
     -> exit 1, last line `rc01 sha=d2f3f3b90 wrong=3`; full output:
     `rc01 x-mistral-panel-seat.md -> mistral` / `rc01 x-panel-seat-mistral.md -> agy (mistral takes no UI work until do_spl_vendor_ui_retest passes (the brief names csi-spl-wui/))` /
     `rc01 x-panel-seat-mistral-2.md -> agy (...)` / `rc01 x-orc-panel-seat-no-ui-swap.md -> claude (...)` /
     `rc01 c002-s152-panel-seat-mistral.md -> agy (...)` / `rc01 d2b8def8-....md -> mistral` /
     `rc01 sha=d2f3f3b90 wrong=3`. Second run (n=2) identical, exit 1.
     RED for the plan's reason: the `-panel-seat-<vendor>` forms swap to agy while
     the `-panel-seat` suffix form stays mistral and the coding control still swaps.
   - rc02, n=1: `bash rc02.sh d2f3f3b90` -> exit 1, last line
     `rc02 sha=d2f3f3b90 bullet-line=258 code-on-master=1 bullet-names-origin-master=0`.
     RED for the plan's reason: the code has the on-origin/master case, the bullet
     does not name origin/master.
   - Live state: rc01 writes only under `C="$(mktemp -d)"` + `git archive "$full" csi-spl-orc csi-spl-cnf | tar -x -C "$C"` + `trap 'rm -rf -- "$C"' EXIT`;
     rc02 only `git show`. Neither touches live state. PASS.

4. **Root cause of each row, read at `d2f3f3b90`.**
   - Row 01: `git show d2f3f3b90:csi-spl-orc/src/bash/run/spl-spawn-place.func.sh | sed -n '1000,1060p'`
     shows `spl_spawn_place_swap` (:1014): the spare test at :1019 is exactly
     `[[ "$(basename "$2" .md)" == *-panel-seat ]]`, so a slug ending
     `-panel-seat-mistral` is not spared, falls through to
     `spl_lane_mix_mistral_ui_off` (:1028), and a `Kind: specs_and_docs` brief
     quoting a `csi-spl-wui/` path trips the UI rule (`spl_lane_mix_ui_target`,
     `spl-lane-mix.func.sh:255-268`, defined :261) -> `case "$kind" in specs_and_docs|i18n) to=agy`.
     rc01 above reproduces it. The plan's reading holds.
   - Row 02: `git show d2f3f3b90:csi-spl-orc/src/bash/run/spl-review-go.func.sh | sed -n '788,835p'`
     shows `_spl_review_go_elsewhere` (:801): after the related-origin-branch case,
     it takes origin's master tip (`mtip` from `git ls-remote origin`, else
     `refs/remotes/origin/master`) and at :812-816
     `git merge-base --is-ancestor "$2" "$ref"` -> `echo "is on origin/master (it landed; ...)"` —
     BEFORE the local-branch (:818) and worktree checks. `spec.md:258` lists only
     (c) and (a) "found locally only". rc02 above reproduces the gap. The plan's
     reading holds. PASS.

5. **Row fields (R2 control, tests, vendor, kind, batch, R7).**
   - Row 01: red control rc01 fails on `d2f3f3b90` (exit 1, wrong=3, check 3); the
     plan's fix scope (slug regex `-panel-seat(-(agy|claude|grok|mistral|qwen)(-[0-9a-z]+)?)?$`
     in the swap, coding control still swapping) makes rc01 exit 0 (wrong=0) — the
     control's own counting. Test column: `git grep -l 'place_swap\|review_seat\|panel-seat' d2f3f3b90 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features`
     -> `features/spawn-agents/tests/test-lane-issue.sh`, `tests/spl-box-pick.tst.sh`,
     `tests/spl-spawn-place-argmax.tst.sh`, `tests/spl-spawn-queue.tst.sh` — the plan's
     "at least" list holds (rc01.sh is the external red control, not in the repo).
     vendor claude, kind `simple_coding`, batch 1.
   - Row 02: red control rc02 fails on `d2f3f3b90` (exit 1, check 3); passes after
     the bullet names origin/master (exit 0). Test column: rc02 + dist hygiene (check 8).
     vendor claude, kind `specs_and_docs`, batch 1.
   - No mistral coding or testing row: both rows are claude; mistral appears only as
     row 02's R7 reviewer (this seat, a read-only doc review, cross-vendor to the
     claude author, rulebook 2.7.2), backup the claude waiver seat. Row 01's R7 is
     the claude waiver seat (1a7c70da): re-run by me,
     `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick`
     -> `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% billing read 50m ago; <box2> 99% billing read 50m ago]: queue the lane, spawn nothing`
     — as the plan's section 8 records, so the R7 is the waiver seat, never mistral.
   - R1: batch 1 file sets `comm -12` -> 0 shared files (row 01:
     `spl-spawn-place.func.sh`+`spl-spawn-queue.tst.sh`; row 02: `spec.md`). PASS.

6. **R3 lane map.** `bash /opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh,csi-spl-doc/specs/157-dispatch-automation/spec.md,csi-spl-doc/doc/md/bug-round-28-plan.md --agent m-021`
   -> `WARN no live lane lists` them; `FATAL Command 'do_spl_lane_map' failed at line 185 with status 4.`, exit 4.
   Unknown no-file lanes: `c-338@sat c-338-c002-s183-p3-cli-mcp-orc-topic-pdf`,
   `c-339@sat c-339-c002-s183-p4-renderer-cloud-run`, `c-341@sat c-341-c003-refactor-round-75-planner`,
   `c-358@sat c-358-c002-s-default-model-per-kind-spec`, `c-360@sat c-360-c002-s183-p2b-renderer-timeout-504`,
   `c-362@sat c-362-c002-bug-round-28-planner` (the planner itself). Their briefs are
   not on <box2> (NOT READ here — see N3); the plan read them on sat at 11:54:08Z and
   recorded none is a row file. Exit 4 means ask-first, not free. Queued asks:
   `grep -l '"state":"queued"' /var/spool-hub/asks/*.json | wc -l` -> 20;
   ask `6f3ec664-7d70-4aed-8421-bf449bacf020.json` (r75-01) -> `"state":"queued"`,
   shares `spl-spawn-queue.tst.sh` with row 01 — the plan's R3 ordering (row 01 waits
   for r75-01 if it is live first) is recorded in section 3.1. No row file is listed
   by any live lane. PASS (with N3).

7. **Inputs accounted for.** b27 plan section 7's "first inputs for round 28" (read on
   origin/master, `bug-round-27-plan.md` lines 185-193): the done-claim `job` label,
   `test-agent-name-shape.sh:89`, the AltGr picker (SPL-5850 N1), the blog switcher's
   Enter, the orc/iac suites as the agent OS user, the slug-regex doc input — all six
   are accounted for in b28 plan section 4 (rows 2-7). The candidates file
   `/var/spool-hub/dispatch/c002-next-round-candidates.md` is NOT on <box2>
   (`ls` -> No such file; `grep -rl 'Bug-shaped' /var/spool-hub` -> only brief copies),
   so its "next BUG round" / "Bug-shaped" sections are NOT READ here (N4); the plan's
   section 5 re-measures its 7 entries, each with a disposition, and I re-verified the
   checkable ones on the tree: review-notify author line fixed `3e46a758c`
   (`fix(b22-02-orc-review-notify-author-line-wins, SPL-5976)`), done-claim sha256sum
   prefix skipped at `spl-done-claim-check.func.sh:344` (SPL-5990), `blog.test.mjs:329`
   served by b26-01 `c540aca24` (`git log -1 --format='%h %s' d2f3f3b90 -- csi-spl-wui/tests/e2e/blog.test.mjs`).
   The two rows come from the candidates file's last entries (c-325 R7 W1 on b27-02;
   b27-01 N5), as the plan's section 5 states. No bug-shaped input I can see from <box2>
   is neither served nor accounted for. PASS (with N4).

8. **Distribution hygiene.** `cd csi-spl-iac && sudo -u <PUSH_USER> ./run -a do_check_dist_hygiene`
   -> `ok - non-Csitea org or bank reference`, `ok - personal name`,
   `ok - literal OS user / box / AD id`, `ok - personal home directory`,
   `ok - owner mail address or domain`, `ok - hidden workspace or private literal (SPL-1874)`,
   `ok - retired relay estate (SPL-1910)`, `ok - no tracked .vibe/ dir`,
   `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-021`, exit 0. PASS.

Plan cross-counts re-run: `git rev-list --count 0509f0b7b..d2f3f3b90` -> `33`;
`git rev-list --count d2e4c74eb..d2f3f3b90` -> `8` ("8 since W");
`git log origin/master --oneline -E --grep='\(b27-0[12]-'` -> `21abdb87e` (b27-02, SPL-6028),
`656ab3389` (b27-01, SPL-6027); close record `d2e4c74eb docs(b27-plan, SPL-6019)` — all as the plan's header claims.

## Defects

None. Every check above printed what the plan claims; both red controls fail on
`d2f3f3b90` for the reason the plan gives, not for an environment reason.

## Notes

- **N1:** origin/master moved during the review (`62daca7aa` at the plan's 11:56Z ->
  `f17b02d3b` at my read); `git diff --name-only d2f3f3b90 origin/master -- <the 7 row
  and site files>` -> empty, and the cited lines are byte-identical (check 2), so the
  verdict is unaffected by the churn.
- **N2:** the red-control files live on sat only; on <box2> I rebuilt them from the plan's
  printed blocks and their sha256/size match the plan's claims exactly
  (`ce884e8d3052`/2441 B, `1161749de2a6`/839 B), so the run is the plan's control, not a
  lookalike.
- **N3:** lane-map exit 4 names 6 unknown no-file lanes, all @sat; their briefs are not
  readable from <box2> (NOT READ here). The plan read them on sat (section 3.1, 11:54:08Z)
  and recorded none is a row file; c-362 is the planner itself. Exit 4 = ask-first, not
  free; the orchestrator re-runs R3 before the row spawns.
- **N4:** `/var/spool-hub/dispatch/c002-next-round-candidates.md` is sat-only; its
  sections are NOT READ from <box2>. The b27 section 7 half is fully accounted (check 7);
  the plan's section 5 dispositions that are checkable on the tree re-verified.
- **N5:** on <box2> `ls /var/spool-hub/dispatch/briefs | grep -E 'b28-[0-9]{2}|bug-round-28'`
  -> 0 because the b28 briefs here are UUID-named (this seat's is
  `spawn-remote/briefs/d2b8def8-....md`); the plan's sat half (2 slug-named briefs)
  was asked of the holder per its section 8. No UUID false-hit of `b28-[0-9]{2}` on
  this box either.
- **N6:** `do_spl_box_pick BOX_PICK_KIND=grok` re-run from <box2> -> hold (sat 99%, <box2> 99%
  weekly), so row 01's R7 stays the claude waiver seat (1a7c70da), never mistral.

## Verdict

**Verdict: PASS on `b4a015d342339dfc6b79771978343cfe0d62db6d`.** All eight checks ran
with the outputs quoted above; both red controls are RED on the plan's base
`d2f3f3b90` for the plan's stated reasons and touch no live state; every cited
file:line matches on the base and on current origin/master with no drift; the rows
are disjoint in batch 1, carry failing-today controls, test lists, claude vendor and
kind, and cross-vendor or waiver R7 reviewers (never mistral); the slug b28 is
unused since W; dist hygiene is clean. No W defects. Per the brief the final
signature waits for the editor's v1.0 sha; if c-362@sat names v0.1 as final, this
PASS is the signature on it.

## Signature on v1.0 `ed59ce77b1814b0c372948a8db6c15cafd8abf51` (2026-11-20 12:5xZ, <box2>)

Named by c-362@sat, msg `32771253-4476-4c14-90bf-8a53787293a0` (task
`84dc98b2-0d74-5f93-8d89-3b956f93e6be`): "v1.0 `ed59ce77b` (one commit on
b4a015d34, a fast-forward of review/c002-bug-round-28-planner) records your PASS
and the other box's checks; rows unchanged. Please sign v1.0 on that sha."
Provenance, all run now:

- `git ls-remote origin review/c002-bug-round-28-planner` ->
  `ed59ce77b1814b0c372948a8db6c15cafd8abf51` (the branch tip).
- `git fetch origin review/c002-bug-round-28-planner`;
  `git rev-parse ed59ce77b^{commit}` -> `ed59ce77b1814b0c372948a8db6c15cafd8abf51`.
- `git merge-base --is-ancestor b4a015d342339dfc6b79771978343cfe0d62db6d ed59ce77b`
  -> rc 0: v1.0 is a fast-forward on v0.1.
- `git log --oneline b4a015d3..ed59ce77b` -> one commit, `ed59ce77b docs(b28-plan,
  SPL-6046): bug round 28 plan v1.0, panel m-021 (mistral) PASS on v0.1 b4a015d34,
  no W, the other box's slug and lane checks folded, rows unchanged`.
- `git diff --name-only b4a015d3 ed59ce77b` -> `csi-spl-doc/doc/md/bug-round-28-plan.md`
  only; `git diff --stat` -> 12 insertions(+), 9 deletions(-). The hunks touch only
  the status/panel header, the sat cron-log row, the lane-map and slug rows, section
  8's review history and the consensus table; `sed -n '/^| 0[12] /p'` of the plan at
  v0.1 and at v1.0, `diff` -> empty (rows byte-identical); sections 4 and 5 unchanged.
- The PASS v1.0 records (plan lines 16 and 200) cites msg `6ae7712c` and seat sha
  `3c829af0b` on `review/c002-bug-round-28-mistral-seat` — both mine and both correct.
- `git merge-base --is-ancestor ed59ce77b origin/master` -> rc 1: v1.0 is
  review-branch only, not on master.
- The corrected review line (`ran:` straight after the sha, the seat-file field moved
  into `read:`) passes the full check on this box:
  `REVIEW_LINE='<line>' ./run -a do_spl_review_line_check` (csi-spl-orc) ->
  `NOTE read as <AGENT_USER> (sudo -n)` /
  `OK 1 of 1 named in ran: are commands in ~/.vibe/logs/session/unified/a7880f92-9c8a-dcf6-0d14-b91939441543 (1871 commands read): spl-spawn-queue.tst.sh`,
  exit 0.

**Signature: PASS on `ed59ce77b1814b0c372948a8db6c15cafd8abf51`.** v1.0 is a
fast-forward on the v0.1 I passed, touches only the plan file, changes no row and no
section 4/5 accounting, and records my v0.1 PASS with the correct msg id and seat sha.
I sign it.
