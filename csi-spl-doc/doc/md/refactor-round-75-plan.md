# Refactoring round 75 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6038  
Topic: 47105c3c-eea4-4455-99a7-d0fc69414bf0  
Discussion: 47105c3c-eea4-4455-99a7-d0fc69414bf0 (t1 #refactoring, "Refactor round 75", opener msg 1503d52c)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r75**, plan `refactor-round-75-plan.md`, rows `r75-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 74 ([refactor-round-74-plan.md](refactor-round-74-plan.md))
is closed (`64049c396`): r74-01 landed `1f5404315` (SPL-6024), r74-02 landed `412a44ab0`
(SPL-6026). No signed row is handed on: r75 is a fresh round. The perf floor (rulebook
4.4), the holder's read on `64049c396`: `perf 29 refactor 102 perf-share 22.1% floor-met`,
so this is a refactor round.

Both rows come from r74 section 7's first two lines (its first line's hold, bug round
27, is closed): **12 lines in `csi-spl-orc/src/bash/run` still build the app's var dir
by hand as `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>`**. r74 moved 10 such lines to
r71-01's helper (`spl_var_app_subdir`); this round moves 9 of the 12 the same way. Row 01
takes 5 installers whose dir is the action's own `local logdir`; row 02 takes 4 whose
dir is a global `SPL_*_CRON_LOGDIR` (3) or whose installer the box deploy calls (1). The
other 3 stay out with a measured reason each (section 7).

**Status: v0.1**, draft for the panel. Editor: **c-341** (claude).

