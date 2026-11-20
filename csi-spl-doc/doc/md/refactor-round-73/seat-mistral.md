# Refactor round 73 — seat mistral (panel, docs and reviews only)

Seat: m-256@sat, placement `c002-refactor-round-73-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-73-mistral-panel-seat.md`
(Issue SPL-6017, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `2fe02b1c-57ab-4155-9aed-b88f64eddefe`).

Review target: plan v0.1 `76fb311e91dd9a72f67a1e3220cc6123b98e69c2`, named by the
editor c-247@sat (msg 6c60df37). Provenance at my read (2026-11-20T06:2xZ):
`git ls-remote origin | grep -E 'r73-[0-9]{2}|refactor-round-73'` -> one line,
`76fb311e91dd9a72f67a1e3220cc6123b98e69c2  refs/heads/review/c002-refactor-round-73-planner`;
`git log -1 --format='%H parent=%P' 76fb311e9...` -> parent
`5c7f42f7046fe3222222e3318f3e07223e29a71a`, and `git rev-parse origin/master` ->
`5c7f42f7046fe3222222e3318f3e07223e29a71a` (same); `git show --stat 76fb311e9` ->
1 file, `csi-spl-doc/doc/md/refactor-round-73-plan.md` +315. All reads below are on
`5c7f42f70` unless stated; every file:line cited was checked with
`git show 5c7f42f70:<file> | sed -n <N>p`.

**Verdict: PASS** on `76fb311e91dd9a72f67a1e3220cc6123b98e69c2`. One defect W1 (the
1.3 measurement undercounts the hand-spelled shape it claims to measure; both rows are
unaffected) and notes N1..N6, for the editor to fold into v1.0.

## 1. Slug r73 unused

- `git log origin/master --oneline -E --grep='\(r73-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r73-[0-9]{2}|refactor-round-73'` -> only
  `76fb311e... refs/heads/review/c002-refactor-round-73-planner` (the planner's branch,
  expected; my seat branch did not exist yet at read time).
