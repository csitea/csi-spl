# Refactor round 79 — panel seat mistral (m-620@<box>)

Issue: SPL-6126 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-79-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/refactor-round-79-plan.md` on branch
`review/c002-refactor-round-79-planner`, at the v0.1 sha the dispatch holder named
(spool msg dea620d4, 2026-11-21T02:26:04Z, task `dispatch-refactor-r79`):
`043b1af86df5ce2386c5f7e2d0d2188a36f6a321`. Rules:
`csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2 the panel signs the
plan sha; 5.1 1 to 3 rows; 5.3 numbering and window). Form:
`csi-spl-doc/doc/md/refactor-round-78-plan.md` (on origin/master).

## Verdict

**PASS** on `043b1af86df5ce2386c5f7e2d0d2188a36f6a321` — plan v0.1, branch
`review/c002-refactor-round-79-planner` (one commit, parent `3f33e9dab`, +369 lines, one
file), measured base `d6fc241f9` (`origin/master` at the planner's read,
2026-11-21T03:03:03+01:00). Defects W1..: none. Notes N1..N3 below.

### 1. Slug r79 unused since the plan's Window W

- W read: `git log origin/master -1 --format=%cI -E --grep='^docs\(r78-plan'` ->
  `12c6b0a9b7097b846f2411940c3411451769439d 2026-11-21T02:32:24+01:00 docs(r78-plan, SPL-6109): ...`
  — matches the plan's `Window: W=2026-11-21T02:32:24+01:00`.
- `git log origin/master --since="$W" --oneline -E --grep='\(r79-' | wc -l` -> `0`; the
  same grep over all history (no `--since`) -> `0`.
- `git ls-remote origin | grep -E 'r79-[0-9]{2}|refactor-round-79'` -> exactly 1 head:
  `043b1af86df5ce2386c5f7e2d0d2188a36f6a321 refs/heads/review/c002-refactor-round-79-planner`
  (the planner's own branch; this seat's branch is pushed after this read). No `r79-NN`
  row head, nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r79-[0-9]{2}|refactor-round-79'` ->
  `c002-refactor-round-79-mistral-panel-seat.md`, `c002-refactor-round-79-planner.md`
  (this seat's and the planner's; expected).
- Control: `--grep='\(r78-'` since W -> 1 line (`12c6b0a9b`): the read sees a used id.
- `git ls-tree d6fc241f9 csi-spl-doc/doc/md/ | grep -c refactor-round-79` -> `0` (the
  plan takes the plain name, 5.3 "Files").
- Base on trunk: `git merge-base --is-ancestor d6fc241f99ca2bf96d8894317162ed996dfb411e origin/master`
  -> rc 0.

### 2. Every site file:line of every row exists on the base sha and on origin/master

26 cited lines checked with `git show <sha>:<file> | sed -n <N>p` on `d6fc241f9` and on
`origin/master` (2026-11-21T02:3xZ): 26 of 26 identical, none empty. Row sites:

- `.github/workflows/10_ci-quality.yml`: `:146` -> `  CI_GO_CACHE_SAVE_MAX_MB: "4000"`;
  `:439-445` -> the comment block quoted in the plan, `:445` ->
  `      # and it also covers the downloaded archive the restore unpacks.`; `:446` ->
  `      - name: Disk check, report only (short of the need plus the Go cache?)`; `:451`
  -> `        run: CI_DISK_NEED_GB=$((CI_DISK_NEED_GB + (CI_GO_CACHE_SAVE_MAX_MB + 1023) / 1024)) bash csi-spl-orc/src/bash/scripts/ci-disk-guard.sh`.
- `csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh`: `:39` usage line, `:90` ->
  `    --print-crontab) PRINT=1; shift ;;`, `:100` ->
  `ORC="$(cd "$(dirname "$SELF")/../../.." && pwd)"`, `:175` worktree refusal, `:182` ->
  `if [ "$PRINT" = 1 ]; then`, `:185` -> `  ORG_APP="$(basename "$ORC")"; ORG_APP="${ORG_APP%-orc}"`,
  `:187-188` the printf head, `:189` ->
  `    "${DESK_CRON_LOG_DIR:-/var/${ORG_APP%%-*}/$ORG_APP/desk-reconcile}" "$ORG_APP"`.
- `csi-spl-orc/src/bash/tests/no-literal-paths-spelled.baseline:12` ->
  `1 csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh`.
- `csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh:270-272` -> the `bad`/`n_sd` greps
  and `[[ -z "$bad" && "$n_sd" -ge 5 ]] && pass "... ($n_sd paths, desk-reconcile included) ..."`.
