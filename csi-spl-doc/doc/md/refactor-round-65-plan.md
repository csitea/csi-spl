# Refactoring round 65 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5949  
Topic: 4e78ebcb-64f1-4e4b-81ee-e97a6c4e246a  
Discussion: 4e78ebcb-64f1-4e4b-81ee-e97a6c4e246a (t1 #refactoring, "Refactor round 65", opener msg 8835e31a)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r65**, plan `refactor-round-65-plan.md`, rows `r65-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 64 ([refactor-round-64-plan.md](refactor-round-64-plan.md))
has r64-01 landed (`87d56eaae`) and r64-02 live (the `no-literal-paths` gate widened to
non-test `*.sh`; graft's 2 scripts enter its baseline). So r65 carries no signed row: a
fresh round. Both rows serve the same practice as r62 to r64, **no literal box path**
(developer guide 2.3.1): the two places whose default state path is still a literal
while the code that writes that state derives it, or every other state dir does.

**Status: v0.1**, draft for the panel. Editor: **c-293** (claude).

**One sha:** every count is measured on **`93a625324`** (`origin/master`
93a625324be56d6d5dced9cb4acbb1aa7eb16daf, committed 2026-11-19T10:08:17+01:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`. Queue, lane
map and vendor readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-19T09:04:00+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r64-plan'` -> commit
  `86572482f` "refactor round 64 plan records the v1.0 signature, m-828 mistral PASS on
  b9d80db5a". Every later read of r65 uses this W.
- **`r65` is free** (2026-11-19T09:11:39Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r65-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r65-*' 'refs/heads/wip/*r65*' 'refs/heads/*-r65-*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r65-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (run as root) on this lane's box, 2026-11-19T09:13:54Z -> only this planner's own
    brief, which names the row form `r65-<NN>`. The other box's briefs were not read by
    this lane (the holder read them all 0 at 08:15Z).
  - Control: the same log read for `r64` -> 4 lines (`cd840afe0`, `103da374f`,
    `86572482f` the plan, `87d56eaae` r64-01), so the read sees a used id.
- **No `refactor-round-65*` file** exists under `csi-spl-doc/doc/md` on `93a625324`, so
  the plan takes the plain name (5.3 "Files").

### 1.2 The candidates, re-measured

The literal grep: `git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' 93a625324 -- <path>`.

The dispatcher's candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`)
is on the other box; this lane could not read it (`cat` -> No such file on this box).
Its items, as the brief names them, are re-measured here from the tree.

| input | source | on `93a625324` | here |
|---|---|---|---|
| `spl-reflection-gather.func.sh:59,203`: `REFLECTION_ZOMBIE_LOG` defaults to `/var/csi/csi-spl/zombie-topics/cron.log`, while the cron that writes the log derives its root | the baseline; left out by r35 and r64 while SPL-5825's follow-ups were open on the file | **2 lines**. Newest change on the file: `ce765392c` (b14-01, SPL-5856, 2026-11-18T06:01+02:00); `git log origin/master --since=2026-11-18T00:00Z -- <file>` -> that one commit, none since W | **row 01** |
| graft's var root: `graft-index-dir.sh:24` `graft_var_root` default `/var/csi/csi-spl/graft`, its comment `:20`, `graft-cron.sh:11` (comment) | r64 plan section 7, "the first candidate for r65" | **2 files, 3 lines**; the non-test `*.sh` scan (`git grep -cE <literal> 93a625324 -- '*.sh' ':!*.func.sh' ':!**/tests/**'`) -> exactly these 2 files | **row 02** |
| `installation-and-configuration-guide.md:594` literal state dir (now under `csi-spl-doc/doc/md/guides/`) | candidates file, r63-01 R7 N3 | 1 line; the guide is the export of Qto doc `8e8454fe-...` (line 1: "edit it there") and names the box layout on purpose (`/opt/csi/csi-spl` on many lines, e.g. `:44`, `:155`) | left out (section 7) |
| SPL-5824 W1, N1, N2: `spl_desk_live_hop` drops env overrides | candidates file | an override set by the caller is lost: fixing it changes behaviour, a bug | left out (section 7) |
| SPL-5828 r60-06 N1/N2 comment (`spl-uplink-probe.func.sh:14-15`) | candidates file | r64 read it served (its 1.2); not re-read here | left out, served |
| p18-02 R7 N1, `10_ci-quality.yml:444-445` "it also covers the downloaded archive" | candidates file | still reads so on `93a625324` (`:445`) | left out (section 7) |
| the other 3 baseline files: `spl-cmd-guard-mode` 3, `spl-file-erase` 2, `fleet-logrotate-install` 3 | the gate | unchanged since r64 | left out (section 7) |
| spec 011 tasks still `[ ]` (`grep -nE '^\s*- \[ \]' tasks.md`) | spec 011 | T001-T008 "deferred by owner 2026-09-19"; T019, T023, T027 "open, owner decision"; T018, T020, T021, T034 a package split or a sweep, not one push | left out (section 7) |

**Row 01's sites** (`git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' 93a625324 -- csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh`, 2 lines):
- `orc:run/spl-reflection-gather.func.sh:59`
  `# @param REFLECTION_ZOMBIE_LOG (optional) - default /var/csi/csi-spl/zombie-topics/cron.log`
- `orc:run/spl-reflection-gather.func.sh:203`
  `out="$(grep -h 'OK zombie sweep, night of' "${REFLECTION_ZOMBIE_LOG:-/var/csi/csi-spl/zombie-topics/cron.log}" 2>/dev/null | tail -1)"`

The writer: `csi-spl-orc/cnf/box-crons/box-crons.manifest:62` runs
`src/bash/scripts/zombie-topics-cron.sh` with log `zombie-topics/cron.log` under the box
crons' state root, which `orc:run/install-box-crons.func.sh:36,52,61` derives:
`BOX_CRONS_STATE_DIR`, default `SPL_VAR_APP_DIR`, FATAL when no tree. So on another
prefix the gather's section 6 reads a file the cron never writes and prints "(no zombie
sweep summary in the log)". On the box layout both are the same file: `spl_run_paths`
from the main checkout with `APP_PATH`, `PROJ_PATH` and `SPL_VAR_APP_DIR` unset prints
`SPL_VAR_APP_DIR=/var/csi/csi-spl`, and `/var/csi/csi-spl/zombie-topics/cron.log`
exists (last written 2026-11-19 10:00 local), read 09:14Z.

**Row 02's sites** (the literal grep on `csi-spl-orc/src/bash/features/graft/`, 7 lines,
3 of them in the 2 scripts):
- `orc:features/graft/scripts/graft-index-dir.sh:24`
  `graft_var_root() { printf '%s' "${GRAFT_VAR_ROOT:-/var/csi/csi-spl/graft}"; }`
- `orc:features/graft/scripts/graft-index-dir.sh:20` (comment) and
  `orc:features/graft/scripts/graft-cron.sh:11` (comment) name that default.
- `orc:features/graft/tests/test-graft-index-dir.sh:27` asserts the default as the
  literal `/var/csi/csi-spl/graft/index/$SLUG`.
- The other 3 lines are md docs (`README.md:25`, `assets/agy-rules/graft.md:19`,
  `assets/skills/graft/SKILL.md:116`): section 7.

graft runs from the tree in place (`box-crons.manifest:29-30` run
`src/bash/features/graft/scripts/graft-cron.sh`; `graft-common.inc.sh:47,263` and
`graft-safe.sh:124` call `graft-index-dir.sh` beside them), so `spl_run_paths` can start
from the script's own checkout (`_spl_run_paths_top`, as r64-01's cron wrappers do).
`spl_run_paths` reads files only, no git call (`orclib:spl-run-paths.func.sh`, the
`spl_main_checkout` comment "Read from the file, no git call"), so `graft-safe.sh`,
which runs on every agent graft call, takes no git subprocess. A `graft_var_root` that
derives nothing prints nothing, and `graft_index_dir` already returns 1 on an empty
root (`graft-index-dir.sh:37`): the existing refusal, no new one.

**The baseline:** `git show 93a625324:csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -vE '^\s*(#|$)'`
-> **4 files, 10 lines** (`3 spl-cmd-guard-mode`, `2 spl-file-erase`,
`2 spl-reflection-gather`, `3 fleet-logrotate-install`). r64-02, as planned, adds
`1 graft-cron.sh` and `2 graft-index-dir.sh` (6 files, 13 lines). The gate fails a stale
entry (`no-literal-paths.tst.sh` `nlp_check`: "STALE baseline: ... drop its line"), so
each row drops its own lines in the same commit.

**The derived form**, as r62-01 to r64-01 landed it: an env override, else
`${SPL_VAR_APP_DIR}/<sub>` after `spl_run_paths` (`orclib:spl-run-paths.func.sh`,
sourced as `declare -F spl_run_paths >/dev/null || source ...`).

### 1.3 The tests (R2, C4)

`NAMES` = the row's basenames:
`pat=$(for n in $NAMES; do printf '%s' "|\b$n(\.sh|\.tst\.sh|\.func\.sh)?([^a-z0-9_-]|\$)"; done); git grep -lE "${pat#|}" 93a625324 -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' 'csi-spl-utl/**/tests/*'`

- r65-01 (`spl-reflection-gather`) -> **3** files: `spl-reflection-gather.tst.sh`,
  `no-literal-paths.baseline`, `orc-shard-weights.txt` (not a test). Function names
  (`git grep -lE 'graft_var_root|spl_reflection_gather|do_spl_reflection_gather' 93a625324 -- '*tests/*'`)
  -> `spl-reflection-gather.tst.sh` only. Its one `REFLECTION_ZOMBIE_LOG` use
  (`:192`) sets the var, so no case reads the default today.
- r65-02 (`graft-index-dir graft-cron`) -> **4** files: `features/graft/tests/test-graft-cron.sh`,
  `test-graft-index-dir.sh`, `test-graft-safe.sh`, and `orc:tests/install-box-crons.tst.sh`.
  No test names `graft_var_root` (the command above). The graft feature tests run as
  `bash csi-spl-orc/src/bash/features/graft/tests/run-all.sh`, and in
  `do_check_pre_push` (`check-pre-push-features.func.sh`, every `features/*/tests`).
- R2 bullet 2, a 30-character string of each changed line, in any `csi-spl-*` tests dir
  (`git grep -lF '<string>' 93a625324 -- 'csi-spl-*/**/tests/*'`) for
  `REFLECTION_ZOMBIE_LOG:-/var/csi`, `default /var/csi/csi-spl/zombie-topics`,
  `GRAFT_VAR_ROOT:-/var/csi/csi-spl`, `GRAFT_VAR_ROOT (default /var/csi`,
  `repos.list (default /var/csi/csi-spl` -> **0 files** each.
- Both rows: `no-literal-paths.tst.sh` (the baseline drops lines) and
  `spl-run-paths.tst.sh`.

## 2. The 2 rows

Paths: `orc:` = `csi-spl-orc/src/bash/`, `orclib:` = `csi-spl-orc/lib/bash/funcs/`.

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r65-01-orc-reflection-zombie-log-dir)` | no literal box path (developer guide 2.3.1) | the gather reads the zombie sweep log at a literal `/var/<org>/<app>` path while the cron that writes it derives its root (`BOX_CRONS_STATE_DIR`, default `SPL_VAR_APP_DIR`); on another prefix section 6 reads a file nobody writes | `orc:run/spl-reflection-gather.func.sh:59,203`<br>`orc:tests/no-literal-paths.baseline` (drop `2 ...spl-reflection-gather.func.sh`)<br>`orc:tests/spl-reflection-gather.tst.sh` (a case) | 1 file, 2 lines | `:203` reads `${REFLECTION_ZOMBIE_LOG:-$SPL_VAR_APP_DIR/zombie-topics/cron.log}` after `spl_run_paths`; `:59` says "default `<SPL_VAR_APP_DIR>/zombie-topics/cron.log`". No dir derived and no override: section 6 prints one `(not read: ...)` line naming `REFLECTION_ZOMBIE_LOG`, the form its other sections use (`:40`). New case in `spl-reflection-gather.tst.sh`: `REFLECTION_ZOMBIE_LOG` unset, `SPL_VAR_APP_DIR=$T/v` with a summary line in `$T/v/zombie-topics/cron.log` -> section 6 prints it. Tests: `spl-reflection-gather.tst.sh`, `no-literal-paths.tst.sh`, `spl-run-paths.tst.sh`, `run-eager-files.tst.sh`. **Control:** below. | either | claude | simple_coding | 1 (after r64-02) |
| 02 `refactor(r65-02-orc-graft-var-root)` | no literal box path (developer guide 2.3.1) | graft's box-wide state root is the one non-test `*.sh` literal left after r64-01; r64-02 lists it in the baseline, while every other csi-spl state dir is `<SPL_VAR_APP_DIR>/<sub>` | `orc:features/graft/scripts/graft-index-dir.sh:20,24`<br>`orc:features/graft/scripts/graft-cron.sh:11`<br>`orc:features/graft/tests/test-graft-index-dir.sh:27`<br>`orc:tests/no-literal-paths.baseline` (drop graft's 2 lines) | 2 files, 3 lines | `graft_var_root` prints `${GRAFT_VAR_ROOT:-$SPL_VAR_APP_DIR/graft}` after `spl_run_paths` (sourced from the script's own checkout); empty when neither: the existing rc 1 of `graft_index_dir` (1.2). The 2 comments say "default `<SPL_VAR_APP_DIR>/graft`". `test-graft-index-dir.sh:27` sets `SPL_VAR_APP_DIR=$T/v` and expects `$T/v/graft/index/$SLUG`; a new case with `SPL_RUN_PATHS_TOP=` and `APP_PATH`, `PROJ_PATH`, `SPL_VAR_APP_DIR`, `GRAFT_*` unset expects rc 1. Tests: `features/graft/tests/run-all.sh` (cron, index-dir, safe, install, wrap), `install-box-crons.tst.sh`, `no-literal-paths.tst.sh`, `spl-run-paths.tst.sh`. **Control:** below. | either | claude | simple_coding | 2 (after 01) |

**Control for both rows** (as r64-01): on the box the derived path equals the old
literal: the lane prints both (row 01: the log path; row 02: `graft_var_root` and
`graft-index-dir.sh <repo>`) from the main checkout with `APP_PATH` unset, and with
the env override set (the override wins). `SPL_RUN_PATHS_TOP=` (no tree) gives the row's
no-dir answer. Row 01 also runs `REFLECTION_FORCE=1 ./run -a do_spl_reflection_gather`
(`DRY_RUN` defaults to 1) on the box and shows section 6 the same before and after. Row
02 shows `graft-cron.sh --resolve-only` prints the same `repo-list`, `log` and `lock`
lines before and after. Both outputs in the body. `git diff` touches only the sites
above and their new derive lines.

**Re-measure first:** each row lane re-runs the literal grep and the test command of
1.2 and 1.3 on the `origin/master` it starts from and says in its result if they moved.

**Subject** (R6 reads it): `<type>(r65-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r65-NN` (R7, 2.7.4; the line box-free in a commit body).

### 2.1 Batches (R1, R16)

- **Both rows wait for r64-02** (c-859, SPL-5948): it owns
  `no-literal-paths.baseline` and adds graft's 2 lines to it, which row 02 then drops.
- **Batch 1: row 01**, queued as `SPAWN_AFTER=c002-r64-02-orc-no-literal-paths-scripts`.
- **Batch 2: row 02, after row 01 lands**: both drop lines from the same baseline file
  (R1). Queued as `SPAWN_AFTER=c002-r65-01-orc-reflection-zombie-log-dir`, within 30
  minutes (R16).
- If r64-02 ends without landing (its issue ended with a reason): row 01 still drops its
  baseline line; row 02 drops none (the gate then does not scan graft) and its control
  is the literal grep on the 2 scripts -> 0. The holder says so in the row brief.
- Neither row edits a migration, `csi-spl-cnf/`, a workflow, terraform or a file under
  `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

The 6 written paths: `orc:run/spl-reflection-gather.func.sh`,
`orc:tests/spl-reflection-gather.tst.sh`, `orc:tests/no-literal-paths.baseline`,
`orc:features/graft/scripts/graft-index-dir.sh`, `orc:features/graft/scripts/graft-cron.sh`,
`orc:features/graft/tests/test-graft-index-dir.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-293`, one call per
  path (the 6 above and graft's 3 md files), 2026-11-19T09:13:05Z -> **exit 4** for
  each: no live lane lists any of them, but 4 live lanes record no files: c-706
  (SPL-5888, WUI export to PDF), c-852 (SPL-5883 T01, a migration), c-855
  (SPL-5883 T16, filter pref), c-859 (r64-02, `no-literal-paths.tst.sh` and
  `.baseline`). Their scopes, from the planner brief: only c-859 touches a row path (the
  baseline), so both rows wait for it (2.1). n=1. The holder's R3 check before each
  row's spawn governs.
- **Commits:** `git log origin/master --since="$W" -- <the row files>` -> **0**.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-19T09:13:40Z):
  1 queued, 1 placing: SPL-5883 T17 (feature, label match) and an agy language review
  for SPL-42. Neither is refactor; neither summary names a row file. Live share
  `refactor 2 12% (band 10-20%: ok)`; last 24 h `refactor 9% (band 20-30%: UNDER)`;
  `phase day`.
- **Briefs on this lane's box** that name a row basename, `no-literal-paths` or
  `r65-NN` (`grep -rlE` over `/var/spool-hub/dispatch/briefs` and
  `/var/spool-hub/spawn-remote/briefs`, run as root, 2026-11-19T09:13:54Z): 2 newer than
  W, this planner's own and the bug round 20 planner's (`322f9071`), which names
  `no-literal-paths` only in its list of lanes to stay off (c-859). The 13 others since
  2026-11-18 are r63-01/02 and their reviewers, the SPL-5919 bug and its reviewer
  (landed), and older ones. None names `spl-reflection-gather` or a graft script as a
  file to edit. The bug round 20 plan is not written yet: the holder checks it before
  queueing row 01.
- **Unlanded round rows:** r64-02 only (above). `git grep -lE 'spl-reflection-gather|graft_var_root'`
  over `csi-spl-doc/doc/md/*-round-*-plan.md` on `93a625324` -> 7 plans: `bug-round-14`
  (row b14-01 on the gather, landed `ce765392c`), `bug-round-15`, `-18`, `-19` (the
  SPL-5825 follow-ups listed as left out or unchanged; b18 reads W2 and N1 fixed by
  b14-01), `refactor-round-35`, `-63`, `-64` (left-out mentions). No unlanded row names
  either file. SPL-5825's remaining notes are bug-round inputs on other lines of the
  gather (section 7, `spl_reflection_stalled`), not on `:59` or `:203`.

## 3. Per row: what the lane does

- **r65-01:** the gather reads the zombie sweep log under `SPL_VAR_APP_DIR`, as the cron
  that writes it does; its baseline line goes.
- **r65-02:** after r65-01: graft's state root is `<SPL_VAR_APP_DIR>/graft`; the
  baseline lines r64-02 added for it go, and no non-test `*.sh` is left in the baseline.

## 4. Panel and reviewers (R7)

- Editor: c-293 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Vendor state** (2026-11-19T09:14:42Z, n=1 each, `BOX_PICK_KIND=<k> ./run -a do_spl_box_pick`,
  read on this lane's box): grok `pick=hold` (weekly 99% >= 95% on both boxes); agy,
  mistral and claude pick this box (60% < 70%).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r65`):
  one **agy** doc seat, the main vendor for spec and plan reviews; mistral as its
  backup, as r62 to r64 had. The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2): agy if its pick still holds
  when the row is queued, else the holder's call (a fresh claude seat under the claude
  waiver, as r63 and r64). Not a mistral code R7. The holder re-reads the agy and grok
  picks before each row's reviewer is queued.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one
(rulebook 4.3), the sites and line numbers of 1.2, its R7 reviewer seat, and
"re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r65-01 | `c002-r65-01-orc-reflection-zombie-log-dir` | `refactor(r65-01-orc-reflection-zombie-log-dir, SPL-<row issue>): ...` | `review/r65-01` | 1, `SPAWN_AFTER=c002-r64-02-orc-no-literal-paths-scripts` |
| r65-02 | `c002-r65-02-orc-graft-var-root` | `refactor(r65-02-orc-graft-var-root, SPL-<row issue>): ...` | `review/r65-02` | 2, `SPAWN_AFTER=c002-r65-01-orc-reflection-zombie-log-dir` |

**r65-01 brief, Files: ONLY** `orc:run/spl-reflection-gather.func.sh`,
`orc:tests/spl-reflection-gather.tst.sh`, `orc:tests/no-literal-paths.baseline` (its one
line). Do: plan section 2 row 01 verbatim; control as section 2 (derived path = old
literal from the main checkout, `APP_PATH` unset, the override; `SPL_RUN_PATHS_TOP=`;
section 6 the same before and after on the box). Gates: `spl-reflection-gather`,
`no-literal-paths`, `spl-run-paths`, `run-eager-files`;
`cd csi-spl-iac && ./run -a do_check_pre_push`. Kind `simple_coding`, vendor claude.

**r65-02 brief, Files: ONLY** `orc:features/graft/scripts/graft-index-dir.sh`,
`orc:features/graft/scripts/graft-cron.sh`, `orc:features/graft/tests/test-graft-index-dir.sh`,
`orc:tests/no-literal-paths.baseline` (graft's lines). Do: plan section 2 row 02
verbatim; control as section 2 (`graft_var_root` and `graft-index-dir.sh <repo>` the
same on the box; `graft-cron.sh --resolve-only` the same; `SPL_RUN_PATHS_TOP=` -> rc 1).
Gates: `bash csi-spl-orc/src/bash/features/graft/tests/run-all.sh`,
`install-box-crons`, `no-literal-paths`, `spl-run-paths`;
`cd csi-spl-iac && ./run -a do_check_pre_push` (it runs the feature tests). Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash 2) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: row 01 (after r64-02); batch 2: row 02 (after 01) |
| `no-literal-paths` baseline | 4 files / 10 lines today -> 6 / 13 after r64-02 -> 5 / 11 after r65-01 -> 3 / 8 after r65-02 |
| literal box paths in non-test `*.sh` (`':!*.func.sh' ':!**/tests/**'`) | 2 files / 3 lines -> 0 after r65-02 |
| measured on | `93a625324`, n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| graft's md docs (`README.md:25`, `assets/agy-rules/graft.md:19`, `assets/skills/graft/SKILL.md:116`) name `/var/csi/csi-spl/graft` | still the value on the box layout after row 02; not scanned by the gate; the 2 assets are installed into agent homes, so a wording change there is an install change. A docs follow-up after r65-02, not a 6th site | 1.2 |
| `guides/installation-and-configuration-guide.md:594` | a Qto `system` doc export that names the box layout on purpose (`/opt/csi/csi-spl` throughout); the edit goes in Qto, a doc lane's | 1.2 |
| `spl-cmd-guard-mode`, `fleet-logrotate-install`, `spl-file-erase` (3 files, 8 lines) | round 35 section 6, unchanged: an org var dir export from `spl_run_paths` first; `spl-file-erase` is a protected-root deny list | 1.2 |
| SPL-5824 W1, N1, N2 (desk hop drops env) | changes what a caller's override does: a bug round's | 1.2 |
| p18-02 R7 N1 (`10_ci-quality.yml:444-445` wording) | a workflow comment from a perf row; a perf round's follow-up or a docs fix, and a workflow edit runs every CI job | 1.2 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred (2026-09-19) or an open owner decision (topic 582f7895), or larger than one push | 1.2 |
| the candidates file's bug-shaped items (review-go retry to a retired author; AltGr) | bugs, not refactor rows (the planner brief) | the brief |

## 8. Changes

- v0.1 (c-293): first draft. A fresh round: 2 rows found on `93a625324`. Row 01 the
  reflection gather's zombie log default; row 02 graft's var root (r64's section 7
  first candidate). Window W and the r65 slug proof recorded. Both rows wait for r64-02
  (the baseline).

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-293 (claude): v0.1.
- Panel reviewer seat: requested (section 4).
- Row R7 seats: section 4.
