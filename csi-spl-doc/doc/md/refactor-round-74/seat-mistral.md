# Refactor round 74 — seat mistral (panel, docs and reviews only)

Seat: m-295@sat, placement `c003-refactor-round-74-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c003-refactor-round-74-mistral-panel-seat.md`
(Issue SPL-6021, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `4f8d99b3-9670-4dcf-8bd8-5699e1375a15`).

Review target: plan v0.1 `3036c5754cf341955bd2c9a713e0ad33d4ab31ad`, named by the
editor c-290@sat (msg 55db940b). Provenance at my read (2026-11-20T08:2xZ):
`git ls-remote origin | grep -E 'r74-[0-9]{2}|refactor-round-74'` -> one line,
`3036c5754cf341955bd2c9a713e0ad33d4ab31ad  refs/heads/review/c002-refactor-round-74-planner`;
`git log -1 --format='%H %P %s' 3036c5754...` -> parent
`af8ca0ba723c03b70383d94830cdb8e6a3dd6f35`; `git rev-parse origin/master` ->
`af8ca0ba723c03b70383d94830cdb8e6a3dd6f35` (same);
`git diff --stat 3036c5754^ 3036c5754` -> 1 file,
`csi-spl-doc/doc/md/refactor-round-74-plan.md` +350. All reads below are on
`af8ca0ba7` unless stated; every file:line cited was checked with
`git show af8ca0ba7:<file> | sed -n <N>p`.

**Verdict: PASS** on `3036c5754cf341955bd2c9a713e0ad33d4ab31ad`. No defects; notes
N1..N3, for the editor to fold into v1.0.

## 1. Slug r74 unused

- `git log origin/master --oneline -E --grep='\(r74-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r74-[0-9]{2}|refactor-round-74'` -> only
  `3036c5754... refs/heads/review/c002-refactor-round-74-planner` (the planner's
  branch, expected; my seat branch did not exist yet at read time).
- `grep -rlE 'r74-[0-9]{2}|round-74' /var/spool-hub/dispatch/briefs` -> 2 files:
  `c002-refactor-round-74-planner.md` and `c003-refactor-round-74-mistral-panel-seat.md`
  (the planner's and this brief, both expected).
- Control: `git log origin/master --oneline -E --grep='\(r73-0[12]-'` -> 2 lines
  (`0509f0b7b`, `1c18a5be8`), so the read sees a used id.

## 2. Row sites exist on af8ca0ba7 and still on origin/master

All 22 gate sites (10 row sites + 12 left-out) checked with
`git show af8ca0ba7:<file> | sed -n <N>p` and the same on `origin/master`; every one
prints the same hand-spelled line on both shas (origin/master was still `af8ca0ba7`
at my read). The 10 row sites:

- `csi-spl-orc/src/bash/run/spl-accepted-close-install-cron.func.sh:40` ->
  `logdir="${ACCEPT_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/accepted-close}"`
- `csi-spl-orc/src/bash/run/spl-desk-poll-ack-install-cron.func.sh:40` ->
  `logdir="${POLL_ACK_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/poll-ack}"`
- `csi-spl-orc/src/bash/run/spl-security-round-install-cron.func.sh:44` ->
  `logdir="${SECURITY_ROUND_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/security-round}"`
- `csi-spl-orc/src/bash/run/spl-spawn-fill-install-cron.func.sh:40` ->
  `logdir="${SPAWN_FILL_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/spawn-fill}"`
- `csi-spl-orc/src/bash/run/spl-topic-archive-suggest-install-cron.func.sh:38` ->
  `logdir="${ARCHIVE_SUGGEST_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/topic-archive-suggest}"`
- `csi-spl-orc/src/bash/run/check-disk-headroom-install-cron.func.sh:46` ->
  `logdir="${DISK_HEADROOM_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/disk-headroom}"`
- `csi-spl-orc/src/bash/run/check-env-order-install-cron.func.sh:43` ->
  `logdir="${ENV_ORDER_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/env-order}"`
- `csi-spl-orc/src/bash/run/setup-box-stats-cron.func.sh:48` ->
  `logdir="${BOX_STATS_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/box-stats}"`
- `csi-spl-orc/src/bash/run/setup-ci-overflow-cron.func.sh:41` ->
  `logdir="${CI_OVERFLOW_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/ci-overflow}"`
- `csi-spl-orc/src/bash/run/setup-go-cache-prune-cron.func.sh:46` ->
  `logdir="${GO_CACHE_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/go-cache-prune}"`

The 12 left-out sites also match the plan's 1.3 table line for line
(`setup-gh-runner-cpu-budget-cron:58`, `spl-box-restart-install-cron:91`,
`spl-desk-install-service:120`, `spl-dispatch-rotate-install-cron:74`,
`spl-orch-rotate-install-cron:45`, `spl-peer-crons:137`, `spl-review-go-install-cron:39`,
`spl-spawn-place-install-cron:38`, `spl-spawn-remote-install-cron:48`,
`spl-unanswered-sweep-install-cron:57`, `spl-wd-ensure-install-cron:76`,
`spl-workspace-delivery-probe-install-cron:53`).

Drift: `git diff --name-only af8ca0ba7 origin/master -- <the 10 row files>` -> empty.
No site drifted.

## 3. The gate

- `git grep -nE '/(var|opt)/\$\{?SPL_ORG_APP' af8ca0ba7 -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l`
  -> **22** on `af8ca0ba7`; the same command on `origin/master` -> **22** (same sha).
  The 22 lines are exactly the plan's 1.3 table (10 row + 12 left-out, listed in
  check 2).