**One sha:** every count is measured on **`47a30b7a6`** (`origin/master`
47a30b7a693311464d4f504552f996789778dc8f, committed 2026-11-20T11:34:58+01:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`; the tests ran
on this lane's worktree at that sha, as the push user with `SPOOL_TEST=1`. Queue, lane
map, brief and worktree readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-20T11:40:17+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r74-plan'` -> commit
  `64049c396` "refactor round 74 plan records the round closed, rows 01-02 landed".
  Every later read of r75 uses this W.
- **`r75` is free** (2026-11-20T10:38:11Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r75-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r75-*' 'refs/heads/wip/*r75*' 'refs/heads/*-r75-*' 'refs/heads/*refactor-round-75*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r75-[0-9]{2}|refactor-round-75' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (as root) on this lane's box -> **1 file**, this planner's own brief. The other
    box's briefs were not read by this lane; the holder's read before the spawn: 0
    besides this brief (the brief).
  - Control: the same log read with `(r74-` since W -> 1 line, `64049c396` (the r74
    close record, whose body names the rows), so the read sees a used id.
- **No `refactor-round-75*` file** exists under `csi-spl-doc/doc/md` on `47a30b7a6`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-75` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `lib:` = `csi-spl-orc/lib/bash/funcs/`,
`iac:` = `csi-spl-iac/src/bash/`.

| input | source | on `47a30b7a6` | here |
|---|---|---|---|
| r74 section 7, lines 1-2: the 12 `SPL_ORG_APP` sites left | r74 section 7 | 12 lines (1.3); bug round 27, which held 2 of them out, is closed (`d2e4c74eb`; rows `656ab3389`, `21abdb87e` on master) | **rows 01, 02** take 9; 3 stay out (section 7) |
| r74 section 7, the 5 `/var/${org_app\|ORG_APP\|app}/...` lines and the 3 tenant dirs | r74 section 7 | `'/(var\|opt)/\$\{?(org_app\|ORG_APP\|app)\b'` -> **5**, `'/(var\|opt)/\$\{?(ORG\|org)\b'` -> **3** (1.3's filter), unchanged | left out, r74's reasons hold (section 7) |
| the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`) | the brief | on this lane's box: 12780 bytes, last changed 2026-11-20 12:04 +0200. Its refactor-shaped items (the watchdog / lane-rotate `/var` literals, `reverse-tunnel-cron.sh`, the agent-boot-restore dir) are the ones r71 to r74 read as served. The items added since r74 read it are bug-shaped: the `unanswered-sweep.tst.sh` section 12 push-user WARN (c-973 fecf24d8) and the `*-panel-seat-<vendor>` slug match (c-325 W1 on b27-02) | nothing new; the first one keeps `unanswered-sweep.tst.sh` out of this round (2.2) |
| `.shellcheck-warning-baseline.txt` | the brief | `grep -vcE '^\s*(#\|$)'` -> **68 lines**; `git log --oneline --since="$W" -- .shellcheck-warning-baseline.txt` -> 0, the same 68 r74 read | nothing taken: r71 to r74 section 7's reasons hold |
| `no-literal-paths.baseline` | the brief | 1 entry, `2 csi-spl-orc/src/bash/run/spl-file-erase.func.sh` (a protected-root deny list, r66 to r74: behaviour) | left out (section 7) |
| r74 R7 findings | the brief | `1f5404315` (c-951) and `412a44ab0` (c-957): `git log -1 --format=%B <sha> \| grep -nE '^(review:\|N[0-9]\|W[0-9])'` -> one `review:` line each (`:33`, `:54`), no N or W line in the bodies. Neither body names a site left to move | nothing taken |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0, unchanged | left out (section 7), r65 to r74's reasons hold |

### 1.3 The hand-spelled `SPL_ORG_APP` var dir: 12 lines in `csi-spl-orc/src/bash/run`

`lib:spl-run-paths.func.sh:66-76` (`spl_run_paths`) derives `SPL_VAR_APP_DIR` =
`<var>/<org>/<main checkout name>`, and `spl_var_app_subdir <var> <sub>` (`:81-85`,
r71-01) sets the named variable to `$SPL_VAR_APP_DIR/<sub>` with `printf -v`. The
developer guide (2.3.1): "No action carries a literal `/opt/<org>` or `/var/<org>`
path". These lines build the same dir by hand from `SPL_ORG_APP`, which each action sets
as `SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"`,
so `no-literal-paths.tst.sh` (it greps `/(opt|var)/<org>` with the org's real name)
cannot see them.

**Gate:** `git grep -nE '/(var|opt)/\$\{?SPL_ORG_APP' -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l`
-> **12** on `47a30b7a6` (r74 read 22 on `af8ca0ba7`; its rows took 10).

The 12, with the row each one goes to (function and its length from `awk` over
`^name() {` to the first `^}`; "own" = the function's own `local logdir`, "global" = a
`SPL_*_CRON_LOGDIR` the file's other functions read):

| file (`orc:run/`) : line | function (lines) | dir var | sub | override | suites that name it (`git grep -lE '<basename>\|<do_ name>' -- '*tests/*'`) | row |
|---|---|---|---|---|---|---|
| `spl-review-go-install-cron.func.sh:39` | `do_spl_review_go_install_cron` (37) | own | `review-go` | `REVIEW_GO_CRON_LOG_DIR` | `orc:tests/spl-review-go.tst.sh` | 01 |
| `spl-spawn-place-install-cron.func.sh:38` | `do_spl_spawn_place_install_cron` (38) | own | `spawn-place` | `SPAWN_PLACE_CRON_LOG_DIR` | `orc:tests/spl-spawn-queue.tst.sh` | 01 |
| `spl-spawn-remote-install-cron.func.sh:48` | `do_spl_spawn_remote_install_cron` (55) | own | `spawn-remote` | `SPAWN_REMOTE_CRON_LOG_DIR` | `orc:tests/spawn-remote-cron.tst.sh` | 01 |
| `spl-workspace-delivery-probe-install-cron.func.sh:53` | `do_spl_workspace_delivery_probe_install_cron` (59) | own | `delivery-probe` | `PROBE_CRON_LOG_DIR` | `orc:tests/workspace-delivery-probe.tst.sh` | 01 |
| `setup-gh-runner-cpu-budget-cron.func.sh:58` | `do_setup_gh_runner_cpu_budget_cron` (54) | own | `gh-runner-cpu-budget` | `CPU_BUDGET_CRON_LOG_DIR` | `orc:tests/setup-gh-runner-cpu-budget-cron.tst.sh`; `orc:tests/apply-gh-runner-cpu-budget.tst.sh` (runs the installer with the override, `:468-473`); `orc-shard-weights.txt` (a name only) | 01 |
| `spl-orch-rotate-install-cron.func.sh:45` | `do_spl_orch_rotate_install_cron` (55) | own | `orch-rotate` | `ROTATE_CRON_LOG_DIR` | `orc:tests/orch-rotate.tst.sh`; `orc:tests/spl-box-deploy.tst.sh` (stubs it, `:58`); **`iac:tests/satellite-ansible.tst.sh`** (greps its `tag=` line, `:371-372`) | 02 |
| `spl-box-restart-install-cron.func.sh:91` | `spl_brx_cron_build` (12) | global `SPL_BRX_CRON_LOGDIR` | `box-restart` | `BOX_RESTART_LOG_DIR` | `orc:tests/box-restart-schedule.tst.sh` | 02 |
| `spl-peer-crons.func.sh:137` | `spl_peer_cron_build` (11) | global `SPL_PEER_CRON_LOGDIR` | `peer` | `PEER_CRON_LOG_DIR` | `orc:tests/peer-restart.tst.sh`, `orc:tests/wd-ensure.tst.sh`; `orc:tests/boot-cron-gate.tst.sh` (sources the file for `spl_peer_cron_script_of`, `:125-126`) | 02 |
| `spl-wd-ensure-install-cron.func.sh:76` | `spl_wd_cron_prep` (42) | global `SPL_WD_CRON_LOGDIR` | `wd` | `WD_CRON_LOG_DIR` | `orc:tests/wd-ensure.tst.sh`, `orc:tests/boot-cron-gate.tst.sh`, `orc:tests/wd-peer-restart.tst.sh` | 02 |
| `spl-dispatch-rotate-install-cron.func.sh:74` | `do_spl_dispatch_rotate_install_cron` (**73**) | own | | | | out (section 7) |
| `spl-unanswered-sweep-install-cron.func.sh:57` | `do_spl_unanswered_sweep_install_cron` (65) | own | | | | out (section 7) |
| `spl-desk-install-service.func.sh:120` | `do_spl_desk_install_service` (60) | own | | | 21 test files | out (section 7) |

**Same dir today, measured** (this lane's box, 2026-11-20T10:53:32Z, n=1 per tree and
sub; the lib at `47a30b7a6`, run as the push user under `env -i`): for `PROJ_PATH` = the
main checkout's, the desk-cron checkout's (a worktree) and this lane's worktree's
`csi-spl-orc`, `spl_var_app_subdir d <sub>` and the hand form (the `SPL_ORG_APP` line
above, then `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>`) print the same path for the
subs `review-go`, `wd` and `peer`: **9 of 9 EQUAL**. The two forms differ only where r74
1.3 says (a tree outside `<base>/<org>/<app>`; a preset `SPL_VAR_APP_DIR`, which wins; no
tree at all, where the parent planned `/var///<sub>` and the change FATALs), plus one
r74 did not name: **a caller that presets `SPL_ORG_APP`** to a name other than its
tree's. The hand form follows that name, the helper follows the tree. `grep -nE
'SPL_ORG_APP=' <suite>` over the 11 row suites (edited and run): where a case presets
it and runs an installer, the override is on the same command
(`spl-spawn-queue.tst.sh:1999-2000`, `setup-gh-runner-cpu-budget-cron.tst.sh:37`,
`wd-ensure.tst.sh:261`, `boot-cron-gate.tst.sh:52-53` and `:138`,
`wd-peer-restart.tst.sh:82`); the other presets call a function that builds no log dir
(`box-restart-schedule.tst.sh:226-230` `spl_brx_cron_slot`, `peer-restart.tst.sh:390`
and `wd-ensure.tst.sh:313` `spl_peer_cron_8_1`). So no test reads the default under a
preset name.

**The shape to copy** is on master, r74-01's form (`git show 1f5404315 --
csi-spl-orc/src/bash/run/spl-spawn-fill-install-cron.func.sh`):

```text
logdir="${SPAWN_FILL_CRON_LOG_DIR:-}"
if [[ -z "$logdir" ]]; then
  declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
  spl_var_app_subdir logdir spawn-fill || { do_log "FATAL cannot derive the spawn-fill cron log dir (no tree for spl_run_paths): set SPAWN_FILL_CRON_LOG_DIR"; return 1; }
fi
```

Each site becomes that block with its own variable, sub and override name: net **+4
or +5 lines** (r74-01: `git show --stat 1f5404315` -> each code file `6 +++++-`). For
row 02's three global sites the variable is the global `SPL_*_CRON_LOGDIR` (no function
in those files declares it `local`: `grep -nE 'local .*SPL_(BRX|PEER|WD)_CRON_LOGDIR'`
-> 0), so `printf -v` writes the global the other functions read; the locals of the
helper chain are `main org base` and `d g` (`lib:spl-run-paths.func.sh:67`, `:43`), none
a target name. `SPL_ORG_APP` stays: every site still reads it for its `tag`, its `run` /
`script` path or its `spl_cron_no_stack_pre` tree.

**Function length** (bash clean code cap 75, `iac:tests/bash-cleancode.tst.sh`
`MAX_LINES=75`): after +5 the longest row function is 64
(`do_spl_workspace_delivery_probe_install_cron`, 59 today).
`do_spl_dispatch_rotate_install_cron`'s 73 would go over the cap (77 or 78): it stays
out (section 7).

**A source-reading test (R2, bold in the row):** `iac:tests/satellite-ansible.tst.sh:270-272`
greps `orc` and `iac` `src/bash` for `/var/(...)/[^ "]*(desk-reconcile|unanswered-sweep|weekly-scan|backup|tenants)`
and needs **at least 5** distinct hits (`n_sd -ge 5`). On `47a30b7a6` it finds **6**
(`grep -rhoE <its pattern> csi-spl-orc/src/bash csi-spl-iac/src/bash | sort -u`); no row
site is among them. Moving the `unanswered-sweep` site would leave exactly 5, and moving
`desk-reconcile` too would drop it to 4 and turn the case red: section 7 records it for
the round that takes those two. The same file's `:371-372` greps
`tag="$SPL_ORG_APP:orch-rotate"` in row 02's file: the `tag=` line does not change.

**Tests (R2):** each site's suites (the table's column), plus `orc:tests/no-literal-paths.tst.sh`
(it scans `run/`) and `iac:tests/bash-cleancode.tst.sh` (a line count). **Every
existing case passes the override:** `grep -c <OVERRIDE>` -> 1 on each edited suite;
`grep -cE '/var/(\$|csi)'` -> 0, except `boot-cron-gate.tst.sh`, whose 2 hits are its
header comment (`:5-6`); `grep -c SPL_VAR_APP_DIR` -> 0 on every row suite. So no test
reads the default today: each row adds the default's case per site (section 2).

**Before** (this lane, worktree at `47a30b7a6`, 2026-11-20T10:43Z-11:02Z, n=1,
`SPOOL_TEST=1`, as the push user; pass lines `grep -ciE '^ *(ok|pass)'`, fail lines
`grep -ciE '^ *(not ok|fail)'`):

| suite | row | rc | pass lines | fail lines | last line |
|---|---|---|---|---|---|
| `spl-review-go.tst.sh` | 01 | 0 | 182 | 0 | `spl-review-go: 0 failure(s)` |
| `spl-spawn-queue.tst.sh` | 01 | 0 | 274 | 0 | `PASS: all` |
| `spawn-remote-cron.tst.sh` | 01 | 0 | 7 | 0 | `-- spawn-remote-cron.tst.sh: fails=0` |
| `workspace-delivery-probe.tst.sh` | 01 | 0 | 27 | 0 | `ALL PASS` |
| `setup-gh-runner-cpu-budget-cron.tst.sh` | 01 | 0 | 7 | 0 | `setup-gh-runner-cpu-budget-cron: all passed` |
| `apply-gh-runner-cpu-budget.tst.sh` | 01 (run) | 0 | 90 | 0 | `apply-gh-runner-cpu-budget: all passed` |
| `orch-rotate.tst.sh` | 02 | 0 | 194 | 0 | `orch-rotate: all passed` |
| `box-restart-schedule.tst.sh` | 02 | 0 | 32 | 0 | `box-restart-schedule: 0 failure(s)` |
| `peer-restart.tst.sh` | 02 | 0 | 34 | 0 | `peer-restart: all passed` |
| `wd-ensure.tst.sh` | 02 | 0 | 33 | 0 | `=== fails=0` |
| `boot-cron-gate.tst.sh` | 02 (run) | 0 | 10 | 0 | `boot-cron-gate: 0 failure(s)` |
| `wd-peer-restart.tst.sh` | 02 (run) | 0 | 39 | 0 | `wd-peer-restart: all passed` |
| `spl-box-deploy.tst.sh` | 02 (run) | 0 | 36 | 0 | `ALL PASS` |
| `iac:tests/satellite-ansible.tst.sh` | 02 (run) | 0 | 96 | 0 | `PASS: all satellite-ansible.tst.sh assertions` |
| `no-literal-paths.tst.sh` | both | 0 | 8 | 0 | `ALL PASS` |
| `iac:tests/bash-cleancode.tst.sh` | both | 0 | 15 | 0 | `PASS: all bash-cleancode.tst.sh assertions` |

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r75-01-orc-var-app-subdir-own-logdir-crons)` | canonical paths, no box path in an action (developer guide 2.3.1); folded helpers exist once (2.2.4) | 5 cron installers build their own `logdir` by hand from `SPL_ORG_APP`, which the literal-path gate cannot see; r71-01's helper derives it | `orc:run/spl-review-go-install-cron.func.sh:39`<br>`orc:run/spl-spawn-place-install-cron.func.sh:38`<br>`orc:run/spl-spawn-remote-install-cron.func.sh:48`<br>`orc:run/spl-workspace-delivery-probe-install-cron.func.sh:53`<br>`orc:run/setup-gh-runner-cpu-budget-cron.func.sh:58`<br>(+ one new case in each site's first suite, 1.3's table) | 5 sites | Each site takes 1.3's form: the override kept, else `spl_var_app_subdir logdir <sub>` (`review-go`, `spawn-place`, `spawn-remote`, `delivery-probe`, `gh-runner-cpu-budget`), FATAL + `return 1` naming the override when no tree. **Gate:** 1.3's grep 12 -> **7**. **New cases**, one per suite (`spl-review-go.tst.sh`, `spl-spawn-queue.tst.sh`, `spawn-remote-cron.tst.sh`, `workspace-delivery-probe.tst.sh`, `setup-gh-runner-cpu-budget-cron.tst.sh`), override empty, `SPL_VAR_APP_DIR=$T/var`, the suite's own crontab stub and a `DRY_RUN=1` install: the printed cron line holds `$T/var/<sub>/` (its lock and its `cron.out` / `cron.log`; the probe's `cron-<env>.lock`) and nothing is created under `$T/var`. **Red control:** the 5 new cases FAIL on the parent (it prints `/var/<org>/<org>-<app>/<sub>`), output in the body; a dry run writes nothing, so no live dir is touched. **Behaviour:** on this box with no override each installer's `DRY_RUN=1` output is byte-identical on the parent and the change (its crontab a fake file), diff in the body; the suites' pass counts equal 1.3's plus the new cases. Tests: the 5 suites and `apply-gh-runner-cpu-budget.tst.sh`, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (all `SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push` (shellcheck: no new warning). | either | claude | simple_coding | 1 |
| 02 `refactor(r75-02-orc-var-app-subdir-global-logdir-crons)` | as row 01 | 4 more installers build the dir the same way: 3 into a global `SPL_*_CRON_LOGDIR` that their other functions read, 1 (`orch-rotate`) installed by the box deploy | `orc:run/spl-orch-rotate-install-cron.func.sh:45`<br>`orc:run/spl-box-restart-install-cron.func.sh:91`<br>`orc:run/spl-peer-crons.func.sh:137`<br>`orc:run/spl-wd-ensure-install-cron.func.sh:76`<br>(+ one new case in each site's first suite, 1.3's table) | 4 sites | As row 01; variables `logdir`, `SPL_BRX_CRON_LOGDIR`, `SPL_PEER_CRON_LOGDIR`, `SPL_WD_CRON_LOGDIR`; subs `orch-rotate`, `box-restart`, `peer`, `wd`. **Gate:** 1.3's grep 12 -> **8** on its own, **3** with row 01. **New cases**, one per suite (`orch-rotate.tst.sh`, `box-restart-schedule.tst.sh`, `peer-restart.tst.sh`, `wd-ensure.tst.sh`), as row 01: override empty, `SPL_VAR_APP_DIR=$T/var`, dry run; the printed line holds `$T/var/<sub>/` (`box-restart.lock` / `.out`; `<name>.lock` / `.out`; `ensure.lock` / `ensure.out`, `starter.out`). **Red control:** the 4 new cases FAIL on the parent, output in the body; dry runs only. **Behaviour:** as row 01: byte-identical `DRY_RUN=1` output on this box with no override, parent vs change, for all 4 (for `wd-ensure` and `peer-crons` the rendered cron lines), diff in the body; counts equal 1.3's plus the new cases. Tests: the 4 suites, `boot-cron-gate.tst.sh`, `wd-peer-restart.tst.sh`, `spl-box-deploy.tst.sh`, **`iac:tests/satellite-ansible.tst.sh`**, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs 1.3's gate grep and the line reads on the
`origin/master` it starts from, and says in its result if the sites moved.

**Subject** (R6 reads it): `<type>(r75-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r75-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each action's `@param <OVERRIDE>` help line names the default as
`/var/<org>/<org>-<app>/<sub>` (e.g. `spl-review-go-install-cron.func.sh:18`), the
derived dir's shape on a `<base>/<org>/<org>-<app>` tree (developer guide 2.3.1), so it
does not change; the guide already says paths come from `spl_run_paths`. Each row
carries `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, placed together. Their file sets are disjoint: 9 code
  files and 9 edited suites, no file in both (1.3's table). The suites a row only runs
  (`apply-gh-runner-cpu-budget.tst.sh`; `boot-cron-gate.tst.sh`,
  `wd-peer-restart.tst.sh`, `spl-box-deploy.tst.sh`, `satellite-ansible.tst.sh`;
  `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh`) are not edited. The second row to
  land rebases over the first without a shared line; its gate count is then 3.
- No row edits `lib:spl-run-paths.func.sh`, a migration, `csi-spl-cnf/`, a workflow,
  terraform, `csi-spl-iac/`, `csi-spl-utl/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-341`, one call per
  path, 2026-11-20T10:39:45Z (16 paths) and 10:58:12Z (`peer-restart.tst.sh`,
  `wd-ensure.tst.sh`), n=1: **exit 4 on all 18 row paths** (9 code files, 9 suites): no
  live lane lists them; 13 live lanes on the other box record no files: c-049, c-060, c-625,
  c-812, c-924, c-927, c-977 (each `rotate`), c-959 (b27-02, landed), c-968 (s182 L1 rdb
  + store), c-970 (a review build), c-973 (s182 L2b orc sweep), c-975 (s182 L3 wui),
  c-981 (s183 P1 hub). The non-rotate ones were read from their briefs (below).
- **Spec 182 L2b (c-973, live):** its brief's scope is `spl-unanswered-sweep.func.sh`,
  `unanswered-sweep-classify.py`, `spl-take-auto.func.sh` "and their tests"; its pushed
  branches (`review/c002-s182-l2b-orc-sweep-skip-loop` and `-r2`) change
  `spl-take-auto.func.sh`, `spl-unanswered-sweep.func.sh`, `enc-cache-writers.tst.sh`,
  `spl-take-auto.tst.sh` and 4 `unanswered-sweep-*.tst.sh` (`git diff --name-only
  $(git merge-base origin/master <b>) <b>`): no row file. The sweep installer and
  `unanswered-sweep.tst.sh` stay out anyway (section 7).
- **Spec 183 (c-981 live; P2-P4 held), spec 182 L1 / L2 / L3, the queued spec lanes for
  SPL-6035 (message forward) and SPL-6036 (default model per kind):** their briefs
  (`c002-s18[23]-*.md`, `c002-s-msg-forward-spec.md`, `c002-s-default-model-per-kind-spec.md`
  under `/var/spool-hub/dispatch/briefs`) name none of the 18 row basenames (`grep -oE`,
  as root, 10:4xZ).
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-20T10:41:38Z):
  **15 queued, 0 placing**, all `feature` (spec 033 T020-T027, spec 123 P01-P07, the two
  spec lanes above, a CLAUDE.md forms rule, a scheduled-tasks spec). The basename grep
  over their briefs: one hit, `c002-s033-t024-cli-orc-kinds.md` (HELD behind T022-T023),
  which edits `orc:run/spl-review-go.func.sh:202` and names its tests as
  `agent-handoff.tst.sh`, `desk-actions.tst.sh`, `desk-reply-human-guard.tst.sh` and a
  parity test: neither row 01's `spl-review-go-install-cron.func.sh` nor
  `spl-review-go.tst.sh`. Live share: `refactor 1 4% (band 10-20%: UNDER)`, `phase day`;
  last 24 h `refactor 18% (band 20-30%: UNDER)`.
- **Every remote branch committed in the last 24 h** (105 branches after a fetch,
  2026-11-20T10:40:53Z): `git diff --name-only $(git merge-base origin/master <b>) <b>`
  filtered for the row files -> **3 hits**, `review/b23-01`, `review/b27-01`
  (`spl-review-go.tst.sh`) and `review/b27-02` (`spl-spawn-queue.tst.sh`): all landed
  (`git cherry origin/master <b>` -> `-` only).
- **This box's lane worktrees** (2026-11-20T10:54:01Z, 167 besides this one):
  `git -C <wt> diff --name-only origin/master...HEAD` and `git -C <wt> diff --name-only HEAD`,
  same filter -> **5 hits**, all stale: `g-962-r4620` (HEAD 2026-11-02), three `/tmp`
  copies of g-416 and g-418 (HEADs 2026-11-16, their patches on master per `git cherry`),
  and one more `/tmp` g-418 copy (2026-11-16, 1 dirty file: an old red-control plant). No
  tmux window carries g-962, g-416 or g-418. The other box's worktrees were not read by
  this lane.
- **Commits since W** on the row paths (`git log origin/master --since="$W" -- <paths>`)
  -> **2**, the landed b27 rows (`656ab3389` on `spl-review-go.tst.sh`, `21abdb87e` on
  `spl-spawn-queue.tst.sh`); 1.3's suite counts are on top of them.
- **Unlanded round rows:** none of bug round 27 (closed); the s182 / s183 build rows
  above; the dedicated channel seats on the other box work outside this repo.

## 3. Per row: what the lane does

- **r75-01:** 5 cron installers derive their own log dir with `spl_var_app_subdir`
  when the override is unset; their cron lines are the same on the box. The 5 suites
  each gain the default-path case.
- **r75-02:** the same for 4 more installers, 3 of them writing a global
  `SPL_*_CRON_LOGDIR`.

## 4. Panel and reviewers (R7)

- Editor: c-341 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r75`):
  one **cross-vendor** doc seat: agy is the main vendor for plan reviews, mistral its
  backup, as r62 to r74 had (the brief: no agy CLI on this box, agy quota out on the
  other until ~11-24, so mistral is the likely seat). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2), the holder's call when the row
  is queued (a fresh claude seat under the claude waiver, as r63 to r74). Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3, its R7 reviewer seat, and "re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r75-01 | `c002-r75-01-orc-var-app-subdir-own-logdir-crons` | `refactor(r75-01-orc-var-app-subdir-own-logdir-crons, SPL-<row issue>): ...` | `review/r75-01` | 1 |
| r75-02 | `c002-r75-02-orc-var-app-subdir-global-logdir-crons` | `refactor(r75-02-orc-var-app-subdir-global-logdir-crons, SPL-<row issue>): ...` | `review/r75-02` | 1 |

**r75-01 brief, Files: ONLY** `orc:run/spl-review-go-install-cron.func.sh` (`:39`),
`orc:run/spl-spawn-place-install-cron.func.sh` (`:38`),
`orc:run/spl-spawn-remote-install-cron.func.sh` (`:48`),
`orc:run/spl-workspace-delivery-probe-install-cron.func.sh` (`:53`),
`orc:run/setup-gh-runner-cpu-budget-cron.func.sh` (`:58`), and one new case each in
`orc:tests/spl-review-go.tst.sh`, `spl-spawn-queue.tst.sh`, `spawn-remote-cron.tst.sh`,
`workspace-delivery-probe.tst.sh`, `setup-gh-runner-cpu-budget-cron.tst.sh`. NOT
`lib:spl-run-paths.func.sh`, NOT row 02's files, NOT `orc:run/spl-review-go.func.sh`
(spec 033 T024, queued) or `orc:run/spl-spawn-place.func.sh`. Do: plan section 2 row 01
verbatim, 1.3's form; the gate (12 -> 7), the 5 new cases red on the parent and green on
the change, the byte-identical dry-run output, and the suites' counts in the body.
Gates: the 5 suites, `apply-gh-runner-cpu-budget.tst.sh`, `no-literal-paths.tst.sh`,
`bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r75-02 brief, Files: ONLY** `orc:run/spl-orch-rotate-install-cron.func.sh` (`:45`),
`orc:run/spl-box-restart-install-cron.func.sh` (`:91`), `orc:run/spl-peer-crons.func.sh`
(`:137`), `orc:run/spl-wd-ensure-install-cron.func.sh` (`:76`), and one new case each in
`orc:tests/orch-rotate.tst.sh`, `box-restart-schedule.tst.sh`, `peer-restart.tst.sh`,
`wd-ensure.tst.sh`. NOT `lib:spl-run-paths.func.sh`, NOT row 01's files, NOT
`spl-dispatch-rotate-install-cron.func.sh`, `spl-unanswered-sweep*`,
`unanswered-sweep*.tst.sh` (spec 182 L2b) or `spl-desk-install-service.func.sh`. Do:
plan section 2 row 02 verbatim, 1.3's form with the global variable as the target; the
gate (12 -> 8 alone, 3 with row 01), the 4 new cases red on the parent and green on the
change, the byte-identical dry-run output, the suites' counts in the body. Gates: the 4
suites, `boot-cron-gate.tst.sh`, `wd-peer-restart.tst.sh`, `spl-box-deploy.tst.sh`,
`iac:tests/satellite-ansible.tst.sh`, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh`
(`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`.
Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash cron installers, 5 and 4 sites) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: rows 01 and 02 |
| hand-spelled `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP` lines in `csi-spl-orc/src/bash` outside tests (1.3's gate) | 12 today -> 7 after row 01 -> 8 after row 02 alone -> 3 after both |
| all three hand spellings (r74 1.3: `SPL_ORG_APP` + `org_app\|ORG_APP\|app` + tenant) | 20 today -> 11 after both |
| measured on | `47a30b7a6`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `spl-dispatch-rotate-install-cron.func.sh:74` | its function is 73 lines; 1.3's form adds 4 or 5, over the 75 cap (`bash-cleancode.tst.sh`). A row that first splits a named step out of `do_spl_dispatch_rotate_install_cron`, then moves the site | 1.3 |
| `spl-unanswered-sweep-install-cron.func.sh:57` | spec 182 L2b (c-973, live) owns the unanswered sweep "and their tests"; the candidates file's bug item names `unanswered-sweep.tst.sh` section 12; moving it leaves `satellite-ansible.tst.sh:270-272` at exactly its floor of 5 | 1.3, 2.2 |
| `spl-desk-install-service.func.sh:120` | the same refactor, but its file is named by 21 test files (1.3's command), and once the sweep site moves, its `desk-reconcile` hit is the 5th of `satellite-ansible.tst.sh`'s `n_sd -ge 5`: that case needs its own change in the same row (count the derived dirs, not the literal spelling) | 1.3 |
| the 5 `/var/${org_app\|ORG_APP\|app}/...` lines and the 3 tenant-dir sites | r74 section 7's reasons hold (a fourth spelling, an operator NOTE text, a cron wrapper; the tenant root-key store is secret-class) | 1.2 |
| `iac:run/` and `csi-spl-utl/src/bash/run/` hand-spelled lines | `spl_run_paths` lives in the orc lib: a choice for its own row (or a shared lib first); `gcp-backup-env` is secret-class (r73) | r73 1.3 |
| a gate for the shape (extend `no-literal-paths.tst.sh` with a baseline) | its pattern must cover all spellings; after this round the orc count is 11; a gate row then ratchets the rest (r74 section 7, its panel's N3) | 1.3 |
| SC2034 baseline, iac test SC2034, `workflow-tool-checksums.tst.sh:33` `naked`, the p18-02 N1 workflow comment | r71 to r74 section 7's reasons hold; the baseline is unchanged (68 lines) | 1.2 |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66 to r74) | 1.2 |
| bash `LONG` `do_provision_firebase_dns` 169 and `[long-example]`; `action-header-tags-baseline.txt` `[missing]` | r67 to r74 section 7's reasons hold | r73 1.2 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, terraform layout or docs; the spec folder unchanged since W | 1.2 |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | r73 section 7's reason holds | r73 1.2 |

## 8. Changes

- v0.1 (c-341): first draft. A fresh round: r74 section 7's first two lines give the
  rows, 9 of the 12 hand-spelled `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/<sub>` log dirs in
  `orc:run/` cron installers, 5 (own `logdir`) and 4 (3 global `SPL_*_CRON_LOGDIR`, 1
  box-deploy installer), both in batch 1; proven to derive the same dir on this box's 3
  tree kinds; the 3 left out each with a measured reason (the 75-line cap, a live spec
  182 lane, 21 test callers and a source-count floor). Window W and the r75 slug proof
  recorded.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-341 (claude): v0.1.
- Panel reviewer seat: pending (section 4).
- Row R7 seats: section 4.
