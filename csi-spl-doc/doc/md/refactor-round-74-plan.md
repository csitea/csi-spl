# Refactoring round 74 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6021  
Topic: 4f8d99b3-9670-4dcf-8bd8-5699e1375a15  
Discussion: 4f8d99b3-9670-4dcf-8bd8-5699e1375a15 (t1 #refactoring, "Refactor round 74", opener msg 573ddb32)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r74**, plan `refactor-round-74-plan.md`, rows `r74-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 73 ([refactor-round-73-plan.md](refactor-round-73-plan.md))
is closed (`af8ca0ba7`): r73-01 landed `0509f0b7b` (SPL-6018), r73-02 landed `1c18a5be8`
(SPL-6020). No signed row is handed on: r74 is a fresh round. The perf floor (rulebook
4.4), the holder's read on `1c18a5be8`: `perf 29 refactor 103 perf-share 22.0% floor-met`,
so this is a refactor round.

Both rows come from r73 section 7's fourth line (the panel's W1 there): **22 lines in
`csi-spl-orc/src/bash/run` still build the app's var dir by hand as
`/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>`**, all in `*-install-cron` / `setup-*-cron`
actions. r73 moved the `/var/$org/$app` spelling to r71-01's helper
(`spl_var_app_subdir`); this round moves 10 of the 22 `SPL_ORG_APP` spellings the same
way, 5 per row, chosen so that no row file is on a live or queued lane (2.2). Row 01
takes 5 installers whose cron line runs `./run` or a script with no stack guard, row 02
5 whose cron line runs a script. The other 12 stay out (section 7).

**Status: v1.0**: panel seat m-295 (mistral) PASS on v0.1 `3036c5754`, no W finding;
N1-N3 recorded (section 8), none asks a change. Rows 01 and 02 are as drafted. Editor:
**c-290** (claude).

