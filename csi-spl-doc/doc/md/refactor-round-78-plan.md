# Refactoring round 78 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6109  
Topic: d03d4669-e9f4-459c-ad22-452889a8aa4d  
Discussion: d03d4669-e9f4-459c-ad22-452889a8aa4d (t1 #refactoring, "Refactor round 78", opener msg d3c1a2b5)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r78**, plan `refactor-round-78-plan.md`, rows `r78-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 77 ([refactor-round-77-plan.md](refactor-round-77-plan.md))
is closed (`0782cf525`): r77-01 landed `a8d2ea7d5` (SPL-6092), r77-02 landed `7ff2604dd`
(SPL-6104). No signed row is handed on: r78 is a fresh round. The perf floor (rulebook
4.4), the holder's read on `0782cf525`: `perf 29 refactor 105 perf-share 21.6% floor-met`,
so this is a refactor round.

**Row 01** moves the desk-reconcile cron log dir of `do_spl_desk_install_service` onto
`spl_var_app_subdir`, r77 section 7's first item, and lowers r77-01's spelled-dir
baseline by its line. **Row 02** makes `do_tf_log_open` return a code instead of exiting
the caller's shell on a missing argument (developer guide 2.4.3), a b12-02 R7 finding
from the holder's candidates list.

**Status: v0.1**, draft for the panel. Editor: **c-391** (claude).

**One sha:** every count is measured on **`4c5633d84`** (`origin/master`
4c5633d8492832fa20e695afae69808ce4b25966, committed 2026-11-21T00:03:48+01:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`; the tests ran
on this lane's worktree at that sha, as the push user with `SPOOL_TEST=1`. Queue, lane
map, brief and worktree readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-20T23:56:41+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r77-plan'` -> commit
  `0782cf525` "refactor round 77 plan records the round closed, rows 01-02 landed".
  Every later read of r78 uses this W.
- **`r78` is free** (2026-11-20T23:1xZ, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r78-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r78-*' 'refs/heads/wip/*r78*' 'refs/heads/*-r78-*' 'refs/heads/*refactor-round-78*'`
    -> **1 head**, `refs/heads/review/c002-refactor-round-78-mistral-seat`: the panel
    seat's own seat branch, no row head. This planner's review branch is pushed after
    that read.
  - `grep -rlE 'r78-[0-9]{2}|refactor-round-78' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
    (as root) on this lane's box -> **1 file**: this planner's brief. The panel seat's
    brief is on the other box and was not read by this lane.
  - Control: the same log read with `(r77-` since W -> 1 line, `0782cf525` (the r77
    close record), so the read sees a used id.
- **No `refactor-round-78*` file** exists under `csi-spl-doc/doc/md` on `4c5633d84`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-78` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `lib:` = `csi-spl-orc/lib/bash/funcs/`,
`iac:` = `csi-spl-iac/`.

| input | source | on `4c5633d84` | here |
|---|---|---|---|
| `orc:run/spl-desk-install-service.func.sh:120` | r77 section 7, line 369 | the line is there; its 21 test files and `satellite-ansible.tst.sh`'s `n_sd` read (1.3) | **row 01** |
| the iac / utl lines that need a shared run-paths helper first | r77 section 7, line 374 | unchanged: 3 iac and 7 utl lines in `no-literal-paths-spelled.baseline` | left out (section 7) |
| a gate over files outside the existing scope | r77 section 7, line 375 | not measured this round | left out (section 7) |
| r77-01 N1: a baseline entry's file name carries an OS user | `a8d2ea7d5` body | the entry is `orc:run/check-ysg-box-deps.func.sh`; the name is the frozen engine's (spec 069 `ysg-box-out`): 9 files name the file or `do_check_ysg_box_deps` (`git grep -lE 'check-ysg-box-deps\|check_ysg_box_deps'`), plus 5 `YSG_BOX_DEPS_*` params and the default pattern `ysg-box(-[a-z]+)?/` | left out (section 7) |
| r77-02 N1: the sourced run lib exports `SPL_*` into the scripts' children | `7ff2604dd` body | `lib:spl-run-paths.func.sh:75` `export SPL_ORG_DIR SPL_VAR_APP_DIR SPL_VAR_ORG_DIR SPL_WT_ROOT SPL_DESK_DIR` | left out (section 7) |
| `spl-unanswered-sweep-install-cron.func.sh:57` | the brief | the site is there; spec 182 lanes are live | left out (section 7) |
| the candidates file (`<spool>/dispatch/c002-next-round-candidates.md`, the other box) | the brief; its refactor items inlined by the holder (spool msg 96b64969, 23:09Z) | re-measured below, item by item | row 02 from item 2; the rest below |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0 | left out (section 7), r65 to r77's reasons hold |

The holder's candidates, item by item (its numbering):

| # | item | on `4c5633d84` | here |
|---|---|---|---|
| 1 | literal `/var` in `spl-watchdog.func.sh` and `spl-lane-rotate.func.sh` | `git grep -nE '/var/'` on both files, comment lines out -> **0**: served | nothing taken |
| 2 N3 | `${1:?}` in the tf log helper exits the shell | `iac:lib/bash/funcs/tf-log-mask.func.sh:25` `local f="${1:?do_tf_log_open: the log file}"` (the item named `tf-log-mask.func.sh` under `run/`; the file is in `lib/`) | **row 02** |
| 2 N2 | `terraform init` without `-input=false` | 13 `init` calls in `iac:src/bash/run/tf-*.func.sh` lack it (`tf-plan-pending:38` and `setup-tf-mirror:59` carry it); a prompt that waits today would fail instead: a behaviour change, and 13 sites > 5 | left out (section 7) |
| 2 N1 | a duplicate case in `tf-apply-no-input.tst.sh:83` | `:79-86` on this sha: one `check` per action plus a `(log was 0664)` variant and the two `DRY_RUN=1` cases; no duplicate found | nothing taken |
| 3 | env forwarding of the desk hop (SPL-5824) | not re-measured: a forwarded-list change alters what the hop passes, so its W1 is a bug row | left out (section 7) |
| 4 N1 | `spl-uplink-probe.func.sh:14-15` wording | `:14-15` now say "In probe mode a down link never fails the probe: it exits 0. A config fault does, FATAL with rc 1": served | nothing taken |
| 5 W1 | `reverse-tunnel-cron.sh` literal | `:27` reads `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`: served | nothing taken |
| 5 N3 | the install guide names `/var/csi/csi-spl/reverse-tunnel` | `installation-and-configuration-guide.md:594`, still there; the guide is a Qto export | left out (section 7) |
| 6 | `10_ci-quality.yml:444-445` comment overstates the margin | `:445` "and it also covers the downloaded archive the restore unpacks." still there | left out (section 7), the first candidate of r79 |
| 7 | the agent-boot-restore dir | writer `spl-agent-boot-restore-install-cron.func.sh:59-60` calls `spl_var_app_subdir`: served | nothing taken |
| 8 | spec 182 L2: the `!inserted` branch untested | spec 182 N4 (hub `topic_loop*`) is live | left out (section 7) |

### 1.3 Row 01's site: the desk-reconcile log dir

`orc:run/spl-desk-install-service.func.sh` (505 lines):

```text
:83   # @param DESK_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/desk-reconcile
:120  logdir="${DESK_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/desk-reconcile}"
```

`SPL_ORG_APP` comes from `spl_cloud_cnf_locate` (`lib:spl-cloud-cnf.func.sh:82-87`): the
basename of `$PROJ_PATH` without `-orc`, so `csi-spl` in every tree of this repo.
`logdir` feeds the cron line (`spl_desk_cron_build_line`, `:127`, `:130`), the check's
JSON `log_dir` (`:138`, `:196`), the dry plan (`:236`) and the install's `mkdir -p`
(`:169`).

**The shape**, as r76-01 and r69's agent-boot-restore writer
(`spl-agent-boot-restore-install-cron.func.sh:59-60`) already do it:

```text
if [[ -n "${DESK_CRON_LOG_DIR:-}" ]]; then logdir="$DESK_CRON_LOG_DIR"
else
  declare -F spl_var_app_subdir >/dev/null || source "<the lib, from BASH_SOURCE>/spl-run-paths.func.sh"
  spl_var_app_subdir logdir desk-reconcile || { do_log "FATAL cannot derive the desk-reconcile log dir (spl_run_paths): set DESK_CRON_LOG_DIR"; return 1; }
fi
```

and `:83` reads `default <SPL_VAR_APP_DIR>/desk-reconcile (spl_run_paths)`.

**Same dir today, measured** (this lane's box, 2026-11-20T23:11:18Z, n=1 per tree, as the
push user under `env -i PATH=/usr/bin:/bin`): for the main checkout, the desk-cron
checkout (a worktree) and this lane's worktree, the hand form (`SPL_ORG_APP` from the orc
dir name) and `spl_var_app_subdir d desk-reconcile` (that tree's lib) print the same path:
**3 of 3 EQUAL** (`/var/<org>/<org>-<app>/desk-reconcile`). They differ only where r74 to
r77 say: a tree outside `<base>/<org>/<app>`, a preset `SPL_VAR_APP_DIR` (it wins), and an
`APP_PATH` / `PROJ_PATH` naming another tree.

**The reader stays.** `orc:scripts/desk-reconcile-cron.sh:189` prints the same dir for
`--print` (`ORG_APP` from its module dir). Moving it too drops both `desk-reconcile`
paths from `satellite-ansible.tst.sh`'s `n_sd` (below) and needs the scripts-side source
r77-02 used: its own row (section 7).

**The tests.** `git grep -lE 'spl-desk-install-service|do_spl_desk_install_service' -- '*tests/*.sh'`
-> **21 files**. Four pass `DESK_CRON_LOG_DIR` (`desk-install-service-envs`,
`-user`, `desk-reconcile-boot`, `desk-up-all`); the rest source the action or check its
tags and cron lines, not the default dir (`grep -nE 'log_dir|desk-reconcile/'` on them:
only `boot-cron-gate.tst.sh`, which builds its own `$L/desk-reconcile`).
`iac:src/bash/tests/satellite-ansible.tst.sh:270-272` greps every
`/var/<var>/.../desk-reconcile|unanswered-sweep|weekly-scan|backup|tenants` in orc and iac
`src/bash`: **6** distinct paths on this sha, `-ge 5` to pass. Row 01 removes 1
(`/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/desk-reconcile`), so **6 -> 5, still passes**, and
"desk-reconcile included" still holds through `desk-reconcile-cron.sh:189`.

**The baseline.** `orc:tests/no-literal-paths-spelled.baseline` (r77-01): **19 lines in 17
files**; `:6` is `1 csi-spl-orc/src/bash/run/spl-desk-install-service.func.sh`. Row 01
drops it: **18 in 16**, else the gate's STALE check fails.

### 1.4 Row 02's site: `do_tf_log_open`

`iac:lib/bash/funcs/tf-log-mask.func.sh` (27 lines), `:24-27`:

```text
do_tf_log_open() {
  local f="${1:?do_tf_log_open: the log file}"
  mkdir -p "${f%/*}" && (umask 027 && : >>"$f") && chmod 0640 "$f"
}
```

`${1:?}` with an empty or missing argument prints the message and **exits** the
non-interactive shell, so the caller's `|| return 1` never runs. Developer guide 2.4.3:
"a function returns a code instead of exiting the caller's shell". The 5 callers each pass
a set log path and handle a failure: `iac:src/bash/run/tf-apply.func.sh:22`,
`tf-apply-target.func.sh:38`, `tf-destroy.func.sh:17`, `tf-destroy-target.func.sh:32`,
`tf-destroy-local-step-bucket.func.sh:27`, each `do_tf_log_open "$<log>" || return 1`.

**The shape:** `[[ -n "${1:-}" ]] || { echo "do_tf_log_open: the log file" >&2; return 1; }`,
then `local f="$1"`. Every call with a path behaves as today; only the empty-argument
path changes, from a shell exit to rc 1, which each caller turns into its own
`return 1`. The other `local x="${1:?...}"` lines (15 in 8 iac lib / run files, 10 in 4
orc ones, `git grep -cE '^\s*local [a-z_]+="\$\{1:\?'`) are not this row (section 7).

**The tests** naming the file or its functions: `iac:src/bash/tests/tf-apply-no-input.tst.sh`
(its section 3b calls `do_tf_log_open`), `tf-log-mask-billing-id.tst.sh`,
`tf-apply-destroy-quoted-paths.tst.sh`.

### 1.5 Before (this lane, worktree at `4c5633d84`)

2026-11-20T23:15:14Z, n=1, `SPOOL_TEST=1`, as the push user; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`:

| suite | row | rc | pass lines | fail lines | last line |
|---|---|---|---|---|---|
| `orc:tests/no-literal-paths.tst.sh` | 01 | 0 | 15 | 0 | `ALL PASS` |
| `orc:tests/desk-install-service-envs.tst.sh` | 01 | 0 | 12 | 0 | `desk-install-service-envs: 0 failure(s)` |
| `iac:src/bash/tests/satellite-ansible.tst.sh` | 01 | 0 | 96 | 0 | `PASS: all satellite-ansible.tst.sh assertions` |
| `iac:src/bash/tests/tf-apply-no-input.tst.sh` | 02 | 0 | 29 | 0 | `PASS: all tf-apply-no-input.tst.sh assertions` |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | both | 0 | 15 | 0 | `PASS: all bash-cleancode.tst.sh assertions` |

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r78-01-orc-desk-cron-log-dir-var-app-subdir)` | canonical paths (developer guide 2.3.1); folded helpers exist once (2.2.4) | the desk-reconcile installer spells its cron log dir by hand; the run lib's helper derives the same dir (1.3, 3 of 3) | `orc:run/spl-desk-install-service.func.sh:83` (the `@param` default), `:120`<br>`orc:tests/no-literal-paths-spelled.baseline:6` (drop the line)<br>(+ one new case in `orc:tests/desk-install-service-envs.tst.sh`) | 1 site | The site takes 1.3's shape. **Gate:** r77-01's ratchet, baseline 17 -> **16** files (19 -> 18 lines); the entry dropped in this commit, else its STALE check fails. **New case** in `desk-install-service-envs.tst.sh`: `svc` with `DESK_CRON_LOG_DIR` unset (`env -u`) and `SPL_VAR_APP_DIR=$T/var`, `DESK_SERVICE_ACTION=check` (read-only: it writes nothing): its JSON `log_dir` is `$T/var/desk-reconcile`. **Red control:** the same case on the parent prints the hand form (`/var/<org>/<org>-<app>/desk-reconcile`) and FAILs; `check` creates no dir, so the red run touches no live path; output in the body. **Behaviour:** the 3-tree same-dir proof of 1.3, re-run on the lane's start sha, in the body. Suite pass lines 1.5's 12 plus the new ones; `satellite-ansible.tst.sh` still passes with `n_sd` 5. Tests: the 21 files of 1.3's grep (run each), `no-literal-paths.tst.sh`, `iac:src/bash/tests/satellite-ansible.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r78-02-iac-tf-log-open-returns)` | bash that fails safely: a function returns a code (developer guide 2.4.3) | `do_tf_log_open`'s `${1:?}` exits the caller's shell on an empty argument, so its 5 callers' `|| return 1` never runs (1.4) | `iac:lib/bash/funcs/tf-log-mask.func.sh:25`<br>(+ one new case in `iac:src/bash/tests/tf-apply-no-input.tst.sh`, section 3b) | 1 site | The site takes 1.4's shape. **New case** in section 3b: in a subshell, `source "$MASK_LIB"; do_tf_log_open ""; echo "rc=$?"` prints `rc=1` and the message on stderr, and creates nothing; the same with no argument. **Red control:** on the parent the subshell exits at `:25` and prints no `rc=` line: FAIL, then GREEN; outputs in the body. **Behaviour:** the existing 29 pass lines (5 actions, their 640 logs, `do_tf_apply`'s rc) unchanged. Tests: `tf-apply-no-input.tst.sh`, `tf-log-mask-billing-id.tst.sh`, `tf-apply-destroy-quoted-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. No terraform, no GCP: the tests stub them. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads, row 01's baseline count, 1.3's
`n_sd` read and same-dir proof, on the `origin/master` it starts from, and says in its
result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r78-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r78-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01's help text is the `@param` line in the action itself (`:83`); no
`csi-spl-doc/` page names the default (`git grep -n DESK_CRON_LOG_DIR -- csi-spl-doc` ->
0). Row 02 changes no documented behaviour. Each: `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02.** Their files are disjoint (orc run + orc tests vs iac lib +
  iac test), so both place at once.
- No row edits `lib:spl-run-paths.func.sh`, `lib:spl-cloud-cnf.func.sh`,
  `orc:scripts/desk-reconcile-cron.sh`, `iac:src/bash/tests/satellite-ansible.tst.sh`
  (read, run, not edited), `orc:tests/no-literal-paths.tst.sh`, any `iac:src/bash/run/tf-*`
  caller, a migration, `csi-spl-cnf/`, a workflow, terraform, `csi-spl-utl/` or
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Row paths: `orc:run/spl-desk-install-service.func.sh`,
`orc:tests/desk-install-service-envs.tst.sh`, `orc:tests/no-literal-paths-spelled.baseline`,
`iac:lib/bash/funcs/tf-log-mask.func.sh`, `iac:src/bash/tests/tf-apply-no-input.tst.sh` (5).

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-391`, one call per
  path, 2026-11-20T23:11:34Z, n=1: **exit 4 on all 5**: no live lane lists them; 4 live
  lanes on the other box record no files: c-461 (spec 123 P03, project cost mask), c-476
  (a `rotate` seat), m-551 (the bug round 30 panel seat), m-555 (this round's panel
  seat). Their briefs are not on this box; none is a coding lane near these paths by its
  slug. The holder re-checks them before placing.
- **Briefs on this box** changed in the last 48 h (176 files, 23:11:58Z), grepped for
  `spl-desk-install-service|desk-install-service-envs|no-literal-paths-spelled|tf-log-mask|tf-apply-no-input|do_tf_log_open`:
  **5 files**: this brief, r77-01's and r77-02's row briefs and r77-02's R7 brief
  (landed, `a8d2ea7d5`, `7ff2604dd`) and r76-02's R7 brief (landed). None live, none
  queued.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 23:12:06Z): **35
  queued, 1 placing**, every row class `feature`: spec 123 P05 / P07 and its cost-label
  L0-L7, spec 184, spec 181 (b4-b6, b10, v04), spec 033 T025-T027, spec 143, 187, WUI
  lanes. `c002-s181-b5-tf-step-workspace-vms-plan` is the nearest by name (a terraform
  step); its brief is not on this box, and the holder re-checks it against row 02's
  `tf-log-mask.func.sh` before placing. Live share at that read: `refactor 2 10% (band
  40-60%: UNDER)`, `phase night`; last 24 h `refactor 11% (band 20-30%: UNDER)`.
- **Remote branches committed in the last 24 h** (37 besides master, as this lane's
  fetch holds them, 23:12:56Z): `git diff --name-only $(git merge-base origin/master <b>) <b>`
  filtered for the 5 basenames -> **0 hits**.
- **This box's lane worktrees** (317 besides this one, 23:13:30Z):
  `git -C <wt> diff --name-only origin/master...HEAD` and `git -C <wt> diff --name-only HEAD`,
  same filter -> **0 hits**. The other box's worktrees were not read by this lane.
- **Commits since W** on the row paths (`git log origin/master --since="$W" -- <paths>`)
  -> **0**.
- **Unlanded round rows:** bug round 30 (SPL-6108) has no plan on `4c5633d84`
  (`ls csi-spl-doc/doc/md | grep -c bug-round-30` -> 0); its rows are not yet known. The
  holder re-checks 2.2 against b30's plan before placing. Spec 182 / 123 / 033 / 181
  rows: by their slugs, hub, WUI, rdb, CLI and cost lanes, none on a row path.

## 3. Per row: what the lane does

- **r78-01:** `do_spl_desk_install_service` derives its desk-reconcile log dir with
  `spl_var_app_subdir` when `DESK_CRON_LOG_DIR` is unset, its `@param` line says so, its
  line leaves the spelled-dir baseline, and the envs suite gains the default-dir case.
- **r78-02:** `do_tf_log_open` returns 1 on an empty argument instead of exiting the
  shell; the no-input suite gains the case.

## 4. Panel and reviewers (R7)

- Editor: c-391 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r78`):
  one **cross-vendor** doc seat, the queued mistral seat
  `c002-refactor-round-78-mistral-panel-seat` (m-555 on the lane map; agy, the main vendor
  for plan reviews, is out until about 11-24). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2). `BOX_PICK_KIND=grok
  ./run -a do_spl_box_pick` at 2026-11-20T23:15:42Z -> `pick=hold` (grok weekly 99% on
  both boxes), so each row takes a fresh **claude waiver seat** (1a7c70da), as r63 to
  r77. Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r78-01 | `c002-r78-01-orc-desk-cron-log-dir` | `refactor(r78-01-orc-desk-cron-log-dir-var-app-subdir, SPL-<row issue>): ...` | `review/r78-01` | 1 |
| r78-02 | `c002-r78-02-iac-tf-log-open-returns` | `refactor(r78-02-iac-tf-log-open-returns, SPL-<row issue>): ...` | `review/r78-02` | 1 |

**r78-01 brief, Files: ONLY** `orc:run/spl-desk-install-service.func.sh` (`:83`, `:120`),
`orc:tests/desk-install-service-envs.tst.sh` (one new case) and
`orc:tests/no-literal-paths-spelled.baseline` (drop `:6`). NOT `lib:spl-run-paths.func.sh`,
NOT `lib:spl-cloud-cnf.func.sh`, NOT `orc:scripts/desk-reconcile-cron.sh` (the reader
stays, 1.3), NOT `orc:tests/no-literal-paths.tst.sh`, NOT
`iac:src/bash/tests/satellite-ansible.tst.sh` (run it, do not edit it). Do: plan section 2
row 01 verbatim, 1.3's shape; the red control with `DESK_SERVICE_ACTION=check` only (it
writes nothing), never an install or a dry plan with the override unset on the parent;
the 3-tree same-dir proof; the suite counts and `n_sd` in the body. Gates: the 21 test
files of 1.3, `no-literal-paths.tst.sh`, `satellite-ansible.tst.sh`,
`bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r78-02 brief, Files: ONLY** `iac:lib/bash/funcs/tf-log-mask.func.sh` (`:25`) and
`iac:src/bash/tests/tf-apply-no-input.tst.sh` (one new case in section 3b). NOT any
`iac:src/bash/run/tf-*.func.sh` caller, NOT `do_tf_log_mask`, NOT the other `${1:?}`
lines (1.4). Do: plan section 2 row 02 verbatim, 1.4's shape; the red control RED then
GREEN in the body. Gates: `tf-apply-no-input.tst.sh`, `tf-log-mask-billing-id.tst.sh`,
`tf-apply-destroy-quoted-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`),
`cd csi-spl-iac && ./run -a do_check_pre_push`. No terraform run, no GCP. `Docs: none
(...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (2 refactors, `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| spelled var-dir lines (`no-literal-paths-spelled.baseline`) | 19 in 17 files today -> 18 in 16 after row 01 |
| `satellite-ansible.tst.sh` `n_sd` | 6 today -> 5 after row 01 (passes at `-ge 5`) |
| `${1:?}` exits in `tf-log-mask.func.sh` | 1 today -> 0 after row 02 |
| measured on | `4c5633d84`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:scripts/desk-reconcile-cron.sh:189` (the `--print` reader of the same dir) | a cron wrapper in `scripts/` that needs the scripts-side source (r77-02's shape); moving it with row 01 drops `n_sd` to 4 and fails `satellite-ansible.tst.sh` (iac). A row of its own after row 01, with that test's floor or pattern in it | 1.3 |
| `10_ci-quality.yml:444-445` comment (candidates item 6) | wording only, a workflow file; **first candidate for r79** | 1.2 |
| `terraform init` without `-input=false` (candidates item 2 N2) | 13 sites; a prompt that waits today would fail: a behaviour change, a bug or hardening row, measured on the tf-runner path first | 1.2 |
| the other `local x="${1:?...}"` lines (15 in 8 iac files, 10 in 4 orc files) | the same practice as row 02; their callers differ, so a row of its own after row 02 shows the shape | 1.4 |
| r77-01 N1, `check-ysg-box-deps.func.sh` | the name is the frozen engine's (spec 069 `ysg-box-out`); a rename changes the action name `do_check_ysg_box_deps`, 5 `YSG_BOX_DEPS_*` params and 9 files: an operator-facing rename, its own row with spec 069's owner | 1.2 |
| r77-02 N1, `SPL_*` exported into the box-sessions scripts' children | `spl_run_paths` exports them by design (`lib:spl-run-paths.func.sh:75`); a test that pins it is a test row of its own; a change of it is a bug row | 1.2 |
| `spl-unanswered-sweep-install-cron.func.sh:57` | spec 182 lanes are live on the unanswered sweep and loops; re-check the lane map next round | 1.2 |
| the desk hop's env forwarding (candidates item 3, SPL-5824 W1, N1, N2) | the forwarded list changes what reaches the hop: a bug row | 1.2 |
| the install guide's reverse-tunnel literal (candidates item 5 N3) | `installation-and-configuration-guide.md:594`; the guide is a Qto export: an ask to the holder | 1.2 |
| spec 182 L2 `!inserted` branch untested (candidates item 8) | spec 182 N4 is live on hub `topic_loop*` | 1.2 |
| the iac / utl spelled lines; a gate over files outside the existing scope | r77 section 7's reasons hold | r77 1.3 |
| the 3 tenant-dir sites, `gcp-backup-env.func.sh` | secret-class work (the data rule), r73 to r77 | r77 1.3 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, terraform layout or docs; the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-391): first draft. A fresh round: row 01 moves the desk-reconcile installer's
  log dir onto `spl_var_app_subdir` (same dir on this box's 3 tree kinds, 3 of 3) and
  lowers r77-01's baseline; row 02 makes `do_tf_log_open` return instead of exit. Batch 1
  both. Window W and the r78 slug proof recorded.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-391 (claude): v0.1.
- Panel reviewer seat: pending (the queued mistral seat).
- Row R7 seats: section 4.
