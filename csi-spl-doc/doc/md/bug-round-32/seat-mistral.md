# Bug round 32 — panel seat mistral (m-696@sat)

Issue: SPL-6151 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-32-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-32-plan.md` on branch
`review/c002-bug-round-32-planner`, at the v0.1 sha the dispatch holder named on
task `dispatch-bug-r32` (c-002@sat, msg 95e75567, 05:43:46Z). Rules:
`csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the panel
signs the plan sha; 5.1: 1 to 3 rows; 5.3 numbering and window; 5.4 bugs
priority 2). Form: `csi-spl-doc/doc/md/bug-round-31-plan.md` on origin/master.

**Verdict: PASS on `1f694cb86b0c9fada1e1c5dbd6d8bde9a0b5fdc4` (v0.1). No W.**

Reviewed sha: `1f694cb86b0c9fada1e1c5dbd6d8bde9a0b5fdc4`, the head of
`review/c002-bug-round-32-planner` at my fetch (`git ls-remote origin
review/c002-bug-round-32-planner` -> the same sha, 05:44Z). The branch moved to
v0.2 `0498a1a90` while I reviewed; per the brief I review only the named sha and
sign v0.2 by delta below. `git show 1f694cb86:<plan> | sha256sum` ->
`a59499f8ca987b9f021f4cf8a0e2f219287b12432fd92be9eb41b84e7780a5bc`. The commit
touches 1 file, +260. The plan's own base: `8b7828a6b`; window
`W=2026-11-21T06:58:42+02:00` (`67a6bfa20`, the b31 plan v1.0).

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 31. `<PUSH_USER>`
is the OS user that owns the checkouts and pushes, and `<AGENT_USER>` is the OS
user the agents run as. The public repo names neither.