- After both rows the 12 that stay are the 12 left-out sites; plan section 7 says
  why each group is left out: `spl-review-go-install-cron:39` and
  `spl-spawn-place-install-cron:38` because their only suites
  (`spl-review-go.tst.sh`, `spl-spawn-queue.tst.sh` — verified:
  `git grep -lE 'spl-review-go-install-cron|do_spl_review_go_install_cron' af8ca0ba7 -- '*tests/*'`
  -> `spl-review-go.tst.sh` only; same for spawn-place -> `spl-spawn-queue.tst.sh`
  only) are bug round 27's row files; the other 10 because of wider callers
  (`spl-desk-install-service.func.sh` named by 21 test files, the rotate /
  unanswered-sweep installers by the box deploy and satellite tests, three set
  global `SPL_*_CRON_LOGDIR` vars). 22 -> 17 -> 12 arithmetic holds.
- Does the grep miss other hand-spelled `SPL_ORG_APP` var-dir forms in
  `csi-spl-orc/src/bash`? Probes run on `af8ca0ba7` (non-test lines only):
  - `git grep -nE '/(var|opt)/' af8ca0ba7 -- csi-spl-orc/src/bash ':!*/tests/*' | grep -E 'SPL_ORG_APP|\$\{?(org|ORG|org_app|ORG_APP|app)\b'`
    -> **30** lines total; the 8 not matched by the gate pattern are exactly
    5 × `/var/${org_app|ORG_APP|app...}` (`spl-box-update-install-cron:34`,
    `spl-cost-rollup-install-cron:42`, `spl-spool-refresh:55`, `spl-wd-ensure:194`,
    `scripts/desk-reconcile-cron.sh:189`) and 3 × tenant dirs
    `/var/$org/$SPL_ORG_APP/tenants/$ENV` (`spl-desk-rebox:111`,
    `spl-invite-e2e:118`, `spl-m3-e2e:159`) — the two other spellings the plan's
    1.3 counts separately (22 + 5 + 3 = 30). No other quoting, braces or `/opt/`
    form exists: any line with `/var/` or `/opt/` plus an org/app var that the
    gate misses appears in that 8, so nothing else is missed.

## 4. Equivalence (no behaviour change)

- Read `csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh` on `af8ca0ba7`:
  `spl_run_paths` at `:66-76` derives
  `SPL_VAR_APP_DIR=${base%/*}/var/${org##*/}/${main##*/}` from the main checkout
  (`spl_main_checkout` `:45-61`, worktree `.git` pointer resolved at `:55-60`),
  keeping a preset `SPL_VAR_APP_DIR` (`:71` `: "${SPL_VAR_APP_DIR:=...}"`);
  `spl_var_app_subdir` at `:81-85` validates the var name, calls `spl_run_paths`,
  requires non-empty `SPL_VAR_APP_DIR`, then `printf -v "$1" '%s/%s' ...`.
  rc 1 with the var untouched when no tree is known.