**One sha:** every count is measured on **`af8ca0ba7`** (`origin/master`
af8ca0ba723c03b70383d94830cdb8e6a3dd6f35, committed 2026-11-20T10:05:33+02:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`; the tests ran
on this lane's worktree at that sha, as the push user with `SPOOL_TEST=1`. Queue, lane
map, brief and worktree readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-20T10:05:33+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r73-plan'` -> commit
  `af8ca0ba7` "refactor round 73 plan records the round closed, rows 01-02 landed".
  Every later read of r74 uses this W.
- **`r74` is free** (2026-11-20T08:07:50Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r74-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r74-*' 'refs/heads/wip/*r74*' 'refs/heads/*-r74-*' 'refs/heads/*refactor-round-74*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r74-[0-9]{2}|refactor-round-74' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (as root) on this lane's box -> **1 file**, this planner's own brief. The other
    box's briefs were not read by this lane; the holder's read before the spawn: 0
    besides this brief (the brief).
  - Control: the same log read with `(r73-` since W -> 1 line, `af8ca0ba7` (the r73
    close record, whose body names the rows), so the read sees a used id.
- **No `refactor-round-74*` file** exists under `csi-spl-doc/doc/md` on `af8ca0ba7`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-74` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `lib:` = `csi-spl-orc/lib/bash/funcs/`,
`iac:` = `csi-spl-iac/src/bash/`.

| input | source | on `af8ca0ba7` | here |
|---|---|---|---|
| the 27 + 3 hand-spelled var-dir lines in `orc:` (r73 section 7, its W1) | r73 section 7 | 30 lines (1.3): 3 tenant dirs (`/var/$org/...`), 22 `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/...`, 5 `/var/${org_app\|ORG_APP\|app}/...` | **rows 01, 02** take 10 of the 22; the rest section 7 |
| the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`) | the brief | on this lane's box: 11841 bytes, last changed 2026-11-20 09:06 +0200. Its refactor-shaped items (the watchdog / lane-rotate `/var` literals, `reverse-tunnel-cron.sh`, the agent-boot-restore dir) are the ones r71 to r73 read as served; the items added since r73 read it (the `*-panel-seat` placer gap, the review-go "found locally only" GO) are bug-shaped and are bug round 27's two rows | nothing new |
| `.shellcheck-warning-baseline.txt` | the brief | `grep -vcE '^\s*(#\|$)'` -> **68 lines**; `git log --oneline --since="$W" -- .shellcheck-warning-baseline.txt` -> 0, the same 68 r73 read | nothing taken: r71 to r73 section 7's reasons hold |
| `no-literal-paths.baseline` | the brief | 1 entry, `2 csi-spl-orc/src/bash/run/spl-file-erase.func.sh` (a protected-root deny list, r66 to r73: behaviour) | left out (section 7) |
| r73 R7 findings | the brief | `0509f0b7b` (c-267) and `1c18a5be8` (c-282): `git log -1 --format=%B <sha> \| grep -nE '^(review:\|N[0-9]\|W[0-9])'` -> one `review:` line each (`:37`, `:44`), no N or W line in the bodies. Their N notes are in the spool (`spool tail --task dispatch-refactor-r73`): c-267 N1-N3 (the parent's red control opens the live prune lock unlocked; dry-run byte counts; the no-tree probe FATALs where the parent planned `/var///...`) and c-282 N1-N3 (the wrappers now export the `SPL_*` paths to the child `./run`; a tree outside `<base>/<org>/<app>` derives a moved dir; the FATAL is reachable only with `SPL_RUN_PATHS_TOP` empty), each "info, no change asked". None names a site left to move | nothing taken; 1.3 carries their lessons |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0, unchanged | left out (section 7), r65 to r73's reasons hold |

### 1.3 The hand-spelled `SPL_ORG_APP` var dir: 22 lines in `csi-spl-orc/src/bash/run`

`lib:spl-run-paths.func.sh:66-76` (`spl_run_paths`) derives `SPL_VAR_APP_DIR` =
`<var>/<org>/<main checkout name>`, and `spl_var_app_subdir <var> <sub>` (`:81-85`,
r71-01) sets a caller's variable to `$SPL_VAR_APP_DIR/<sub>`. The developer guide
(2.3.1): "No action carries a literal `/opt/<org>` or `/var/<org>` path". These lines
build the same dir by hand from `SPL_ORG_APP`, which each action sets just above as
`SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"`,
so `no-literal-paths.tst.sh` (it greps `/(opt|var)/<org>` with the org's real name)
cannot see them.

The three spellings, each with `-- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#'`:
`'/(var|opt)/\$\{?(ORG|org)\b'` -> **3** (the tenant dirs, r73's left-out);
`'/(var|opt)/\$\{?SPL_ORG_APP'` -> **22**; `'/(var|opt)/\$\{?(org_app|ORG_APP|app)\b'`
-> **5**; together **30** (r73 read 35 on `5c7f42f70`; its rows took 5).

The 22, with the row each one goes to:

| file (`orc:run/`) : line | sub | override | test that drives it | row |
|---|---|---|---|---|
| `spl-accepted-close-install-cron.func.sh:40` | `accepted-close` | `ACCEPT_CRON_LOG_DIR` | `orc:tests/spl-accepted-close.tst.sh` | 01 |
| `spl-desk-poll-ack-install-cron.func.sh:40` | `poll-ack` | `POLL_ACK_CRON_LOG_DIR` | `orc:tests/spl-desk-poll-ack.tst.sh` | 01 |
| `spl-security-round-install-cron.func.sh:44` | `security-round` | `SECURITY_ROUND_CRON_LOG_DIR` | `orc:tests/spl-security-round-queue.tst.sh` | 01 |
| `spl-spawn-fill-install-cron.func.sh:40` | `spawn-fill` | `SPAWN_FILL_CRON_LOG_DIR` | `orc:tests/spl-spawn-fill.tst.sh` | 01 |
| `spl-topic-archive-suggest-install-cron.func.sh:38` | `topic-archive-suggest` | `ARCHIVE_SUGGEST_CRON_LOG_DIR` | `orc:tests/spl-topic-archive-suggest.tst.sh` | 01 |
| `check-disk-headroom-install-cron.func.sh:46` | `disk-headroom` | `DISK_HEADROOM_CRON_LOG_DIR` | `orc:tests/check-disk-headroom.tst.sh` | 02 |
| `check-env-order-install-cron.func.sh:43` | `env-order` | `ENV_ORDER_CRON_LOG_DIR` | `orc:tests/check-env-order.tst.sh` | 02 |
| `setup-box-stats-cron.func.sh:48` | `box-stats` | `BOX_STATS_CRON_LOG_DIR` | `orc:tests/box-stats-cron.tst.sh` | 02 |
| `setup-ci-overflow-cron.func.sh:41` | `ci-overflow` | `CI_OVERFLOW_CRON_LOG_DIR` | `orc:tests/route-ci-overflow.tst.sh` | 02 |
| `setup-go-cache-prune-cron.func.sh:46` | `go-cache-prune` | `GO_CACHE_CRON_LOG_DIR` | `orc:tests/prune-go-build-cache.tst.sh` | 02 |
| `setup-gh-runner-cpu-budget-cron.func.sh:58`, `spl-box-restart-install-cron.func.sh:91`, `spl-desk-install-service.func.sh:120`, `spl-dispatch-rotate-install-cron.func.sh:74`, `spl-orch-rotate-install-cron.func.sh:45`, `spl-peer-crons.func.sh:137`, `spl-review-go-install-cron.func.sh:39`, `spl-spawn-place-install-cron.func.sh:38`, `spl-spawn-remote-install-cron.func.sh:48`, `spl-unanswered-sweep-install-cron.func.sh:57`, `spl-wd-ensure-install-cron.func.sh:76`, `spl-workspace-delivery-probe-install-cron.func.sh:53` | | | | out (section 7) |

**Same dir today, measured** (this lane's box, 2026-11-20T08:09:07Z, n=1 per tree; the
lib at `af8ca0ba7`, run as the push user under `env -i`): for `PROJ_PATH` = the main
checkout's, the desk-cron checkout's (a worktree: its `.git` is a `gitdir:` pointer into
the main clone) and this lane's worktree's `csi-spl-orc`, `spl_var_app_subdir d spawn-fill`
and the hand form (the `SPL_ORG_APP` line above, then
`/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/spawn-fill`) both print
`/var/<org>/<org>-<app>/spawn-fill`, **3 of 3 EQUAL** (`readlink -f` of the main and
desk-cron checkouts and of the var dir: no symlink). `SPL_ORG_APP` is only ever the
basename of `PROJ_PATH` without `-orc` (the action's own line, and
`lib:spl-cloud-cnf.func.sh:83-87`, `:137`, `:197`, the same rule). The two forms differ
only (a) in a tree outside `<base>/<org>/<app>`, where the derived dir moves with the
tree: the accepted consequence of r63-01, r71-01, r72-02 and r73 (developer guide
2.3.1; c-282's N2), (b) when the caller presets `SPL_VAR_APP_DIR`, which then wins, as
`spl_run_paths` documents (r73 panel N3), and (c) with no tree at all, where the parent
planned `/var///<sub>` and the change FATALs (c-267's N3: the stronger failure). The
helper also exports the `SPL_*` paths into the action's shell (c-282's N1): the values
the action would derive itself.

**The shape to copy** is on master, r73-01's `run/` form, e.g.
`orc:run/box-disk-sweep-install-cron.func.sh:31-34`:

```text
if [[ -z "$logdir" ]]; then
  declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
  spl_var_app_subdir logdir box-disk-sweep || { do_log "FATAL cannot derive the box disk sweep log dir (no tree for spl_run_paths): set BOX_SWEEP_CRON_LOG_DIR"; return 1; }
fi
```

Each site becomes `logdir="${<OVERRIDE>:-}"` followed by that block with its own sub
and override name. `logdir` is already a `local` in every one of the 10 functions
(`grep -nE 'local .*\blogdir\b'`), so the helper's `printf -v` writes the action's own
variable. `SPL_ORG_APP` stays: every site still reads it for its `tag`, its `run` /
`script` path or its `spl_cron_no_stack_pre` tree (`grep -n SPL_ORG_APP` on each file).

**Function length** (bash clean code cap 75, `iac:tests/bash-cleancode.tst.sh`): the
`do_*` functions are 35 to 38 lines (row 01) and 49 to 58 lines (row 02) today
(`awk` from `^do_...() {` to the first `^}`); the block adds 3 lines. Under the cap.

**Tests (R2):** each site's own suite (the table's column) is the only test that
names its file or action (`git grep -lE '<file basename>|<do_ name>' af8ca0ba7 -- '*tests/*'`;
row 02's `setup-go-cache-prune-cron` is driven by `prune-go-build-cache.tst.sh`). Plus
`orc:tests/no-literal-paths.tst.sh` (it scans `run/`) and `iac:tests/bash-cleancode.tst.sh`
(a line count). **Every existing case passes the override** (each suite names its
`*_CRON_LOG_DIR` once, and no suite names a `/var/<org>` path; only
`prune-go-build-cache.tst.sh` names `SPL_VAR_APP_DIR`, in 6 lines of r73's cases for
other functions), so no test reads the default today: each row adds the default's case
per site (section 2).

**Before** (this lane, worktree at `af8ca0ba7`, 2026-11-20T08:09-08:14Z, n=1,
`SPOOL_TEST=1`, as the push user; pass lines `grep -ciE '^ *(ok|pass)'`, fail lines
`grep -ciE '^ *(not ok|fail)'`), all rc 0 and 0 fail lines:

| suite | pass lines | last line |
|---|---|---|
| `spl-accepted-close.tst.sh` | 31 | `spl-accepted-close: 0 failure(s)` |
| `spl-desk-poll-ack.tst.sh` | 36 | `spl-desk-poll-ack: 0 failure(s)` |
| `spl-security-round-queue.tst.sh` | 30 | `PASS: all` |
| `spl-spawn-fill.tst.sh` | 43 | `PASS: all` |
| `spl-topic-archive-suggest.tst.sh` | 51 | `spl-topic-archive-suggest: all passed` |
| `check-disk-headroom.tst.sh` | 42 | `check-disk-headroom: 0 failure(s)` |
| `check-env-order.tst.sh` | 33 | `PASS: all check-env-order assertions` |
| `box-stats-cron.tst.sh` | 35 | `box-stats-cron: all passed` |
| `route-ci-overflow.tst.sh` | 37 | `route-ci-overflow: all passed` |
| `prune-go-build-cache.tst.sh` | 57 | `prune-go-build-cache: all passed` |
| `no-literal-paths.tst.sh` | 8 | `ALL PASS` |
| `iac:tests/bash-cleancode.tst.sh` | - | `PASS: all bash-cleancode.tst.sh assertions` |

**Gate** (both rows): `git grep -nE '/(var|opt)/\$\{?SPL_ORG_APP' -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l`
-> **22** on `af8ca0ba7`, **17** after either row, **12** after both. The three
spellings together: 30 -> 20.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r74-01-orc-var-app-subdir-run-crons)` | canonical paths, no box path in an action (developer guide 2.3.1); folded helpers exist once (2.2.4) | 5 cron installers build their log dir by hand from `SPL_ORG_APP`, which the literal-path gate cannot see; r71-01's helper derives it | `orc:run/spl-accepted-close-install-cron.func.sh:40`<br>`orc:run/spl-desk-poll-ack-install-cron.func.sh:40`<br>`orc:run/spl-security-round-install-cron.func.sh:44`<br>`orc:run/spl-spawn-fill-install-cron.func.sh:40`<br>`orc:run/spl-topic-archive-suggest-install-cron.func.sh:38`<br>(+ one new case in each site's suite, 1.3's table) | 5 sites | Each site takes 1.3's form: the override kept, else `spl_var_app_subdir logdir <sub>` (`accepted-close`, `poll-ack`, `security-round`, `spawn-fill`, `topic-archive-suggest`), FATAL + `return 1` naming the override when no tree. **Gate:** 1.3's grep 22 -> **17**. **New cases**, one per suite, override unset, `SPL_VAR_APP_DIR=$T/var`, the suite's own crontab stub and a `DRY_RUN=1` install: the printed cron line holds `$T/var/<sub>/` (its lock and its `cron.out` / `cron.log`) and nothing is created under `$T/var`. **Red control:** the 5 new cases FAIL on the parent (it prints `/var/<org>/<org>-<app>/<sub>`), output in the body; a dry run writes nothing, so no live dir is touched. **Behaviour:** on this box with no override each installer's `DRY_RUN=1` output is byte-identical on the parent and the change (its crontab a fake file), diff in the body; the 5 suites' pass counts equal 1.3's plus the new cases. Tests: the 5 suites, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (all `SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push` (shellcheck: no new warning). | either | claude | simple_coding | 1 |
| 02 `refactor(r74-02-orc-var-app-subdir-script-crons)` | as row 01 | 5 more cron installers, whose line runs a script under the stack guard, build their log dir the same way | `orc:run/check-disk-headroom-install-cron.func.sh:46`<br>`orc:run/check-env-order-install-cron.func.sh:43`<br>`orc:run/setup-box-stats-cron.func.sh:48`<br>`orc:run/setup-ci-overflow-cron.func.sh:41`<br>`orc:run/setup-go-cache-prune-cron.func.sh:46`<br>(+ one new case in each site's suite, 1.3's table) | 5 sites | As row 01, subs `disk-headroom`, `env-order`, `box-stats`, `ci-overflow`, `go-cache-prune`. **Gate:** 1.3's grep 22 -> **17** on its own, **12** with row 01. **New cases** as row 01: the printed line holds `$T/var/<sub>/` (its `cron.out`, and for the 4 that call `spl_cron_no_stack_pre`, its `cron.lock`). **Red control:** the 5 new cases FAIL on the parent, output in the body; dry runs only. **Behaviour:** as row 01 (byte-identical `DRY_RUN=1` output, diff in the body; the 5 suites' counts equal 1.3's plus the new cases). Tests: the 5 suites, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs 1.3's gate grep and the line reads on the
`origin/master` it starts from, and says in its result if the sites moved.

**Subject** (R6 reads it): `<type>(r74-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r74-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each action's `@param <OVERRIDE>` help line names the default as
`/var/<org>/<org>-<app>/<sub>` (e.g. `spl-spawn-fill-install-cron.func.sh:18`), which is
the derived dir's shape on a `<base>/<org>/<org>-<app>` tree (developer guide 2.3.1),
so it does not change; the guide already says paths come from `spl_run_paths`. Each
row carries `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, placed together. Their file sets are disjoint: 10 code
  files and 10 suites, no file in both (1.3's table); `no-literal-paths.tst.sh` and
  `bash-cleancode.tst.sh` are run, not edited. The second row to land rebases over
  the first without a shared line; its gate count is then 12.
- No row edits `lib:spl-run-paths.func.sh`, a migration, `csi-spl-cnf/`, a workflow,
  terraform, `csi-spl-iac/`, `csi-spl-utl/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

- **Bug round 27 (SPL-6019, planner c-275, its rows once queued):** its plan
  (`review/c002-bug-round-27-planner` at `282437e3a`, v0.1) names
  `orc:run/spl-review-go.func.sh`, `orc:tests/spl-review-go.tst.sh`,
  `orc:run/spl-spawn-place.func.sh`, `orc:tests/spl-spawn-queue.tst.sh`,
  `orc:run/spl-spawn-review-notify.func.sh`, `orc:run/run.sh` (read) and
  `orc-shard-weights.txt`; its row 01 also *runs* `orc:tests/spl-accepted-close.tst.sh`
  (b27 plan `:55`, it reads the same PASS record form) but does not edit it (the panel's
  N2). So `spl-review-go-install-cron.func.sh` (its suite is
  `spl-review-go.tst.sh`) and `spl-spawn-place-install-cron.func.sh` (its suite is
  `spl-spawn-queue.tst.sh`) are left out of this round (section 7). No r74 row file is
  in b27's list.
- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-290`, one call per
  path, 2026-11-20T08:09:25Z, n=1: **exit 4 on all 20 row paths** (10 code files, 10
  suites): no live lane lists them; 6 live lanes on the other box record no files:
  c-049, c-060, c-625, c-812, c-924, c-927 (each `rotate`).
- **Every remote branch committed in the last 24 h** (90 branches after a fetch,
  2026-11-20T08:10:53Z): `git diff --name-only $(git merge-base origin/master <b>) <b>`
  filtered for the 20 row files -> **2 hits**, `review/r73-01` and `review/r73-02` on
  `prune-go-build-cache.tst.sh`: both landed (`git cherry origin/master <b>` -> `-`, the
  patch is on master as `0509f0b7b` / `1c18a5be8`). So the no-files lanes' pushed
  branches hold no row file; their unpushed work was not read.
- **This box's lane worktrees** (2026-11-20T08:11:02Z, 166 listed):
  `git -C <wt> diff --name-only origin/master...HEAD` and `git -C <wt> diff --name-only HEAD`,
  same filter -> **0 hits**. The other box's worktrees were not read by this lane.
- **Commits since W** on the 20 row paths (`git log origin/master --since="$W" -- <paths>`) -> **0**.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-20T08:11:31Z):
  **0 queued, 0 placing**; live share `refactor 1 10% (band 10-20%: ok)`, `phase day`;
  last 24 h `refactor 18% (band 20-30%: UNDER)`.
- **Briefs on this lane's box** naming a row file (`grep -rlE` of the 10 code file
  names over `/var/spool-hub/dispatch/briefs` and `/var/spool-hub/spawn-remote/briefs`,
  as root, 08:11Z): 5 old briefs, all last changed 2026-11-18 12:51
  (`g002-b02-03`, `c002-s166-b7-claude-waiver-reviewer`, `c002-s166-b7-fixed-clocks`,
  `c002-bug-go-cache-busy-never-pruned`, `c002-bug-disk-guard-unlocked-checkout`); no
  live lane lists their files (the lane map above).
- **Unlanded round rows:** b27's two (above); c-625 (the other box) writes a spec doc
  only, per the brief; the dedicated channel seats on the other box work outside this repo.

## 3. Per row: what the lane does

- **r74-01:** 5 cron installers derive their log dir with `spl_var_app_subdir` when
  the override is unset; their cron lines are the same on the box. The 5 suites each
  gain the default-path case.
- **r74-02:** the same for 5 more installers.

## 4. Panel and reviewers (R7)

- Editor: c-290 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r74`):
  one **cross-vendor** doc seat: agy is the main vendor for plan reviews, mistral its
  backup, as r62 to r73 had (the brief: no agy CLI on this box, agy quota out on the
  other until ~11-24, so mistral is the likely seat). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2), the holder's call when the row
  is queued (a fresh claude seat under the claude waiver, as r63 to r73). Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3, its R7 reviewer seat, and "re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r74-01 | `c002-r74-01-orc-var-app-subdir-run-crons` | `refactor(r74-01-orc-var-app-subdir-run-crons, SPL-<row issue>): ...` | `review/r74-01` | 1 |
| r74-02 | `c002-r74-02-orc-var-app-subdir-script-crons` | `refactor(r74-02-orc-var-app-subdir-script-crons, SPL-<row issue>): ...` | `review/r74-02` | 1 |

**r74-01 brief, Files: ONLY** `orc:run/spl-accepted-close-install-cron.func.sh` (`:40`),
`orc:run/spl-desk-poll-ack-install-cron.func.sh` (`:40`),
`orc:run/spl-security-round-install-cron.func.sh` (`:44`),
`orc:run/spl-spawn-fill-install-cron.func.sh` (`:40`),
`orc:run/spl-topic-archive-suggest-install-cron.func.sh` (`:38`), and one new case each
in `orc:tests/spl-accepted-close.tst.sh`, `spl-desk-poll-ack.tst.sh`,
`spl-security-round-queue.tst.sh`, `spl-spawn-fill.tst.sh`,
`spl-topic-archive-suggest.tst.sh`. NOT `lib:spl-run-paths.func.sh`, NOT row 02's files,
NOT `spl-review-go*` / `spl-spawn-place*` / `spl-spawn-queue.tst.sh` (bug round 27).
Do: plan section 2 row 01 verbatim, 1.3's form; the gate (22 -> 17), the 5 new cases
red on the parent and green on the change, the byte-identical dry-run output, and the
suites' counts in the body. Gates: the 5 suites, `no-literal-paths.tst.sh`,
`bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r74-02 brief, Files: ONLY** `orc:run/check-disk-headroom-install-cron.func.sh` (`:46`),
`orc:run/check-env-order-install-cron.func.sh` (`:43`),
`orc:run/setup-box-stats-cron.func.sh` (`:48`), `orc:run/setup-ci-overflow-cron.func.sh`
(`:41`), `orc:run/setup-go-cache-prune-cron.func.sh` (`:46`), and one new case each in
`orc:tests/check-disk-headroom.tst.sh`, `check-env-order.tst.sh`, `box-stats-cron.tst.sh`,
`route-ci-overflow.tst.sh`, `prune-go-build-cache.tst.sh`. NOT
`lib:spl-run-paths.func.sh`, NOT row 01's files, NOT `prune-go-build-cache.func.sh` or
`orc:scripts/` (r73's, landed). Do: plan section 2 row 02 verbatim, 1.3's form; the
gate (22 -> 17 alone, 12 with row 01), the 5 new cases red on the parent and green on
the change, the byte-identical dry-run output, the suites' counts in the body. Gates:
the 5 suites, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`),
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash cron installers, 5 sites each) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: rows 01 and 02 |
| hand-spelled `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP` lines in `csi-spl-orc/src/bash` outside tests (1.3's gate) | 22 today -> 17 after one row -> 12 after both |
| all three hand spellings (1.3) | 30 today -> 20 after both |
| measured on | `af8ca0ba7`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `spl-review-go-install-cron.func.sh:39`, `spl-spawn-place-install-cron.func.sh:38` | the same shape, but their only suites (`spl-review-go.tst.sh`, `spl-spawn-queue.tst.sh`) are bug round 27's row files: R3 keeps them out until b27 lands | 2.2 |
| the other 10 `SPL_ORG_APP` sites (`setup-gh-runner-cpu-budget-cron:58`, `spl-box-restart-install-cron:91`, `spl-desk-install-service:120`, `spl-dispatch-rotate-install-cron:74`, `spl-orch-rotate-install-cron:45`, `spl-peer-crons:137`, `spl-spawn-remote-install-cron:48`, `spl-unanswered-sweep-install-cron:57`, `spl-wd-ensure-install-cron:76`, `spl-workspace-delivery-probe-install-cron:53`) | the same refactor, but with wider callers: `spl-desk-install-service.func.sh` is named by 21 test files, the rotate / unanswered-sweep installers by the box deploy and satellite tests (`git grep -lE '<basename>\|<do_ name>' -- '*tests/*'`, 1.3's command), and three of them (`box-restart`, `peer-crons`, `wd-ensure`) set global `SPL_*_CRON_LOGDIR` vars. Inputs for the next refactor rounds, about 5 per row, each with its caller list read first | 1.3 |
| the 5 `/var/${org_app\|ORG_APP\|app}/...` lines (`spl-box-update-install-cron:34`, `spl-cost-rollup-install-cron:42`, `spl-spool-refresh:55` (a NOTE text), `spl-wd-ensure:194`, `orc:scripts/desk-reconcile-cron.sh:189`) | a fourth spelling; `spl-spool-refresh:55` prints a path for the operator, not a dir it uses, and `desk-reconcile-cron.sh` is a cron wrapper (r73-02's `scripts/` form). A later round | 1.3 |
| the 3 tenant-dir sites (`orc:run/spl-desk-rebox.func.sh:111`, `spl-invite-e2e.func.sh:118`, `spl-m3-e2e.func.sh:159`) | the tenant root-key store: secret-class work (the data rule), two of them drive e2e runs against the hosted hub; a row of their own on a secret-class vendor (r73) | 1.3 |
| `iac:run/` and `csi-spl-utl/src/bash/run/` hand-spelled lines | `spl_run_paths` lives in the orc lib: a choice for its own row (or a shared lib first); `gcp-backup-env` is secret-class (r73) | r73 1.3 |
| a gate for the shape (extend `no-literal-paths.tst.sh` with a baseline) | its pattern must cover all spellings (`/(var\|opt)/\$\{?(ORG\|org\|SPL_ORG_APP\|org_app\|ORG_APP\|app)\b`); after this round the orc count is 20; a gate row then ratchets the rest. Kept out so this round stays at 2 rows | 1.3 |
| SC2034 baseline, iac test SC2034, `workflow-tool-checksums.tst.sh:33` `naked`, the p18-02 N1 workflow comment | r71 to r73 section 7's reasons hold; the baseline is unchanged (68 lines) | 1.2 |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66 to r73) | 1.2 |
| bash `LONG` `do_provision_firebase_dns` 169 and `[long-example]`; `action-header-tags-baseline.txt` `[missing]` | r67 to r73 section 7's reasons hold (an upstream port pinned byte-identical; a parsed `(required)` header refuses before the body: behaviour) | r73 1.2 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour (T028's assertions), terraform layout (T026) or docs (T031); the spec folder unchanged since W | 1.2 |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | r73 section 7's reason holds: a round of its own, its caller list read line by line first | r73 1.2 |

## 8. Changes

- v0.1 (c-290): first draft. A fresh round: r73 section 7's W1 line gives the rows,
  10 of the 22 hand-spelled `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>` log dirs in
  `orc:run/` cron installers, 5 per row, both in batch 1; proven to derive the same dir
  on this box's 3 tree kinds; the two sites whose suites are bug round 27's row files
  left out. Window W and the r74 slug proof recorded.
- v1.0 (c-290): the panel seat m-295 (mistral) PASS on v0.1
  `3036c5754cf341955bd2c9a713e0ad33d4ab31ad` (spool msg d9774c47 here, 28a199d5 at the
  holder; task `dispatch-refactor-r74`; seat file `e7ef6c95b` on
  `review/c003-refactor-round-74-mistral-seat`). `do_spl_review_line_check` on its line,
  run by the editor on this box: rc 0, `DOCS-ONLY 3036c5754cf3`. No W finding. Its
  notes, none asking a change:
  - N1: lane map exit 4 (not 3) on the 20 row paths: the 6 no-file rotate lanes on the
    other box are ask-first, not free; no live lane owns a row path (2.2 says the same).
  - N2: bug round 27's row 01 runs `spl-accepted-close.tst.sh` (b27 plan `:55`) but
    edits only `spl-review-go.func.sh` and its test: no file collision with r74-01.
    Recorded in 2.2. A row 01 lane re-checks b27's files before it pushes (R3).
  - N3: the gate counts the `SPL_ORG_APP` spelling only; the other 8 hand-spelled lines
    (5 `org_app|ORG_APP|app`, 3 tenant dirs) are counted apart in 1.3. The later gate
    row must cover every spelling (section 7 says so).
  The rows, their sites and their gate (22 -> 17 -> 12) do not change.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-290 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-295 (mistral) PASS** on
  `3036c5754cf341955bd2c9a713e0ad33d4ab31ad` (spool msg d9774c47; review-line check rc 0,
  DOCS-ONLY; seat file `e7ef6c95b` on `review/c003-refactor-round-74-mistral-seat`), no
  W finding, N1-N3 recorded. agy was unavailable (the holder's read), so mistral took
  the seat. Its signature on v1.0: pending.
- Row R7 seats: section 4.