- `csi-spl-orc/src/bash/tests/desk-install-service-user.tst.sh:144` case-9 header, `:148`
  -> `cp "$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh" "$CO/lib/bash/funcs/"`, `:155`
  the case-9 assertion.

Drift: `git diff --name-only d6fc241f9 origin/master -- <the 5 row files>` -> empty
(rc 0); `git log origin/master --since="$W" -- <the 5 row paths> | wc -l` -> `0`.
Line counts on base: wf10 2056, desk-reconcile-cron.sh 567, satellite-ansible.tst.sh 535,
desk-install-service-user.tst.sh 174 — all match the plan.

### 3. Red controls, run on the plan's base in a scratch copy

Scratch copy: `git worktree add --detach /tmp/r79-scratch d6fc241f9` (removed after the
runs). sha256sums of the control files at base (`git show d6fc241f9:<file> | sha256sum`):

- `5d69e1853c81bea56a56be2fc16f10ffb2d24a6c120fbdb1bb98bd0068c9a5cf  csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh`
- `7145ccbbb451cb5ee2dbef0239933d8276b716268f00fafcc1241c3d9ec322128  csi-spl-orc/src/bash/tests/desk-install-service-user.tst.sh`
- `92668cb4da9643639dff076dfd63e6fe50248c583ad619031cc119213db7bd97  csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh`
- `cfdb3106c19eef92648bcec3de3972318c75007a0f52c90fff06e09aa698156c  csi-spl-orc/src/bash/tests/no-literal-paths-spelled.baseline`
- `8a7e9704b93ff1e92b35dcd34c3ba04ef5608972cbdab341af8c6987bee67667  .github/workflows/10_ci-quality.yml`
- `cf62365076e38654b73f210410d4cd7e1f0976d44e5d6b934ef3d16585be7b36  csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh`

- **Row 01 (grep-count + comment-only diff):** `grep -c 'it also covers the downloaded archive' .github/workflows/10_ci-quality.yml`
  in the scratch -> `1` (rc 0) on base. After applying the plan's 1.3 shape to `:444-445`
  in the scratch: count -> `0` (grep rc 1);
  `git diff -U0 -- .github/workflows/10_ci-quality.yml | grep -E '^[+-] ' | grep -vcE '^[+-]\s*#'` -> `0`
  (comment lines only). `actionlint .github/workflows/10_ci-quality.yml` base vs after:
  rc 1 both, 8 lines both, the same two findings (SC2015 at :969, SC2001 at :1765), line
  numbers +1 after because the comment block grows by one line — same findings, no new
  one. Fails for the plan's reason (the overstating clause is present today), and the
  run touches no live state (a comment edit in a scratch worktree).