- Same dir today, re-run by me (`env -i`, lib at `af8ca0ba7`, hand form
  `SPL_ORG_APP=$(basename $PROJ_PATH); SPL_ORG_APP=${SPL_ORG_APP%-orc};
  /var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/spawn-fill` vs `spl_var_app_subdir d spawn-fill`):
  - `PROJ_PATH=/opt/csi/csi-spl/csi-spl-orc` -> both `/var/csi/csi-spl/spawn-fill`, **EQUAL**
  - `PROJ_PATH=/opt/csi/csi-spl-desk-cron/csi-spl-orc` -> **EQUAL**
  - `PROJ_PATH=/opt/csi/csi-spl-wt/m-295/csi-spl-orc` -> **EQUAL**
  3 of 3 equal, matching the plan's 1.3 claim.
- Env that sets `SPL_VAR_APP_DIR`: `env -i PROJ_PATH=/opt/csi/csi-spl/csi-spl-orc SPL_VAR_APP_DIR=/tmp/custom-var ...`
  -> helper `/tmp/custom-var/spawn-fill`, hand form still `/var/csi/csi-spl/spawn-fill`.
  The preset wins in the new form — the documented `spl_run_paths` semantics
  (developer guide 2.3.1, "an env var of the same name wins"), the accepted
  consequence the plan names at 1.3 (b).
