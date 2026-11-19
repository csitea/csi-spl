# Refactoring round 70 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6003  
Topic: 9f978f35-bf40-4d3d-890f-1d57bd3d00f7  
Discussion: 9f978f35-bf40-4d3d-890f-1d57bd3d00f7 (t1 #refactoring, "Refactor round 70", opener msg 50f5d0ce)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r70**, plan `refactor-round-70-plan.md`, rows `r70-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 69 ([refactor-round-69-plan.md](refactor-round-69-plan.md),
v1.0 `17f0d7b00`) is open: r69-01 landed `79c409b35` (SPL-5996); r69-02 (the `MergeTopic`
parameter object, api) is in its lane, unlanded. No signed row is handed on, so r70 is a
fresh round, and it stays off r69-02's files (2.2). The perf floor (rulebook 4.4), the
holder's read on `cb8f0f117`: `perf 29 refactor 98 perf-share 22.8% floor-met`, so the
next round is a refactor round.

The round takes the first input r69 named for round 70 (its section 7: the
agent-boot-restore dir, refactor-shaped after the panel's W1) and two dead locals in the
spawn-agents libs that the shellcheck WARNING baseline still holds.

**Status: v1.0, signed**: panel seat m-117 (mistral) PASS on v0.1 `87a07ddb5`, no defect
(W: none), notes N1-N5 asked no change (section 8); rows 01 and 02 are unchanged and may
place. Editor: **c-112** (claude).

**One sha:** every count is measured on **`cb8f0f117`** (`origin/master`
cb8f0f117e3baf8998f694d2e917532e1837a3ac, committed 2026-11-19T22:43:09+01:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`, shellcheck
0.10.0, and the tests on this lane's worktree at that sha, as the push user with
`SPOOL_TEST=1`. Queue, lane map, brief and worktree readings are live state and carry
their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-19T21:46:55+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r69-plan'` -> commit
  `17f0d7b00` "refactor round 69 plan v1.0, signed by m-079 mistral PASS on 36833e559".
  Every later read of r70 uses this W.
- **`r70` is free** (2026-11-19T22:12:49Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r70-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r70-*' 'refs/heads/wip/*r70*' 'refs/heads/*-r70-*' 'refs/heads/*refactor-round-70*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r70-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (as root) on this lane's box -> **0 files**. The other box's briefs were not read by
    this lane.
  - Control: the same log read for `r69` -> 2 lines (`79c409b35` r69-01, `17f0d7b00` the
    plan), so the read sees a used id.
- **No `refactor-round-70*` file** exists under `csi-spl-doc/doc/md` on `cb8f0f117`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-70` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The candidates, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`.

| input | source | on `cb8f0f117` | here |
|---|---|---|---|
| agent-boot-restore dir, computed `/var/<org>/<org>-<app>` default | r69 section 7 ("the first refactor candidate of round 70"), the candidates file's newest entry (c-002, 20:3xZ) | writer `orc:run/spl-agent-boot-restore-install-cron.func.sh:57`, reader `orc:run/spl-watchdog.func.sh:539`, both unchanged since r69 measured them (`git log origin/master --since="$W" -- <the 2 files>` -> 0) | **row 01** (1.3) |
| `.shellcheck-warning-baseline.txt` | the brief; the ratchet (developer guide 2.4.3) | `grep -vcE '^\s*(#\|$)'` -> **70 lines** (73 at r69, minus r69-01's 3); SC2034 25 lines, 4 of them in `sa:lib/`. Two of those are one dead local each: `sa:lib/spool-notify.inc.sh` and `sa:lib/spool-poke-queue.inc.sh` | **row 02** (1.4); the other SC2034 lines: section 7 |
| `no-literal-paths.baseline` | the brief | `git show cb8f0f117:csi-spl-orc/src/bash/tests/no-literal-paths.baseline \| grep -vcE '^\s*(#\|$)'` -> **1**, `spl-file-erase.func.sh`: a deny list r66 to r69 ruled a behaviour change | left out (section 7) |
| the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, read 22:1xZ, 48 lines) | the brief | refactor-shaped items: (a) the agent-boot-restore dir: row 01; (b) r34 N3, literal `/var` at `orc:run/spl-watchdog.func.sh:72,:1311` and `orc:run/spl-lane-rotate.func.sh:112`: served, `:72` now names `spl_claude_login_state_dir`, `:1318` calls it, and `git grep -nE '/var/' cb8f0f117 -- orc:run/spl-lane-rotate.func.sh` -> 0; (c) r63-01 W1, `orc:scripts/reverse-tunnel-cron.sh`: served, `:27` reads `$SPL_VAR_APP_DIR/reverse-tunnel`; (d) p18-02 N1, a comment's wording in `.github/workflows/10_ci-quality.yml:444-445`: a workflow edit, left out (section 7). The rest is bug-shaped (review-go, the reflection sweep, the desk hop's env, the placer's author pick, the sha256 prefix, terraform `-input=false`, the e2e flake): not refactor rows | row 01 only |
| r68 and r69 R7 findings | the brief | r69's panel notes N1-N7 asked no change (r69 section 8); r69-01's commit `79c409b35` carries its `review:` line and no N or W note (`git log -1 --format=%B 79c409b35 \| grep -ciE '^(N[0-9]\|W[0-9]\|note)'` -> 0). The seat files were not read | nothing taken |
| Go `wideFuncs` `MoveMessage` pair | r69 section 7 | 25 store call lines in 13 files; 5 of those files and `cleancode_test.go` are r69-02's, which is unlanded | left out by R3 (section 7) |
| spec 011 tasks | the brief | the spec folder unchanged since W (`git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0) | left out (section 7), r65 to r69's reasons hold |

### 1.3 Row 01: the agent-boot-restore dir

The writer and the reader build the dir from the app name; the other orc state dirs take
`$SPL_VAR_APP_DIR` (`csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh:66-71`, developer
guide 2.3.1), as `do_setup_reverse_tunnel` does since r63-01
(`orc:run/setup-reverse-tunnel.func.sh:48-50`):

| file:line | what | here |
|---|---|---|
| `orc:run/spl-agent-boot-restore-install-cron.func.sh:31` | `# @param BOOT_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/agent-boot-restore` | the help says `<SPL_VAR_APP_DIR>/agent-boot-restore` |
| `orc:run/spl-agent-boot-restore-install-cron.func.sh:57` | `logdir="${BOOT_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/agent-boot-restore}"`, the writer: the `@reboot` line's `cron.out`, the `retired` and `removed` markers | `${BOOT_CRON_LOG_DIR:-$SPL_VAR_APP_DIR/agent-boot-restore}` after `spl_run_paths`; refused (FATAL, rc 1) when neither is known |
| `orc:run/spl-watchdog.func.sh:534-540` | `spl_wd_boot_retired`: the comment and `echo "${BOOT_CRON_LOG_DIR:-/var/${oa%%-*}/$oa/agent-boot-restore}/retired"`, the reader of the marker the writer leaves | the same derived dir |

**Equal on the box** (2026-11-19T22:15Z, this lane's box, n=1):
`env -i PATH=/usr/bin:/bin bash -c 'source csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh; PROJ_PATH=<desk-cron checkout>/csi-spl-orc spl_run_paths; echo "$SPL_VAR_APP_DIR/agent-boot-restore"'`
-> `/var/csi/csi-spl/agent-boot-restore`, and the literal with `oa=csi-spl` -> the same
string. The desk-cron checkout's `.git` is a 58-byte pointer file (a worktree, so
`spl_main_checkout` resolves the main clone), and the box's installed `@reboot` line
waits on that same dir (`crontab -l` of the push user). The other box: r69's panel seat
and editor read the same equality there (r69 section 7, W1). The row re-reads it on both
boxes and records both.

What moves: the dir moves only on a layout off the canonical one (a standalone clone
under another name, a base other than `<root>/opt`), where the literal is the wrong dir
already; `BOOT_CRON_LOG_DIR` still wins. The writer and the reader move in **one commit**
(the watchdog reads the marker the cron writes).

**Before** (this lane, n=1, `SPOOL_TEST=1`, as the push user):
`sa:tests/test-agent-boot-restore.sh` rc 0 `37 passed, 0 failed`;
`orc:tests/wd-reboot.tst.sh` rc 0 `wd-reboot: all passed`;
`orc:tests/boot-cron-gate.tst.sh` rc 0. Every case there sets `BOOT_CRON_LOG_DIR`
(`grep -n BOOT_CRON_LOG_DIR` -> `wd-reboot.tst.sh:236,341`, `boot-cron-gate.tst.sh:53`,
`test-agent-boot-restore.sh:115`), so no test reads the default today: the row adds the
case.

**Tests (R2):** `git grep -lF <name> cb8f0f117` for `spl_wd_boot_retired`,
`BOOT_CRON_LOG_DIR`, `spl-agent-boot-restore-install-cron` and
`do_spl_agent_boot_restore_install_cron` over orc, iac, utl and the workflows -> the
three tests above, `orc:tests/spl-box-deploy.tst.sh` and
`csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh` (they name the action and set no
dir). The column: those five, `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` (the
install-cron function is 61 lines, `MAX_LINES` 75) and
`csi-spl-orc/src/bash/tests/no-literal-paths.tst.sh`.

### 1.4 Row 02: two dead locals in the spawn-agents libs

`shellcheck -S warning -i SC2034 -f gcc <file>` on the worktree at `cb8f0f117`:

| file:line | variable | read anywhere? | here |
|---|---|---|---|
| `sa:lib/spool-notify.inc.sh:749` | `i`, the counter of `for i in 1 2 ... 15` in `spool_notify_wait_composer` (a bounded wait), also in its `local` at `:746` | the loop body reads `$shown` and `$needle` only; its callees are `tmux capture-pane`, `grep` and `sleep` | **row 02** |
| `sa:lib/spool-poke-queue.inc.sh:487` | `text` in the `local` list of `spool_poke_show` (`:484-553`), never assigned | `awk 'NR>=484 && NR<=553' <file> \| grep -cE '\$\{?text\b'` -> **0**. Its callees (`spool_pane_of`, `spool_tmux_argv`, `spool_notify_clean`, `spool_notify_shown_body`, `spool_notice_head_in`, `spool_show_colour`, `spool_show_escape`, `spool_pane_is_tui`, `spool_show_notice_pane`, `spool_notice_line`, `spool_poke_queue_dir`, `spool_strip`) read no outer `text`: `git grep -nE '\$\{?text\b' cb8f0f117 -- sa:lib` -> 12 lines, all in `channel-move`, `go-ask-guard`, `owner-orders` and the two `spool-notify` functions that declare their own `local text` | **row 02** |

The changes, as r69-01 made them: `for _ in 1 2 ... 15` and `i` leaves the `local` list
at `:746`; `text` leaves the `local` list at `:487`. The two lines
`SC2034|sa:lib/spool-notify.inc.sh|1` and `SC2034|sa:lib/spool-poke-queue.inc.sh|1` leave
`.shellcheck-warning-baseline.txt` in the same commit: `do_sec_shellcheck`
(`csi-spl-iac/src/bash/run/sec-shellcheck.func.sh`) holds the count per (code, file)
**equal** to the baseline; the red control is that drop left out (r67-01 to r69-01).

**Before** (this lane, n=1, `SPOOL_TEST=1`, as the push user):
`sa:tests/test-spool-notify.sh` rc 0 `136 passed, 0 failed`;
`sa:tests/test-spool-poke-queue.sh` rc 0 `110 passed, 0 failed`. The rest of the column:
section 8 records them.

**Tests (R2):** `git grep -lE '\b<name>'` over orc, iac and the workflows for
`spool_notify_wait_composer` (0 files), `spool_poke_show`, `spool-notify.inc` and
`spool-poke-queue.inc` -> `sa:tests/` `test-enc-side-files`, `test-poke-ghost`,
`test-poke-retiring-pane`, `test-spool-mirror`, `test-spool-notify`,
`test-spool-notify-orch`, `test-spool-notify-topic-seat`, `test-spool-poke-queue`,
`test-strip-agy-optin`, `test-strip-resize`, `test-strip-two-envs`, `test-strip-two-way`,
and `orc:tests/` `desk-owners.tst.sh`, `enc-dirs-untouched.tst.sh`, `spl-take-auto.tst.sh`;
plus `csi-spl-iac/src/bash/tests/sec-shellcheck.tst.sh`.

## 2. The 2 rows

Paths: `orc:` = `csi-spl-orc/src/bash/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`,
`base:` = `.shellcheck-warning-baseline.txt` (repo root).

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r70-01-orc-boot-restore-dir-derived)` | canonical paths (developer guide 2.3.1): a state dir comes from `spl_run_paths`, never built from the app name | the boot restore's writer and the watchdog's reader each rebuild `/var/<org>/<org>-<app>/agent-boot-restore` from `SPL_ORG_APP`; the other orc state dirs take `$SPL_VAR_APP_DIR`, and two hand-built copies of one dir can drift apart | `orc:run/spl-agent-boot-restore-install-cron.func.sh:31,57`<br>`orc:run/spl-watchdog.func.sh:534-540`<br>a new case in `orc:tests/wd-reboot.tst.sh` | 2 files, 2 code sites + 2 comments | the change of 1.3, writer and reader in one commit, `declare -F spl_run_paths \|\| source ...` as `setup-reverse-tunnel.func.sh:48`. **Red control:** a new `wd-reboot.tst.sh` case with `BOOT_CRON_LOG_DIR` unset and `SPL_VAR_APP_DIR=$T/var`: the install-cron dry run's line names `$T/var/agent-boot-restore/cron.out` and `spl_wd_boot_retired` prints `$T/var/agent-boot-restore/retired`. On `cb8f0f117` both print the `/var/<org>/<org>-<app>` dir -> FAIL; with the change -> PASS. Both outputs in the body. **Equal on the box:** the `env -i ... spl_run_paths` read of 1.3 on both boxes, output in the body. **Behaviour:** each column test's count the same before and after (1.3). Tests: 1.3's column, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r70-02-spawn-libs-shellcheck-dead-locals)` | bash that fails safely (developer guide 2.4.3): the shellcheck WARNING ratchet only shrinks | two spawn-agents libs keep a loop counter and a local no line reads; each file's baseline line would hide a real new SC2034 there | `sa:lib/spool-notify.inc.sh:746,749`<br>`sa:lib/spool-poke-queue.inc.sh:487`<br>`base:` its 2 SC2034 lines | 2 files, 2 warnings | the changes of 1.4. **Red control:** sites fixed, baseline left -> `do_sec_shellcheck` FAILS (a count below its line) on the 2 pairs; lines dropped -> PASS. **Behaviour:** each column test's `N passed, 0 failed` the same before and after (1.4: 136, 110, and section 8's), both in the body. Tests: 1.4's column (`SPOOL_TEST=1`), `bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh` (a test red on the parent too is named, not fixed), `cd csi-spl-iac && ./run -a do_check_pre_push_lint`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its reads (row 01 the `git grep` and the
equality read of 1.3, row 02 the shellcheck and the baseline grep of 1.2 / 1.4) on the
`origin/master` it starts from, and says in its result if they moved. A fix that unmasks
another warning is reported, and the editor records it.

**Subject** (R6 reads it): `<type>(r70-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r70-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 changes the action's `@param` help line (in the action file); no
`csi-spl-doc/` page names the dir (`git grep -nE 'var/[^ ]*agent-boot-restore' cb8f0f117 -- csi-spl-doc`
-> round plans only). Row 02 is lib-internal. Each row carries `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, file sets disjoint (row 01: two orc actions and
  `wd-reboot.tst.sh`; row 02: two spawn-agents libs and `base:`). No `SPAWN_AFTER`
  between them.
- No row edits a migration, `csi-spl-cnf/`, a workflow, terraform, or a file under
  `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-112`, one call per
  path, 2026-11-19T22:17:10Z, n=1: **exit 4 on all 7 paths** (the 2 actions,
  `wd-reboot.tst.sh`, `test-agent-boot-restore.sh`, the 2 libs, `base:`): no live lane
  lists them; 11 live lanes record no files. The holder's R3 check before the spawn
  governs.
- **This box's lane worktrees** (22:17Z): `git -C <wt> diff --name-only origin/master...HEAD`
  and `git -C <wt> diff --name-only HEAD`, both restricted to the 7 paths, over every
  lane worktree -> one hit, `g-890-r5525` (`base:`, `wd-reboot.tst.sh`; dir last changed
  2026-11-14, no live window). The live agent windows on this box (c-001, c-002, c-003,
  c-046, c-946, this lane): c-046's branch (spec 143 B-6b) and c-946's (SPL-5963) change
  api and doc files only.
- **The live lanes the brief names** (22:1xZ): c-638 r69-02 (api `MergeTopic`), c-640
  SPL-5882 T2 (rdb, store upsert), c-644 b24-01 (api hub flow), c-646 b24-02
  (`sa:tests/lib.inc.sh` `t_spool_bin`, by the b24 plan's row 02 on `cb8f0f117`), c-046,
  c-946, c-625 (spec 181, doc only): none is a row path. The other box's worktrees were
  not read by this lane.
- **Commits:** `git log origin/master --since="$W" -- <the 7 paths>` -> **1**:
  `79c409b35` (r69-01, `base:` only). Landed.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-19T22:18:30Z):
  **0 queued, 0 placing**. Live share `refactor 3 18% (band 40-60%: UNDER)`; last 24 h
  `refactor 12% (band 20-30%: UNDER)`; `phase night`.
- **Briefs on this lane's box** that name a row path or symbol
  (`grep -rlE 'agent-boot-restore-install-cron|spl_wd_boot_retired|spool-notify\.inc|spool-poke-queue\.inc|spool_notify_wait_composer|spool_poke_show|wd-reboot\.tst|test-agent-boot-restore'`
  over `/var/spool-hub/dispatch/briefs` and `/var/spool-hub/spawn-remote/briefs`, as root,
  2026-11-19T22:18:42Z): the newest are the r69 and r68 panel seat briefs (a review seat
  commits nothing, 2.7.6), then older lanes with no live window.
- **Unlanded round rows:** r69-02 (api), b24-01 (api) and b24-02 (`sa:tests/lib.inc.sh`):
  none of the rows' files.

## 3. Per row: what the lane does

- **r70-01:** the boot restore's install-cron action and the watchdog's marker read take
  the dir from `spl_run_paths` (`$SPL_VAR_APP_DIR/agent-boot-restore`), in one commit,
  with a test that reads the default.
- **r70-02:** two spawn-agents libs drop a loop counter and a local no line reads; their
  2 SC2034 baseline lines go.

## 4. Panel and reviewers (R7)

- Editor: c-112 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r70`):
  one **agy** doc seat, the main vendor for spec and plan reviews, with mistral as its
  backup, as r62 to r69 had (the brief: no agy CLI on one box, agy quota out on the other
  until ~11-24, so mistral is the likely seat). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2), the holder's call when the row
  is queued (a fresh claude seat under the claude waiver, as r63 to r69). Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r70-01 | `c002-r70-01-orc-boot-restore-dir-derived` | `refactor(r70-01-orc-boot-restore-dir-derived, SPL-<row issue>): ...` | `review/r70-01` | 1 |
| r70-02 | `c002-r70-02-spawn-libs-shellcheck-dead-locals` | `refactor(r70-02-spawn-libs-shellcheck-dead-locals, SPL-<row issue>): ...` | `review/r70-02` | 1 |

**r70-01 brief, Files: ONLY** `orc:run/spl-agent-boot-restore-install-cron.func.sh`,
`orc:run/spl-watchdog.func.sh` (`spl_wd_boot_retired` and its comment only),
`orc:tests/wd-reboot.tst.sh` (one new case). Do: plan section 2 row 01 verbatim; writer
and reader in ONE commit; the red control's two outputs (FAIL on the parent, PASS on the
change) and the `env -i ... spl_run_paths` equality read on both boxes in the body; each
column test's count before and after (plan 1.3). Run the tests with `SPOOL_TEST=1`.
Gates: 1.3's column, `cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`.
Kind `simple_coding`, vendor claude.

**r70-02 brief, Files: ONLY** `sa:lib/spool-notify.inc.sh` (`spool_notify_wait_composer`),
`sa:lib/spool-poke-queue.inc.sh` (`spool_poke_show`'s `local` line),
`.shellcheck-warning-baseline.txt` (its 2 SC2034 lines). Do: plan section 2 row 02
verbatim; red control the sites fixed with the baseline lines left (`do_sec_shellcheck`
FAIL on the 2 pairs) then dropped (PASS), both outputs in the body; each column test's
`N passed, 0 failed` before and after in the body (plan 1.4). Run the tests with
`SPOOL_TEST=1`. Gates: 1.4's column,
`bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh`,
`bash csi-spl-iac/src/bash/tests/sec-shellcheck.tst.sh`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash action code 1, Bash lib code 1) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: rows 01 and 02 |
| hand-built `agent-boot-restore` dir defaults | 2 today -> 0 after r70-01 |
| `.shellcheck-warning-baseline.txt` lines | 70 today -> 68 after r70-02 |
| SC2034 baseline lines in `sa:lib/` | 4 -> 2 (`spool-env.inc.sh`, `spool-mirror-hooks.inc.sh`: section 7) |
| SC2034 warnings removed | 2 |
| measured on | `cb8f0f117`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| Go `wideFuncs`: the `MoveMessage` pair (interface `api:internal/store/message_move.go:74`, Memory `:136`, Postgres `message_move_postgres.go:97`) | same shape as r69-02; shares 5 test files and `cleancode_test.go` with r69-02, which is unlanded (c-638): R3. The first row of round 71 once r69-02 lands | r69 section 7 |
| `sa:lib/spool-env.inc.sh:845` `SPOOL_PANE_TTY`, `SPOOL_PANE_CMD`; `sa:lib/spool-mirror-hooks.inc.sh:162,170` `SMH_ARGS`, `SMH_WHERE` | upper-case globals set for a caller or a sourcing script to read (the baseline's "read by a sourcing caller" case): each needs the per-variable read check across every sourcer; input for a later round | `shellcheck -S warning -i SC2034` on `cb8f0f117` |
| `sa:scripts/` `CHAIN_KIND` (4 chain / task scripts), `AGENT_TOP_TAG`, `trust-workdir.sh:368`, the spawn and restore families; `orc:run/spl-spec-import-issues.func.sh:300-304` | vars a sourced lib, a called function or a launcher may read; each needs the per-variable read check (r68 section 7) | same |
| `sa:tests/lib.inc.sh:10` `T_SCRIPTS`; iac SC2034 in tests (4 lines) | read by a sourcing test (r69 section 7); r67 section 7's reasons | r69, r67 |
| SC2154, SC2120, SC1090, SC2088, SC2046, SC2319, SC2164, SC2155 | the baseline's header names these kinds deliberate | the baseline's header |
| `.github/workflows/10_ci-quality.yml:444-445` comment wording (p18-02 N1) | a workflow edit for one clause of a comment; fits a CI or perf row that touches the file anyway | the candidates file |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | 63 positional caller lines in 35 files (r67's read), a WUI row with its e2e gate | r68 1.2 |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66 to r69) | 1.2 |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour (T028's assertions), terraform layout (T026) or docs (T031); the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-112): first draft. A fresh round: 2 rows found on `cb8f0f117`, the
  agent-boot-restore dir r69 named for round 70, and the two dead locals of the
  spawn-agents libs in the SC2034 baseline. Window W and the r70 slug proof recorded.
  Row 02's column before counts (this lane, n=1, `SPOOL_TEST=1`, as the push user):
  `test-enc-side-files` 18, `test-strip-agy-optin` 15, `test-strip-two-envs` 21,
  `test-strip-two-way` 32, `test-strip-resize` 8, `test-poke-retiring-pane` 7,
  `test-spool-mirror` 110, `test-spool-notify-orch` 35, `test-spool-notify-topic-seat` 25
  (`N passed, 0 failed`, rc 0 each); `test-poke-ghost` rc 0 `0 failed`;
  `desk-owners.tst.sh` rc 0, `enc-dirs-untouched.tst.sh` rc 0 `17 passed`,
  `spl-take-auto.tst.sh` rc 0 `ALL PASS`.
- v1.0 (c-112): the panel seat m-117 (mistral) passed v0.1 `87a07ddb5`, W: none. N1
  (origin/master `418c40de8` at its read, one commit past `cb8f0f117`, calendar files only;
  all 12 cited site lines identical on both), N2 (lane map exit 4 on all 7 row paths, 11
  lanes on the other box record no files; the holder's R3 check before the spawn governs),
  N3 (red controls read in the gate and site code, not run), N4 (the briefs grep counts the
  seat brief only; the planner's brief carries no `r70-NN` literal), N5 (it signed v0.1, no
  v1.0 named yet): no change. Rows 01 and 02 unchanged; rebased onto `40e6fae15`, no row
  file changed since `cb8f0f117` (`git diff --stat cb8f0f117 40e6fae15 -- <the 7 paths>` -> empty).

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-112 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-117 (mistral) PASS** on `87a07ddb595cab628e62414588f427f82003f823`
  (spool msg 6f4cc061, task `dispatch-refactor-r70`); seat file on branch
  `review/c002-refactor-round-70-mistral-seat` (`1dbe177df`). W: none; N1-N5. agy was
  absent or out of quota (the holder's read), so mistral took the seat.
- Row R7 seats: section 4.
