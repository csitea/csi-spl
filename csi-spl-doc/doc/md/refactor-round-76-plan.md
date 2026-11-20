# Refactoring round 76 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6061  
Topic: 1ee84a49-4f72-4605-b47c-7bc9a26febcc  
Discussion: 1ee84a49-4f72-4605-b47c-7bc9a26febcc (t1 #refactoring, "Refactor round 76", opener msg 370f7ffb)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r76**, plan `refactor-round-76-plan.md`, rows `r76-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 75 ([refactor-round-75-plan.md](refactor-round-75-plan.md))
is closed (`497fa03f2`): r75-01 landed `68249a2d9` (SPL-6051), r75-02 landed `d6cf92dd0`
(SPL-6052). No signed row is handed on: r76 is a fresh round. The perf floor (rulebook
4.4), the holder's read on `497fa03f2`: `perf 29 refactor 104 perf-share 21.8% floor-met`,
so this is a refactor round.

The rows continue r73 to r75's work: **cron installers in `csi-spl-orc/src/bash/run`
that still build the app's var dir by hand** instead of r71-01's helper
`spl_var_app_subdir`. Row 01 takes the 2 installers that spell it from a local
`org_app` (a spelling r74 and r75 left out, section 7 of each). Row 02 takes
`spl-dispatch-rotate-install-cron.func.sh:74`, which r75 left out only because its
function (73 lines) would pass the 75-line cap: the row first moves the function's
`check` branch into a named helper, then moves the site.

**Status: v1.0**: panel seat m-148 (mistral) PASS on v0.1 `41552fddd`, one W finding
(W1, a regex spelling in 1.3, fixed) and N1-N4 recorded (section 8); none changes a row.
Rows 01 and 02 are as drafted. Editor: **c-410** (claude).

**One sha:** every count is measured on **`4168d752b`** (`origin/master`
4168d752b1421bbb2fe3ec7a8afcccba5a74c53e, committed 2026-11-20T16:19:07+02:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`; the tests ran
on this lane's worktree at that sha, as the push user with `SPOOL_TEST=1`. Queue, lane
map, brief and worktree readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-20T16:02:21+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r75-plan'` -> commit
  `497fa03f2` "refactor round 75 plan records the round closed, rows 01-02 landed".
  Every later read of r76 uses this W.
- **`r76` is free** (2026-11-20T14:30:28Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r76-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r76-*' 'refs/heads/wip/*r76*' 'refs/heads/*-r76-*' 'refs/heads/*refactor-round-76*'`
    -> **nothing** (rc 0). This planner's review branch is pushed after that read.
  - `grep -rlE 'r76-[0-9]{2}|refactor-round-76' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
    (as root) on this lane's box -> **1 file**, this planner's own brief. The other
    box's briefs were not read by this lane; the holder's read before the spawn: 0
    besides this brief (the brief).
  - Control: the same log read with `(r75-` since W -> 1 line, `497fa03f2` (the r75
    close record), so the read sees a used id.
- **No `refactor-round-76*` file** exists under `csi-spl-doc/doc/md` on `4168d752b`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-76` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `lib:` = `csi-spl-orc/lib/bash/funcs/`,
`iac:` = `csi-spl-iac/src/bash/`.

| input | source | on `4168d752b` | here |
|---|---|---|---|
| r75 section 7: `spl-dispatch-rotate-install-cron.func.sh:74` | r75 section 7 | the site is there; `do_spl_dispatch_rotate_install_cron` is still 73 lines (`:53-125`); no commit on the file since W | **row 02** (split first, 1.4) |
| r75 section 7: `spl-desk-install-service.func.sh:120` | r75 section 7 | the site is there; 21 test files name the file or its action (1.3's command). `satellite-ansible.tst.sh:271`'s `n_sd` reads **6** (1.3), so moving this site alone leaves 5, still `-ge 5` | left out (section 7): its 21 callers make it a row of its own |
| r75 section 7: `spl-unanswered-sweep-install-cron.func.sh:57` | r75 section 7 | the site is there; spec 182 L2b (c-973) is still on the lane map (2.2) | left out (section 7) |
| r75 section 7 / r74 section 7: the `org_app\|ORG_APP\|app` spelling, 5 lines | r74 section 7 | `git grep -nE '/(var\|opt)/\$\{?(org_app\|ORG_APP\|app)\b'` (1.3's filter) -> **5**: `spl-box-update-install-cron:34`, `spl-cost-rollup-install-cron:42`, `spl-spool-refresh:55` (an operator NOTE), `spl-wd-ensure:194`, `orc:scripts/desk-reconcile-cron.sh:189` | **row 01** takes the 2 installers; 3 stay out (section 7) |
| r75 section 7: the gate for the shape (`no-literal-paths.tst.sh` with a baseline, `features/` too, r75 panel N1) | r75 section 7 | `no-literal-paths.tst.sh:42` still greps `/(opt\|var)/<org>` only; the hand spellings in `orc:` outside tests: `SPL_ORG_APP` **3**, `org_app\|ORG_APP\|app` **5**, `ORG\|org` **3**, plus 2 `bs_org_app` lines in `features/` (1.3) | left out (section 7): the first candidate of round 77 once this round lands, so its baseline is cut once |
| r75 section 7: `features/box-sessions/scripts/{save-sessions,sessions-boot}.sh:41` | r75 panel N1 | both lines there (`/var/${bs_org_app%%-*}/$bs_org_app/box-sessions`); standalone scripts that source `spool-env.inc.sh`, not `lib:spl-run-paths.func.sh` | left out (section 7) |
| the candidates file (`<spool>/dispatch/c002-next-round-candidates.md`) | the brief | on this lane's box: 13535 bytes, last changed 2026-11-20 14:13 (box local). Its refactor-shaped items (the watchdog / lane-rotate `/var` literals, `reverse-tunnel-cron.sh`, the agent-boot-restore dir) are the ones r71 to r75 read as served; the item added since r75 read it is bug-shaped (the weekly-quota reading kept across a credential copy) | nothing taken |
| `.shellcheck-warning-baseline.txt` | the brief | no commit since W (`git log --oneline --since="$W" -- .shellcheck-warning-baseline.txt` -> 0): the 68 lines r75 read | nothing taken: r71 to r75 section 7's reasons hold |
| `no-literal-paths.baseline` | the brief | 1 entry, `2 csi-spl-orc/src/bash/run/spl-file-erase.func.sh` (a protected-root deny list, r66 to r75: behaviour) | left out (section 7) |
| r75 R7 findings | the brief | `68249a2d9` (c-104) and `d6cf92dd0` (c-390): `git log -1 --format=%B <sha> \| grep -cE '^(N[0-9]\|W[0-9])'` -> 0 each; one `review:` line each. Neither body names a site left to move | nothing taken |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0 | left out (section 7), r65 to r75's reasons hold |

### 1.3 The hand-spelled var dirs left in `orc:`

`lib:spl-run-paths.func.sh:66-76` (`spl_run_paths`) derives `SPL_VAR_APP_DIR` =
`<var>/<org>/<main checkout name>`; `spl_var_app_subdir <var> <sub>` (`:81-85`, r71-01)
sets the named variable to `$SPL_VAR_APP_DIR/<sub>` with `printf -v`. The developer guide
(2.3.1): "No action carries a literal `/opt/<org>` or `/var/<org>` path".
`no-literal-paths.tst.sh:42` greps `/(opt|var)/<org>` with the org's real name, so it
does not see a dir spelled from a variable.

**Gates** (each `git grep -nE '<rx>' 4168d752b -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l`):

| rx | count | lines |
|---|---|---|
| `'/(var\|opt)/\$\{?SPL_ORG_APP'` (r75's gate) | **3** | `spl-desk-install-service:120`, `spl-dispatch-rotate-install-cron:74` (row 02), `spl-unanswered-sweep-install-cron:57` |
| `'/(var\|opt)/\$\{?(org_app\|ORG_APP\|app)\b'` | **5** | `spl-box-update-install-cron:34`, `spl-cost-rollup-install-cron:42` (row 01), `spl-spool-refresh:55`, `spl-wd-ensure:194`, `orc:scripts/desk-reconcile-cron.sh:189` |
| `'/(var\|opt)/\$\{?(ORG\|org)\b'` | **3** | the tenant dirs (`spl-desk-rebox:111`, `spl-invite-e2e:118`, `spl-m3-e2e:159`) |

In the table, `\|` is markdown's escape for a pipe inside a cell; the shell regex has a
plain `|` (panel W1). The three commands to paste, each -> 3, 5, 3 on `4168d752b`:

```text
git grep -nE '/(var|opt)/\$\{?SPL_ORG_APP' 4168d752b -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l
git grep -nE '/(var|opt)/\$\{?(org_app|ORG_APP|app)\b' 4168d752b -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l
git grep -nE '/(var|opt)/\$\{?(ORG|org)\b' 4168d752b -- csi-spl-orc/src/bash ':!*/tests/*' | grep -vE ':[0-9]+:\s*#' | wc -l
```

The row sites (function and its length from `awk` over `^name() {` to the first `^}`):

| file (`orc:run/`) : line | function (lines) | var | sub | override | suites that name it (`git grep -lE '<basename>\|<do_ name>' -- '*tests/*'`) | row |
|---|---|---|---|---|---|---|
| `spl-box-update-install-cron.func.sh:34` | `do_spl_box_update_install_cron` (30, `:26-55`) | `logdir` (local) | `box-update` | `BOX_UPDATE_CRON_LOG_DIR` | `orc:tests/spl-box-update-install-cron.tst.sh`; `orc:tests/spl-box-deploy.tst.sh` (stubs it, `:65`); `orc-shard-weights.txt` (a name only) | 01 |
| `spl-cost-rollup-install-cron.func.sh:42` | `do_spl_cost_rollup_install_cron` (35, `:34-68`) | `logdir` (local) | `cost-rollup` | `COST_ROLLUP_CRON_LOG_DIR` | `orc:tests/spl-cost-rollup-install-cron.tst.sh`; `orc-shard-weights.txt` (a name only) | 01 |
| `spl-dispatch-rotate-install-cron.func.sh:74` | `do_spl_dispatch_rotate_install_cron` (**73**, `:53-125`) | `logdir` (local) | `dispatch-rotate` | `ROTATE_CRON_LOG_DIR` | `orc:tests/dispatch-rotate.tst.sh`; `orc:tests/spl-box-deploy.tst.sh`; **`iac:tests/satellite-ansible.tst.sh`** (greps its `tag=` line, `:371-372`) | 02 |

Row 01's sites set `org_app="$(basename "$PROJ_PATH")"; org_app="${org_app%-orc}"`
(`:32` and `:40`), the same value r75's sites read as `SPL_ORG_APP`. `org_app` stays:
each site still reads it for its `tag`.

**Same dir today, measured** (this lane's box, 2026-11-20T14:37:46Z, n=1 per tree and
sub; the lib at `4168d752b`, run as the push user under `env -i`): for `PROJ_PATH` = the
main checkout's, the desk-cron checkout's (a worktree) and this lane's worktree's
`csi-spl-orc`, `spl_var_app_subdir d <sub>` and the hand form (`basename` of
`PROJ_PATH` without `-orc`, then `/var/${oa%%-*}/$oa/<sub>`) print the same path for the
subs `box-update`, `cost-rollup` and `dispatch-rotate`: **9 of 9 EQUAL**. The forms differ
only where r74 1.3 and r75 1.3 say: a tree outside `<base>/<org>/<app>`, a preset
`SPL_VAR_APP_DIR` (it wins), no tree at all (the change FATALs where the parent planned
`/var///<sub>`), and a caller that presets the org-app name to another value than its
tree's. The 3 row suites never preset it (`grep -c 'SPL_ORG_APP='` -> 0 on each; row 01's
sites read `PROJ_PATH` only) and every existing case passes the override
(`grep -c <OVERRIDE>`: `spl-box-update-install-cron.tst.sh` 2, `spl-cost-rollup-install-cron.tst.sh`
1, `dispatch-rotate.tst.sh` 1, at `:23,68`, `:28`, `:606`); `grep -c SPL_VAR_APP_DIR` -> 0
and `grep -cE '/var/(\$|csi)'` -> 0 on all 3. So no test reads the default today: each
row adds the default's case.

**The shape to copy** is on master, r74-01's form (`git show 1f5404315 --
csi-spl-orc/src/bash/run/spl-spawn-fill-install-cron.func.sh`), as r75 used it:

```text
logdir="${SPAWN_FILL_CRON_LOG_DIR:-}"
if [[ -z "$logdir" ]]; then
  declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
  spl_var_app_subdir logdir spawn-fill || { do_log "FATAL cannot derive the spawn-fill cron log dir (no tree for spl_run_paths): set SPAWN_FILL_CRON_LOG_DIR"; return 1; }
fi
```

Each site becomes that block with its own sub and override name: net **+4 lines**.

**A source-reading test (R2, bold in the row):** `iac:tests/satellite-ansible.tst.sh:270-272`
greps `orc` and `iac` `src/bash` for `/var/(...)/[^ "]*(desk-reconcile|unanswered-sweep|weekly-scan|backup|tenants)`
and needs **at least 5** distinct hits (`n_sd -ge 5`). On `4168d752b` it finds **6**
(`grep -rhoE <its pattern> csi-spl-orc/src/bash csi-spl-iac/src/bash | sort -u`); no row
site is among them (`box-update`, `cost-rollup`, `dispatch-rotate` are not in its
list). Its `:371-372` greps `tag="$SPL_ORG_APP:dispatch-rotate"` in row 02's file: the
`tag=` line does not change.

### 1.4 Row 02's split: the `check` branch of `do_spl_dispatch_rotate_install_cron`

Bash clean code cap 75 (`iac:tests/bash-cleancode.tst.sh` `MAX_LINES=75`). The function
is 73 lines; 1.3's form adds 4, so it would be 77. The `check` branch is one block,
`:87-99` (13 lines, `if [[ "$act" == check ]]; then` to its `fi`), that reads only
`$current`, `$hcurrent`, `$line`, `$every`, `$tag` and `$htag` and always returns. Moved
to a named helper next to `spl_disp_heal_offset` (e.g. `_spl_disp_cron_check`) and
called as one line (`[[ "$act" == check ]] && { _spl_disp_cron_check ...; return; }`),
the function is 61 lines, and **65** with the site moved. The helper is 13 to 15 lines.
Its messages and return codes stay byte for byte.

`dispatch-rotate.tst.sh` section 10 covers the branch once, on the pass path ("10.
check passes once installed", `:623`); its 3 FAIL paths (no rotation line, a script that
is gone, no heal line while `ROTATE_HEAL_CRON_EVERY` > 0) have no case. So the row first
adds those 3 cases, green on the parent, and they must stay green on the split
(behaviour pinned before it moves).

### 1.5 Before (this lane, worktree at `4168d752b`)

2026-11-20T14:3xZ (14:37:39Z end), n=1, `SPOOL_TEST=1`, as the push user; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`:

| suite | row | rc | pass lines | fail lines | last line |
|---|---|---|---|---|---|
| `spl-box-update-install-cron.tst.sh` | 01 | 0 | 11 | 0 | `ALL PASS` |
| `spl-cost-rollup-install-cron.tst.sh` | 01 | 0 | 15 | 0 | `spl-cost-rollup-install-cron: 0 failure(s)` |
| `dispatch-rotate.tst.sh` | 02 | 0 | 199 | 0 | `dispatch-rotate: all passed` |
| `spl-box-deploy.tst.sh` | both (run) | 0 | 36 | 0 | `ALL PASS` |
| `iac:tests/satellite-ansible.tst.sh` | 02 (run) | 0 | 96 | 0 | `PASS: all satellite-ansible.tst.sh assertions` |
| `no-literal-paths.tst.sh` | both | 0 | 8 | 0 | `ALL PASS` |
| `iac:tests/bash-cleancode.tst.sh` | both | 0 | 15 | 0 | `PASS: all bash-cleancode.tst.sh assertions` |

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r76-01-orc-var-app-subdir-org-app-crons)` | canonical paths, no box path in an action (developer guide 2.3.1); folded helpers exist once (2.2.4) | 2 cron installers build their own `logdir` by hand from a local `org_app`, a spelling the literal-path gate cannot see; r71-01's helper derives it | `orc:run/spl-box-update-install-cron.func.sh:34`<br>`orc:run/spl-cost-rollup-install-cron.func.sh:42`<br>(+ one new case in each site's suite) | 2 sites | Each site takes 1.3's form: the override kept, else `spl_var_app_subdir logdir <sub>` (`box-update`, `cost-rollup`), FATAL + `return 1` naming the override when no tree. **Gate:** 1.3's `org_app\|ORG_APP\|app` grep 5 -> **3**. **New cases**, one per suite (`spl-box-update-install-cron.tst.sh`, `spl-cost-rollup-install-cron.tst.sh`): override empty, `SPL_VAR_APP_DIR=$T/var`, the suite's own crontab stub, a `DRY_RUN=1` install: the printed diff holds `$T/var/<sub>/` (its lock and its `cron.out`; for cost-rollup `cost-rollup-dev.lock` and `cron-dev.out`) and nothing is created under `$T/var`. **Red control:** both new cases FAIL on the parent (it prints `/var/<org>/<org>-<app>/<sub>`), output in the body; a dry run writes nothing. **Behaviour:** on this box with no override each installer's `DRY_RUN=1` output is byte-identical on the parent and the change (crontab a fake file), diff in the body; the suites' pass counts equal 1.5's plus the new cases. Tests: the 2 suites, `spl-box-deploy.tst.sh`, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r76-02-orc-dispatch-rotate-cron-check-split-var-app-subdir)` | small functions, 75 lines (2.2.1); canonical paths (2.3.1) | the last `SPL_ORG_APP` installer r75 could not move without passing the 75-line cap | `orc:run/spl-dispatch-rotate-install-cron.func.sh:87-99` (the `check` branch, to a helper)<br>`orc:run/spl-dispatch-rotate-install-cron.func.sh:74`<br>(+ 4 new cases in `orc:tests/dispatch-rotate.tst.sh` section 10) | 1 split, 1 site | **Step 1, pin:** 3 new section-10 cases on the `check` FAIL paths (no rotation line -> rc 1 and `FAIL the dispatcher rotation is NOT installed`; the line's script removed or not executable -> rc 1 and `FAIL the line names a script`; the heal line dropped by hand with `ROTATE_HEAL_CRON_EVERY` > 0 -> rc 1 and `FAIL the dispatcher heal is NOT installed`), green on the parent. **Step 2, split:** 1.4's helper; the function 73 -> 61 lines; the 4 check cases still green, output unchanged. **Step 3, site:** 1.3's form, sub `dispatch-rotate`, override `ROTATE_CRON_LOG_DIR`; function 65 lines. **Gate:** 1.3's `SPL_ORG_APP` grep 3 -> **2**; `bash-cleancode.tst.sh` green with no new `LONG` entry. **New case** (the 4th): override empty, `SPL_VAR_APP_DIR=$T/var`, `DRY_RUN=1`: the diff holds `$T/var/dispatch-rotate/cron.out` and `heal.out` / `heal.lock`, nothing under `$T/var`. **Red control:** that case FAILs on the parent, output in the body. **Behaviour:** `DRY_RUN=1` and `ROTATE_CRON_ACTION=check` output on this box (fake crontab) byte-identical on parent and change, diff in the body; counts equal 1.5's plus 4. Tests: `dispatch-rotate.tst.sh`, `spl-box-deploy.tst.sh`, **`iac:tests/satellite-ansible.tst.sh`**, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. One commit, or the pin and the split + site as two (rulebook 1.2: at most 3 pushes). | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs 1.3's gate greps, the function lengths and
the line reads on the `origin/master` it starts from, and says in its result if the
sites moved.

**Subject** (R6 reads it): `<type>(r76-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r76-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each action's `@param <OVERRIDE>` help line names the default as
`/var/<org>/<org>-<app>/<sub>` (`spl-box-update-install-cron.func.sh:18`,
`spl-cost-rollup-install-cron.func.sh:25`, `spl-dispatch-rotate-install-cron.func.sh:28`),
the derived dir's shape on a `<base>/<org>/<org>-<app>` tree, so it does not change. Each
row carries `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, placed together. Their file sets are disjoint: row 01
  edits 2 code files and 2 suites, row 02 one code file and one suite, no file in both.
  The suites a row only runs (`spl-box-deploy.tst.sh`, `satellite-ansible.tst.sh`,
  `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh`) are not edited.
- No row edits `lib:spl-run-paths.func.sh`, a migration, `csi-spl-cnf/`, a workflow,
  terraform, `csi-spl-iac/`, `csi-spl-utl/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Row paths: `orc:run/spl-box-update-install-cron.func.sh`,
`orc:run/spl-cost-rollup-install-cron.func.sh`, `orc:run/spl-dispatch-rotate-install-cron.func.sh`,
`orc:tests/spl-box-update-install-cron.tst.sh`, `orc:tests/spl-cost-rollup-install-cron.tst.sh`,
`orc:tests/dispatch-rotate.tst.sh` (6).

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-410`, one call per
  path, 2026-11-20T14:31:43Z, n=1: **exit 4 on all 6**: no live lane lists them; 19 live
  lanes on the other box record no files: 10 `rotate` seats (c-056, c-060, c-064,
  c-068, c-075, c-625, c-812, c-924, c-927, c-977), c-093 (spec lane, cost labels),
  c-098 (spec lane, multicast prompt), c-127 (b28-02, a spec 157 doc row), c-968 /
  c-973 / c-975 (spec 182 L1 rdb + store, L2b orc sweep, L3 wui), c-970 (a review
  build), m-021 (the bug round 28 panel seat). The non-rotate ones were read from their
  briefs on this box (`c002-s-cost-labels-translate-on-save-spec.md`,
  `c002-s-multicast-prompt-spec.md`, `c002-b28-02-doc-spec157-review-go-on-master.md`,
  `c002-s182-l1-*`, `-l2b-*`, `-l3-*`): `grep -cE 'cost-rollup|box-update|dispatch-rotate|box-sessions|spl-desk-install-service'`
  -> 0 on each. c-973's scope is the unanswered sweep, which this round leaves out.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-20T14:31:17Z):
  **22 queued, 0 placing**: spec 033 T022-T027, spec 123 P02-P07 (project cost), spec
  184 (agent model), and t1 bug / feature lanes (WUI notes, docs view, events column,
  topic create, calendar, a scheduled-tasks spec, a pinned-topic spec). Their briefs on
  this box (`c002-s123-*`, `c002-s184-*`, `c002-s033-*`, the two hand-placed ones, the
  t1 lanes' briefs): the 6 row basenames, their action names and `cost[-_]rollup` ->
  **0 hits** (14:31:34Z). Spec 123's lanes are the project cost read, mask, RLS, page
  and help; none names the rollup installer. Live share: `refactor 2 5% (band 10-20%:
  UNDER)`, `phase day`; last 24 h `refactor 16% (band 20-30%: UNDER)`.
- **Every brief on this box that names a row file** (`grep -lE` over
  `<spool>/dispatch/briefs/*.md`, 14:31:14Z): 17 old reviewer / rotation briefs from
  2026-11-18 (landed or closed lanes) and r75-02's two (landed), plus this one. None
  live.
- **Every remote branch committed in the last 24 h** (120 branches besides master after
  a fetch, 2026-11-20T14:32:22Z): `git diff --name-only $(git merge-base origin/master <b>) <b>`
  filtered for the row files and `box-sessions/` -> **0 hits**.
- **This box's lane worktrees** (2026-11-20T14:32:33Z, 179 besides this one):
  `git -C <wt> diff --name-only origin/master...HEAD` and `git -C <wt> diff --name-only HEAD`,
  same filter -> **1 hit**, stale: a `/tmp` copy of g-015 (HEAD 2026-11-15, SPL-5549;
  `git cherry origin/master HEAD` -> 5 `-`, all on master; no tmux window carries g-015).
  The other box's worktrees were not read by this lane.
- **Commits since W** on the 6 row paths (`git log origin/master --since="$W" -- <paths>`)
  -> **0**.
- **Unlanded round rows:** bug round 28 (b28-01 on `orc:run/spl-spawn-place.func.sh`,
  b28-02 a spec 157 doc row): no row file. The spec 182 / 183 build rows: their briefs
  name no row file (above); spec 183's c-339 edits terraform 030/031 and
  `build-push-pdf-image.func.sh`, c-338 `spl-topic-pdf.func.sh` (the brief), not row
  files.

## 3. Per row: what the lane does

- **r76-01:** 2 cron installers derive their own log dir with `spl_var_app_subdir`
  when the override is unset; their cron lines are the same on the box. The 2 suites
  each gain the default-path case.
- **r76-02:** pin the `check` branch's 3 FAIL paths with cases, move the branch into a
  named helper (73 -> 61 lines), then move the site as row 01 does (65 lines); the suite
  gains the default-path case.

## 4. Panel and reviewers (R7)

- Editor: c-410 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r76`):
  one **cross-vendor** doc seat: agy is the main vendor for plan reviews, mistral its
  backup, as r62 to r75 had (no agy CLI on this lane's box). The seat reviews this plan
  only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2), the holder's call when the row
  is queued (a fresh claude seat under the claude waiver, as r63 to r75). Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r76-01 | `c002-r76-01-orc-var-app-subdir-org-app-crons` | `refactor(r76-01-orc-var-app-subdir-org-app-crons, SPL-<row issue>): ...` | `review/r76-01` | 1 |
| r76-02 | `c002-r76-02-orc-dispatch-rotate-cron-check-split` | `refactor(r76-02-orc-dispatch-rotate-cron-check-split-var-app-subdir, SPL-<row issue>): ...` | `review/r76-02` | 1 |

**r76-01 brief, Files: ONLY** `orc:run/spl-box-update-install-cron.func.sh` (`:34`),
`orc:run/spl-cost-rollup-install-cron.func.sh` (`:42`), and one new case each in
`orc:tests/spl-box-update-install-cron.tst.sh` and
`orc:tests/spl-cost-rollup-install-cron.tst.sh`. NOT `lib:spl-run-paths.func.sh`, NOT
row 02's files, NOT `orc:run/spl-cost-rollup-daily*` or any spec 123 file, NOT
`spl-spool-refresh.func.sh`, `spl-wd-ensure.func.sh` or `orc:scripts/desk-reconcile-cron.sh`.
A `DRY_RUN=0` cost-rollup install is the operator's (its header): dry runs only. Do: plan
section 2 row 01 verbatim, 1.3's form; the gate (5 -> 3), the 2 new cases red on the
parent and green on the change, the byte-identical dry-run output, and the suites'
counts in the body. Gates: the 2 suites, `spl-box-deploy.tst.sh`,
`no-literal-paths.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`),
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r76-02 brief, Files: ONLY** `orc:run/spl-dispatch-rotate-install-cron.func.sh`
(`:87-99` the `check` branch, `:74` the site) and `orc:tests/dispatch-rotate.tst.sh`
(4 new section-10 cases). NOT `lib:spl-run-paths.func.sh`, NOT `lib:spl-desk-cron-*.func.sh`,
NOT `orc:run/spl-desk-install-service.func.sh` (its `spl_desk_cron_*` helpers are
called, not changed), NOT `orc:scripts/dispatch-rotate-cron.sh`, NOT row 01's files, NOT
`spl-unanswered-sweep*`. Do: plan section 2 row 02 verbatim: pin (3 cases, green on the
parent), split (1.4, output unchanged), site (1.3's form); the gate (3 -> 2), the
function lengths (73 -> 61 -> 65) from the `awk` read, the default-dir case red on the
parent and green on the change, the byte-identical dry-run and check output, the suite's
counts in the body. Gates: `dispatch-rotate.tst.sh`, `spl-box-deploy.tst.sh`,
`iac:tests/satellite-ansible.tst.sh`, `no-literal-paths.tst.sh`, `bash-cleancode.tst.sh`
(`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`.
Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash cron installers: 2 sites; 1 split + 1 site) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: rows 01 and 02 |
| `org_app\|ORG_APP\|app` hand-spelled lines in `orc:` outside tests (1.3) | 5 today -> 3 after row 01 |
| `SPL_ORG_APP` hand-spelled lines in `orc:` outside tests (1.3, r75's gate) | 3 today -> 2 after row 02 |
| all three hand spellings in `orc:` (1.3) | 11 today -> 8 after both |
| `do_spl_dispatch_rotate_install_cron` lines | 73 today -> 65 after row 02 (cap 75) |
| measured on | `4168d752b`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `spl-desk-install-service.func.sh:120` | the same refactor; `do_spl_desk_install_service` is 60 lines (room for +4), and `satellite-ansible.tst.sh`'s `n_sd` would read 5 (still `-ge 5`), but 21 test files name the file or its action: a row of its own, its callers read first, with `n_sd` changed to count derived dirs before it can fall under 5 | 1.2, 1.3 |
| `spl-unanswered-sweep-install-cron.func.sh:57` | spec 182 L2b (c-973) is still on the lane map and owns the unanswered sweep "and their tests"; moving it with the desk site would leave `n_sd` at 4 | 1.3, 2.2 |
| `spl-spool-refresh.func.sh:55`, `spl-wd-ensure.func.sh:194`, `orc:scripts/desk-reconcile-cron.sh:189` | an operator NOTE text (no dir used); a reader of `wd-ensure`'s log dir (r75-02 moved its writer, `SPL_WD_CRON_LOGDIR`; the reader is its own row with a same-dir proof); a cron wrapper in `scripts/` (r73-02's form) | 1.3 |
| the 3 tenant-dir sites | the tenant root-key store: secret-class work (the data rule), a row of its own on a secret-class vendor (r73 to r75) | 1.3 |
| `features/box-sessions/scripts/{save-sessions,sessions-boot}.sh:41` | standalone scripts that source `spawn-agents/lib/spool-env.inc.sh`, not the run lib: the move needs a source line for `lib:spl-run-paths.func.sh` from `features/`, and both files in one row; a candidate for round 77 | 1.2 |
| a gate for the shape (extend `no-literal-paths.tst.sh` with a baseline over all spellings, `run/`, `scripts/` and `features/`) | its baseline is cut from the count after this round (8 in `orc:` outside tests, plus 2 in `features/`); placed now, both rows would lower it in the same batch. The first candidate of round 77 | 1.3 |
| `iac:run/` and `csi-spl-utl/src/bash/run/` hand-spelled lines | `spl_run_paths` lives in the orc lib: a choice for its own row (or a shared lib first); `gcp-backup-env` is secret-class (r73) | r73 1.3 |
| SC2034 baseline, iac test SC2034, `workflow-tool-checksums.tst.sh:33` `naked`, the p18-02 N1 workflow comment | r71 to r75 section 7's reasons hold; the baseline is unchanged since W | 1.2 |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66 to r75) | 1.2 |
| bash `LONG` `do_provision_firebase_dns` 169 and `[long-example]`; `action-header-tags-baseline.txt` `[missing]` | r67 to r75 section 7's reasons hold | r73 1.2 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, terraform layout or docs; the spec folder unchanged since W | 1.2 |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | r73 section 7's reason holds | r73 1.2 |

## 8. Changes

- v0.1 (c-410): first draft. A fresh round: row 01 takes the 2 `org_app`-spelled cron
  installer log dirs (`box-update`, `cost-rollup`) r74 / r75 left out; row 02 takes
  r75's `dispatch-rotate` site, behind a split of the function's `check` branch (pinned
  first by 3 new FAIL-path cases) so the function stays under the 75-line cap. Both in
  batch 1; the dirs proven equal on this box's 3 tree kinds (9 of 9). Window W and the
  r76 slug proof recorded.
- v1.0 (c-410): the panel seat m-148 (mistral) PASS on v0.1
  `41552fddd3683281595393a3e104c0d0df7e24a2` (spool msg 459bbeee, its copy to the editor 949a8222; task
  `9b013f0a-95da-5561-a3dc-6faf1f731f14`; seat file `0683873287f8` on
  `review/c002-refactor-round-76-mistral-seat`). `do_spl_review_line_check` on its line:
  rc 0 on the seat's box as the seat reports it (its run pasted in its message; the
  holder has the full check re-run there before the GO); `REVIEW_LINE_SYNTAX=1`
  on the editor's box: `SYNTAX OK`, rc 0. Its first send carried the seat file inside the
  line and failed the syntax check (rc 1); the re-sent line keeps it on a line of its own.
  Its findings:
  - W1: 1.3's gate command named `'<rx>'` while the table cells spell the regex with
    markdown's `\|`; pasted into a shell that form matches a literal pipe and prints 0.
    Fixed: the three commands follow the table as literal lines (each re-run on
    `4168d752b` -> 3, 5, 3). The counts and the row targets do not change.
  - N1: the counts agree on `4168d752b`, its child `4c4e97f75` and a later
    `origin/master`; the sites and gates did not move.
  - N2: lane map exit 4 on all 6 row paths from the seat's box too (no owner; the
    no-file lanes' briefs name no row file).
  - N3: the seat's own branch appears on origin only after its push. Nothing to change.
  - N4: the gate's blind spots are the ones section 7 names (the 2 `bs_org_app` lines in
    `features/`), plus one user-name path pattern in an `orc:` check, not a var
    dir. The seat could not read the candidates file (it lives on the editor's box): its
    check 8 is NOT RUN there; it read 1.2's served items on `origin/master` instead.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-410 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-148 (mistral) PASS** on
  `41552fddd3683281595393a3e104c0d0df7e24a2` (spool msg 459bbeee; review-line check rc 0
  on the seat's box as the seat reports it, `SYNTAX OK` on the editor's; seat file
  `0683873287f8` on
  `review/c002-refactor-round-76-mistral-seat`), W1 fixed, N1-N4 recorded. agy was
  unavailable (no agy cli on the editor's box), so mistral took the seat.
- Row R7 seats: section 4.
