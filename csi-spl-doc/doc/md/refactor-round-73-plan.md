# Refactoring round 73 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6017  
Topic: 2fe02b1c-57ab-4155-9aed-b88f64eddefe  
Discussion: 2fe02b1c-57ab-4155-9aed-b88f64eddefe (t1 #refactoring, "Refactor round 73", opener msg c007d31d)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r73**, plan `refactor-round-73-plan.md`, rows `r73-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 72 ([refactor-round-72-plan.md](refactor-round-72-plan.md))
is closed (`5c7f42f70`): r72-01 landed `6cab1632d` (SPL-6013), r72-02 landed `2453d5770`
(SPL-6014). No signed row is handed on: r73 is a fresh round. The perf floor (rulebook
4.4), the holder's read on `5c7f42f70`: `perf 29 refactor 102 perf-share 22.1% floor-met`,
so this is a refactor round.

r72 section 7's inputs and the brief's other inputs are re-read in 1.2: none gives a row
this round. Both rows come from one new measurement (1.3): **8 lines in
`csi-spl-orc/src/bash` still spell the app's var dir by hand as `/var/$org/$app/...`**.
They carry no literal `csi`, so `no-literal-paths.tst.sh` (which greps
`/(opt|var)/<org>` with the org's real name) does not see them. They are r71's
derive-block family in a third shape. Row 01 takes the 3 in `run/` actions, row 02 the
2 in `scripts/` cron wrappers. The other 3 (tenant key dirs) stay out (section 7).
These 8 are one spelling of a wider shape: **35 lines** of `csi-spl-orc/src/bash` build
the var dir by hand (the panel's W1, re-read in 1.3); the other 27 are a later round's.

**Status: v1.0, signed**: panel seat m-256 (mistral) PASS on v0.1 `76fb311e9`, W1
folded (section 8), N1-N6 asked no change. Rows 01 and 02 are as drafted. Editor:
**c-247** (claude).

**One sha:** every count is measured on **`5c7f42f70`** (`origin/master`
5c7f42f7046fe3222222e3318f3e07223e29a71a, committed 2026-11-20T06:51:39+01:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`; the tests ran
on this lane's worktree at that sha, as the push user with `SPOOL_TEST=1`. Queue, lane
map, brief and worktree readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-20T06:51:39+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r72-plan'` -> commit
  `5c7f42f70` "refactor round 72 plan records the round closed, rows 01-02 landed".
  Every later read of r73 uses this W.
- **`r73` is free** (2026-11-20T05:58:44Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r73-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r73-*' 'refs/heads/wip/*r73*' 'refs/heads/*-r73-*' 'refs/heads/*refactor-round-73*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r73-[0-9]{2}|refactor-round-73' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (as root) on this lane's box -> **1 file**, this planner's own brief. The other
    box's briefs were not read by this lane; the holder's read before the spawn: 0
    besides this brief (the brief).
  - Control: the same log read with `(r72-` since W -> 1 line, `5c7f42f70` (the r72
    close record, whose body names the rows), so the read sees a used id.
- **No `refactor-round-73*` file** exists under `csi-spl-doc/doc/md` on `5c7f42f70`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-73` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `lib:` = `csi-spl-orc/lib/bash/funcs/`,
`iac:` = `csi-spl-iac/src/bash/`, `api:` = `csi-spl-api/src/go/spool-hub-api/internal/`.

| input | source | on `5c7f42f70` | here |
|---|---|---|---|
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | r72 section 7 | still the one `WIDE` entry (`csi-spl-wui/tests/unit/cleancode.test.mjs:47-49`), `send` at `src/stores/channel.ts:540`; its caller lines: `git grep -nE 'useChannelStore\(\)\.send\(\|\b(channel\|store\|ch\|chan\|target\|deps)\.send\(' -- csi-spl-wui` -> **66 lines in 37 files, 57 of them in 30 `tests/e2e/` files** (an upper bound: the grep also catches a few sends of other stores; not read line by line) | left out (section 7) |
| the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`) | the brief | on this lane's box: 9542 bytes, last changed 2026-11-19 22:49:35 +0200, the same as r71 and r72 read. Its refactor-shaped items re-read: the watchdog / lane-rotate `/var` literals (`git grep -nE '/var/\$\{?org\|/var/csi'` on `orc:run/spl-watchdog.func.sh`, `spl-lane-rotate.func.sh`, `spl-agent-boot-restore-install-cron.func.sh` -> 0), `orc:scripts/reverse-tunnel-cron.sh` (`:27` reads `$SPL_VAR_APP_DIR/reverse-tunnel`), the agent-boot-restore dir (`spl_var_app_subdir`, r71): all served. The p18-02 N1 workflow comment: r72's reason holds. The rest is bug-shaped | nothing new |
| `.shellcheck-warning-baseline.txt` | the brief | `grep -vcE '^\s*(#\|$)'` -> **68 lines**; `git log --oneline 6fedc5bbb..5c7f42f70 -- .shellcheck-warning-baseline.txt` -> 0, unchanged since r71 read it | nothing taken: r71 / r72 section 7's reasons hold |
| `no-literal-paths.baseline` | the brief | 1 entry, `2 csi-spl-orc/src/bash/run/spl-file-erase.func.sh` (a protected-root deny list, r66 to r72: behaviour) | left out (section 7) |
| r72 R7 findings | the brief | `6cab1632d` (c-817) and `2453d5770` (c-795): `git log -1 --format=%B <sha> \| grep -nE '^(review:\|N[0-9]\|W[0-9])'` -> one `review:` line each (`:50`, `:35`), no N or W line; both PASS, counts equal before and after. The seat files were not read | nothing taken |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0, unchanged | left out (section 7), r65 to r72's reasons hold |
| the only-shrink lists of the clean code gates | this lane | Go `longFuncs` and `wideFuncs` empty (`api:cleancode/cleancode_test.go:33,39`, `map[string]bool{}`); WUI `LONG` empty (`cleancode.test.mjs:40-41`); bash `LONG` 1 entry, `do_provision_firebase_dns 169` (`iac:tests/bash-cleancode.tst.sh:25-27`), pinned byte-identical to its upstream port (`iac:tests/wui-hosting-019-031.tst.sh`, r67 section 7); `action-header-tags-baseline.txt` `[missing]` 9 files, ruled behaviour by rounds 20, 27-29, 34 and 67 (a parsed `(required)` header refuses before the body) | left out (section 7) |
| the hand-spelled var dir, `/var/$org/$app` | this lane (1.3) | 8 lines in `orc:` (1.3) | **rows 01, 02** |

### 1.3 The hand-spelled var dir: 8 lines in `csi-spl-orc/src/bash`

`lib:spl-run-paths.func.sh:66-76` (`spl_run_paths`) derives `SPL_VAR_APP_DIR` =
`<var>/<org>/<main checkout name>`, and r71-01 (`82f0e0b0f`) gave the derive its one
helper, `spl_var_app_subdir <var> <sub>` (`:81-85`). The developer guide (2.3.1): "No
action carries a literal `/opt/<org>` or `/var/<org>` path". These lines build the same
dir by hand from `PROJ_PATH` / the script's own path, with `org` and `app` variables, so
the gate's grep (`/(opt|var)/csi`) cannot see them.

`git grep -nE '/(var|opt)/\$\{?(ORG|org)\b' 5c7f42f70 -- '*.sh' ':!*/tests/*' ':!csi-spl-doc' | grep -vE ':[0-9]+:\s*#'`
-> **17 lines**: 2 in the helper's own home (`lib:spl-run-paths.func.sh:71-72`), 3 in
`iac:run/`, 4 in `csi-spl-utl/src/bash/run/`, and **8 in `orc:`**:

| file:line | default it builds | override | row |
|---|---|---|---|
| `orc:run/box-disk-sweep-install-cron.func.sh:31-32` | `/var/${org}/${app}/box-disk-sweep` (cron log + lock dir) | `BOX_SWEEP_CRON_LOG_DIR` | 01 |
| `orc:run/git-prune-merged-install-cron.func.sh:24-25` | `/var/$org/$app/git-prune-merged` (cron log dir) | `GIT_PRUNE_CRON_LOG_DIR` | 01 |
| `orc:run/prune-go-build-cache.func.sh:247-250` (`go_cache_lock_or_stop`) | `/var/${org}/${app}/go-cache-prune/prune.lock` | `GO_CACHE_LOCK_FILE` | 01 |
| `orc:scripts/git-prune-merged-cron.sh:39-42` | `/var/${org}/${app}/git-prune-merged` (run lock dir) | `GIT_PRUNE_CRON_LOG_DIR` | 02 |
| `orc:scripts/prune-go-build-cache-cron.sh:32-35` | `/var/${org}/${app}/go-cache-prune` (lock dir) | `GO_CACHE_LOG_DIR` | 02 |
| `orc:run/spl-desk-rebox.func.sh:111`, `spl-invite-e2e.func.sh:118`, `spl-m3-e2e.func.sh:159` | `/var/$org/$SPL_ORG_APP/tenants/$ENV` | `SPL_TENANTS_DIR` | out (section 7) |

**Same dir today, measured** (this lane's box, 2026-11-20T06:0xZ, n=1 per tree; the lib
at `5c7f42f70`, run as the push user under `env -i`): for `PROJ_PATH` = the main
checkout's, the desk-cron checkout's (a worktree) and this lane's worktree's
`csi-spl-orc`, `spl_var_app_subdir x box-disk-sweep` and the hand form
(`app=$(basename $PROJ_PATH); app=${app%-orc}; org=${app%%-*}; /var/$org/$app/box-disk-sweep`)
both print `/var/<org>/<app>/box-disk-sweep`, 3 of 3 equal (`readlink -f` of the three
trees and of the var dir: no symlink). The two forms differ only in a tree outside
`<base>/<org>/<app>`, where the derived dir moves with the tree: the same accepted
consequence as r63-01, r71-01 and r72-02 (developer guide 2.3.1).

**The shapes to copy** are already on master:
- `run/`: r71-01's caller form, e.g. `orc:run/prune-docker-images-install-cron.func.sh:37-40`:

  ```text
  if [[ -z "$logdir" ]]; then
    declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
    spl_var_app_subdir logdir docker-prune || { do_log "FATAL cannot derive the docker prune log dir (no tree for spl_run_paths): set PRUNE_CRON_LOG_DIR"; return 1; }
  fi
  ```
- `scripts/`: the cron wrappers' form, `orc:scripts/push-orphan-check-cron.sh:24-28`
  (also `reverse-tunnel-cron.sh:23-27`, `issue-key-rate-cron.sh:23-24`):

  ```text
  # shellcheck source=../../../lib/bash/funcs/spl-run-paths.func.sh
  declare -F spl_run_paths >/dev/null || source "$ORC/lib/bash/funcs/spl-run-paths.func.sh"
  [ -n "${PUSH_ORPHAN_STATE_DIR:-}" ] || { spl_run_paths && [ -n "${SPL_VAR_APP_DIR:-}" ]; } ||
    { say "FATAL cannot derive the push orphan state dir (no tree for spl_run_paths): set PUSH_ORPHAN_STATE_DIR"; exit 2; }
  state="${PUSH_ORPHAN_STATE_DIR:-$SPL_VAR_APP_DIR/push-orphan-check}"
  ```

**What each site does with "no dir"** (the helper's rc 1; in a `./run` action
`PROJ_PATH` is always set, so it is reachable only by hand):
- the two installers: FATAL and `return 1`, as r71's installers do;
- `go_cache_lock_or_stop`: `return 0`, the function's own "no lock in use" answer
  (`:242-243`: lock off, or no `flock` -> `return 0`);
- the two cron wrappers: FATAL and `exit 2`, as their other start checks do (`:37` /
  `:30`, `$ORC/run` missing). A wrapper that found `$ORC/run` also finds the lib beside it.

**Variables freed.** `org` and, where nothing else reads it, `app` go with their line,
or shellcheck reports SC2034: `box-disk-sweep-install-cron.func.sh` reads neither after
`:32` (`tag` is the literal `csi-spl:box-disk-sweep`), so `:31` and the two `local`
names go; `git-prune-merged-install-cron.func.sh` keeps `app` (`tag="$app:git-prune-merged"`,
`:25`) and drops `org`; `go_cache_lock_or_stop` drops both (`:241`, `:247-249`); each
wrapper drops its 3 lines (`:39-41` / `:32-34`); nothing below reads them
(`grep -nE '\$\{?(app|org)\b'` on each file -> only those lines).

**Tests (R2):** `git grep -lE 'box-disk-sweep-install-cron|do_box_disk_sweep_install_cron|git-prune-merged-install-cron|do_git_prune_merged_install_cron|go_cache_lock_or_stop|prune-go-build-cache|git-prune-merged-cron|prune-go-build-cache-cron' 5c7f42f70 -- '*tests/*' '*.tst.sh' .github/workflows`
-> `orc:tests/box-disk-sweep.tst.sh`, `git-prune-merged-cron.tst.sh`,
`prune-go-build-cache.tst.sh`, `run-log-sweep.tst.sh` and `orc-shard-weights.txt` (a
weight, not a test). Plus `orc:tests/no-literal-paths.tst.sh` (it scans these files) and
`iac:tests/bash-cleancode.tst.sh` (a line count). **Every existing case passes an
override** (`BOX_SWEEP_CRON_LOG_DIR="$T/log"`, `GIT_PRUNE_CRON_LOG_DIR="$T/log"` /
`"$T/clog"`, `GO_CACHE_LOG_DIR="$T/log"`, `GO_CACHE_LOCK_FILE="$T/lock7"`), so no test
reads the default today: each row adds the default's case (section 2).

**Before** (this lane, worktree at `5c7f42f70`, 2026-11-20T06:01-06:02Z, n=1,
`SPOOL_TEST=1`, as the push user): `box-disk-sweep.tst.sh` rc 0, 88 pass lines, 0 fail,
3 skip lines, `box-disk-sweep: 0 failure(s)`; `git-prune-merged-cron.tst.sh` rc 0, 13
pass, `ALL PASS`; `prune-go-build-cache.tst.sh` rc 0, 55 pass, 1 skip line,
`all passed`; `run-log-sweep.tst.sh` rc 0, 16 pass; `no-literal-paths.tst.sh` rc 0, 8
pass; `bash-cleancode.tst.sh` rc 0, `all bash-cleancode.tst.sh assertions`. (Pass lines:
`grep -ciE '^ *(ok|pass)'`.)

**Gate** (both rows): `git grep -nE '/(var|opt)/\$\{?(ORG|org)\b' -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l`
-> **8** on `5c7f42f70`, **5** after row 01, **3** after both (the tenant dirs).

**The wider shape** (the panel's W1; re-read by the editor on `5c7f42f70`, n=1, each
pattern with the same `-- csi-spl-orc/src/bash ':!*/tests/*'` and comment filter):
`'/(var|opt)/\$\{?(ORG|org)\b'` -> 8 (the gate above); `'/(var|opt)/\$\{?SPL_ORG_APP'`
-> **22** (`/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>`, mostly the `*-install-cron`
actions); `'/(var|opt)/\$\{?(org_app|ORG_APP|app)\b'` -> **5**; the three together ->
**35** lines, one per file in the 27 new files. This round takes 5 of the 35; the gate
above stays the rows' gate (8 -> 5 -> 3), and the other 27 are section 7's.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r73-01-orc-var-app-subdir-cron-dirs)` | canonical paths, no box path in an action (developer guide 2.3.1); folded helpers exist once (2.2.4) | 3 `run/` actions build the app's var dir by hand as `/var/$org/$app/<sub>`, which the literal-path gate cannot see; r71-01's helper derives it | `orc:run/box-disk-sweep-install-cron.func.sh:30-32`<br>`orc:run/git-prune-merged-install-cron.func.sh:23-25`<br>`orc:run/prune-go-build-cache.func.sh:241-251`<br>`orc:tests/box-disk-sweep.tst.sh`, `orc:tests/git-prune-merged-cron.tst.sh`, `orc:tests/prune-go-build-cache.tst.sh` (one new case each) | 3 sites | Each site takes 1.3's `run/` form: the override kept, else `spl_var_app_subdir <var> <sub>` (`box-disk-sweep`, `git-prune-merged`, `go-cache-prune/prune.lock`), the freed variables dropped (1.3). **Gate:** 1.3's grep 8 -> **5**. **New cases**, override unset, `SPL_VAR_APP_DIR=$T/var`: the box sweep installer's dry run prints its line with `$T/var/box-disk-sweep/box-disk-sweep.lock`; the git prune installer's with `$T/var/git-prune-merged/cron.out`; `go_cache_lock_or_stop` (`GO_CACHE_LOCK_FILE` unset) leaves `$T/var/go-cache-prune/prune.lock`. **Red control:** the 3 new cases FAIL on the parent (it builds `/var/<org>/<app>/...`), output in the body; on the parent the lock case runs with a stub `flock` first on `PATH` that exits 1 without locking, so the box's live prune lock is never held. **Behaviour:** on this box with no override the installers' dry-run lines are byte-identical on the parent and the change (`BOX_SWEEP_CRONTAB` / `GIT_PRUNE_CRONTAB` a fake file, `DRY_RUN=1`), diff in the body; the 4 suites' pass counts equal plus the new cases. Tests: the 4 suites of 1.3, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (all `SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push` (shellcheck: no new SC2034). | either | claude | simple_coding | 1 |
| 02 `refactor(r73-02-orc-var-app-dir-cron-wrappers)` | as row 01 | the 2 cron wrappers in `scripts/` build their lock dir the same way; the wrappers' own derive form is on master (`push-orphan-check-cron.sh:24-28`) | `orc:scripts/git-prune-merged-cron.sh:39-43`<br>`orc:scripts/prune-go-build-cache-cron.sh:32-36`<br>`orc:tests/git-prune-merged-cron.tst.sh`, `orc:tests/prune-go-build-cache.tst.sh` (one new case each) | 2 sites | Each wrapper takes 1.3's `scripts/` form: the `# shellcheck source=` line, the guarded `source "$ORC/lib/bash/funcs/spl-run-paths.func.sh"`, `[ -n "${<OVERRIDE>:-}" ] \|\| { spl_run_paths && [ -n "${SPL_VAR_APP_DIR:-}" ]; } \|\| { say "FATAL ..."; exit 2; }`, then `<dir>="${<OVERRIDE>:-$SPL_VAR_APP_DIR/<sub>}"`; its 3 `app`/`org` lines go. **Gate:** 1.3's grep 5 -> **3**. **New cases**, override unset, `SPL_VAR_APP_DIR=$T/var`: `git-prune-merged-cron.sh` (stub run, `GH_TOKEN=x`) creates `$T/var/git-prune-merged/run.lock`; `prune-go-build-cache-cron.sh` (the test's stub `run`) records `LOCK=$T/var/go-cache-prune/prune.lock`. **Red control:** both FAIL on the parent (it writes under `/var/<org>/<app>`); the parent's control runs as a user that cannot write there, or reads only the recorded path, so no live lock is taken; output in the body. **Behaviour:** the existing cases (override set) pass unchanged; pass counts equal plus the new cases. Tests: `git-prune-merged-cron.tst.sh`, `prune-go-build-cache.tst.sh`, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 2 (after 01) |

**Re-measure first:** each row lane re-runs 1.3's gate grep and the line reads on the
`origin/master` it starts from, and says in its result if the sites moved.

**Subject** (R6 reads it): `<type>(r73-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r73-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** the `@param` help lines keep naming the default as `/var/<org>/<app>/<sub>`
(`box-disk-sweep-install-cron.func.sh:21`), which is the derived dir's shape (developer
guide 2.3.1), so they do not change; the guide already says paths come from
`spl_run_paths`. Each row carries `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: row 01. Batch 2: row 02**, after row 01 lands (R16: placed within 30
  minutes). The rows' code files are disjoint, but both add a case to
  `orc:tests/git-prune-merged-cron.tst.sh` and `orc:tests/prune-go-build-cache.tst.sh`,
  so R1 serialises them.
- No row edits `lib:spl-run-paths.func.sh`, a migration, `csi-spl-cnf/`, a workflow,
  terraform, `csi-spl-iac/`, `csi-spl-utl/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-247`, one call per
  path, 2026-11-20T06:02:24Z, n=1: **exit 4 on all 8 row paths** (the 5 code files, the 3
  test files): no live lane lists them; 10 live lanes on the other box record no files:
  c-049, c-060, c-625, c-778, c-789, c-812, c-924, c-927 (each `rotate`), c-811 (the b26
  panel seat, doc) and c-822 (b26-01, WUI blog switcher e2e).
- **Every remote branch committed in the last 24 h** (63 branches after a fetch,
  2026-11-20T06:02:50Z): `git diff --name-only $(git merge-base origin/master <b>) <b>`
  restricted to `box-disk-sweep|git-prune-merged|prune-go-build-cache` -> **0 hits**.
  So the no-files lanes' pushed branches hold no row file; their unpushed work was not
  read.
- **This box's lane worktrees** (2026-11-20T06:02:55Z, 158 that exist):
  `git -C <wt> diff --name-only origin/master...HEAD` and `git -C <wt> diff --name-only HEAD`,
  same filter -> **0 hits**. The other box's worktrees were not read by this lane.
- **Commits since W** on the 8 row paths (`git log origin/master --since="$W" -- <paths>`) -> **0**.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-20T06:03:19Z):
  **0 queued, 0 placing**; live share `refactor 3 23% (band 10-20%: OVER)`, `phase day`;
  last 24 h `refactor 18% (band 20-30%: UNDER)`.
- **Briefs on this lane's box** naming a row file
  (`grep -rlE 'box-disk-sweep-install|git-prune-merged|prune-go-build-cache'` over
  `/var/spool-hub/dispatch/briefs` and `/var/spool-hub/spawn-remote/briefs`, as root,
  06:03Z): the newest is the r71-02 reviewer brief (landed), then older ones
  (`go-cache-size-cap`, `c002-orc-go-cache-prune-in-use`, landed lanes).
- **Unlanded round rows:** none known to this lane; b26-01 (c-822) is WUI test files,
  not a row file.

## 3. Per row: what the lane does

- **r73-01:** the 3 `run/` sites derive their dir with `spl_var_app_subdir` when the
  override is unset; the installers' cron lines and the prune lock are the same on the
  box. The 3 suites each gain the default-path case.
- **r73-02:** the 2 cron wrappers derive their lock dir with `spl_run_paths`, as the
  other wrappers in `scripts/` do; their 3 hand lines go. The 2 suites each gain the
  default-path case.

## 4. Panel and reviewers (R7)

- Editor: c-247 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r73`):
  one **cross-vendor** doc seat: agy is the main vendor for plan reviews, mistral its
  backup, as r62 to r72 had (the brief: no agy CLI on one box, agy quota out on the
  other until ~11-24, so mistral is the likely seat). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2), the holder's call when the row
  is queued (a fresh claude seat under the claude waiver, as r63 to r72). Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3, its R7 reviewer seat, and "re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r73-01 | `c002-r73-01-orc-var-app-subdir-cron-dirs` | `refactor(r73-01-orc-var-app-subdir-cron-dirs, SPL-<row issue>): ...` | `review/r73-01` | 1 |
| r73-02 | `c002-r73-02-orc-var-app-dir-cron-wrappers` | `refactor(r73-02-orc-var-app-dir-cron-wrappers, SPL-<row issue>): ...` | `review/r73-02` | 2, after r73-01 lands |

**r73-01 brief, Files: ONLY** `orc:run/box-disk-sweep-install-cron.func.sh` (`:30-32`),
`orc:run/git-prune-merged-install-cron.func.sh` (`:23-25`),
`orc:run/prune-go-build-cache.func.sh` (`go_cache_lock_or_stop`, `:241-251`), and one
new case each in `orc:tests/box-disk-sweep.tst.sh`, `git-prune-merged-cron.tst.sh`,
`prune-go-build-cache.tst.sh`. NOT `lib:spl-run-paths.func.sh`, NOT `orc:scripts/`
(row 02), NOT the tenant-dir sites. Do: plan section 2 row 01 verbatim, 1.3's `run/`
form; the gate (8 -> 5), the 3 new cases red on the parent (the lock case with a stub
`flock`) and green on the change, the byte-identical dry-run lines, and the suites'
counts in the body. Gates: the 4 suites of 1.3, `no-literal-paths.tst.sh`,
`bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r73-02 brief, Files: ONLY** `orc:scripts/git-prune-merged-cron.sh` (`:39-43`),
`orc:scripts/prune-go-build-cache-cron.sh` (`:32-36`), and one new case each in
`orc:tests/git-prune-merged-cron.tst.sh` and `prune-go-build-cache.tst.sh`. NOT
`lib:spl-run-paths.func.sh`, NOT `orc:run/`. Do: plan section 2 row 02 verbatim, 1.3's
`scripts/` form; the gate (5 -> 3), the 2 new cases red on the parent without taking a
live lock and green on the change, the suites' counts in the body. Gates:
`git-prune-merged-cron.tst.sh`, `prune-go-build-cache.tst.sh`, `no-literal-paths.tst.sh`,
`bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude. Placed after r73-01 lands.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash actions 1, Bash cron wrappers 1) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: row 01; batch 2: row 02 |
| hand-spelled `/var/$org/...` lines in `csi-spl-orc/src/bash` outside tests (1.3's gate) | 8 today -> 5 after r73-01 -> 3 after r73-02 |
| measured on | `5c7f42f70`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | 66 caller lines in 37 files, 57 of them in 30 e2e files (an upper bound, 1.2). Most e2e calls sit in `page.evaluate` bodies that `pnpm run typecheck` does not see, so a missed caller would silently pass its arguments into the wrong slot; the row would rewrite every caller, add a positional-call gate, and run every e2e file the pre-push map selects for those 30. Too big for one row of a 2-row round: a candidate for a round of its own (one row), with its caller list read line by line first | 1.2 |
| the 3 tenant-dir sites (`orc:run/spl-desk-rebox.func.sh:111`, `spl-invite-e2e.func.sh:118`, `spl-m3-e2e.func.sh:159`) | they name the tenant root-key store: secret-class work (the data rule), and two of them drive e2e runs against the hosted hub; a row of their own, placed on a secret-class vendor | 1.3 |
| `iac:run/` (3: `gcp-backup-env.func.sh:55`, `gcp-s3-download-all.func.sh:24`, `install-weekly-full-scan-cron.func.sh:48`) and `csi-spl-utl/src/bash/run/` (4: `box-disk-guard-install.func.sh:114,116`, `box-proc-sample.func.sh:303,334`) | the same hand-spelled shape, but `spl_run_paths` lives in the orc lib: an iac or utl action would source another module's lib, a choice for its own row (or a shared lib first); `gcp-backup-env` is also secret-class (env backups) | 1.3 |
| the other 27 hand-spelled lines in `orc:` (22 `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>`, 5 `/var/${org_app\|ORG_APP\|app}/...`; the panel's W1) | the same refactor as rows 01-02 at 27 sites, mostly `*-install-cron` actions: inputs for the next refactor rounds, 2-3 rows of about 5 sites each, each site re-checked for equivalence as 1.3 did | 1.3 |
| a gate for the shape (extend `no-literal-paths.tst.sh` with a baseline) | its pattern must cover all three spellings, `/(var\|opt)/\$\{?(ORG\|org\|SPL_ORG_APP\|org_app\|ORG_APP\|app)\b` (`/(var\|opt)/$org` alone misses 27 of 35); once the rows land the orc count is 30 (35 - 5); a gate row then ratchets the rest. Kept out so this round stays at 2 rows | 1.3 |
| SC2034 baseline, iac test SC2034, `workflow-tool-checksums.tst.sh:33` `naked`, the p18-02 N1 workflow comment | r71 and r72 section 7's reasons hold; the baseline is unchanged since r71 | 1.2 |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66 to r72) | 1.2 |
| bash `LONG` `do_provision_firebase_dns` 169 and `[long-example]` | pinned byte-identical to its upstream port (`iac:tests/wui-hosting-019-031.tst.sh`): it belongs upstream first (r67) | 1.2 |
| `action-header-tags-baseline.txt` `[missing]` 9 files | each declares a `(required)` param; a parsed header makes `do_validate_params` refuse before the body: behaviour, a bug round's (rounds 20, 27-29, 34, 67) | 1.2 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour (T028's assertions), terraform layout (T026) or docs (T031); the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-247): first draft. A fresh round: the brief's inputs re-read on `5c7f42f70`
  give no row; one new measurement, the hand-spelled `/var/$org/$app` dir (8 lines in
  `csi-spl-orc/src/bash`), gives 2 rows on 5 sites, proven to derive the same dir on
  this box's 3 tree kinds. Window W and the r73 slug proof recorded.
- v1.0 (c-247): the panel seat m-256 (mistral) PASS on v0.1
  `76fb311e91dd9a72f67a1e3220cc6123b98e69c2` (spool msg 00451a0d here, c28af011 at the holder; `do_spl_review_line_check` rc 0 on the seat's box, DOCS-ONLY, the holder's run, msg a76e9957; task
  `dispatch-refactor-r73`; seat file `16d53eaf0` on
  `review/c002-refactor-round-73-mistral-seat`). Folded:
  - W1: the 8 lines are one spelling of 35 hand-spelled var-dir lines in `orc:` (22
    `SPL_ORG_APP`, 5 `org_app|ORG_APP|app`). Re-read by the editor (1.3): 8 + 22 + 5 =
    35. 1.3 and the intro now say 5 of 35; section 7 gains the other 27 and the future
    gate's pattern covers all three spellings. The rows, their sites and their gate
    (8 -> 5 -> 3) do not change.
  Its notes, none asking a change:
  - N1: lane map exit 4 on the 8 row paths; the no-file lanes' review branches
    (b26-01 `745cedb1b`, c-181's `60b6931e`) touch no row file.
  - N2: the candidates file grew after the editor's read (9542 -> 10395 B); its one
    new item (a placer gap on `*-panel-seat` briefs) is bug-shaped.
  - N3: the equivalence re-read 3 of 3 trees equal on the seat's box; a preset
    `SPL_VAR_APP_DIR` wins, as `spl_run_paths` documents.
  - N4: the live prune lock exists and was free; with the stub `flock` the parent's
    red control opens the file but never holds it.
  - N5: the five suites green at `5c7f42f70`, 88/13/55/16/8 pass lines, as 1.3.
  - N6: r66-01, r66-02 and r71-01 are ancestors of `5c7f42f70`.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-247 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-256 (mistral) PASS** on
  `76fb311e91dd9a72f67a1e3220cc6123b98e69c2` (spool msg 00451a0d here, c28af011 at the holder; review-line check rc 0, msg a76e9957; seat file `16d53eaf0`
  on `review/c002-refactor-round-73-mistral-seat`), W1 folded in v1.0, N1-N6 no change.
  agy was unavailable (the holder's read), so mistral took the seat.
- Row R7 seats: section 4.