- `grep -rlE 'r73-[0-9]{2}|round-73' /var/spool-hub/dispatch/briefs` -> 2 files:
  `c002-refactor-round-73-planner.md` and `c002-refactor-round-73-mistral-panel-seat.md`
  (the planner's and this brief, both expected);
  `grep -rlE 'r73-[0-9]{2}|round-73' /var/spool-hub/spawn-remote/briefs` -> none.
- Control: `git log origin/master --oneline -E --grep='\(r72-'` -> 3 lines
  (`5c7f42f70`, `6cab1632d`, `2453d5770`), so the read sees a used id.

## 2. Row sites exist on 5c7f42f70 and still on origin/master

Each checked with `git show 5c7f42f70:<file> | sed -n <N>p`:

- `csi-spl-orc/src/bash/run/box-disk-sweep-install-cron.func.sh:30-32` ->
  `local app org logdir tag="csi-spl:box-disk-sweep" ...` / `app="$(basename "$PROJ_PATH")"; app="${app%-orc}"; org="${app%%-*}"` /
  `logdir="${BOX_SWEEP_CRON_LOG_DIR:-/var/${org}/${app}/box-disk-sweep}"` — matches the plan.
- `csi-spl-orc/src/bash/run/git-prune-merged-install-cron.func.sh:23-25` ->
  `local ct=... app org logdir tag script ...` / `app=...; org=...` /
  `logdir="${GIT_PRUNE_CRON_LOG_DIR:-/var/$org/$app/git-prune-merged}" tag="$app:git-prune-merged"` — matches.
- `csi-spl-orc/src/bash/run/prune-go-build-cache.func.sh:241-251` (`go_cache_lock_or_stop`) ->
  `local lock app org` / `[[ "${GO_CACHE_LOCK:-1}" == 1 ]] || return 0` /
  `command -v flock >/dev/null 2>&1 || return 0` / `if [[ -n "${GO_CACHE_LOCK_FILE:-}" ]] ... else` /
  `app="$(basename "${PROJ_PATH:-csi-spl-orc}")"` / `app="${app%-orc}"` / `org="${app%%-*}"` /
  `lock="/var/${org}/${app}/go-cache-prune/prune.lock"` — matches.
- `csi-spl-orc/src/bash/scripts/git-prune-merged-cron.sh:39-43` -> `app="$(basename "$ORC")"` /
  `app="${app%-orc}"` / `org="${app%%-*}"` /
  `logdir="${GIT_PRUNE_CRON_LOG_DIR:-/var/${org}/${app}/git-prune-merged}"` / `mkdir -p "$logdir" || ... exit 2` — matches.
- `csi-spl-orc/src/bash/scripts/prune-go-build-cache-cron.sh:32-36` -> `app=...` / `app=...` /
  `org=...` / `lockdir="${GO_CACHE_LOG_DIR:-/var/${org}/${app}/go-cache-prune}"` / `mkdir -p "$lockdir" 2>/dev/null || true` — matches.
- Left-out tenant sites also as claimed: `run/spl-desk-rebox.func.sh:111`,
  `run/spl-invite-e2e.func.sh:118`, `run/spl-m3-e2e.func.sh:159` all read
  `/var/$org/$SPL_ORG_APP/tenants/$ENV` behind `SPL_TENANTS_DIR`.
- Helper and shape references as claimed: `lib/bash/funcs/spl-run-paths.func.sh:66-76`
  (`spl_run_paths`), `:81-85` (`spl_var_app_subdir`);
  `run/prune-docker-images-install-cron.func.sh:37-40`, `scripts/push-orphan-check-cron.sh:24-28`,
  `scripts/reverse-tunnel-cron.sh:23-27`, `scripts/issue-key-rate-cron.sh:23-24`.
- Drift: `git diff --name-only 5c7f42f70 origin/master -- <the 5 code files, the 3 test
  files, run-log-sweep.tst.sh, no-literal-paths.tst.sh, lib spl-run-paths.func.sh>` ->
  empty (origin/master was still `5c7f42f70` at my read). No site drifted.

## 3. The gate

- `git grep -nE '/(var|opt)/\$\{?(ORG|org)\b' -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l`
  -> **8** on the worktree and **8** with `5c7f42f70` spelled out. The 8 lines:
  `run/box-disk-sweep-install-cron.func.sh:32`, `run/git-prune-merged-install-cron.func.sh:25`,
  `run/prune-go-build-cache.func.sh:250` (row 01), `scripts/git-prune-merged-cron.sh:42`,
  `scripts/prune-go-build-cache-cron.sh:35` (row 02), and the 3 tenant sites
  (`run/spl-desk-rebox.func.sh:111`, `run/spl-invite-e2e.func.sh:118`, `run/spl-m3-e2e.func.sh:159`).
  So after row 01 the gate reads 5 and after both rows 3, and the 3 that stay are the
  tenant-dir sites; the plan says why (section 7): secret-class (the data rule), two of
  them drive e2e runs against the hosted hub; the iac/utl sites would source another
  module's lib.
- The plan's wider 1.3 grep `git grep -nE '/(var|opt)/\$\{?(ORG|org)\b' 5c7f42f70 -- '*.sh' ':!*/tests/*' ':!csi-spl-doc' | grep -vE ':[0-9]+:\s*#'`
  -> **17** lines: 2 `lib:spl-run-paths.func.sh`, 3 `iac:run/`, 4 `csi-spl-utl/src/bash/run/`,
  8 `orc:` — matches plan lines 91-92.
- Does the grep miss other hand-spelled var-dir forms in `csi-spl-orc/src/bash`? **Yes — 27 more lines** (see W1):
  - probe A, literal org name: `git grep -nE '/(var|opt)/csi' 5c7f42f70 -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#'`
    -> only `/var/spool-hub`, `/opt/$box_user`, `/var/lib/$GHR_USER`-style OS paths, no app var dir.
  - probe E: `git grep -nE '/(var|opt)/\$\{?SPL_ORG_APP' 5c7f42f70 -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#'` -> **22 lines**
    (`/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>` in check-disk-headroom, check-env-order,
    setup-box-stats, setup-ci-overflow, setup-gh-runner-cpu-budget, setup-go-cache-prune,
    spl-accepted-close, spl-box-restart, spl-desk-install-service, spl-desk-poll-ack,
    spl-dispatch-rotate, spl-orch-rotate, spl-peer-crons, spl-review-go,
    spl-security-round, spl-spawn-fill, spl-spawn-place, spl-spawn-remote,
    spl-topic-archive-suggest, spl-unanswered-sweep, spl-wd-ensure-install-cron,
    spl-workspace-delivery-probe install-cron actions).
  - probe F: `git grep -nE '/(var|opt)/\$\{?(org_app|ORG_APP)\b|/(var|opt)/\$\{?app\b' 5c7f42f70 -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#'`
    -> **5 lines**: `run/spl-box-update-install-cron.func.sh:34`, `run/spl-cost-rollup-install-cron.func.sh:42`,
    `run/spl-spool-refresh.func.sh:55`, `run/spl-wd-ensure.func.sh:194`, `scripts/desk-reconcile-cron.sh:189`.
  - total hand-spelled app-var-dir lines in `orc:` non-tests (all three variable families): **35**, not 8.

## 4. Equivalence (no behaviour change)

- Read `csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh` on `5c7f42f70` (`:33-36`
  `_spl_run_paths_top`, `:45-61` `spl_main_checkout`, `:66-76` `spl_run_paths`,
  `:81-85` `spl_var_app_subdir`).
- Same dir today, re-run by me (`env -i`, lib at `5c7f42f70`, `PROJ_PATH` set per tree;
  hand form `app=$(basename $PROJ_PATH); app=${app%-orc}; org=${app%%-*}; /var/$org/$app/box-disk-sweep`):
  - `PROJ_PATH=/opt/csi/csi-spl/csi-spl-orc` -> derived `/var/csi/csi-spl/box-disk-sweep`, hand same, **EQUAL**
  - `PROJ_PATH=/opt/csi/csi-spl-desk-cron/csi-spl-orc` -> **EQUAL** (`/var/csi/csi-spl/box-disk-sweep`)
  - `PROJ_PATH=/opt/csi/csi-spl-wt/m-256/csi-spl-orc` -> **EQUAL** (worktree `.git` pointer resolves to the main clone)
  3 of 3 equal, matching the plan's 1.3 claim (line 103).
- Env that overrides org/app: a preset `SPL_VAR_APP_DIR` wins in the derived form
  (`env -i SPL_VAR_APP_DIR=/custom/var ... spl_var_app_subdir d box-disk-sweep` ->
  `derived=/custom/var/box-disk-sweep`); the hand form ignores it and always builds
  `/var/$org/$app`. That is the documented `spl_run_paths` semantics (developer guide
  2.3.1: "an env var of the same name wins") and the same accepted consequence as
  r63-01 / r71-01 / r72-02 (plan line 109). The per-site overrides
  (`BOX_SWEEP_CRON_LOG_DIR`, `GIT_PRUNE_CRON_LOG_DIR`, `GO_CACHE_LOCK_FILE`,
  `GO_CACHE_LOG_DIR`) are kept in both forms.
- Unset/empty inputs: `env -i bash -c 'source <lib>; spl_run_paths'` -> rc 1 (no tree);
  `spl_var_app_subdir x sub` -> rc 1, `x` untouched; empty `APP_PATH`/`PROJ_PATH` -> rc 1.
  In a `./run` action `PROJ_PATH` is always set (`run.sh:792`), so the rc-1 path is
  reachable only by hand, as the plan says. The wrappers set `ORC` and check
  `[ -x "$ORC/run" ]` at `git-prune-merged-cron.sh:37` / `prune-go-build-cache-cron.sh:30`
  before the site lines; sourcing the lib from `$ORC` derives
  `SPL_VAR_APP_DIR=/var/csi/csi-spl` under `env -i` from both the main and the m-256
  worktree lib (ran both).
- Freed variables (SC2034): `git grep -nE '\$\{?(app|org)\b' 5c7f42f70 -- <each row file>`
  shows only the site lines use them — `box-disk-sweep-install-cron.func.sh:31-32` only;
  `git-prune-merged-install-cron.func.sh:24-25` (keeps `app` for `tag="$app:..."` at `:25`);
  `prune-go-build-cache.func.sh:248-250`; `git-prune-merged-cron.sh:40-42`;
  `prune-go-build-cache-cron.sh:33-35`. The plan's claim holds.
- r66 timing: `git merge-base --is-ancestor b576da5e5 5c7f42f70` and
  `git merge-base --is-ancestor ffd7d6a72 5c7f42f70` both exit 0 (r66-01/r66-02,
  2026-11-19, are ancestors of the measured sha), and r71-01 `82f0e0b0f` is too —
  the plan measured after them.
- The rows' new cases catch a difference: they assert the derived default
  (`SPL_VAR_APP_DIR=$T/var`, override unset); on the parent the code builds
  `/var/csi/csi-spl/...` (probe: running the parent's derive with
  `PROJ_PATH=/opt/csi/csi-spl/csi-spl-orc` prints
  `parent lock would be: /var/csi/csi-spl/go-cache-prune/prune.lock`), so the cases
  fail on the parent.

## 5. Per row

Both rows carry practice, why, sites (3 / 2 code file:line sites plus their test files,
the same table form as r72's plan), an R2 control (gate 8 -> 5 / 5 -> 3, new default-path
cases red on the parent, byte-identical dry-run lines on the box), a test list, box
`either`, vendor `claude`, kind `simple_coding`, batches 1 then 2 (the two rows share
`git-prune-merged-cron.tst.sh` and `prune-go-build-cache.tst.sh`, so R1 serialises them).
No mistral coding or testing row (both rows claude); the R7 row reviewer is a
cross-vendor seat or the claude waiver seat, "Not a mistral code R7" (plan section 4) —
compliant with the owner's mistral rule.

Red controls really fail on `5c7f42f70`: the new cases assert `$T/var/...` while the
parent builds `/var/<org>/<app>/...` (probe above), so they fail by construction.

Live prune lock: `/var/csi/csi-spl/go-cache-prune/prune.lock` exists and is currently
free (`flock -n <file> -c true` -> ok). On the parent `go_cache_lock_or_stop` does
`exec 9>>"$lock"` (opens/creates the file) then `flock -n 9`; with the plan's stub
`flock` first on `PATH` exiting 1, no lock is taken (the function returns 2), so the
box's live prune lock is never **held** — the plan's claim holds in that sense; note
the lock file itself is still opened for append.

Suites run by me on this worktree at `5c7f42f70`, `SPOOL_TEST=1`, as the push user
(as the push user, `env SPOOL_TEST=1 bash src/bash/tests/<t>.tst.sh` from `csi-spl-orc`):
`box-disk-sweep.tst.sh` rc 0, `box-disk-sweep: 0 failure(s)`, 88 pass lines;
`git-prune-merged-cron.tst.sh` rc 0, `ALL PASS`, 13 pass lines;
`prune-go-build-cache.tst.sh` rc 0, `all passed`, 55 pass lines;
`run-log-sweep.tst.sh` rc 0, 16 pass lines; `no-literal-paths.tst.sh` rc 0, `ALL PASS`,
8 pass lines — equal to the plan's "before" counts (plan 1.3).

## 6. R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/box-disk-sweep-install-cron.func.sh,csi-spl-orc/src/bash/run/git-prune-merged-install-cron.func.sh,csi-spl-orc/src/bash/run/prune-go-build-cache.func.sh,csi-spl-orc/src/bash/scripts/git-prune-merged-cron.sh,csi-spl-orc/src/bash/scripts/prune-go-build-cache-cron.sh,csi-spl-orc/src/bash/tests/box-disk-sweep.tst.sh,csi-spl-orc/src/bash/tests/git-prune-merged-cron.tst.sh,csi-spl-orc/src/bash/tests/prune-go-build-cache.tst.sh --agent m-256`
-> **exit 4**: no live lane lists any of the 8 row paths; `unknown:` c-049, c-060,
c-625, c-789, c-811, c-812, c-822, c-924, c-927 (all on the other box, no files recorded —
ask-first, not free; box qualifiers dropped here, the other box's name is
hygiene-banned in the tree). Exit 4, not 3: no row path is owned by a live lane.
The brief's named lanes, checked by branch: `review/b26-01` = `745cedb1b...` and
`review/c-181-c002-s114-t002a-own-reads-name-tenant` = `60b6931e...`;
`git diff --name-only $(git merge-base origin/master <sha>) <sha> | grep -E 'box-disk-sweep|git-prune-merged|prune-go-build-cache'`
-> no match for either. No row file is touched by them.

## 7. R1 across rounds

- Every `perf-round-<N>-plan.md` on origin/master (`5c7f42f70`; newest is
  `perf-round-18-plan.md`): `git show origin/master:csi-spl-doc/doc/md/<p> | grep -cE 'box-disk-sweep-install|git-prune-merged-install|prune-go-build-cache\.func|git-prune-merged-cron\.sh|prune-go-build-cache-cron\.sh'`
  -> 0 for each (only nonzero would print; none did). `bug-round-26-plan.md` -> **0**.
- Remote branches: fetched all heads; for each of the first 200,
  `git diff --name-only $(git merge-base origin/master <sha>) <sha> | grep -cE '<row files>'`
  -> 0 for every one ("no branch among first 200 touches row files").

## 8. Candidates

`/var/spool-hub/dispatch/c002-next-round-candidates.md` is now **10395 bytes, mtime
2026-11-20 08:20** — it grew after the planner's read (plan line 73 records 9542 bytes,
2026-11-19 22:49:35 +0200). The only new item (added 2026-11-20 06:2xZ, the placer gap
on `*-panel-seat` briefs) is bug-shaped. The refactor-shaped items are all served on
`5c7f42f70`: `spl-watchdog.func.sh:72,:1311` and `spl-lane-rotate.func.sh:112` carry no
`/var` literal (both the plan's pattern and the corrected alternation
`/var/\$\{?org|/var/csi` read rc 1 on those files — note the plan's 1.2 pattern has a
literal `\|`, which as ERE matches nothing; the corrected pattern also reads 0, so the
"all served" claim holds either way); `scripts/reverse-tunnel-cron.sh:27` reads
`$SPL_VAR_APP_DIR/reverse-tunnel`; `run/spl-agent-boot-restore-install-cron.func.sh:60`
uses `spl_var_app_subdir`. No refactor-shaped item that the plan neither serves nor
lists in section 7.

## 9. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-256`, rc 0.

## Defects

- **W1** (plan lines 28, 166, 295, 305): the gate and the 1.3 measurement count only the
  `/var/$org/$app` spelling — 8 lines. The same hand-spelled app-var-dir shape appears in
  **27 more lines** of `csi-spl-orc/src/bash` (non-tests) under other variable names:
  22 × `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>` and 5 × `/var/${org_app|ORG_APP|app...}`
  (probes in check 3; 35 total). The rows' 5 sites are inside the counted 8, so both rows
  stand and the gate's 8 -> 5 -> 3 is accurate as a gate; but "8 lines ... still spell the
  app's var dir by hand" (line 28) understates the shape, and the section-7 gate row's
  pattern `/(var|opt)/$org` (line 295) would miss those 27. Fold into v1.0: restate 1.3 as
  "8 of 35 hand-spelled var-dir lines (the `$org/$app` spelling)" and widen the future
  gate's pattern to cover the `$SPL_ORG_APP` / `$org_app` / `$app` forms.

## Notes

- N1: lane-map exit 4, not 3 — the 9 no-file lanes on the other box are ask-first, not
  free; no row path is owned by any live lane.
- N2: the candidates file grew after the planner's read (check 8); the only new item is
  bug-shaped, so section 7 misses nothing refactor-shaped.
- N3: equivalence re-verified 3/3 trees on this box; the only difference is a preset
  `SPL_VAR_APP_DIR`, which is the documented `spl_run_paths` override semantics.
- N4: the parent's red-control lock case opens/creates the lock file (`exec 9>>`) but
  with the stub `flock` never holds the live lock; the lock file was free at my read.
- N5: all five suites green on the worktree at `5c7f42f70`, pass counts equal to the
  plan's "before" (check 5).
- N6: r66-01/r66-02 (`b576da5e5`, `ffd7d6a72`) and r71-01 (`82f0e0b0f`) are all ancestors
  of the measured `5c7f42f70` — the plan measured after them.
