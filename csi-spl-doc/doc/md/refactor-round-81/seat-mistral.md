# Refactor round 81 — panel seat mistral (m-723@<box>)

Issue: SPL-6161 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-81-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/refactor-round-81-plan.md` on branch
`review/c002-refactor-round-81-planner`, at the v0.1 sha the dispatch holder named
(spool msg f95d7fc5-651f-4559-995a-527a1e634211, 2026-11-21T07:03Z, task
`dispatch-refactor-r81`): `7dbfe9f783ffcbcdb5a3738a9d01900186282eee` (1 commit on
`5083f4cf9`, 1 file +378). Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to
3 and 5 (3.2 the panel signs the plan sha; 5.1 1 to 3 rows; 5.3 numbering and window).
Form: `csi-spl-doc/doc/md/refactor-round-79-plan.md` (on origin/master). Measured base
`5083f4cf9` (the plan's own "One sha"); `origin/master` at my reads `dc435a7128`, then
`0e9efb6c2` (both after the plan's base; row files show no drift, check 2).

## Verdict

**PASS** on `7dbfe9f783ffcbcdb5a3738a9d01900186282eee`. 2 rows (5.1: aim 2, at most 3),
both `refactor`, vendor claude, kind `simple_coding`, batch 1, files disjoint. No W
defect. Notes N1-N4 below.

### 1. Slug r81 unused since the plan's `Window: W=`

W = `2026-11-21T07:52:49+02:00`, re-derived by me: `git log origin/master -1 --format='%H
%cI' -E --grep='^docs\(r80-plan'` at my read printed `dc435a7128... 2026-11-21T09:06:40+02:00`
(the r80 close record, landed after the plan's 06:52Z read); the plan's W comes from
`d02aea0f88896cde76c1be07c3c43f6723505466 2026-11-21T07:52:49+02:00` — verified with
`git log -1 --format='%H %cI' d02aea0f8`, matches the plan's 1.1 exactly. Per rulebook 5.3
the recorded W is the one every later read uses.

- `git log origin/master --since="$W" --oneline -E --grep='\(r81-' | wc -l` -> **0**; the
  same grep over all history (no `--since`) -> **0**. Control: `(r80-` since W -> **4**
  lines (`0e9efb6c2` is b31-02, not r80; the r80 ones: `dc435a712`, `5083f4cf9`,
  `f886bfcdd`, `d02aea0f8`), so the read sees a used id. (The plan read 3 at 06:52:35Z;
  the r80 close record `dc435a712` landed 07:06:40Z after it — N3.)
- `git ls-remote origin | grep -E 'r81-[0-9]{2}|refactor-round-81'` -> one line:
  `7dbfe9f783ffcbcdb5a3738a9d01900186282eee  refs/heads/review/c002-refactor-round-81-planner`
  (the planner's, expected; my seat branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r81-[0-9]{2}|refactor-round-81'` -> exactly
  the 2 expected files (`c002-refactor-round-81-planner.md`,
  `c002-refactor-round-81-mistral-panel-seat.md`); `ls /var/spool-hub/spawn-remote/briefs |
  grep -E 'r81-[0-9]{2}|refactor-round-81'` -> none (rc 1).
- `git ls-tree 5083f4cf9 csi-spl-doc/doc/md | grep -c refactor-round-81` -> **0**, so the
  plain plan name is right (rulebook 5.3 "Files").

### 2. Every site file:line of every row exists on the base sha and on origin/master

Every cited line checked with `git show <sha>:<file> | sed -n <N>p` on `5083f4cf9` and on
`origin/master` (`0e9efb6c2` at the final re-check): all SAME, none empty.

- row 01: `csi-spl-orc/src/bash/scripts/spl-desk-reply.sh:7,9,19,22,39,52,239` -> e.g. `:9` ->
  `#                     [--to <HUM-id>] [--task <uuid>] [--kind note|result|reject|blocker|msg]`,
  `:19` -> `#   DESK_KIND   note | result | reject | blocker | msg (default: note)`,
  `:239` -> `    --kind "$DESK_KIND" \`;
  `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-kinds.sh:46,55` -> `:46` ->
  `has "2. the usage line names SPOOL_KINDS" "--kind $SPOOL_KINDS" "$(bash "$SS" --help 2>&1)"`,
  `:55` -> `t_done`;
  input sites: `csi-spl-orc/src/bash/run/spl-desk-reply.func.sh:147,148,550` -> `:550` ->
  `  spool_kind_in "result|reject|blocker|msg|$SPOOL_NOTE_KINDS" "$kind" || { do_log "FATAL DESK_KIND must be res...`,
  `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:138,139` ->
  `export SPOOL_KINDS='task|result|note|reject|blocker|msg|feature|bug|alert|question|idea|decision|docs'`
  (13 kinds) and `export SPOOL_NOTE_KINDS='note|feature|bug|alert|question|idea|decision|docs'`
  (8) — the reply action's set is 4+8 = **12**, not `task`;
  `csi-spl-orc/src/bash/tests/enc-dirs-untouched.tst.sh:50` lists the script.
- row 02: `csi-spl-orc/src/bash/run/spl-self-host-up.func.sh:283,316,317,320,321` -> `:283` ->
  `  SPOOL_CLOUD_PROVIDER=none do_spl_cloud_dispatch hub_deploy roll "$dir" || return 1`,
  `:317` -> `  local dir="${1:?do_hub_deploy_roll_none <dir>}"`;
  `csi-spl-orc/src/bash/tests/check-hub-deploy.tst.sh:198,208,234,236,239,241` -> `:198` ->
  `in_none() { # [VAR=value ...] -- <snippet>; stdout -> $T/nout, stderr -> $T/nerr`,
  `:236`/`:239` the two `hub_deploy roll` cases, `:241` the gcp-roll pass line.

Drift: `git diff --name-only 5083f4cf9 origin/master -- <the 4 row files>` -> empty (rc 0),
re-checked at `0e9efb6c2`; `git log origin/master --since="$W" -- <the 4 row paths> | wc -l`
-> **0**. Line counts on base match the plan: `spl-desk-reply.sh` 280,
`test-spool-kinds.sh` 55, `spl-self-host-up.func.sh` 321, `check-hub-deploy.tst.sh` 248.
Plan 1.2/1.3/1.4 counts re-run on base: `git grep -lE 'spl-self-host-up|do_spl_self_host_up|hub_deploy|roll_none'
5083f4cf9 -- '*tests/*'` -> the same **10 files** the plan lists;
`git grep -nE 'local [A-Za-z_]+="?\$\{[0-9]:\?' 5083f4cf9` over iac/orc/utl lib + `src/bash/run`
-> **30 lines in 12 files** (matches 1.2);
`git grep -nE 'hub_deploy roll|roll_none' 5083f4cf9 -- csi-spl-orc csi-spl-iac` -> the one
caller `:283`, the definition `:316-317`, headers `:308,:313`, the test `:236,:239`,
`run-loader-convention.tst.sh:29`;
`git grep -n 'spl-desk-reply\.sh' 5083f4cf9 -- csi-spl-doc | grep -v round- | wc -l` -> **9**;
`git grep -nE 'note\|result\|reject\|blocker\|msg[^|]' 5083f4cf9 -- csi-spl-doc | grep -v round- | wc -l`
-> **0**; `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
-> 0; `git log -1 --format=%B f886bfcdd | grep -c '^review: '` -> 1.

### 3. Red controls, run on the plan's base in a scratch copy

Scratch: `git archive 5083f4cf9` extracted to a `mktemp -d` dir under /tmp; runs as the push
user with `SPOOL_TEST=1` (the guard `spool_test_guard` in `spool-env.inc.sh` refuses the
live spool root under it); `test-spool-kinds.sh` runs under `t_sandbox` (throwaway
SPOOL_ROOT, private tmux socket under its own tmp dir — lib.inc.sh header: "Nothing here
touches the real spool root or the box user's tmux"); `check-hub-deploy.tst.sh` stubs
docker and gcloud on its own PATH (`$T/nstub`) and records calls to its own logs. All
writes went under the scratch dir and the tests' own mktemp dirs; nothing touched live
state. sha256sums at base (`git show 5083f4cf9:<file> | sha256sum`):

- `56a2bf8f6697269d7c7b5b9c85840bb7fc50a28f68c5d4edb49d3d0560c75a2c  csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-kinds.sh`
- `d6bac55cccef49154fb17c97545469a17c700f9b9c7a79edac890c874e61c578  csi-spl-orc/src/bash/tests/check-hub-deploy.tst.sh`
- `958de6bcd6340180394d1af2aa7ada69e4502c8a23999b1c8e68e29701dabe64  csi-spl-orc/src/bash/scripts/spl-desk-reply.sh`
- `7dab48b7c4e8a5b1ceb1837b56fe469592ec2b3c2e59fc26d4c51bc5ccd62e2c  csi-spl-orc/src/bash/run/spl-self-host-up.func.sh`

Before (unmodified base, n=1): `SPOOL_TEST=1 bash .../test-spool-kinds.sh` -> rc **0**,
last line `-- test-spool-kinds.sh: 43 passed, 0 failed`; `SPOOL_TEST=1 bash
.../check-hub-deploy.tst.sh` -> rc **0**, last line `PASS: all check-hub-deploy
assertions`, 54 pass 0 fail. Matches the plan's 1.5 "before" column.

- **Row 01, red control (plan 1.3's section 4 inserted before `t_done`, site
  unmodified):** `SPOOL_TEST=1 bash .../test-spool-kinds.sh` -> rc **1**, last line
  `-- test-spool-kinds.sh: 43 passed, 2 failed`; both FAIL lines:
  `FAIL - 4. spl-desk-reply.sh usage --kind lists the reply kinds (want 'alert blocker bug decision docs feature idea msg note question reject result', got 'blocker msg note reject result')`
  and the same for the `DESK_KIND` line. Fails for exactly the plan's reason (the usage
  lists 5 kinds, the action takes 12), not for an environment reason. **Green** (site
  `:9`,`:19` changed to the 12 kinds, same scratch): rc **0**, last line
  `-- test-spool-kinds.sh: 45 passed, 0 failed`.
- **Row 02, red control (plan 1.4's case inserted after `:241`, site unmodified):**
  `SPOOL_TEST=1 bash .../check-hub-deploy.tst.sh` -> rc **1**, last line `FAILED: 2`; both
  FAIL lines: `FAIL: none roll '""': out '' err '.../spl-self-host-up.func.sh: line 317: 1: do_hub_deploy_roll_none <dir>' stub ''`
  and the same for the missing-argument form — no `rc=` line, nothing run. Fails for
  exactly the plan's reason. **Green** (site `:317` takes 1.4's shape, same scratch): rc
  **0**, last line `PASS: all check-hub-deploy assertions`, 56 pass lines, the 2 new
  `returns 1, says why, runs nothing` passes present.

### 4. Equivalence of each row

- **Row 01:** `diff -U0` of the site before/after the row's shape -> only `:9` and `:19`
  change; `grep -E '^[-+][^-+#]'` over the diff -> **0** non-comment lines. Comment text
  only, so the launcher behaves as before (same exit codes, same `--kind` pass-through at
  `:239`). The control would catch a difference: section 4 compares the `--help` kind sets
  against the action's own check at `spl-desk-reply.func.sh:550` — RED on the parent (2
  FAILs above), GREEN on the head.
- **Row 02:** only `:317` changes; with a non-empty argument the guard passes and
  `local dir="$1"` is the old assignment, so every real call behaves as before. The one
  caller (`spl-self-host-up.func.sh:283`, `git grep -nE 'hub_deploy roll|roll_none'` ->
  that call, the definition, headers, the test) passes `"$dir"` and has `|| return 1`,
  which on an empty argument is never reached today. Measured on the base site (n=1 per
  form, `bash -c 'do_log(){ echo "$*" >&2; }; source <file>; do_hub_deploy_roll_none <args>; echo "rc=$?"'`):
  `""` and no argument each print `line 317: 1: do_hub_deploy_roll_none <dir>` and **no
  `rc=` line** — the shell exits, matching the plan's 1.4. The control catches the
  difference: the new case RED on the parent, GREEN on the head (check 3).

### 5. Row fields (R2, R7, R1)

Each row has a control that fails today and passes after (check 3), a test list (row 01:
`test-spool-kinds.sh`, `desk-root-readers.tst.sh`, `watcher-read-only.tst.sh`,
`enc-dirs-untouched.tst.sh`, `bash-cleancode.tst.sh`, `do_check_pre_push`; row 02: the 10
test files of 1.4's grep, `bash-cleancode.tst.sh`, `do_check_pre_push`), vendor **claude**,
kind **simple_coding**, batch **1**. No mistral coding or testing row. R7 reviewer per row:
a fresh **claude waiver seat** (1a7c70da) — cross-vendor or waiver, never mistral (plan
section 4; the box pick printed a load pick with no grok quota line, and the brief's read
is grok on hold). R1: `comm -12` of row 01's file list (`spl-desk-reply.sh`,
`test-spool-kinds.sh`) and row 02's (`spl-self-host-up.func.sh`, `check-hub-deploy.tst.sh`)
-> **0** shared files; 4 distinct row paths.

### 6. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/scripts/spl-desk-reply.sh,csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-kinds.sh,csi-spl-orc/src/bash/run/spl-self-host-up.func.sh,csi-spl-orc/src/bash/tests/check-hub-deploy.tst.sh --agent m-723`
-> **exit 4**, 17 `unknown:` lanes, all on the other box, each "has no files recorded; ask
it or read its brief": c-146, c-461 (s123-p05), c-463, c-490 (s033-t025-t027), c-506, c-562,
c-579 (wui qto), c-598 (s123-l2), c-601, c-602, c-610 (wui calendar), c-634 (wui notes),
c-649 (b32-01 push-master), c-651 (r80-02 merged-cnf), c-812, c-924, c-927 (all rotate or
other slugs). Per path individually: exit 4 on all 4, no exit 3 — no live lane lists a row
path, and no unknown lane's slug names one (c-651's files are the iac cnf merge, landed
`5083f4cf9`). Spawn queue at my read (`./run -a do_spl_spawn_queue`): 13 queued, 0 placing
(spec 184 held on SPL-6036, s123 L2b-L7 held, s033 T026 held) — none names a row path.
Briefs naming a row basename over the 120 newest in `/var/spool-hub/dispatch/briefs`:
exactly the r81 planner's, the r80 planner's (landed round) and
`c003-s033-t024-claude-waiver-reviewer.md` (SPL-6107's R7, landed). The two remote branches
the plan names as touching `test-spool-kinds.sh` (`review/c002-bug-round-30-mistral-seat`,
`review/c002-s033-t024-cli-orc-kinds`): `git diff <b> origin/master -- <f> | grep -c
'^[-+][^-+]'` -> 0 on both. The holder's re-check before placing is the one that counts
(plan 2.2 says the same).

### 7. Inputs accounted for

Plan section 7 against `/var/spool-hub/dispatch/c002-next-round-candidates.md`
(refactor-shaped items only, 101 lines) and r80 section 7 — every refactor-shaped input is
served or accounted for:

- served by a row: "[refactor] SPL-6107 N1" `spl-desk-reply.sh:9,19` -> **row 01**
  (re-measured: `SPOOL_KINDS` 13 at `spool-env.inc.sh:138`, the reply action takes 12 at
  `spl-desk-reply.func.sh:550`, `task` is not one).
- accounted in section 7 with reasons: the other `local x="${N:?}"` lines (re-counted on
  base: 30 in 12 files; multi-copy files named; `tf-each-target` set -e; cost files beside
  the held s123 lanes; first candidate for r82 named: `gcp-account-pin.func.sh` iac+orc),
  `spl-spawn-place-argmax.tst.sh` s9, spec 182 L2, `ws-docs-head.mjs`, spec 181 B10 N1/N2/N4,
  the desk hop's env forwarding (SPL-5824 W1, bug-shaped), spec 011 (15 open tasks,
  `grep -cE '^\s*- \[ \]' tasks.md` -> 15; 0 commits since W).
- served earlier, re-verified by the plan's own citations: watchdog/rotate `/var` literals,
  `reverse-tunnel-cron.sh:23`, agent-boot-restore dir, uplink-probe wording, wf10 comment
  (r79-01), tf-log-mask `${1:?}` (r78-02).
- Nothing refactor-shaped is left unserved and unaccounted. One borderline item: the
  candidates file's doc literal `installation-and-configuration-guide.md:594`
  (reverse-tunnel state dir) is not re-listed in r81 section 7; r80 section 7 already ruled
  it "a Qto export: an ask to the holder", so it is accounted by that ruling (N4).
- Behaviour-change scan: row 01 changes no exit code, message, path or default (0
  non-comment diff lines, check 4). Row 02 changes the empty/missing-argument path only:
  shell exit -> `return 1` plus a usage line on stderr — disclosed in plan 1.4, pinned by
  the row's control, no caller takes that path (one caller, `:283`, `|| return 1`), same
  shape as landed r80-02 `5083f4cf9`. See N1.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean
over the tracked tree of <worktree>`, exit 0 (run again after this file was added: clean).

## Defects

None. No W.

## Notes

- **N1:** row 02 does change an exit behaviour on the empty/missing-argument path: on base
  `${1:?}` exits the caller's shell (measured: no `rc=` line), the row returns 1 with a
  usage line. Confined to a path no caller takes (1 caller, `spl-self-host-up.func.sh:283`,
  `|| return 1`), it is the fail-safe developer guide 2.4.3 mandates, disclosed in plan
  1.4 and pinned by the row's control; r80-02 `5083f4cf9` set the same precedent. Recorded,
  not a W.
- **N2:** two line-citation imprecisions in the plan, neither touching a row site: 1.3
  says `usage()` is `:25-28`, on base it is `:26-29` (line 25 is blank; the usage block
  `:7-22` and the row sites `:9`,`:19` match exactly); 1.3's `git grep -lE
  'spl-desk-reply\.sh' -- '*test*'` -> 4 files does not reproduce with that command (it
  returns 2: `desk-root-readers.tst.sh`, `enc-dirs-untouched.tst.sh`;
  `watcher-read-only.tst.sh:127` names `spl-desk-reply.func.sh`, `orc-shard-weights.txt:430`
  names `spl-desk-reply-ref.tst.sh`). The section 5 gate list still names the right files.
- **N3:** live-state counts moved between the plan's read and mine: lane map 16 -> 17
  `unknown:` lanes (exit 4 both times, none on a row path by slug); spawn queue 15 -> 13
  queued; the `(r80-` since-W control 3 -> 4 lines (`dc435a712`, the r80 close record,
  landed 07:06:40Z); remote branches in 24 h 78 -> 86. All carry their own times; the
  holder's re-check before placing is the one that counts.
- **N4:** `origin/master` moved past the plan's base during my review (`dc435a7128` docs,
  `0e9efb6c2` b31-02 fix); `git diff --name-only 5083f4cf9 origin/master -- <the 4 row
  files>` -> empty at both reads, so no row site drifted. The candidates file's doc-literal
  item (`installation-and-configuration-guide.md:594`) is accounted by r80 section 7's
  "ask to the holder" ruling, not re-listed in r81 section 7.

## Verdict v1.0

**PASS** on `864f7ff17f842cd9b60d8b3067138e3dec2bc6cf` — plan v1.0, landed on
`origin/master` by the editor c-722 (named on task `dispatch-refactor-r81`, c-722 msg
2026-11-21T07:20:27Z "r81 plan LANDED (c-722, SPL-6161): v1.0 is master
864f7ff17f842cd9b60d8b3067138e3dec2bc6cf"). Found at rotation 20261121T0751Z: the
editor's v1.0 was on the task and on `origin/master`, not on the planner branch (that
branch still reads `7dbfe9f78`). Re-verified this session, each with its command:

- `git branch -r --contains 864f7ff17f842cd9b60d8b3067138e3dec2bc6cf` -> `origin/master`
  (plus `origin/review/r81-01`, `origin/review/r81-02` and two unrelated review branches
  that forked from it); `git log -1 --format='%H %cI %s' 864f7ff17` ->
  `864f7ff17f842cd9b60d8b3067138e3dec2bc6cf 2026-11-21T09:19:19+02:00 docs(r81-plan,
  SPL-6161): refactor round 81 plan v1.0, panel m-723 mistral PASS on v0.1 7dbfe9f78
  with no W, ... the seat file 85ef799a7 folded in`.
- Plan delta v0.1 -> v1.0: `git diff 7dbfe9f78 864f7ff17 --
  csi-spl-doc/doc/md/refactor-round-81-plan.md | grep -cE '^[-+][^-+]'` -> **49** changed
  lines, all in the Status line, section 4's waiver note, section 8's panel record, and
  one test-list citation (1.3's `git grep -lE 'spl-desk-reply\.sh' -- '*test*'` 4 -> 2
  files, N2's correction; row 01's gates keep `watcher-read-only.tst.sh` as a neighbour).
  Row sites, row 02's table line, vendor, kind and batch are unchanged — the only row-table
  edit is that Tests cell.
- Row files: `git diff --name-only 7dbfe9f78 864f7ff17 -- <the 4 row files>` -> empty
  (rc 0), so no row site moved between v0.1 and v1.0.
- Seat file folded in byte-identical: `git diff 85ef799a7 864f7ff17 --
  csi-spl-doc/doc/md/refactor-round-81/seat-mistral.md | wc -l` -> **0**.
- Slug and branches re-read: `git ls-remote origin | grep -E 'r81-[0-9]{2}|refactor-round-81'`
  -> my seat branch `85ef799a7`, the planner's `7dbfe9f78`, `review/r81-02 1a9c457fe6`
  (the r81-02 row lane's, expected; r81-01 landed on master as `3174e591a3` and its branch
  is gone). `ls /var/spool-hub/dispatch/briefs | grep -E 'r81-[0-9]{2}|refactor-round-81'`
  -> the 2 round briefs + 4 row/reviewer briefs, all expected.
- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean
  over the tracked tree`, exit 0.

No W on v1.0. The v0.1 PASS carries: v1.0 changes no row. Signed as a second commit on
`review/c002-refactor-round-81-mistral-seat` and re-reported in the `review:` form to the
planner c-722 and the dispatch lease holder on task `dispatch-refactor-r81`. Waiting on: a
message on the task whose body starts with ACCEPTED (then `/exit-clean`).

## State history

- 2026-11-21T07:1xZ commit on `review/c002-refactor-round-81-mistral-seat`: full review of
  `7dbfe9f783ffcbcdb5a3738a9d01900186282eee` (checks 1-8 above), verdict PASS, notes N1-N4.
- 2026-11-21T07:5xZ commit on `review/c002-refactor-round-81-mistral-seat` (rotation
  20261121T0751Z): signs v1.0 `864f7ff17f842cd9b60d8b3067138e3dec2bc6cf` — PASS carries,
  no row changed; the editor's v1.0 was found on task `dispatch-refactor-r81`, not on the
  planner branch.
- rotation at 08:51Z (note 478222f4, task `lane-rotate-m-723`): state — v0.1 PASS on
  `7dbfe9f78` delivered (`85ef799a7`), v1.0 `864f7ff17` signed (`24a8020a0`, on this review
  branch only, not master: `git merge-base --is-ancestor 24a8020a0 origin/master` rc 1),
  reported on task `dispatch-refactor-r81` to planner c-722 (msg `a801be62`) and lease
  holder c-002@sat (msg `9c237038`); c-002 confirmed receipt and the checks (msg
  `c1e6adb2`). Nothing unpushed. Awaiting a message on the task whose body starts with
  ACCEPTED (then `/exit-clean`).

Seed STEP 0: read `csi-spl-doc/doc/md/developer-guide.md`, then
`cd csi-spl-orc && sudo -u <push user> env AGENT_ID=m-723 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack`
-> `ACK m-723 read developer-guide.md blob 8b1916cdc5d75c52cc4b3248babef398acf1366b`.
Read whole this session: `CLAUDE.md`, `csi-spl-doc/doc/help/how-to-post.md`,
`csi-spl-doc/doc/md/rounds-rulebook.md` (sections 1-5), the plan at `7dbfe9f783` (via
`git show <sha>:csi-spl-doc/doc/md/refactor-round-81-plan.md`), `refactor-round-79-plan.md`
and `refactor-round-80-plan.md` + `refactor-round-80/seat-mistral.md` (origin/master, the
form), `/var/spool-hub/dispatch/c002-next-round-candidates.md`, both r81 briefs, and the
row site and test files at `5083f4cf9` via `git show` / `git grep`.