- Unset/empty inputs: `env -i SPL_RUN_PATHS_TOP= bash -c 'source <lib>; spl_var_app_subdir d spawn-fill'`
  -> rc 1, `d` untouched (the plan's FATAL + `return 1` path); the hand form with
  empty `SPL_ORG_APP` would print `/var///spawn-fill` — the helper fails stronger,
  as the plan says (c).
- Each site keeps its override env var: every row site line is
  `logdir="${<OVERRIDE>:-/var/...}"` (check 2), and the plan's shape keeps the
  override first (`logdir="${<OVERRIDE>:-}"` then the helper block only when
  empty). Each site has `local ... logdir ...` (verified:
  `git grep -nE 'local .*\blogdir\b' af8ca0ba7 -- <each row file>` -> one line each),
  so the helper's `printf -v` writes the action's own variable; each file still
  reads `SPL_ORG_APP` 4-5 times for its `tag` / `run` / `script` path.
- The rows' new default-path case catches a difference: with override unset and
  `SPL_VAR_APP_DIR=$T/var`, the parent prints `/var/csi/csi-spl/<sub>` in the cron
  line while the change prints `$T/var/<sub>` — the case fails on the parent by
  construction.
- Shape to copy verified: `box-disk-sweep-install-cron.func.sh:31-34` on
  `af8ca0ba7` is exactly the plan's quoted block.
- Function lengths re-measured (`awk` from `^do_...() {` to first `^}`):
  row 01 = 38, 38, 35, 36, 36; row 02 = 58, 50, 57, 49, 57 — the plan's 35-38 /
  49-58; +3 lines stays under the 75 cap.
- Suite claims re-verified: each of the 10 suites names its `*_CRON_LOG_DIR`
  exactly once (`git grep -cE` -> 1 each); no suite names a `/var/<org>` path
  (the only `/var/` hits are `/var/lib/docker/...` fixture text and `$T/var/...`
  temp paths); only `prune-go-build-cache.tst.sh` names `SPL_VAR_APP_DIR`, 6
  lines. Each row site is named by exactly one suite, matching the plan's table
  (`git grep -lE '<basename>|<do_ name>' af8ca0ba7 -- '*tests/*'`), including
  `setup-ci-overflow-cron` -> `route-ci-overflow.tst.sh` and
  `setup-go-cache-prune-cron` -> `prune-go-build-cache.tst.sh`.

## 5. Per row

Both rows carry practice, why, sites file:line, n, an R2 control (gate 22 -> 17,
new default-path cases red on the parent, byte-identical `DRY_RUN=1` output), a
test list (the 5 suites + `no-literal-paths.tst.sh` + `bash-cleancode.tst.sh` +
`do_check_pre_push`), box `either`, vendor `claude`, kind `simple_coding`, batch 1
(plan section 2 table). No mistral coding or testing row (the plan quotes the
owner's rule and sets claude for every row); the R7 row reviewer is a cross-vendor
seat or the claude waiver seat, "Not a mistral code R7" (plan section 4) —
compliant.

Red controls really fail on `af8ca0ba7`: the new cases assert `$T/var/<sub>/` in
the printed cron line with the override unset; on the parent the site builds
`/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>` regardless of `SPL_VAR_APP_DIR`
(check 2 lines), so the assertion fails.

Dry run never writes a live dir or the real crontab — verified in the code, not
just claimed: `spl-spawn-fill-install-cron.func.sh` (row 01) and
`setup-go-cache-prune-cron.func.sh` (row 02) on `af8ca0ba7` both take the
`DRY_RUN=1` branch to `spl_desk_cron_diff` + `spl_desk_cron_checkout_dry`, log
`OK DRY_RUN nothing was touched`, and `return 0` before `mkdir -p "$logdir"` and
`spl_desk_cron_write` (the real crontab), which sit only under `DRY_RUN=0`.

## 6. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 20 row paths, comma-separated> --agent m-295`
(2026-11-20T08:2xZ) -> **exit 4**: no live lane lists any of the 20 row paths;
`unknown:` c-049, c-060, c-625, c-812, c-924, c-927 (all on the other box, all
`rotate`, no files recorded — ask-first, not free; box qualifiers dropped here,
the other box's name is hygiene-banned in the tree). Same six lanes the plan's
2.2 recorded at 08:09:25Z. Exit 4, not 3: no row path is owned by a live lane.

Bug round 27's plan at `282437e3a` (`git cat-file -t 282437e3a` -> commit;
`git log -1 --format=%s` -> `docs(b27-plan, SPL-6019): bug round 27 plan v0.1, ...`;
one file, `csi-spl-doc/doc/md/bug-round-27-plan.md`): its row 01 edit list is
"`spl-review-go.func.sh` and its test only", row 02's is `spl-spawn-place.func.sh` /
`spl-spawn-queue.tst.sh` (+ read-only `run.sh`, `spl-lane-mix.func.sh`,
`spl-spawn-review-notify.func.sh`, `orc-shard-weights.txt`). So no r74 row file is
an edit target of b27 — the plan's 2.2 claim holds. One naming nuance (N2):
b27-plan.md:55 names `spl-accepted-close.tst.sh` (an r74-01 row suite) as a suite
its row-01 lane *runs* ("At least those two suites and `rc01.sh`"), not edits.

## 7. R1 across rounds

- Newest perf plan on origin/master is `csi-spl-doc/doc/md/perf-round-18-plan.md`;
  `git show origin/master:csi-spl-doc/doc/md/perf-round-18-plan.md | grep -cE '<the 20 row paths>'`
  -> **0**. All `perf-round-<N>-plan.md` on origin/master (4..18) read the same
  way: 0 each except `perf-round-17-plan.md` -> 1 (a closed round's lane-mix row
  text, not a live row).
- Bug round 27's plan at `282437e3a`: `git grep -cE '<the 20 row paths>' 282437e3a -- csi-spl-doc/doc/md/bug-round-27-plan.md`
  -> **1**, the run-only mention at `:55` (check 6). The `bug-round-<N>-plan.md`
  files on origin/master (1..26) read the same way: 0 each except closed rounds
  bug-3 (3), bug-10 (4), bug-13 (1), bug-16 (3), bug-23 (1) — mentions of the
  `*.func.sh` files or run-only suites, no live round row names a row file.

## 8. Candidates

`/var/spool-hub/dispatch/c002-next-round-candidates.md`: 11841 bytes, mtime
2026-11-20 09:06 — matches the plan's 1.2 read. Its refactor-shaped items are
served on `af8ca0ba7`, re-verified by me: `git grep -nE '/var/\$\{?org|/var/csi' af8ca0ba7 -- csi-spl-orc/src/bash/run/spl-watchdog.func.sh csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh csi-spl-orc/src/bash/run/spl-agent-boot-restore-install-cron.func.sh`
-> 0 hits; `scripts/reverse-tunnel-cron.sh:27` reads
`"${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}"`;
`spl-agent-boot-restore-install-cron.func.sh:57-60` derives the logdir with
`spl_var_app_subdir`. The items added since r73's read (the `*-panel-seat` placer
gap, the review-go "found locally only" GO) are bug-shaped and are bug round 27's
two rows. No refactor-shaped item that the plan neither serves nor lists in
section 7.

## 9. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-295`, rc 0.

## Defects

None.

## Notes

- N1: lane-map exit 4, not 3 — the 6 no-file lanes on the other box (c-049, c-060,
  c-625, c-812, c-924, c-927, all `rotate`) are ask-first, not free; no row path
  is owned by any live lane. The plan's 2.2 recorded the same six.
- N2: b27's plan `282437e3a` names `spl-accepted-close.tst.sh` at
  `bug-round-27-plan.md:55` as a suite its row-01 lane runs, not edits (row 01's
  edit list is "`spl-review-go.func.sh` and its test only"), so there is no file
  collision with r74-01; the plan's 2.2 sentence "No r74 row file is in b27's
  list" is accurate for edit lists but does not mention this run-only naming.
- N3: the gate pattern covers only the `/var|opt/${SPL_ORG_APP` spelling; the
  other 8 hand-spelled lines (5 `org_app|ORG_APP|app` + 3 tenant dirs) sit outside
  it and are counted separately in 1.3 (30 total, verified). Consistent as
  written; the section-7 gate row for a later round must cover all spellings
  (the plan already says so).

## v1.0 signing (second review)

Review target: plan v1.0 `1d866c25a51523016b7a1341e50ed82cbd638f3a`, named by the
dispatch holder c-002@sat on task `dispatch-refactor-r74` (msg 4ccec708,
2026-11-20T08:37:12Z: "SIGN ... c-290 pushed r74 plan v1.0 1d866c25a ... on
review/c002-refactor-round-74-planner"). Provenance at my read (2026-11-20T08:4xZ):
`git fetch origin master` + the planner branch;
`git ls-remote origin | grep -E 'refactor-round-74'` ->
`1d866c25a... refs/heads/review/c002-refactor-round-74-planner` (plus my seat branch
`e7ef6c95b... review/c003-refactor-round-74-mistral-seat`);
`git log -1 --format='%H parent=%P %s' 1d866c25a` -> parent
`3036c5754cf341955bd2c9a713e0ad33d4ab31ad` (my PASSed v0.1);
`git merge-base --is-ancestor 3036c5754 1d866c25a` -> rc 0 (fast-forward on the
signed v0.1); `git diff --stat 3036c5754 1d866c25a` -> 1 file,
`csi-spl-doc/doc/md/refactor-round-74-plan.md` +27 -4;
`git rev-parse origin/master` -> `af8ca0ba7...` (unchanged).

**Verdict: PASS** on `1d866c25a51523016b7a1341e50ed82cbd638f3a`. The v0.1 -> v1.0
diff folds exactly my report and nothing else: status line -> v1.0 with my PASS;
2.2 gains the N2 run-only note (b27 plan `:55` runs `spl-accepted-close.tst.sh`,
does not edit it); section 8 records the PASS, the seat file `e7ef6c95b` and N1-N3;
section 9 consensus records my PASS on v0.1. No W finding was mine to fold; none
appears.

Checks re-run on the v1.0 sha:

- Rows unchanged: `git show 1d866c25a:csi-spl-doc/doc/md/refactor-round-74-plan.md`
  still carries rows r74-01 / r74-02 with the same 10 sites file:line, gate
  22 -> 17 -> 12, vendor `claude`, kind `simple_coding`, batch 1 (section 2 table
  and section 5 briefs re-read on the sha).
- Slug: `git log origin/master --oneline -E --grep='\(r74-' | wc -l` -> 0 (no row
  commit on master yet).
- Gate: `git grep -nE '/(var|opt)/\$\{?SPL_ORG_APP' af8ca0ba7 -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l`
  -> **22** (origin/master still `af8ca0ba7`).
- Drift: `git diff --name-only 1d866c25a origin/master -- <the 10 row files>` ->
  empty.
- Lane map re-run (2026-11-20T08:4xZ):
  `lane-map.sh --check <the 20 row paths> --agent m-295` -> exit **4**, no live
  lane owns a row path; `unknown:` c-049, c-060, c-625, c-812, c-924, c-927,
  c-939 (all `rotate` on the other box, no files recorded — ask-first, not free;
  box qualifiers dropped, hygiene-banned in the tree). One more no-file lane
  (c-939) than at the v0.1 read; still no owner.

- N4 (cosmetic): section 9 says "Its signature on v1.0: pending" — this section
  is that signature.