- **Row 02, control A (the new case on the parent's script):**
  `env -u DESK_CRON_LOG_DIR SPOOL_TEST=1 SPOOL_BOX_ENV=/tmp/r79-no-box.env bash csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh --print-crontab`
  in the scratch -> rc 0, one stdout line
  `*/5 * * * * ENV=dev TENANT_ID=t1 /tmp/r79-scratch/csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh >> /var/csi/csi-spl/desk-reconcile/cron.out 2>&1 # csi-spl:desk-reconcile`,
  stderr empty; `git status --porcelain | wc -l` after the run -> `0`: `--print-crontab`
  writes nothing, so the red run touches no live path. A case asserting the derived
  `$SPL_VAR_APP_DIR` form FAILs on this output (the printed dir is the hand form).
- **Row 02, control B (satellite-ansible floor):**
  `SPOOL_TEST=1 bash csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh` on the
  unmodified base -> rc 0, 96 pass lines, last line `PASS: all satellite-ansible.tst.sh assertions`,
  line 55 `PASS: every state dir the actions write (5 paths, desk-reconcile included) is under /var/<org>/<org>-<app>`.
  After applying the row's shape to the script in the scratch (old floor kept): the
  `n_sd` grep -> `4`; suite rc 1, `FAIL: state dirs outside /var/<org>/<org>-<app>: ...`
  at `:272`, last line `FAIL: 1 assertion(s) in satellite-ansible.tst.sh`. With the
  floor moved to `-ge 4` (the row's `:272` change): rc 0, `... (4 paths) ...` PASS, last
  line `PASS: all satellite-ansible.tst.sh assertions`. Red for the plan's reason
  (`n_sd` 5 -> 4 against floor `-ge 5`), green after the floor moves; the suite runs
  under `SPOOL_TEST=1` and writes only its own temp dir.
- Suites on the unmodified base (green today, matching the plan's 1.5 table):
  `ci-hub-pg-disk.tst.sh` rc 0, 5 pass, last `PASS: all ci-hub-pg-disk.tst.sh assertions`;
  `ci-disk-guard.tst.sh` rc 0, 17 pass; `no-literal-paths.tst.sh` rc 0, 15 pass, last
  `ALL PASS`; `desk-install-service-user.tst.sh` rc 0, 18 pass, last
  `desk-install-service-user: 0 failure(s)`.

### 4. Equivalence of each row

- **Row 01:** `:439-451` read on base — comment lines plus the step name `:446` and the
  `run:` `:451`; the shape changes only the `:444-445` comment text. No test holds a
  30-character string of `:439-445` outside `csi-spl-doc`: 9 phrases via
  `git grep -lF <phrase> d6fc241f9 -- . ':!csi-spl-doc'` -> only wf10 itself, each.
  Tests reading wf10: `git grep -lE '10_ci-quality' d6fc241f9 -- '*tests/*' | wc -l` ->
  `41`. Arithmetic re-derived: `echo $(( (4000 + 1023) / 1024 ))` -> `4` (GiB margin);
  `echo $(( 4*1024 - 4000 ))` -> `96` (MiB left at the cap); the cap
  `CI_GO_CACHE_SAVE_MAX_MB: "4000"` at `:146` is read against `du -sm` at
  `csi-spl-orc/src/bash/scripts/ci-cache-save-cap.sh:31`. Behaviour: no step, `env`,
  `if:` or `run:` line changes (comment-only diff count 0); actionlint findings
  unchanged. The control catches a difference: grep count 1 -> 0 and the comment-only
  diff count.
- **Row 02:** `:182-200` read on base — the `PRINT=1` block prints one line and
  `exit 0` at `:199`; it writes nothing. The shape adds the `spl_var_app_subdir`
  derivation inside the `PRINT=1` block only; the tick path never reads the dir.
  Same-dir proof on this box's 3 trees (main checkout, desk-cron checkout, this
  worktree), hand form vs `. spl-run-paths.func.sh && spl_var_app_subdir d desk-reconcile`
  under `env -i PATH=/usr/bin:/bin`: **3 of 3 EQUAL** (`/var/<org>/<org>-<app>/desk-reconcile`).
  With `DESK_CRON_LOG_DIR` set, the after-shape output is byte-identical to the parent's
  (`diff` rc 0); with it unset, both print the same dir on this box's layout. Tests
  naming the script: `git grep -lE 'desk-reconcile-cron' d6fc241f9 -- '*tests/*.sh' | wc -l`
  -> `16`. Spelled baseline on base: `awk '!/^#/{s+=$1; f++} END{print s" lines in "f" files"}'`
  -> `18 lines in 16 files`; `:12` is the desk-reconcile-cron.sh entry; the row drops it
  -> 17 in 15. `n_sd` on base: `git grep -hoE '/var/(\$\{?[A-Za-z_%*-]+\}?|csi)/[^ "]*(desk-reconcile|unanswered-sweep|weekly-scan|backup|tenants)' d6fc241f9 -- csi-spl-orc/src/bash csi-spl-iac/src/bash | sort -u | wc -l`
  -> `5` (desk-reconcile, unanswered-sweep, weekly-scan, backup, tenants forms). The
  control catches a difference: the new case (hand form on the parent) and the satellite
  floor (red on head with the old floor, green with `-ge 4`).

### 5. Row fields: R2 control, test list, vendor, kind, batch, R7 reviewer, R1

- Row 01: control = grep count 1 -> 0 plus comment-only diff count 0 (fails today: the
  clause is present; passes after); tests `ci-hub-pg-disk.tst.sh`, `ci-disk-guard.tst.sh`
  (of the 41 wf10 readers), R9's two runs, `do_check_pre_push`; vendor `claude`, kind
  `simple_coding`, batch 1.
- Row 02: controls = the new case red on the parent's script and the satellite floor
  red on head with the old floor; tests the 16 files of the grep,
  `no-literal-paths.tst.sh`, `satellite-ansible.tst.sh`, `bash-cleancode.tst.sh`,
  `do_check_pre_push`; vendor `claude`, kind `simple_coding`, batch 1.
- No mistral coding or testing row (both rows claude). R7:
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=hold` (grok weekly 99% on both
  boxes), so each row takes the claude waiver seat (1a7c70da) — a waiver seat, never
  mistral.
- R1: row 01 files {`.github/workflows/10_ci-quality.yml`} and row 02 files
  {`desk-reconcile-cron.sh`, `no-literal-paths-spelled.baseline`,
  `satellite-ansible.tst.sh`, `desk-install-service-user.tst.sh`} are disjoint; both
  rows batch 1.
- Each row is ONE logical refactor with no behaviour change: row 01 is comment-only;
  row 02 keeps the same dir (3 of 3 EQUAL), the override path byte-identical, and
  `--print-crontab` writes nothing. No row changes an exit code, a message, a path or a
  default on the box's trees.

### 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check .github/workflows/10_ci-quality.yml,csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh,csi-spl-orc/src/bash/tests/no-literal-paths-spelled.baseline,csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh,csi-spl-orc/src/bash/tests/desk-install-service-user.tst.sh --agent m-620`
(2026-11-21T02:3xZ) -> **exit 4**: no live lane lists any row path; 16 live lanes on the
other box record no files (unknown scope): c-146, c-199, c-292, c-324, c-448, c-461,
c-463, c-477, c-490, c-509 (this round's planner), c-512, c-513, c-515, c-812, c-924,
c-927. By slug none is on a row path (rotate seats, spec 123 P02/P05, spec 181
B1/B5/v04, spec 033 T025/T027, b30-02, b30-03, the r79 planner). The plan's own 2.2 read
exit 4 at 02:17:49Z with 1 unknown lane and says the holder re-checks before placing.
Briefs on this box naming a row-path basename: only landed lanes (r75/r77/r78 rows and
their R7 briefs, the b26 panel) and this round's planner brief. Remote branch
`review/c002-bug-round-30-mistral-seat` (`d729bdb5`) touches the spelled baseline among
the commits it picked up — a seat branch, not a live edit (the plan's 2.2 read, confirmed
here). `review/b30-01` exists (`3d51b9937`). Spawn queue read: b30-02/b30-03 reviewer
seats and spec 182 v08 queued; no `r79-NN` row lane yet.

### 7. Inputs accounted for

- Candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md` (95 lines,
  read whole), refactor-shaped items re-measured on `d6fc241f9`: item 1 (`/var/` in
  `spl-watchdog.func.sh` / `spl-lane-rotate.func.sh`, comment lines out) -> `0`: served;
  item 2 `reverse-tunnel-cron.sh:27` reads
  `"${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}"`: served; item 3
  wf10:444-445 -> **row 01**; item 4 `spl-agent-boot-restore-install-cron.func.sh:31`
  `@param ... default <SPL_VAR_APP_DIR>/agent-boot-restore (spl_run_paths)`: served;
  item 5 `spl-uplink-probe.func.sh:14-15` wording: served; item 6
  `spl-spawn-place-argmax.tst.sh` section 9 guard cases -> left out, b30-01 is on review
  on that file (`review/b30-01` exists); item 7 `tf-log-mask.func.sh` `${1:?}` count ->
  `0`: served (r78-02); spec 181 B10 R7 m-612 N1/N2/N4 -> left out (B10 c-492 live on
  specs 121/127/159; N4 waits on an owner poll). Bug/test/secret-shaped candidates
  (SPL-5824, SPL-5825, review-go, quota, sweeps, placer gaps, b29 token hash, etc.) are
  correctly not taken by a refactor round.
- r78 plan section 7 (lines 340-357 on `3af9dfaae`, read): `desk-reconcile-cron.sh:189`
  (line 344) -> **row 02**; `10_ci-quality.yml:444-445` (line 345) -> **row 01**; the
  other items are named in r79 section 7 with their reasons — except spec 182 L2
  `!inserted` (r78 s7 line 351), which r79 section 7 does not name (N2).
- **Named as unaccounted (N1):** the candidates item "[refactor] SPL-6107 N1 (c-388
  d387d62d): spl-desk-reply.sh:9,19 usage text does not list the new kinds" — read on
  `d6fc241f9`: `:9` `[--kind note|result|reject|blocker|msg]`, `:19`
  `DESK_KIND   note | result | reject | blocker | msg (default: note)`; the `task` kind
  is missing. Refactor-shaped, neither served nor named in r79 section 7.
- spec 011: `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor | wc -l`
  -> `0`; `tasks.md` read; the owner-deferred tasks stay left out (section 7).
- Perf floor re-run (rulebook 4.4 command on a fresh fetch) ->
  `perf 29 refactor 107 perf-share 21.3% floor-met` — a refactor round is correct.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` (this worktree, 2026-11-21T02:3xZ) ->
`INFO distribution-hygiene: clean over the tracked tree ...`, rc 0.

## Defects

None. W1..: none.

## Notes

- **N1 (inputs):** the candidates item "[refactor] SPL-6107 N1" —
  `csi-spl-orc/src/bash/scripts/spl-desk-reply.sh:9,19` usage text does not list the
  `task` kind — is a refactor-shaped input the plan neither serves nor names in its
  section 7 (verified present on `d6fc241f9`). **Served in v1.0 `2d00168fd`:** section 7
  names it as a panel-N1 row ("re-measure next round, a wording row if it is").
- **N2 (inputs):** spec 182 L2 `!inserted` branch untested (test-shaped; in r78 s7 line
  351) is not named in r79 section 7; its blocking reason still holds at read time
  (spec 182 v08 queued, `do_spl_spawn_queue` position 20, 2026-11-21T02:3xZ).
  **Served in v1.0 `2d00168fd`:** section 7 names it as a panel-N2 row (spec 182 v08
  queued, files stay off).
- **N3 (lane map):** at this seat's read the unknown-lane count is 16 (exit 4), up from
  1 at the plan's 02:17:49Z read; none is on a row path by slug, and the plan says the
  holder re-checks the unknown lanes before placing. No plan change needed.
  **Served in v1.0 `2d00168fd`:** 2.2 carries the panel-N3 note (16 unknown lanes at
  02:3xZ, none on a row path; holder's re-check before placing is the one that counts).

## State history

- 2026-11-21T02:3xZ commit `d832b6726`: full review of
  `043b1af86df5ce2386c5f7e2d0d2188a36f6a321` (checks 1-8 above), verdict PASS, notes
  N1-N3, pushed to `review/c002-refactor-round-79-mistral-seat` only.
- 2026-11-21T02:4xZ commits `8b2963d8a`, `c59ffe154`: v1.0 signature on the planner head
  `2d00168fd04d22f6677a95a14b6e5d12a24d6a81` (superseding `5b195323d` per holder msg
  5089f1e9 / 29605022), N1-N3 marked served, pushed to the same review branch only.

Seed STEP 0: read `csi-spl-doc/doc/md/developer-guide.md`, then
`cd csi-spl-orc && sudo -u <push user> env AGENT_ID=m-620 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack`
-> `ACK m-620 read developer-guide.md blob 8b1916cdc5d75c52cc4b3248babef398acf1366b`.
Read whole this session: `CLAUDE.md`, `csi-spl-doc/doc/help/how-to-post.md`,
`csi-spl-doc/doc/md/rounds-rulebook.md` (sections 1-5), the plan at `043b1af8`,
`csi-spl-doc/doc/md/refactor-round-78-plan.md` (origin/master),
`/var/spool-hub/dispatch/c002-next-round-candidates.md`, both r79 briefs,
`csi-spl-doc/specs/011-spool-project-refactor/tasks.md`, the r78 seat file on
`review/c002-refactor-round-78-mistral-seat` (form), and the row site files at
`d6fc241f9` via `git show`.

## v1.0 signature

**PASS** on the editor's v1.0 head `2d00168fd04d22f6677a95a14b6e5d12a24d6a81` (branch
`review/c002-refactor-round-79-planner`, ls-remote = this sha, read
2026-11-21T02:4xZ; supersedes `5b195323d` per holder msg 5089f1e9 and planner note
61336dfe). Verified before signing: `git diff 5b195323d 2d00168fd --
csi-spl-doc/doc/md/refactor-round-79-plan.md` touches section 9 only (+2 -1: the
holder's review-line check "pending." -> "rc 0 ... m-620 signs v1.0 next.");
`git diff 043b1af8 5b195323 -- <plan>` touches only the Status line, the 2.2 N3 note,
two section-7 rows (N1, N2), section 8 and section 9; the row table is byte-identical
across all three (`diff <(git show 043b1af8:<plan> | sed -n '/## 2. The 2 rows/,/### 2.1/p')
<(git show 2d00168fd:<plan> | sed -n '/## 2. The 2 rows/,/### 2.1/p')` -> empty,
ROWS-IDENTICAL). N1 and N2 confirmed in section 7 and N3 in 2.2 by this seat's own
read of `2d00168fd`. Section 9 records this seat's PASS on `043b1af8` with N1-N3.
Rows unchanged from the reviewed v0.1, no new defect: this seat signs v1.0
`2d00168fd04d22f6677a95a14b6e5d12a24d6a81`.
