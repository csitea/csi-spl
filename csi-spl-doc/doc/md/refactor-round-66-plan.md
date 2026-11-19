# Refactoring round 66 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5961  
Topic: aa7d4c84-8dc1-47ea-b286-db4e2f0e992a  
Discussion: aa7d4c84-8dc1-47ea-b286-db4e2f0e992a (t1 #refactoring, "Refactor round 66", opener msg 610a0df3)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r66**, plan `refactor-round-66-plan.md`, rows `r66-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 65 ([refactor-round-65-plan.md](refactor-round-65-plan.md))
is served: r65-01 landed `80c903ddc` (SPL-5955), r65-02 landed `e178584df` (SPL-5958),
and r64-02 (`b2ac50a07`, SPL-5948) is on master too. So r66 carries no signed row: a
fresh round. The perf floor (rulebook 4.4) read `perf 29 refactor 96 perf-share 23.2%
floor-met` on `e178584df` (the holder's read), so the next round is a refactor round.

Both rows serve the practice of r62 to r65, **no literal box path** (developer guide
2.3.1), and finish what round 35 deferred: the two baseline files that need the org var
dir `<var>/<org>` could not derive it, because `spl_run_paths` exports
`SPL_VAR_APP_DIR` = `<var>/<org>/<app>` only. Round 35 (section 6) named the export
"its own row, first". Row 01 is that export; row 02 moves its two users onto it.

**Status: v1.0, signed**: panel seat m-391 (mistral) PASS on v0.1 `3bfe87d48` and on
v1.0 `3d48fd2c4`, no W, notes only (sections 8 and 9). Rows unchanged from v0.1. Editor: **c-379** (claude).

**One sha:** every count is measured on **`e178584df`** (`origin/master`
e178584dfc5cdeeb8697ef3292242f06058a384b, committed 2026-11-19T13:44:33+02:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`. Queue, lane
map and vendor readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-19T10:50:02+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r65-plan'` -> commit
  `8c6ea8825` "refactor round 65 plan records the v1.0 signature, m-302 mistral PASS on
  85dbbf088". Every later read of r66 uses this W.
- **`r66` is free** (2026-11-19T12:23:52Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r66-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r66-*' 'refs/heads/wip/*r66*' 'refs/heads/*-r66-*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r66-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (run as root) on this lane's box -> **0 files**. The other box's briefs were not
    read by this lane (the holder read them all 0 at 12:2xZ).
  - Control: the same log read for `r65` -> 5 lines (`9cbbbad23`, `1d5457bd7`,
    `8c6ea8825` the plan, `80c903ddc` r65-01, `e178584df` r65-02), so the read sees a
    used id.
- **No `refactor-round-66*` file** exists under `csi-spl-doc/doc/md` on `e178584df`, so
  the plan takes the plain name (5.3 "Files").

### 1.2 The candidates, re-measured

The literal grep: `git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' e178584df -- <path>`.

The dispatcher's candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`)
is on the other box; this lane could not read it (`ls` -> No such file on this box). Its
items that r65 listed (section 1.2 there) are re-measured from the tree below; the
holder checks the file for a refactor-shaped item added since.

| input | source | on `e178584df` | here |
|---|---|---|---|
| the org var dir: `spl_run_paths` exports `SPL_ORG_DIR` (`<base>/<org>`) and `SPL_VAR_APP_DIR` (`<var>/<org>/<app>`), no `<var>/<org>` | round 35 section 6 ("a new export in a lib every action sources is its own row, first"), carried by r64 and r65 section 7 | `orclib:spl-run-paths.func.sh:64-73`; `git grep -n SPL_VAR_ORG_DIR e178584df` -> **0** (the name is free) | **row 01** |
| `orc:run/spl-cmd-guard-mode.func.sh:20,36,37`: `SPL_RUST_HOME` defaults to `/var/csi/rust` (`/mnt/data/var/csi/rust` when `/mnt/data` is mounted) | `no-literal-paths.baseline` (`3 ...spl-cmd-guard-mode.func.sh`) | **3 lines**; newest change `071685209` (SPL-5487, 2026-11-14), none since W | **row 02** |
| `utl:run/fleet-logrotate-install.func.sh:7,24,70`: `FLEET_LOGROTATE_VAR_DIR` defaults to `/var/csi` | `no-literal-paths.baseline` (`3 ...fleet-logrotate-install.func.sh`) | **3 lines**; newest change `8ca138a3b` (SPL-2233, 2026-10-16), none since W | **row 02** |
| `orc:run/spl-file-erase.func.sh:31,120`: `/var/csi`, `/opt` in the protected-root list | the baseline (`2 ...`) | 2 lines | left out (section 7) |
| r65-02 R7 N1/N2 (the empty-VAR refusal) | the brief | the review notes are on the other box, not read here; the brief rules the refusal a later round's. A refusal where today an empty var passes changes behaviour: not a refactor row | left out (section 7) |
| graft's md docs, `guides/installation-and-configuration-guide.md:594`, SPL-5824 W1/N1/N2, p18-02 R7 N1, spec 011 tasks | r65 section 7 | unchanged since r65 (`git log origin/master --since="$W" -- <file>` -> 0 for the guide, graft's `README.md`, `10_ci-quality.yml` and the spec 011 folder) | left out (section 7), r65's reasons hold |

**The baseline:** `git show e178584df:csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -vE '^\s*(#|$)'`
-> **3 files, 8 lines**: `3 spl-cmd-guard-mode`, `2 spl-file-erase`,
`3 fleet-logrotate-install`. The non-test `*.sh` scan
(`git grep -lE <literal> e178584df -- '*.sh' ':!**/tests/**'`) -> exactly these 3 files.
The gate fails a stale entry (`no-literal-paths.tst.sh`: "STALE baseline: ... drop its
line"), so row 02 drops its two lines in the same commit.

**Row 01's site** (`orclib:spl-run-paths.func.sh`):
- `:62-73` `spl_run_paths`: `main`, `org="${main%/*}"`, `base="${org%/*}"`; `:69`
  `: "${SPL_VAR_APP_DIR:=${base%/*}/var/${org##*/}/${main##*/}}"`; `:72` exports the 4
  vars. The org var dir is the same expression without `/${main##*/}`.
- `:13-16` the header lists each exported var with its form.

On this box (2026-11-19T12:27Z, `env -u APP_PATH -u PROJ_PATH -u SPL_VAR_APP_DIR` and
`spl_run_paths` from the main checkout): `SPL_VAR_APP_DIR=/var/csi/csi-spl`,
`SPL_ORG_DIR=/opt/csi`, so the new var reads `/var/csi`, the value both row 02 literals
hold.

**Row 02's sites** (the literal grep on the 2 files, 6 lines):
- `orc:run/spl-cmd-guard-mode.func.sh:20`
  `# @param SPL_RUST_HOME /mnt/data/var/csi/rust when /mnt/data is mounted, else /var/csi/rust`
- `orc:run/spl-cmd-guard-mode.func.sh:36` `rh=/var/csi/rust`
- `orc:run/spl-cmd-guard-mode.func.sh:37` `mountpoint -q /mnt/data 2>/dev/null && rh=/mnt/data/var/csi/rust`
- `utl:run/fleet-logrotate-install.func.sh:7` (`@description`) `... under /var/csi/csi-spl once they`
- `utl:run/fleet-logrotate-install.func.sh:24` `# @param FLEET_LOGROTATE_VAR_DIR (optional) - default /var/csi`
- `utl:run/fleet-logrotate-install.func.sh:70` `FL_VAR="${FLEET_LOGROTATE_VAR_DIR:-/var/csi}"`

`/mnt/data` is an OS mount point, not a box path: it stays, and `:37` becomes
`/mnt/data$SPL_VAR_ORG_DIR/rust`. On this box `/mnt/data` is not mounted
(`mountpoint -q /mnt/data` -> rc 1) and `/var/csi/rust` exists, 12:27Z.
`FL_VAR` feeds `:89` (`$FL_VAR/csi-spl/desk-reconcile/...`, `$FL_VAR/csi-spl/box-disk-sweep/...`)
and `:96` (`$FL_VAR/csi-spl-desk-cron/...`); those lines carry no literal and do not
change. utl already reaches the orc lib: `utl:run/orphan-process-reap.func.sh:58`
sources it as `declare -F spl_run_paths >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh"`.

**The derived form**, as r62-01 to r65-02 landed it: an env override, else the
derived dir after `spl_run_paths`.

### 1.3 The tests (R2, C4)

`NAMES` = the row's basenames:
`pat=$(for n in $NAMES; do printf '%s' "|\b$n(\.sh|\.tst\.sh|\.func\.sh)?([^a-z0-9_-]|\$)"; done); git grep -lE "${pat#|}" e178584df -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' 'csi-spl-utl/**/tests/*' 'csi-spl-api/**/tests/*'`

- r66-01 (`spl-run-paths`) -> **4** files: `spl-run-paths.tst.sh`,
  `no-literal-paths.tst.sh`, `spl-file-stream-follow.tst.sh`, `wd-login-snapshot.tst.sh`.
  Function names (`git grep -lE 'spl_run_paths|spl_main_checkout' e178584df -- '*tests/*'`)
  add `install-box-crons.tst.sh` (5 in all). The lib loads lazily from the orc `./run`
  index (`f86a52d7b`, SPL-5527), so `run-eager-files.tst.sh` too.
- r66-02 (`spl-cmd-guard-mode fleet-logrotate-install`) -> `spl-cmd-guard-mode.tst.sh`,
  `fleet-logrotate.tst.sh` (utl), `no-literal-paths.baseline`. Today both tests set the
  override (`spl-cmd-guard-mode.tst.sh:106` `SPL_RUST_HOME="$T/rh"`,
  `fleet-logrotate.tst.sh:50` `FLEET_LOGROTATE_VAR_DIR="$VAR"`), so no case reads the
  default.
- R2 bullet 2, a 30-character string of each changed line, in any `csi-spl-*` tests dir
  (`git grep -lF '<string>' e178584df -- 'csi-spl-*/**/tests/*'`) for
  `mountpoint -q /mnt/data 2>/dev/null && rh=`, `FLEET_LOGROTATE_VAR_DIR:-/var/csi`,
  `default /var/csi`, `/var/csi/rust`, `SPL_DESK_DIR:=${main}-desk-cron`,
  `export SPL_ORG_DIR SPL_VAR_APP_DIR` -> **0 files** each.
- Both rows: `no-literal-paths.tst.sh` and `spl-run-paths.tst.sh`.

## 2. The 2 rows

Paths: `orc:` = `csi-spl-orc/src/bash/`, `orclib:` = `csi-spl-orc/lib/bash/funcs/`,
`utl:` = `csi-spl-utl/src/bash/`.

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r66-01-orc-run-paths-var-org-dir)` | no literal box path (developer guide 2.3.1); one home for a derived path | two actions need `<var>/<org>` and hold it as the literal `/var/csi` because the one helper that derives box paths stops at `<var>/<org>/<app>` (round 35 section 6) | `orclib:spl-run-paths.func.sh:13-16,62,69,72`<br>`orc:tests/spl-run-paths.tst.sh` (case 1) | 1 file, 1 new var | `spl_run_paths` also sets `: "${SPL_VAR_ORG_DIR:=${base%/*}/var/${org##*/}}"` and exports it; an env value wins, as for the other 4. The header and the `:62` comment list it (`<var>/<org>`, org state). No caller changes: every existing var keeps its value. `spl-run-paths.tst.sh` case 1: `paths()` unsets `SPL_VAR_ORG_DIR` too and the fixture main checkout and its worktree both derive `$B/var/acme`; an env `SPL_VAR_ORG_DIR` wins. **Red control:** the new assertion on the unchanged lib fails (empty var), then passes. Tests: `spl-run-paths.tst.sh`, `no-literal-paths.tst.sh`, `spl-file-stream-follow.tst.sh`, `wd-login-snapshot.tst.sh`, `install-box-crons.tst.sh`, `run-eager-files.tst.sh`. | either | claude | simple_coding | 1 |
| 02 `refactor(r66-02-orc-utl-var-org-dir-users)` | no literal box path (developer guide 2.3.1) | the rust toolchain home and the logrotate var root are the last two baseline files that only needed `<var>/<org>`; after row 01 they derive it, and the baseline keeps only `spl-file-erase` | `orc:run/spl-cmd-guard-mode.func.sh:20,36,37`<br>`utl:run/fleet-logrotate-install.func.sh:7,24,70`<br>`orc:tests/spl-cmd-guard-mode.tst.sh` (a case)<br>`utl:tests/fleet-logrotate.tst.sh` (a case)<br>`orc:tests/no-literal-paths.baseline` (drop its 2 lines) | 2 files, 6 lines | `_scg_build`: `rh="$SPL_VAR_ORG_DIR/rust"`, `/mnt/data$SPL_VAR_ORG_DIR/rust` when mounted, after `spl_run_paths`; `_fleet_logrotate_resolve`: `FL_VAR="${FLEET_LOGROTATE_VAR_DIR:-$SPL_VAR_ORG_DIR}"` after `spl_run_paths` (sourced as `orphan-process-reap.func.sh:58` does). The 3 comments say "`<SPL_VAR_ORG_DIR>`". No dir derived and no override: `_scg_build` logs FATAL and returns 1 (its form for a missing cargo, `:39`); `_fleet_logrotate_resolve` logs ERROR and returns 1 (its form for an unknown user, `:66`). New case in each test: the override unset, `SPL_VAR_ORG_DIR=$T/v` -> the stub cargo gets `$T/v/rust/...` (`SCG_TEST_ARGS`/env), the rendered logrotate file names `$T/v/csi-spl/desk-reconcile/cron-prd.out`; `SPL_RUN_PATHS_TOP=` with `APP_PATH`, `PROJ_PATH`, `SPL_VAR_ORG_DIR` unset -> rc 1. Tests: `spl-cmd-guard-mode.tst.sh`, `fleet-logrotate.tst.sh`, `no-literal-paths.tst.sh`, `spl-run-paths.tst.sh`, `run-eager-files.tst.sh`. **Control:** below. | either | claude | simple_coding | 2 (after 01) |

**Control for row 02** (as r65): on the box the derived path equals the old literal:
the lane prints both from the main checkout with `APP_PATH` unset (the rust home with
`/mnt/data` unmounted, and the `FL_VAR` the action resolves), and with the env
override set (the override wins). `SPL_RUN_PATHS_TOP=` (no tree) gives the rc 1
answer. `./run -a do_fleet_logrotate_install` (`DRY_RUN` defaults to 1) on the box
prints the same two rendered files before and after (`diff` empty), and
`SPL_CMD_GUARD_IMPL=py ./run -a do_spl_cmd_guard_mode` (dry run) prints the same plan
before and after. The lane never runs `DRY_RUN=0` of either. Both outputs in the body.
`git diff` touches only the sites above and their new derive lines.

**Re-measure first:** each row lane re-runs the literal grep and the test command of
1.2 and 1.3 on the `origin/master` it starts from and says in its result if they moved.

**Subject** (R6 reads it): `<type>(r66-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r66-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 adds a var the developer guide 2.3.1 lists by name. The guide is a Qto
export, and a change to its blob asks every coder to confirm it again (guide section
7), so the row carries `Docs: none (<why>)` with the lib header as the home of the var,
and names the guide line in its result for the next batched guide edit. Row 02 changes
no documented behaviour on the box.

### 2.1 Batches (R1, R16)

- **Batch 1: row 01.** Nothing it touches is held by a live or queued lane (2.2).
- **Batch 2: row 02, after row 01 lands**: it reads the var row 01 adds. Queued as
  `SPAWN_AFTER=c003-r66-01-orc-run-paths-var-org-dir`, within 30 minutes (R16).
- The two rows share no file (row 01: `spl-run-paths.func.sh`, `spl-run-paths.tst.sh`;
  row 02: the other 5 paths), so R1 holds even within a batch; the order is the data
  dependency only.
- Neither row edits a migration, `csi-spl-cnf/`, a workflow, terraform or a file under
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

The 7 written paths: `orclib:spl-run-paths.func.sh`, `orc:tests/spl-run-paths.tst.sh`,
`orc:run/spl-cmd-guard-mode.func.sh`, `orc:tests/spl-cmd-guard-mode.tst.sh`,
`utl:run/fleet-logrotate-install.func.sh`, `utl:tests/fleet-logrotate.tst.sh`,
`orc:tests/no-literal-paths.baseline`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-379`, one call per
  path, 2026-11-19T12:25:49Z -> **exit 4** for each: no live lane lists any of them, but
  5 live lanes record no files: c-852 (SPL-5883 T1: rdb/api/wui), c-912 and
  m-923 (bug round 21 planner and panel), c-922 (WUI e2e CI red), c-926
  (WUI blog share). Their scopes, from the planner brief and the bug round 21 plan
  (below): none writes a row path. n=1. The holder's R3 check before each row's spawn
  governs.
- **Commits:** `git log origin/master --since="$W" -- <the 7 paths>` -> 3 commits, all
  on `no-literal-paths.baseline` and all landed: `b2ac50a07` (r64-02), `80c903ddc`
  (r65-01), `e178584df` (r65-02). None on the other 6 paths.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-19T12:26:27Z):
  **0 queued, 0 placing**. Live share `refactor 3 15% (band 10-20%: ok)`; last 24 h
  `refactor 11% (band 20-30%: UNDER)`; `phase day`.
- **Bug round 21** (live, unsigned): its plan on `review/c002-bug-round-21-planner`
  (`67232dbc8`, `git ls-remote` 12:2xZ) writes, row 01, `orc:run/spl-review-go.func.sh`,
  `orc:tests/spl-review-go.tst.sh`, `csi-spl-doc/specs/157-dispatch-automation/spec.md`;
  row 02, `csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push`,
  `orc:tests/lane-wip-push.tst.sh`, `csi-spl-doc/doc/md/pre-push-gate.md` (its section
  3.1). Disjoint from the 7 paths.
- **Briefs on this lane's box** that name a row basename, `spl_run_paths` or
  `no-literal-paths` (`grep -rlE` over `/var/spool-hub/dispatch/briefs` and
  `/var/spool-hub/spawn-remote/briefs`, run as root, 2026-11-19T12:26:18Z): 4 newer than
  W besides this planner's own: `ad3c0f47` (r65-01 author), `91b90f51` (r65-01 R7),
  `f55b4bef` (r64-02 R7), `7655b655` (r65 panel). All on landed rows; none names a row
  2 file or `spl-run-paths.func.sh` as a file to edit.
- **Unlanded round rows:** none on these paths.
  `git grep -lE 'spl-run-paths\.func|spl-cmd-guard-mode|fleet-logrotate-install' e178584df -- 'csi-spl-doc/doc/md/*-round-*-plan.md'`
  -> 6 plans: `refactor-round-34`, `-35`, `-62`, `-63`, `-64`, `-65`, each a left-out
  or a sourcing mention; every row of r62 to r65 is landed.

## 3. Per row: what the lane does

- **r66-01:** `spl_run_paths` also exports `SPL_VAR_ORG_DIR` (`<var>/<org>`), derived as
  the other 4 and overridable; no caller changes.
- **r66-02:** after r66-01: the rust toolchain home and the logrotate var root derive
  from `SPL_VAR_ORG_DIR`; their 2 baseline lines go, and only `spl-file-erase` (a
  protected-root deny list) is left in the baseline.

## 4. Panel and reviewers (R7)

- Editor: c-379 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Vendor state** (2026-11-19T12:27:20Z, n=1 each, `BOX_PICK_KIND=<k> ./run -a do_spl_box_pick`,
  read on this lane's box): agy, mistral and claude `pick=` this box (69% < 70%); grok
  `pick=hold` (weekly 99% on both boxes). The pick does not read agy's quota; the
  holder knows whether agy is out (r65: no agy CLI on the other box, this box's agy at
  its quota until 2026-11-24).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r66`):
  one **agy** doc seat, the main vendor for spec and plan reviews; mistral as its
  backup, as r62 to r65 had. The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2): agy if its pick still holds
  when the row is queued, else the holder's call (a fresh claude seat under the claude
  waiver, as r63 to r65). Not a mistral code R7. The holder re-reads the agy and grok
  picks before each row's reviewer is queued.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one
(rulebook 4.3), the sites and line numbers of 1.2, its R7 reviewer seat, and
"re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r66-01 | `c003-r66-01-orc-run-paths-var-org-dir` | `refactor(r66-01-orc-run-paths-var-org-dir, SPL-<row issue>): ...` | `review/r66-01` | 1 |
| r66-02 | `c003-r66-02-orc-utl-var-org-dir-users` | `refactor(r66-02-orc-utl-var-org-dir-users, SPL-<row issue>): ...` | `review/r66-02` | 2, `SPAWN_AFTER=c003-r66-01-orc-run-paths-var-org-dir` |

**r66-01 brief, Files: ONLY** `orclib:spl-run-paths.func.sh`,
`orc:tests/spl-run-paths.tst.sh`. Do: plan section 2 row 01 verbatim; red control the
new case-1 assertion on the unchanged lib (RED) then on the change (GREEN), both
outputs in the body; on the box, `spl_run_paths` from the main checkout with
`APP_PATH` unset prints `SPL_VAR_ORG_DIR` = the parent of `SPL_VAR_APP_DIR`, and the
other 4 vars unchanged before and after. Gates: `spl-run-paths`, `no-literal-paths`,
`spl-file-stream-follow`, `wd-login-snapshot`, `install-box-crons`, `run-eager-files`;
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)` as section 2 says.
Kind `simple_coding`, vendor claude.

**r66-02 brief, Files: ONLY** `orc:run/spl-cmd-guard-mode.func.sh`,
`orc:tests/spl-cmd-guard-mode.tst.sh`, `utl:run/fleet-logrotate-install.func.sh`,
`utl:tests/fleet-logrotate.tst.sh`, `orc:tests/no-literal-paths.baseline` (its 2
lines). Do: plan section 2 row 02 verbatim; control as section 2 (derived = old literal
on the box, the override wins, `SPL_RUN_PATHS_TOP=` -> rc 1, both dry runs the same
before and after; never `DRY_RUN=0`). Gates: `spl-cmd-guard-mode`, `no-literal-paths`,
`spl-run-paths`, `run-eager-files` (orc), `fleet-logrotate` (utl,
`bash csi-spl-utl/src/bash/tests/fleet-logrotate.tst.sh`);
`cd csi-spl-iac && ./run -a do_check_pre_push`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash 2) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: row 01; batch 2: row 02 (after 01) |
| `no-literal-paths` baseline | 3 files / 8 lines today -> 3 / 8 after r66-01 -> 1 / 2 after r66-02 |
| literal box paths in non-test `*.sh` (`':!**/tests/**'`) | 3 files / 8 lines -> 1 file / 2 lines after r66-02 |
| measured on | `e178584df`, n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `spl-file-erase` (2 lines, `:31,120`) | a protected-root deny list (`/var/csi`, `/opt`): a failed derivation would shrink it. After row 01 it can read `SPL_VAR_ORG_DIR`, but it needs a refusal on no tree (round 35 section 6): that refusal changes behaviour, so it is a bug or later round's row, with its own red control | 1.2 |
| r65-02 R7 N1/N2, the empty-VAR refusal | a new refusal where an empty var passes today changes behaviour; the brief rules it a later round's. The notes are on the other box and were not read here | the brief |
| graft's md docs, `guides/installation-and-configuration-guide.md:594` | r65 section 7, unchanged: docs follow-ups and a Qto export | 1.2 |
| SPL-5824 W1, N1, N2 (desk hop drops env) | changes what a caller's override does: a bug round's | r65 section 7 |
| p18-02 R7 N1 (`10_ci-quality.yml:444-445` wording) | a workflow comment from a perf row; a workflow edit runs every CI job | r65 section 7 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred (2026-09-19) or an open owner decision, or larger than one push (r65 section 7; the spec folder unchanged since W) | 1.2 |
| the candidates file's bug-shaped items | bugs, not refactor rows (the planner brief) | the brief |
| a `${SPL_VAR_ORG_DIR}` cnf token in `spl_cnf_path_expand` | no cnf value needs it today (`spl-run-paths.tst.sh` case 4 holds every path value to the two tokens); add it with its first user | 1.2 |

## 8. Changes

- v0.1 (c-379): first draft. A fresh round: 2 rows found on `e178584df`. Row 01 the org
  var dir export round 35 deferred; row 02 its two users, the last baseline files that
  only needed it. Window W and the r66 slug proof recorded.
- v1.0 (c-379): the panel seat m-391 (mistral) passed v0.1 `3bfe87d48`, W: none. N1
  (origin/master `67232dbc8`, the b21 plan, one past `e178584df`: every cited row
  file:line byte-identical), N2 (lane map exit 4 with 3 unknown lanes at its read, 5 at
  this plan's; the holder's R3 before each spawn governs), N3 (the other box's
  candidates file, read by the holder: `spl-watchdog.func.sh:72`,
  `spl-lane-rotate.func.sh:112` and `reverse-tunnel-cron.sh:23` carry no literal on
  origin/master, and the non-test `*.sh` scan is still 3 files / 8 lines, so section 7
  misses no refactor item; `watchdog-setup.md` names the box layout as docs only), N4
  (the r66 briefs grep: 1 file, the seat's own brief, on both boxes) and N5 (W
  re-verified, `8c6ea8825`): no change. Status line and sections 8 and 9 only.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-379 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-391 (mistral) PASS** on `3bfe87d48ce7f256ba9c036674b7ef3586b791c2`
  (spool msg 500404e5, task `dispatch-refactor-r66`); seat file on branch
  `review/c002-refactor-round-66-mistral-seat` (`de0023e4a`). W: none; N1-N5 notes.
- v1.0 signed: **m-391 (mistral) PASS** on `3d48fd2c4727b7049ba3debb7e41395c86e28803`
  (spool msg 8e6d7312), seat file `1c7bae9ca`. W: none; N1 (origin/master `ea431c511`:
  slug free, the 7 row paths unchanged since `e178584df`, baseline 3 files / 8 lines),
  N2 (lane map exit 4, 2 unknown lanes), N3-N5 (the fold and the sha checked): no change.
- Row R7 seats: section 4.