## Check 1 — slug b32 unused since the plan's W

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b31-plan')` ->
  `W=2026-11-21T06:58:42+02:00` (same as the plan's `Window:` line).
- `git log origin/master --since="$W" --oneline -E --grep='\(b32-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b32-[0-9]{2}|bug-round-32'` ->
  `1f694cb86... refs/heads/review/c002-bug-round-32-planner` only at 05:44Z (the
  planner's branch, expected; at 05:5xZ it moved to v0.2 `0498a1a90`, still the
  planner's). Nothing else. The rulebook 5.3 form
  `git ls-remote origin 'refs/heads/review/b32-*' 'refs/heads/wip/*b32*' 'refs/heads/*-b32-*'`
  -> empty.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b32-[0-9]{2}|bug-round-32'` ->
  `c002-bug-round-32-mistral-panel-seat.md`, `c002-bug-round-32-planner.md`
  (this seat's and the planner's; expected).
- `git worktree list | grep -E 'b32|bug-round-32'` -> 2: the planner's
  (`c-694-c002-bug-round-32-planner`) and this seat's
  (`m-696-c002-bug-round-32-mistral-panel-seat`). 0 row worktrees.

## Check 2 — every site file:line on the base and on origin/master

Row files: `csi-spl-orc/src/bash/run/spl-push-master.func.sh`,
`csi-spl-orc/src/bash/tests/spl-push-master.tst.sh`,
`csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh`,
`csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh`.

- `git cat-file -e 8b7828a6b:<f>` and `git cat-file -e origin/master:<f>` ->
  all four exist on both (base=yes master=yes for each).
- `git diff --name-only 8b7828a6b origin/master -- <the four row files>` -> empty
  (no drift). `git log --oneline 8b7828a6b..origin/master` at my 05:44Z fetch ->
  `9c3853eda feat(wui, SPL-6140): ...`, `cd2012822 docs(blog-spec, SPL-6140): ...`;
  neither touches a row file. Same for the two read-only lib files
  (`spool-notify.inc.sh`, `lane-issue.inc.sh`): `git diff --name-only
  8b7828a6b origin/master -- <both>` -> empty.
- Every cited file:line printed with `git show 8b7828a6b:<file> | sed -n <N>p`
  and matches the plan's claim (identical on origin/master, no drift):
  - `spl-push-master.func.sh:51` -> `# @param PUSH_BRANCH (optional) - default master; a review/* branch skips the R7 review-line check only`;
    `:73-85` -> `_spl_push_master_state_dir`, `:85` `echo "$d"`;
    `:90` `_spl_push_master_start() {`, `:118` its last line
    (`echo "PUSH: poll with PUSH_CMD=status (state $state)"`);
    `:395` `_spl_push_master_worker() {`, `:396`
    `local remote="${PUSH_REMOTE:-origin}" branch="${PUSH_BRANCH:-master}" ...`,
    `:463` `}`.
  - `spl-push-master.tst.sh:1` shebang, `:112` `fails=0`, `:516` case 20 comment.
  - `spl-spawn-review-notify.func.sh:35-39` header item 3 (`:39` "first
    \"`review/...`, head\", else the first review/ ref."); `:76`
    `branch="$(spl_review_notify_branch "$brief")"; branch="${branch:-(no review/ branch named)}"`;
    `:104-113` `spl_review_notify_branch`, `:108`
    `local r='review/[A-Za-z0-9._/-]*[A-Za-z0-9]' hit`.
  - `spl-spawn-review-notify.tst.sh:32-34` header (case 12 RED CONTROL SPL-5914),
    `:133` case 5 keeps the `(no review/ branch named)` text, `:241-256` case 12.
  - `spool-notify.inc.sh:284` -> `# (<fleet root>/<id>/lifetime/brief.md, the one a rotation restarts from)`.
  - `lane-issue.inc.sh:543` -> `li_review_lane() {`.
  - `/var/spool-hub/dispatch/briefs/c002-s033-t025-claude-waiver-reviewer.md:15`
    -> `Branch \`wip/c002-s033-t025-t027-wui-kinds-live\` (a \`wip/\` ref: ...), head \`e9e3f4ccf...\``.

## Check 3 — red controls read and run on the base

- `ls -la /var/spool-hub/dispatch/b32-red-controls/` -> `rc01.sh` 4053 B,
  `rc02.sh` 2311 B. `sha256sum` -> `a51a28ca72b6761d...` (rc01),
  `a7c6b45d44021f70...` (rc02): the first 12 hex match the plan's section 3.2
  (`a51a28ca72b6`, `a7c6b45d4402`), and the sizes match (4053 B, 2311 B), so the
  files on disk are the ones the plan printed.
- `bash /var/spool-hub/dispatch/b32-red-controls/rc02.sh 8b7828a6b`, n=3
  (05:47Z..05:48Z, from this checkout): RED in 3 of 3, identical output each
  time; last line `rc02 sha=8b7828a6b wrong=2`, exit 1. Full output of run 1:
  `rc02 wiplive: branch=none want=wip/c002-s033-t025-t027-wui-kinds-live` /
  `rc02 wipbare: branch=none want=wip/c-427-SPL-5147-why` /
  `rc02 review: branch=review/b99-01 want=review/b99-01` /
  `rc02 target: branch=review/new want=review/new` /
  `rc02 none: branch=none want=none` / `rc02 sha=8b7828a6b wrong=2`.
- `bash /var/spool-hub/dispatch/b32-red-controls/rc01.sh 8b7828a6b`, n=3
  (05:48Z..05:50Z): RED in 3 of 3; last line `rc01 sha=8b7828a6b wrong=1`, exit 1.
  Run 1: `rc01 seat: PUSHED 89c000ebf9b... master=moved want=REFUSED master=same`
  / `rc01 seatrev: PUSHED b161c461f4c1... master=same want=PUSHED master=same` /
  `rc01 planner: PUSHED 4506803261ec... master=moved want=PUSHED master=moved` /
  `rc01 rowlane: PUSHED 41d1c0feb277... master=moved want=PUSHED master=moved` /
  `rc01 sha=8b7828a6b wrong=1` (the fixture shas differ per run, as the plan
  says).
- Both fail for the reason the plan gives, not an environment reason: rc01's
  `seat` case shows a seat brief with the "to the branch `review/<x>` only" form
  landing on master when `PUSH_BRANCH` is unset; rc02's `wiplive`/`wipbare` show
  a `wip/` target read as `none`. The controls (`seatrev`, `planner`, `rowlane`,
  `review`, `target`, `none`) come out right, and must stay so.
- Live state: both scripts `git archive` the sha into a `mktemp -d` dir and build
  their own fixture (`rc01`: temp bare origin + lane worktree + temp SPOOL_ROOT,
  `core.hooksPath` pointed at an empty dir, no network; `rc02`: one fixture brief
  per case). I read both (sha256 above matches the plan's printed copies): neither
  reads a live queue, worktree, spool or credential, and the `trap rm -rf` cleans
  up. Nothing live was touched.

## Check 4 — root cause of each row, read at the cited lines

- Row 01 holds. `_spl_push_master_start` (`spl-push-master.func.sh:90-118`, read
  whole) checks the tree, the url creds, `PUSH_RETRIES`, the lock, uncommitted
  changes and detached HEAD, and the identity — nothing reads
  `$SPOOL_ROOT/<AGENT_ID>/lifetime/brief.md`. The worker defaults the branch at
  `:396` (`${PUSH_BRANCH:-master}`), and the header `:51` documents the default.
  `_spl_push_master_state_dir` (`:73-85`) picks
  `$SPOOL_ROOT/$AGENT_ID/lifetime/push-master` when `AGENT_ID` is set and the
  lifetime dir exists, so the brief at `lifetime/brief.md`
  (`spool-notify.inc.sh:284`) is at hand at start. Evidence re-verified:
  `git log origin/master -E --grep='revert' -i` -> `5f1e27bc7` (Revert of the b30
  seat mistral state, m-551) and `974d97031` (`revert(doc, SPL-6136): take m-642's
  3 bug round 31 seat notes off master...`, 04:51Z; `git show 974d97031 --stat`
  -> only `csi-spl-doc/doc/md/bug-round-31/seat-mistral.md`, 352 deletions).
  Seat-form prevalence re-measured: of the 40 newest `*panel-seat*` briefs on sat
  (`ls -t /var/spool-hub/dispatch/briefs | grep panel-seat | head -40` -> 40),
  37 carry `to the branch \`review/<x>\` only` (`grep -lE`); the 3 without are
  exactly `c002-b27-02-...`, `c002-b28-01-...`, `c002-b29-02-...` row briefs, as
  the plan says.
- Row 02 holds. `spl_review_notify_branch` (`:107-113`, read whole) builds every
  grep from `r='review/[A-Za-z0-9._/-]*[A-Za-z0-9]'` (`:108`) — the "Branch" line,
  the "`<ref>`, head" form and the first-ref-anywhere fallback are all `review/`
  only (with an optional `origin/` prefix), so a `wip/` target never matches and
  the caller `:76` writes `(no review/ branch named)`. The T025 brief's line 15
  (above) is the real `wip/` case. wip-reviewer-brief prevalence re-measured:
  `grep -l 'wip/' *review*.md *waiver*.md` in the briefs dir -> 46 files (matches
  the plan); of those, 16 have a line-start `` Branch `wip/...` `` and no
  `review/` anywhere (the plan counted 11 others at 05:3xZ; more briefs since —
  N2 below).

## Check 5 — rows: R2 control, tests, vendor, kind, batch, R7, R1

- 2 rows (rulebook 5.1: 1 to 3, aim 2 — ok); ids `b32-01`, `b32-02`; window W
  quoted (5.3 — ok); issue SPL-6151 priority 2 in the header (5.4 — ok).
- R1: batch 1 rows share no file — row 01 {`spl-push-master.func.sh`,
  `spl-push-master.tst.sh`}, row 02 {`spl-spawn-review-notify.func.sh`,
  `spl-spawn-review-notify.tst.sh`}; `git grep -l 'spl-spawn-review-notify'
  8b7828a6b -- <row 01 files>` -> rc 1 (none), and the reverse -> rc 1 (none).
  Disjoint.
- R2 test column re-run on `8b7828a6b`:
  `git grep -l -E 'spl-push-master|do_spl_push_master|_spl_push_master' 8b7828a6b -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features csi-spl-iac/src/bash/tests`
  -> 17 paths: the 7 orc tests, 5 spawn-agents tests, `test-y12-vibe-push-guard.sh`,
  plus `orc-shard-weights.txt` (a list) and 3 non-tests (`hooks/pre-push`,
  `spawn-core.inc.sh`, `tmux-close-window.sh`) — the same list the plan prints.
  The row 02 pattern -> `spl-spawn-review-notify.tst.sh` + `orc-shard-weights.txt`.
  Each row's red control fails on `8b7828a6b` (check 3) and the plan requires the
  commit body to show exit 0 on the fix and exit 1 on `8b7828a6b` (the green half
  is the lane's, as in the b31 form).
- Vendor `claude`, kind `simple_coding`, batch 1 on both rows: no mistral coding
  or testing row (mistral is only this panel). R7 reviewer: the claude waiver
  seat (1a7c70da), fresh session, tree only — the allowed waiver, never mistral.
  Re-run: `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub
  BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (05:52Z) -> `pick=hold
  reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% billing read 15m
  ago; <box2> 99% billing read 15m ago]: queue the lane, spawn nothing` — matches
  the plan's section 8.

## Check 6 — R3 lane map on the row paths

- `lane-map.sh --check csi-spl-orc/src/bash/run/spl-push-master.func.sh,csi-spl-orc/src/bash/tests/spl-push-master.tst.sh,csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-review-notify.tst.sh,csi-spl-doc/doc/md/bug-round-32-plan.md,csi-spl-doc/doc/md/bug-round-32/seat-mistral.md --agent m-696`
  (05:53Z) -> exit 3, naming only
  `csi-spl-doc/doc/md/bug-round-32-plan.md owned by c-694@sat` (the planner) —
  not a row file.
- Without the plan file (the 4 row files + this seat file) -> exit 4:
  `WARN no live lane lists` them; 15 `unknown:` lanes record no files, all on
  `<box2>`: c-146, c-461, c-463, c-490, c-506, c-562, c-579, c-590, c-598, c-601,
  c-602, c-610, c-812, c-924, c-927 — exactly the 15 the plan's section 3.1
  lists. None lists a row file per the hub map. Their `<box2>` worktree diffs are
  not readable from sat — NOT RUN here; the plan's v0.2 folds c-001@`<box2>` msg
  5b9629b4 (0 hits on the 4 row files in all 15), consistent with the hub map.
- Queue re-run (05:54Z): `ENV=prd ./run -a do_spl_spawn_queue` -> `13 queued, 0
  placing` (the plan read 15 at 05:35:40Z; the queue moves, N3 below).

## Check 7 — inputs accounted

- Re-read `/var/spool-hub/dispatch/c002-next-round-candidates.md` (101 lines)
  whole, and `bug-round-31-plan.md`'s "first inputs for round 32" row on
  origin/master (`git show 8b7828a6b:... | sed -n '229p'`, 11 items), plus the
  b31 rows' R7 notes: c-682's report (`/var/spool-hub/reports/c-682.md`: PASS
  29dccf6f5, no W, N1 mention-in-path, N2 older-lane box — both within the row's
  contract); b31-02 has no R7 yet (c-689's report file is its spec 166 lane, not
  an R7), as the planner brief says.
- The b31 first-inputs row: all 11 items appear in the plan's section 4 (wip/
  branch -> row 02; done-claim `job` label — re-checked: `grep -ciE 'job
  [0-9a-f]{7}' /var/csi/csi-spl/done-claim-check/cron.log` -> 0, and 0 since
  04:13Z; AltGr picker / blog switcher Enter; `test-agent-name-shape.sh:89`;
  orc/iac suites as `<AGENT_USER>`; `download iframe` / `workspace-doc-preamble`
  sightings; `tasks`/`forward`/`multicast <hex>` forms; b29-01 N1; overlay
  mount; `<box2>`'s dashless `/tmp` trees; lease vendor order writer).
- The candidates file's "next BUG round" / "Bug-shaped" entries, each mapped:
  - rows: c-001 9d41057c (+ m-642's push, one defect) -> row 01; c-001 7717bbb1
    -> row 02.
  - served, with the sighting predating the fix (landing times read with
    `git log origin/master -1 --format='%h %cI %s' -E --grep='\(<row>-'`):
    1e0907c0/364398a4 (11-19 14:0xZ) < b22-02 `3e46a758c` 11-19 16:16Z;
    2b2ca5b1 (11-20 06:2xZ) < b27-02 `21abdb87e` 11-20 10:05Z; 501ce862 (11-20
    07:3xZ) < b28-02 `4c4e97f75` 11-20 14:32Z; da75da4e (11-20 12:3xZ) < b29-01
    `ac367b7a5` 11-20 21:16Z; b96b804a (11-20 23:3xZ) < b30-01 `9b680e7b5`
    11-21 02:17Z; 82c02da9 (11-20 18:5xZ) < b30-02 `82d1b51da` 11-21 02:50Z
    (the plan carries the knob-off caveat); d77d912f (11-21 01:1xZ) < b30-03
    `6f2a343bb` 11-21 02:59Z; 7e965718 (11-21 01:2xZ) < b31-01 `8b7828a6b`
    11-21 04:23Z; 0f130e27 and 577d03b7 as round 31's section 5 accounts them
    (b20-01, b26-01).
  - accounted as not-a-row in the plan's sections 4 and 5: AltGr (SPL-5850 N1),
    orc/iac suites as the OS user, the done-claim `job` label, the topic loop cap
    race (c-342's file, R3), the spec 181 notes, `ws-docs-head.mjs` click
    (243cff1), SPL-6107 N1, reflection rows A and B, c-655's exit gate
    (ae541e19 — the plan hands the design pick to the holder, first row of
    round 33).
- **No bug-shaped input is neither served nor accounted for.**

## Check 8 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (05:40Z) ->
  `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-696` (all parts ok/allowed).

## W defects

None.

## N notes

- N1: the plan's `34 of 37` lifetime `brief.md` count moved: `ls -d
  /var/spool-hub/*/lifetime | wc -l` -> 39, `ls /var/spool-hub/*/lifetime/brief.md
  | wc -l` -> 36 at 05:49Z (new lanes placed since 05:3xZ, incl. c-694 and
  m-696). The claim was true at the plan's time; the direction is consistent.
- N2: wip-reviewer briefs with a `Branch \`wip/\`` line and no `review/`: 16 now
  (the plan counted 11 others at 05:3xZ). More briefs, same shape; row 02's
  evidence holds.
- N3: the queue moved 15 -> 13 queued between the plan's 05:35:40Z read and my
  05:54Z read. Not a defect.
- N4: the 15 exit-4 `<box2>` lanes' worktree diffs are NOT RUN from sat (their
  worktrees are on `<box2>`); the hub lane map from my run shows they record no
  files, and the plan's v0.2 folds c-001@`<box2>` msg 5b9629b4 (0 hits on the 4
  row files in all 15). Consistent, not independently re-measured here.

---

## Panel verdict on v0.2 — PASS (2026-11-21T05:5xZ)

- Reviewed sha: `0498a1a90204e2e61ac0944043e9aa93fd0e7b74` on branch
  `review/c002-bug-round-32-planner`, named by the dispatch holder c-002@sat on
  task `dispatch-bug-r32` (msg 00cd8859, 05:46:09Z: "Finish your v0.1 review as
  asked; then read the delta `git diff 1f694cb86 0498a1a90` and sign v0.2 in the
  same seat file").
  `git ls-remote origin review/c002-bug-round-32-planner` ->
  `0498a1a90204e2e61ac0944043e9aa93fd0e7b74` (the branch head, matches).
  `git merge-base --is-ancestor 1f694cb86 0498a1a90` -> rc 0 (FF-OK);
  `git log --oneline 1f694cb86..0498a1a90` -> one commit
  (`0498a1a90 docs(b32-plan, SPL-6151): ... v0.2 ...`);
  `git diff --name-only 1f694cb86 0498a1a90` -> only
  `csi-spl-doc/doc/md/bug-round-32-plan.md`; `git diff --stat` -> 9 insertions,
  7 deletions. `git show 0498a1a90:<plan> | sha256sum` ->
  `9a1d7c94a3d0f154d81f2680fb16bb7b13d71835fdc7c8a523c7df79626a03ad`.
- Delta review (`git diff 1f694cb86 0498a1a90 -- <plan>`): 5 hunks, at lines
  ~10 (status line), ~58 (panel line), ~223 (section 6 row), ~243 (section 8),
  ~258 (consensus table) — all plan text only: the `<box2>` R3 half folded in
  (c-001@`<box2>` msg 5b9629b4: 15 exit-4 lanes, 0 hits on the 4 row files; b32
  free on both boxes), the review history and the consensus table. The
  `## 3. The rows` .. `### 3.1` range is IDENTICAL between v0.1 and v0.2
  (`diff <(git show 1f694cb86:<plan> | sed -n '/^## 3\. The rows/,/^### 3\.1/p')
  <(git show 0498a1a90:<plan> | sed -n ...)` -> no output): no row, site, red
  control or fix scope changed; the `One sha` base line is unchanged
  (`8b7828a6b`).
- Checks re-run on the v0.2 head (05:55Z): check 1 -> 0 `(b32-` commits since W;
  `git ls-remote origin | grep -E 'b32-[0-9]{2}|bug-round-32'` ->
  `review/c002-bug-round-32-planner` (0498a1a90) and this seat's
  `review/c002-bug-round-32-mistral-seat` (e301c5feb), both expected; briefs ->
  the two expected. Check 2 -> `git diff --name-only 8b7828a6b origin/master --
  <the four row files>` still empty (no drift). Check 3 -> rc01/rc02 not re-run
  (the delta touches no code; the base sha they run on is unchanged at
  `8b7828a6b`, and my n=3 runs above stand). Check 6 -> lane-map re-run at 05:53Z
  (above): exit 3 names only the planner's plan file; exit 4 lists the same 15
  `unknown:` `<box2>` lanes, none a row file — matching the v0.2 delta's folded
  answer.
- Verdict on v0.2: **PASS**, no W. The delta changes no row, no site, no red
  control; it only folds in the other box's R3 half and the review history,
  which this seat's own lane-map run confirms (the same 15 unknowns).
