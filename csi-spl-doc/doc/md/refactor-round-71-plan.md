# Refactoring round 71 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6007  
Topic: 35e8ea36-d918-4937-b4b1-b880bf7a0962  
Discussion: 35e8ea36-d918-4937-b4b1-b880bf7a0962 (t1 #refactoring, "Refactor round 71", opener msg 1a915a2a)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r71**, plan `refactor-round-71-plan.md`, rows `r71-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 70 ([refactor-round-70-plan.md](refactor-round-70-plan.md),
v1.0 `ef0094700`) is served: r70-01 landed `1a56f4a85` (SPL-6004), r70-02 landed
`53d2fc25a` (SPL-6005). Round 69's r69-02 (the `MergeTopic` parameter object, api) is
still in its lane, unlanded, so r71 stays off its files (2.2). No signed row is handed on:
r71 is a fresh round. The perf floor (rulebook 4.4), the holder's read on `6fedc5bbb`:
`perf 29 refactor 98 perf-share 22.8% floor-met`, so the next round is a refactor round.

The round takes r70's carried N2 (the r70-01 R7 review by c-133): one derive-or-FATAL
block, the `$SPL_VAR_APP_DIR/<sub>` default of an orc action's state dir, written out by
hand in **5** copies on `6fedc5bbb` (the brief named 3; the read below found 2 more).
Row 01 folds it into one helper and moves the 3 named copies; row 02 moves the other 2.

**Status: v0.1, draft**, for the panel (section 4). Editor: **c-156** (claude).

**One sha:** every count is measured on **`6fedc5bbb`** (`origin/master`
6fedc5bbbd2f3f29641028378cf31d7a0afc9a6c, committed 2026-11-20T01:26:24+01:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`, shellcheck
0.10.0, and the tests on this lane's worktree at that sha, as the push user with
`SPOOL_TEST=1`. Queue, lane map, brief and worktree readings are live state and carry
their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-20T00:46:16+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r70-plan'` -> commit
  `ef0094700` "refactor round 70 plan v1.0, signed by m-117 mistral PASS on 87a07ddb5".
  Every later read of r71 uses this W.
- **`r71` is free** (2026-11-20T00:40:42Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r71-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r71-*' 'refs/heads/wip/*r71*' 'refs/heads/*-r71-*' 'refs/heads/*refactor-round-71*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r71-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (as root) on this lane's box -> **0 files**. The other box's briefs were not read by
    this lane.
  - Control: the same log read for `r70` -> 3 lines (`53d2fc25a` r70-02, `1a56f4a85`
    r70-01, `ef0094700` the plan), so the read sees a used id.
- **No `refactor-round-71*` file** exists under `csi-spl-doc/doc/md` on `6fedc5bbb`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-71` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The candidates, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `lib:` = `csi-spl-orc/lib/bash/funcs/`,
`sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`.

| input | source | on `6fedc5bbb` | here |
|---|---|---|---|
| r70's N2: one derive-or-FATAL block in 3 copies | the brief (c-133's r70-01 review, checked by the r70 editor) | `git grep -nE 'SPL_VAR_APP_DIR:\+' 6fedc5bbb -- . ':!csi-spl-doc'` -> **6 lines**; 5 of them are `spl_run_paths && <var>="${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/<sub>}"` inside `if [[ -z "$<var>" ]]` (1.3); the 6th, `orc:run/spl-reflection-gather.func.sh:217`, is a subshell read with no FATAL, another shape | **rows 01 and 02** |
| `.shellcheck-warning-baseline.txt` | the brief | `grep -vcE '^\s*(#\|$)'` -> **68 lines** (70 at r70, minus r70-02's 2); SC2034 23 lines. `sa:lib/` 2 files (`spool-env`, `spool-mirror-hooks`): upper-case globals for a sourcer; iac tests 4 lines: `APP_PATH` x2 and `GCP_ACCOUNT` set for the sourced action, `naked` in `workflow-tool-checksums.tst.sh:33` a guard computed and never asserted (r67 1.3: a bug row); `sa:scripts/` and `orc:run/spl-spec-import-issues.func.sh:300-304`: vars a sourced lib or launcher may read | nothing taken (section 7) |
| `no-literal-paths.baseline` | the brief | `git show 6fedc5bbb:csi-spl-orc/src/bash/tests/no-literal-paths.baseline \| grep -vE '^\s*(#\|$)'` -> **1 line**, `spl-file-erase.func.sh`: a deny list r66 to r70 ruled a behaviour change | left out (section 7) |
| the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, read 2026-11-20T00:4xZ, 9542 bytes, last changed 2026-11-19 22:49) | the brief | refactor-shaped items: (a) the agent-boot-restore dir: served by r70-01 `1a56f4a85`; (b) r34 N3, literal `/var` in the watchdog and lane-rotate: served (r70 1.2); (c) r63-01 W1, `orc:scripts/reverse-tunnel-cron.sh`: served (r70 1.2); (d) SPL-5828 N1, the uplink probe's "exits 0" help: served, `orc:run/spl-uplink-probe.func.sh:14-15` now says "In probe mode a down link never fails the probe ... A config fault does, FATAL with rc 1"; (e) p18-02 N1, a comment in `.github/workflows/10_ci-quality.yml:444-445`: a workflow edit, left out (section 7). The rest is bug-shaped (review-go, the reflection sweep, the desk hop's env, the placer's author pick, the sha256 prefix, terraform `-input=false`, the e2e flake, the OS-user suites): not refactor rows | nothing new |
| r69 and r70 R7 findings | the brief | r70-01 `1a56f4a85` and r70-02 `53d2fc25a` each carry one `review:` line (c-133, c-140); N2 above is the one refactor-shaped note the brief relays. The seat files were not read | N2 taken |
| Go `wideFuncs` `MoveMessage` pair | r70 section 7 | r69-02 (c-638) is still unlanded and shares 5 test files and `cleancode_test.go` with it | left out by R3 (section 7) |
| spec 011 tasks | the brief | the spec folder unchanged since W (`git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0) | left out (section 7), r65 to r70's reasons hold |

### 1.3 The 5 copies of the block

Each copy, inside `if [[ -z "$<var>" ]]; then ... fi` after the env override was read:

```text
declare -F spl_run_paths >/dev/null || source ".../lib/bash/funcs/spl-run-paths.func.sh"
spl_run_paths && <var>="${SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/<sub>}"
[[ -n "$<var>" ]] || { do_log "FATAL cannot derive the <what> (no tree for spl_run_paths): set <OVERRIDE>"; return 1; }
```

| # | file:line | var | `<sub>` | on no dir | row |
|---|---|---|---|---|---|
| 1 | `orc:run/spl-agent-boot-restore-install-cron.func.sh:59-61` | `logdir` | `agent-boot-restore` | FATAL, rc 1 | 01 |
| 2 | `orc:run/spl-watchdog.func.sh:540-542` (`spl_wd_boot_retired`) | `d` | `agent-boot-restore` | **`return 0`, prints nothing** (its comment `:534-536`: "No dir derived: prints nothing") | 01 |
| 3 | `orc:run/setup-reverse-tunnel.func.sh:48-50` | `dir` | `reverse-tunnel` | FATAL, rc 1 | 01 |
| 4 | `orc:run/prune-docker-images-install-cron.func.sh:38-40` | `logdir` | `docker-prune` | FATAL, rc 1 | 02 |
| 5 | `orc:run/spl-workspace-docs-purge.func.sh:51-53` | `dir` | `workspace-docs-purge/$ENV/$tenant/<UTC stamp>` | FATAL, rc 1 | 02 |

Read with `git grep -nE 'spl_run_paths &&' 6fedc5bbb -- csi-spl-orc csi-spl-utl csi-spl-iac`
-> 14 lines; the 5 above are the ones of this shape. The others take the bare
`$SPL_VAR_APP_DIR` or `$SPL_VAR_ORG_DIR` (`install-box-crons`, `spl-box-state-backup`,
`spl-uplink-probe`, `spl-cmd-guard-mode`, utl `fleet-logrotate-install`, three cron
scripts, tests): not this block, not in the round.

**The helper** (row 01), next to `spl_run_paths` in `lib:spl-run-paths.func.sh`
(after `:76`):

```bash
# spl_var_app_subdir <var> <sub>: set <var> (the caller's) to
# $SPL_VAR_APP_DIR/<sub> (spl_run_paths). rc 1, <var> untouched, when no
# dir is known; the caller says what that means (FATAL, or nothing to read).
spl_var_app_subdir() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  spl_run_paths && [[ -n "${SPL_VAR_APP_DIR:-}" ]] || return 1
  printf -v "$1" '%s/%s' "$SPL_VAR_APP_DIR" "$2"
}
```

- **No locals**, so the caller's variable name (`d`, `dir`, `logdir`) is never shadowed
  in `printf -v` (bash's dynamic scope). `printf -v` into a caller's var is already the
  tree's form (`orc:run/spl-uplink-probe.func.sh:77-86`, `spl_uplink_probe_dir`).
- `spl_run_paths` runs in the caller's shell, not in `$( )`: its exports (`SPL_ORG_DIR`,
  `SPL_WT_ROOT`, ...) stay set for the rest of the action, as they do today.
- Each caller keeps its own FATAL text and its own outcome: copy 2 stays `|| return 0`
  with nothing printed. A helper that FATALs itself would change copy 2 (a FATAL line in
  the watchdog log) and is out of this round: that would be a bug row.
- Each copy goes from 3 lines to 2: the `declare -F ... || source` line stays (the helper
  lives in the same lib; the line tests `spl_var_app_subdir`), and
  `spl_var_app_subdir <var> <sub> || { <its own outcome>; }` replaces the other two.
- Copy 5: the stamp `$(date -u +%Y%m%dT%H%M%SZ)` is now evaluated before the call, also
  when no dir is derived (then the action stops with its FATAL). Nothing else reads it:
  same output, same rc.
- **Read on this lane's box** (2026-11-20T00:4xZ, n=1, the helper above sourced after
  the lib at `6fedc5bbb`): `APP_PATH=<main checkout>` with `SPL_VAR_APP_DIR` and
  `SPL_WT_ROOT` unset, called from a function with `local d=""` -> `rc=0`,
  `d=<var>/csi/csi-spl/x`, `SPL_WT_ROOT` set in the caller's shell; no tree
  (`env -u APP_PATH -u PROJ_PATH -u SPL_VAR_APP_DIR SPL_RUN_PATHS_TOP=`), `v=old` ->
  `rc=1 v=old`; name `'a b'` -> `rc=1`. The row lane writes these as test cases.

**Before** (this lane, worktree at `6fedc5bbb`, 2026-11-20T00:4xZ, n=1,
`SPOOL_TEST=1`, as the push user, rc 0 each):
`orc:tests/spl-run-paths.tst.sh` `ALL PASS` (20 pass lines);
`orc:tests/wd-reboot.tst.sh` `wd-reboot: all passed` (64);
`orc:tests/boot-cron-gate.tst.sh` `0 failure(s)` (10);
`sa:tests/test-agent-boot-restore.sh` `37 passed, 0 failed`;
`orc:tests/reverse-tunnel.tst.sh` `ALL PASS` (62);
`orc:tests/prune-docker-images.tst.sh` `0 failure(s)` (49);
`orc:tests/spl-workspace-docs-purge.tst.sh` `ALL PASS` (19);
`orc:tests/install-box-crons.tst.sh` `0 failure(s)` (40);
`orc:tests/no-literal-paths.tst.sh` `ALL PASS` (8).
"pass lines" = `grep -ciE '^ *(ok|pass)'` of the output, the same read after.

**No test reads a no-dir branch today**:
`git grep -nE 'cannot derive the (boot restore|reverse tunnel|docker prune|purge export)' 6fedc5bbb -- '*tests*'`
-> **0**. `wd-reboot.tst.sh` case 11 (`:387-400`) reads copies 1 and 2 with
`SPL_VAR_APP_DIR` set. The rows add the no-dir cases.

**Tests (R2):** `git grep -lF <name> 6fedc5bbb -- '*tests/*' '*.tst.sh' .github/workflows`
for `spl-run-paths`, `spl_run_paths`, `spl_wd_boot_retired`,
`do_spl_agent_boot_restore_install_cron`, `do_setup_reverse_tunnel`,
`do_prune_docker_images_install_cron`, `do_spl_workspace_docs_purge`,
`BOOT_CRON_LOG_DIR`, `REVERSE_TUNNEL_STATE_DIR`, `PRUNE_CRON_LOG_DIR`,
`PURGE_EXPORT_DIR` ->
- row 01: `orc:tests/` `spl-run-paths`, `wd-reboot`, `boot-cron-gate`,
  `reverse-tunnel`, `install-box-crons`, `no-literal-paths`, `wd-login-snapshot`,
  `spl-file-stream-follow`, `spl-cmd-guard-mode`, `spl-box-deploy`;
  `sa:tests/test-agent-boot-restore.sh`; `csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh`;
  `csi-spl-utl/src/bash/tests/fleet-logrotate.tst.sh` (they source the lib or name the
  actions); plus `orc:tests/run-eager-files.tst.sh` (a new function in a `lib/bash/funcs`
  file: the `./run` index's lazy stubs) and
  `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`.
- row 02: `orc:tests/prune-docker-images.tst.sh`, `orc:tests/git-prune-merged-cron.tst.sh`
  (names `PRUNE_CRON_LOG_DIR`), `orc:tests/spl-workspace-docs-purge.tst.sh`,
  `no-literal-paths`, `bash-cleancode`.

## 2. The 2 rows

Paths: `orc:` = `csi-spl-orc/src/bash/`, `lib:` = `csi-spl-orc/lib/bash/funcs/`.

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r71-01-orc-var-app-subdir-helper)` | folded helpers exist once (developer guide 2.2.4); canonical paths (2.3.1) | the same derive block (1.3) is written out by hand in 5 actions; the 3 copies N2 named go to one helper, and the watchdog's silent copy keeps its silence | `lib:spl-run-paths.func.sh:76` (new `spl_var_app_subdir`)<br>`orc:run/spl-agent-boot-restore-install-cron.func.sh:59-61`<br>`orc:run/spl-watchdog.func.sh:540-542`<br>`orc:run/setup-reverse-tunnel.func.sh:48-50`<br>`orc:tests/spl-run-paths.tst.sh` (new cases) | 1 helper, 3 copies, 3 lines out | the change of 1.3 for copies 1 to 3. **Red control:** new `spl-run-paths.tst.sh` cases: (a) `spl_var_app_subdir v x` with `APP_PATH` set -> rc 0, `v` = `<derived var dir>/x`, `SPL_WT_ROOT` set in the same shell; (b) no tree (`env -u APP_PATH -u PROJ_PATH -u SPL_VAR_APP_DIR SPL_RUN_PATHS_TOP=`) -> rc 1, `v` keeps its old value; (c) a bad name (`'a b'`) -> rc 1. On `6fedc5bbb` (no function) the cases FAIL; with the change PASS. **Behaviour, the no-dir branch** (new cases, GREEN before and after): `do_spl_agent_boot_restore_install_cron` and `do_setup_reverse_tunnel` with no tree and no override -> rc 1 and their own FATAL line, unchanged; `spl_wd_boot_retired` with no tree -> rc 0, empty output. Run them on the parent too, both outputs in the body. Each column test's count the same before and after (1.3), plus the new cases. Tests: 1.3's row 01 column, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r71-02-orc-var-app-subdir-callers)` | as row 01 | the 2 copies left after row 01 take the helper | `orc:run/prune-docker-images-install-cron.func.sh:38-40`<br>`orc:run/spl-workspace-docs-purge.func.sh:51-53` | 2 copies, 2 lines out | the change of 1.3 for copies 4 and 5. **Gate:** `git grep -nE 'SPL_VAR_APP_DIR:\+\$SPL_VAR_APP_DIR/' -- csi-spl-orc/src/bash/run` -> 0 after row 02 (5 on `6fedc5bbb`, 2 after row 01). **Behaviour:** new no-dir cases in `prune-docker-images.tst.sh` and `spl-workspace-docs-purge.tst.sh` (no tree, no override -> rc 1 and the action's own FATAL line), GREEN on the parent and on the change, both outputs in the body; each column test's count the same before and after (1.3), plus the new cases. Tests: 1.3's row 02 column, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 2 (after 01) |

**Re-measure first:** each row lane re-runs the `git grep` reads of 1.2 and 1.3 on the
`origin/master` it starts from, and says in its result if the sites moved.

**Subject** (R6 reads it): `<type>(r71-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r71-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** the helper's comment is its doc; the actions' `@param` help lines already say
the dir is `SPL_VAR_APP_DIR/<sub>` from `spl_run_paths`, refused when neither is known,
and do not change. No `csi-spl-doc/` page outside the round plans names the block
(`git grep -n 'SPL_VAR_APP_DIR:+' 6fedc5bbb -- csi-spl-doc`). Each row carries
`Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: row 01** (the lib, its test, 3 actions, 2 action tests).
- **Batch 2: row 02** (2 other actions and their tests), after row 01 lands: it calls
  the helper row 01 adds. Queued `SPAWN_AFTER=<row 01 slug>`, spawned within 30 minutes
  of row 01 on trunk (R16). Files disjoint from row 01's.
- No row edits a migration, `csi-spl-cnf/`, a workflow, terraform, or a file under
  `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-156`, one call per
  path, 2026-11-20T00:41:54Z, n=1: **exit 4 on all 7 action and lib paths** (the lib,
  `spl-run-paths.tst.sh`, the 5 actions): no live lane lists them; 11 live lanes record
  no files. The holder's R3 check before the spawn governs.
- **This box's lane worktrees** (00:42:17Z): `git -C <wt> diff --name-only origin/master...HEAD`
  and `git -C <wt> diff --name-only HEAD`, restricted to those 7 paths, over every
  worktree of `git worktree list` -> **0 hits**. Live agent windows on this box: c-001,
  c-002, c-003, c-046 (spec 143 B-6b, api), this lane, and one retiring window.
- **The live lanes the brief names** (00:3xZ): c-638 r69-02 (api `MergeTopic`), c-640
  SPL-6000 / SPL-5882 T2 (rdb, store upsert), c-644 b24-01 (api hub flow, landed
  `6fedc5bbb`), c-646 b24-02 (`sa:tests/lib.inc.sh`), c-046 SPL-6006 (api), c-625
  (spec 181, doc only): none is a row path. The other box's worktrees were not read by
  this lane.
- **Commits:** `git log origin/master --since="$W" -- <the 7 paths>` -> **1**:
  `1a56f4a85` (r70-01: the boot-restore action and the watchdog). Landed; the line
  numbers of 1.3 are read after it.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-20T00:42:17Z):
  **0 queued, 0 placing**. Live share `refactor 3 21% (band 40-60%: UNDER)`; last 24 h
  `refactor 16% (band 20-30%: UNDER)`; `phase night`.
- **Briefs on this lane's box** that name a row path or symbol
  (`grep -rlE 'spl-run-paths\.(func|tst)|spl_wd_boot_retired|agent-boot-restore-install-cron|setup-reverse-tunnel\.func|prune-docker-images-install-cron|spl-workspace-docs-purge'`
  over `/var/spool-hub/dispatch/briefs` and `/var/spool-hub/spawn-remote/briefs`, as root,
  2026-11-20T00:42:35Z): this planner's brief, then the r70 row, reviewer and panel briefs
  (landed or a review seat, 2.7.6), then older.
- **Unlanded round rows:** r69-02 (api) and b24-02 (`sa:tests/lib.inc.sh`): none of the
  rows' files.

## 3. Per row: what the lane does

- **r71-01:** `spl_var_app_subdir` joins `spl-run-paths.func.sh`; the boot-restore
  install-cron, the watchdog's retired-marker read and the reverse-tunnel setup take it.
  The watchdog keeps "no dir: print nothing, rc 0". Tests for the helper and for each
  caller's no-dir branch.
- **r71-02:** the docker-prune install-cron and the workspace-docs purge take the same
  helper; no hand-written copy of the block is left in `orc:run/`.

## 4. Panel and reviewers (R7)

- Editor: c-156 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r71`):
  one **agy** doc seat, the main vendor for spec and plan reviews, with mistral as its
  backup, as r62 to r70 had (the brief: no agy CLI on one box, agy quota out on the other
  until ~11-24, so mistral is the likely seat). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2), the holder's call when the row
  is queued (a fresh claude seat under the claude waiver, as r63 to r70). Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3, its R7 reviewer seat, and "re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r71-01 | `c002-r71-01-orc-var-app-subdir-helper` | `refactor(r71-01-orc-var-app-subdir-helper, SPL-<row issue>): ...` | `review/r71-01` | 1 |
| r71-02 | `c002-r71-02-orc-var-app-subdir-callers` | `refactor(r71-02-orc-var-app-subdir-callers, SPL-<row issue>): ...` | `review/r71-02` | 2, `SPAWN_AFTER=c002-r71-01-orc-var-app-subdir-helper` |

**r71-01 brief, Files: ONLY** `lib:spl-run-paths.func.sh` (the new function only),
`orc:tests/spl-run-paths.tst.sh` (new cases),
`orc:run/spl-agent-boot-restore-install-cron.func.sh`, `orc:run/spl-watchdog.func.sh`
(`spl_wd_boot_retired` only), `orc:run/setup-reverse-tunnel.func.sh`, and the no-dir
cases in `orc:tests/wd-reboot.tst.sh` and `orc:tests/reverse-tunnel.tst.sh`. Do: plan
section 2 row 01 verbatim, the helper as 1.3 writes it (no locals, `printf -v`, no FATAL
inside); the watchdog copy stays `|| return 0` with nothing printed; the red control's
two outputs (FAIL on the parent, PASS on the change) and the no-dir cases' outputs on
both in the body; each column test's count before and after (1.3). Run the tests with
`SPOOL_TEST=1`. Gates: 1.3's row 01 column, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r71-02 brief, Files: ONLY** `orc:run/prune-docker-images-install-cron.func.sh`,
`orc:run/spl-workspace-docs-purge.func.sh`, and the no-dir cases in
`orc:tests/prune-docker-images.tst.sh` and `orc:tests/spl-workspace-docs-purge.tst.sh`.
Do: plan section 2 row 02 verbatim after r71-01 is on `origin/master`; the `git grep`
gate (0 copies left) and the no-dir cases' outputs on the parent and the change in the
body; each column test's count before and after (1.3). Run the tests with
`SPOOL_TEST=1`. Gates: 1.3's row 02 column, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash lib + action code 1, Bash action code 1) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: row 01; batch 2: row 02 |
| hand-written `SPL_VAR_APP_DIR:+$SPL_VAR_APP_DIR/<sub>` derive blocks in `orc:run/` | 5 today -> 2 after r71-01 -> 0 after r71-02 |
| lines out | 5 (one per copy), plus the helper's 8 in |
| measured on | `6fedc5bbb`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:run/spl-reflection-gather.func.sh:217` `log="$( { spl_run_paths \|\| :; } ...; printf ... "${SPL_VAR_APP_DIR:+...}")"` | a subshell read with no FATAL and no override var: another shape; a helper call there needs its own read of what an empty value does downstream | 1.2 |
| Go `wideFuncs`: the `MoveMessage` pair (r70 section 7) | shares 5 test files and `cleancode_test.go` with r69-02, unlanded (c-638): R3. The first row of the round after r69-02 lands | r70 section 7 |
| SC2034 baseline: `sa:lib/spool-env.inc.sh`, `sa:lib/spool-mirror-hooks.inc.sh`, `sa:scripts/` (spawn, restore, chain, task families, `agent-top.sh:77`, `trust-workdir.sh:368`), `orc:run/spl-spec-import-issues.func.sh:300-304` | upper-case globals or vars a sourcer, launcher or called function may read: each needs the per-variable read check across every sourcer (r68, r70 section 7) | `shellcheck -S warning -i SC2034 -f gcc` on `6fedc5bbb` |
| iac test SC2034: `check-pre-push.tst.sh:53`, `check-weekly-full-scan.tst.sh:29` (`APP_PATH`), `satellite-actions.tst.sh:46` (`GCP_ACCOUNT`) | set for the sourced action under test to read (r67 1.3) | same |
| `iac:tests/workflow-tool-checksums.tst.sh:33` `naked` | a guard computed and never asserted: a bug row (r67 1.3) | same |
| `.github/workflows/10_ci-quality.yml:444-445` comment wording (p18-02 N1) | a workflow edit for one clause of a comment; fits a CI or perf row that touches the file anyway | the candidates file |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66 to r70) | 1.2 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour (T028's assertions), terraform layout (T026) or docs (T031); the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-156): first draft. A fresh round: r70's N2 re-measured on `6fedc5bbb` found 5
  copies of the derive block, not 3; row 01 adds the helper and moves the 3 named
  copies (the watchdog keeps its silent `return 0`), row 02 the other 2. Window W and the
  r71 slug proof recorded.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-156 (claude): v0.1.
- Panel reviewer seat: requested (section 4).
- Row R7 seats: section 4.
