# Refactoring round 64 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5921  
Topic: f054a589-3f8f-4b00-9b59-8db43a114d0e  
Discussion: f054a589-3f8f-4b00-9b59-8db43a114d0e (t1 #refactoring, "Refactor round 64", opener msg 07d84de2)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r64**, plan `refactor-round-64-plan.md`, rows `r64-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 63 ([refactor-round-63-plan.md](refactor-round-63-plan.md))
took the last two rows of round 35, and both landed (`9dcb5589d` r63-01, `4d4c5ecde`
r63-02). So r64 carries no signed row: it is a fresh round, found in the dispatcher's
candidates file and the `no-literal-paths` gate. Both rows serve the same practice as
r62 and r63, **no literal box path** (developer guide 2.3.1), where the gate does not
look yet: the cron wrapper scripts (`*.sh` that are not `*.func.sh`).

**Status: v1.0**: panel seat m-828 (mistral) PASS on v0.1 `b8090a414`, W1 folded (one line cite, section 8), N1-N4 notes; m-828 signed v1.0 `b9d80db5a` (section 9). Rows unchanged from v0.1. Editor: **c-816** (claude).

**One sha:** every count is measured on **`32a261c24`** (`origin/master`
32a261c24f7c3b3067869c6559f7b1b0ccccec46, committed 2026-11-19T02:31:15+02:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`. Queue, lane
map and vendor readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-18T19:28:43+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r63-plan'` -> commit
  `2aad3eb93` "refactor round 63 plan records the v1.0 signature and the ACCEPTED".
  Every later read of r64 uses this W.
- **`r64` is free** (2026-11-19T06:15Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r64-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r64-*' 'refs/heads/wip/*r64*' 'refs/heads/*-r64-*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r64-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote`
    (run as root) on this lane's box, 2026-11-19T06:16:21Z -> **0 files**. The other
    box's briefs were not read by this lane.
  - Control: the same log read for `r63` -> 3 lines (`2aad3eb93` the plan, `9dcb5589d`
    r63-01, `4d4c5ecde` r63-02), so the read sees a used id.
- **No `refactor-round-64*` file** exists under `csi-spl-doc/doc/md` on `32a261c24`, so
  the plan takes the plain name (5.3 "Files").

### 1.2 The candidates, re-measured

The literal grep: `git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' 32a261c24 -- <path>`.

| input | source | on `32a261c24` | here |
|---|---|---|---|
| watchdog `LOGIN_STATE_DIR` default (`spl-watchdog.func.sh:72,:1311`), lane-rotate probe path (`spl-lane-rotate.func.sh:112`) | candidates file, r34 row 05 N3 | literal grep on both files -> **0**; `:72` reads `default spl_claude_login_state_dir (<SPL_VAR_APP_DIR>/agent-login-check)` | served, dropped |
| `reverse-tunnel-cron.sh:23` literal, the cron gate of `do_setup_reverse_tunnel` (r63-01 derived the action's dir, not the cron's) | candidates file, r63-01 R7 W1 | **1 line**, `:23` | **row 01** |
| the same practice in the other cron wrappers of `orc:scripts/` | this plan, the grep on the dir | **4 files, 4 lines** (below) | **row 01** |
| `no-literal-paths.tst.sh` scans only `*.func.sh` and the cnf (`nlp_counts`, its `git ls-files` pathspec), so it never saw the scripts above | candidates file, r63-01 R7 W1 ("scans `run/` only") | the pathspec is `'csi-spl-cnf/*.yaml' 'csi-spl-cnf/*.yml' 'csi-spl-cnf/*.json' '*.func.sh'` | **row 02** |
| `installation-and-configuration-guide.md:594` names the reverse-tunnel state dir as a literal | candidates file, r63-01 R7 N3 | 1 line; the md is the export of Qto doc `8e8454fe-...` (its line 3: "edit it there") | left out (section 7): a Qto edit, not a code row |
| SPL-5828 r60-06 N1, `spl-uplink-probe.func.sh:14-15` "exits 0 even with the link down" | candidates file | `:14-15` now read "In probe mode a down link never fails the probe: it exits 0. A config fault does, FATAL with rc 1" | served, dropped |
| SPL-5824 W1, N1, N2: `spl_desk_live_hop` drops env overrides | candidates file | an override set by the caller is lost: fixing it changes behaviour, not a refactor | left out (section 7) |
| p18-02 R7 N1, `10_ci-quality.yml:444-445` comment overstates the margin | candidates file | still reads "it also covers the downloaded archive" | left out (section 7) |
| the 4 files left in `no-literal-paths.baseline` | the gate | `3 spl-cmd-guard-mode`, `2 spl-file-erase`, `2 spl-reflection-gather`, `3 fleet-logrotate-install` (4 files, 10 lines) | left out (section 7), round 35's reasons hold |

**Row 01's sites** (`git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' 32a261c24 -- 'csi-spl-orc/src/bash/scripts/*'`, 4 lines):
- `orc:scripts/issue-key-rate-cron.sh:23`
  `hist="${KEY_RATE_HISTORY:-${BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}/issue-key-rate/history.tsv}"`
- `orc:scripts/push-orphan-check-cron.sh:24`
  `state="${PUSH_ORPHAN_STATE_DIR:-/var/csi/csi-spl/push-orphan-check}"`
- `orc:scripts/reverse-tunnel-cron.sh:23`
  `ls "${REVERSE_TUNNEL_STATE_DIR:-/var/csi/csi-spl/reverse-tunnel}"/*.conf ... || exit 0`
- `orc:scripts/token-burn-collect-cron.sh:36`
  `dir="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}"`

Each script already computes `ORC` from its own path (`:17`, `:17`, `:18`, `:22`) and
`token-burn-collect-cron.sh` already sources `spl-token-burn-collect.func.sh`, whose
`spl_token_burn_state_dir` derives the same dir (`:34-40`). The reverse-tunnel action
derives its dir as `${SPL_VAR_APP_DIR}/reverse-tunnel` (`orc:run/setup-reverse-tunnel.func.sh`,
r63-01), so on another prefix with no override the cron's gate (`:23`) looks in a dir
the action never writes and exits 0: the r63-01 R7 W1 finding. On the box layout both
read the same dir.

**The whole-repo scan for row 02** (`git grep -cE '/(opt|var)/csi($|[^A-Za-z0-9_-])' 32a261c24 -- '*.sh' ':!*.func.sh'`):
23 files, 86 lines. 17 of them are under a `tests/` dir (fixtures). The 6 outside a
`tests/` dir: row 01's 4 scripts (1 line each) and
`orc:features/graft/scripts/graft-cron.sh:11` (a comment),
`orc:features/graft/scripts/graft-index-dir.sh:20,24` (a comment and the
`graft_var_root` default): 2 files, 3 lines.

**The baseline:** `git show 32a261c24:csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -vE '^\s*(#|$)' | awk '{s+=$1} END{print NR, s}'`
-> **4 files, 10 lines** (r63 read 11 / 23 on `e7ff0e347`; r62-02, r63-01 and r63-02
took 7 files / 13 lines).

**The derived form**, as r62-01 and r63-01 landed it: an env override, else
`${SPL_VAR_APP_DIR}/<sub>` after `spl_run_paths` (`orclib:spl-run-paths.func.sh`,
sourced as `declare -F spl_run_paths >/dev/null || source ...`). A cron wrapper that
runs without `./run` is the case `_spl_run_paths_top` was written for (its comment,
`orclib:spl-run-paths.func.sh:24-31`): the checkout the file sits in is the last
resort. When no dir can be derived, the script logs one FATAL line and takes its
refusal exit (2), as its other refusals do today (`[ -x "$ORC/run" ] || ... exit 2`).

### 1.3 The tests (R2, C4)

`NAMES` = the row's basenames:
`pat=$(for n in $NAMES; do printf '%s' "|\b$n(\.sh|\.tst\.sh)?([^a-z0-9_-]|\$)"; done); git grep -lE "${pat#|}" 32a261c24 -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' 'csi-spl-utl/**/tests/*'`

- r64-01 (`issue-key-rate-cron push-orphan-check-cron reverse-tunnel-cron token-burn-collect-cron`)
  -> **4** files: `install-box-crons.tst.sh`, `reverse-tunnel.tst.sh`,
  `spl-issue-key-rate.tst.sh`, `spl-token-burn-collect.tst.sh` (all `orc:tests/`).
  The action of the push-orphan script has its own test, `spl-push-orphan-check.tst.sh`
  (`git grep -l push-orphan 32a261c24 -- 'csi-spl-orc/**/tests/*'` -> it,
  `install-box-crons.tst.sh` and `orc-shard-weights.txt`, not a test).
- R2 bullet 2, a 30-character string of each changed line, in any `csi-spl-*` tests
  dir (`git grep -lF '<string>' 32a261c24 -- 'csi-spl-*/**/tests/*'`) for
  `BOX_CRONS_STATE_DIR:-/var/csi/csi-spl}`, `PUSH_ORPHAN_STATE_DIR:-/var/csi/csi`,
  `REVERSE_TUNNEL_STATE_DIR:-/var/csi`, `TOKEN_BURN_STATE_DIR:-/var/csi/csi-s` -> **0
  files** each.
- r64-02 (`no-literal-paths`) -> `no-literal-paths.tst.sh` and its baseline (the same
  command -> those 2 files).

## 2. The 2 rows

Paths: `orc:` = `csi-spl-orc/src/bash/`, `orclib:` = `csi-spl-orc/lib/bash/funcs/`,
`iac:` = `csi-spl-iac/src/bash/`.

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r64-01-orc-cron-script-state-dirs)` | no literal box path (developer guide 2.3.1) | 4 cron wrappers default their state dir to `/var/<org>/<app>/<sub>` while their actions derive it; reverse-tunnel's gate then looks where the action never writes on another prefix (r63-01 R7 W1) | `orc:scripts/issue-key-rate-cron.sh:23`<br>`orc:scripts/push-orphan-check-cron.sh:24`<br>`orc:scripts/reverse-tunnel-cron.sh:23`<br>`orc:scripts/token-burn-collect-cron.sh:36` | 4 files, 4 lines | Each default becomes the derived form of 1.2: `${KEY_RATE_HISTORY:-${BOX_CRONS_STATE_DIR:-$SPL_VAR_APP_DIR}/issue-key-rate/history.tsv}`, `${PUSH_ORPHAN_STATE_DIR:-$SPL_VAR_APP_DIR/push-orphan-check}`, `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`, and token-burn calls its sourced `spl_token_burn_state_dir`. No dir derived: one FATAL line, exit 2 (1.2). Tests: the 4 of 1.3, `spl-push-orphan-check.tst.sh`, `spl-run-paths.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh` (unchanged, still green). **Control:** below. | either | claude | simple_coding | 1 |
| 02 `test(r64-02-orc-no-literal-paths-scripts)` | a gate that sees every shell file (developer guide 2.3.1, 2.12.1) | `no-literal-paths` scans `*.func.sh` and the cnf only; the 4 literals of row 01 lay outside it, so nothing stops a new one in a script | `orc:tests/no-literal-paths.tst.sh` (`nlp_counts` pathspec, its header, a fixture case)<br>`orc:tests/no-literal-paths.baseline` (+2 entries) | 1 test, 1 baseline | `nlp_counts` also lists every tracked `*.sh` outside a `tests/` dir; fixtures stay out. The baseline gains `1 csi-spl-orc/src/bash/features/graft/scripts/graft-cron.sh` and `2 csi-spl-orc/src/bash/features/graft/scripts/graft-index-dir.sh` (6 files, 13 lines). **Red control** (C2) on the test's fixture tree: a new `scripts/x.sh` with a literal FAILs `NEW literal path`; a `tests/x.tst.sh` with one passes. Before the change the first case passes: that is the RED (the gate is blind). Gate row: R9 (`PRE_PUSH_TIER=full`, and once with every `PRE_PUSH_*` unset). | either | claude | tests | 2 (after 01) |

**Control for row 01** (as r63-01): on the box the derived dir equals the old literal:
the lane prints both for each script, run from the main checkout with `APP_PATH` unset,
and with each env override set (the override wins). `SPL_RUN_PATHS_TOP=` (no tree)
gives the row's no-dir answer. The crontab lines `do_install_box_crons` writes are the
same before and after (the lane prints them; `install-box-crons.tst.sh`). Both outputs
in the body. `git diff` touches only the 4 lines and their new derive lines.

**Re-measure first:** each row lane re-runs the literal grep and the test command of
1.2 and 1.3 on the `origin/master` it starts from and says in its result if they moved.

**Subject** (R6 reads it): `<type>(r64-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r64-NN` (R7, 2.7.4; the line box-free in a commit body).

### 2.1 Batches (R1, R16)

- **Batch 1: row 01**, nothing before it.
- **Batch 2: row 02, after row 01 lands.** Row 02's widened gate fails on row 01's 4
  literals while they are on master; landing row 01 first keeps the baseline from
  taking 4 entries that would leave it again soon after. Queued as
  `SPAWN_AFTER=c002-r64-01-orc-cron-script-state-dirs`, within 30 minutes (R16).
- The two rows share no file. Neither edits a migration, `csi-spl-cnf/`, a workflow,
  terraform or a file under `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

The 6 written paths: `orc:scripts/issue-key-rate-cron.sh`,
`orc:scripts/push-orphan-check-cron.sh`, `orc:scripts/reverse-tunnel-cron.sh`,
`orc:scripts/token-burn-collect-cron.sh`, `orc:tests/no-literal-paths.tst.sh`,
`orc:tests/no-literal-paths.baseline`.

- **Lane map, every machine:** `lane-map.sh --check <the 6, comma separated> --agent c-816`
  at 2026-11-19T06:16:00Z -> **`free`, exit 0**. n=1. The holder's R3 check before
  each row's spawn governs.
- **The lanes the brief named:** SPL-5919 (the login probe in a code snapshot) landed
  as `e221500d5`; r63-01 and r63-02 landed (`9dcb5589d`, `4d4c5ecde`); SPL-5915
  landed as `0268cbab8` (the brief's reading, not re-read here).
  `git log origin/master --since="$W" -- csi-spl-orc/src/bash/scripts/ <the 2 test files>`
  -> 5 commits, none on a row file: 2 on `orc:scripts/issue-stale-sweep-judge.py`
  (`dcf0fe9b2`, `a9792796b`), p18-02 on `orc:scripts/ci-disk-guard.sh` (`17fd13fd0`),
  r63-01 and r63-02 on the baseline (3 lines removed each).
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-19T06:16:06Z):
  2 queued, 0 placing (a bug-round-19 mistral panel seat, an agy language review).
  Neither is refactor; neither summary names a row file. Live share
  `refactor 1 20% (band 10-20%: ok)`; last 24 h `refactor 8% (band 20-30%: UNDER)`;
  `phase day`.
- **Briefs on this lane's box** changed since W (`find /var/spool-hub/dispatch/briefs
  /var/spool-hub/spawn-remote/briefs -newermt 2026-11-18T18:28:43Z`) that name a row
  basename or `no-literal-paths`, 2026-11-19T06:16:21Z: 10. This planner's own (and a
  backup of it), r62-02's and r63-01/02's (landed) with their reviewer briefs and a
  backup, and the SPL-5919 bug brief and its reviewer's (landed; they name
  `no-literal-paths` as a test to run, not a file to edit). None names a row 01 script.
- **Open plans:** `git grep -l` of the 4 script basenames and `no-literal-paths` over
  `csi-spl-doc/doc/md/*-round-*-plan.md` on `origin/master` -> 7 plans
  (`bug-round-16`, `bug-round-18`, `perf-round-15`, `refactor-round-34`, `-35`, `-62`,
  `-63`). The newest, `bug-round-18` (0 rows) and `refactor-round-63` (served), hold no
  unlanded row.
- **Unlanded round rows:** none on these paths (r62-02, r63-01, r63-02: 1 landed
  commit each by `git log origin/master --oneline -E --grep='\(<row>'`).

## 3. Per row: what the lane does

- **r64-01:** the 4 cron wrappers take their state dir from `spl_run_paths` (or
  token-burn's own derive), as their actions already do; no baseline change (the gate
  does not scan scripts yet).
- **r64-02:** after r64-01: the gate scans every non-test `*.sh` too; graft's 2 files
  enter the baseline, which then only shrinks.

## 4. Panel and reviewers (R7)

- Editor: c-816 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Vendor state** (2026-11-19T06:16:44Z, n=1 each, `BOX_PICK_KIND=<k> ./run -a do_spl_box_pick`,
  read on this lane's box, which lists only itself): grok `pick=hold` (weekly 99% >=
  95%); agy `pick=nokind` (no agy CLI here; the spawn queue says agy on the other box is
  at its quota limit until 2026-11-24T23:34:46Z); mistral and claude pick this box
  (usage unknown, placed anyway).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r64`):
  one **mistral** doc seat, as rounds 35, 62 and 63 (mistral may take docs and
  reviews, owner 10-17, t1 b61851fb msg 91bf8278). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2). With agy at its quota and
  grok on hold, the holder's call per row, as r63 (a fresh claude seat under the
  claude waiver). Not a mistral code R7. The holder re-reads the agy and grok picks
  before each row's reviewer is queued.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one
(rulebook 4.3), the sites and line numbers of 1.2, its R7 reviewer seat, and
"re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r64-01 | `c002-r64-01-orc-cron-script-state-dirs` | `refactor(r64-01-orc-cron-script-state-dirs, SPL-<row issue>): ...` | `review/r64-01` | 1 |
| r64-02 | `c002-r64-02-orc-no-literal-paths-scripts` | `test(r64-02-orc-no-literal-paths-scripts, SPL-<row issue>): ...` | `review/r64-02` | 2, `SPAWN_AFTER=c002-r64-01-orc-cron-script-state-dirs` |

**r64-01 brief, Files: ONLY** `orc:scripts/issue-key-rate-cron.sh`,
`orc:scripts/push-orphan-check-cron.sh`, `orc:scripts/reverse-tunnel-cron.sh`,
`orc:scripts/token-burn-collect-cron.sh`, and a test case in one of the row tests of
1.3 if a script's derive has none. Do: plan section 2 row 01 verbatim; control as
section 2 (derived dir = old literal from the main checkout, `APP_PATH` unset, each
override; `SPL_RUN_PATHS_TOP=`; the installed crontab lines before and after). Gates:
the 4 row tests, `spl-push-orphan-check`, `spl-run-paths`, `run-eager-files`,
`no-literal-paths`; `cd csi-spl-iac && ./run -a do_check_pre_push`. Kind
`simple_coding`, vendor claude.

**r64-02 brief, Files: ONLY** `orc:tests/no-literal-paths.tst.sh`,
`orc:tests/no-literal-paths.baseline`. Do: plan section 2 row 02 verbatim; the red
control on the fixture tree (RED before, GREEN after, both outputs in the body); the
real-tree run lists exactly graft's 2 files, which the baseline takes. Gates:
`no-literal-paths.tst.sh`; R9: `PRE_PUSH_TIER=full ./run -a do_check_pre_push` and once
with every `PRE_PUSH_*` unset. Kind `tests`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 1, test 1; Bash 2) |
| vendor | claude 2 |
| kind | simple_coding 1, tests 1 |
| batches | batch 1: row 01; batch 2: row 02 (after 01) |
| literal box paths in non-test `*.sh` outside the gate | 6 files / 7 lines -> 2 / 3 after r64-01 -> 0 unseen after r64-02 (graft's 2 in the baseline) |
| `no-literal-paths` baseline | 4 files / 10 lines -> 6 / 13 after r64-02 |
| measured on | `32a261c24`, n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| graft's 2 scripts (`graft-cron.sh`, `graft-index-dir.sh`, 3 lines) | graft keeps its own var root (`GRAFT_VAR_ROOT`); deriving it is a row of its own, the first candidate for r65 | 1.2 |
| `installation-and-configuration-guide.md:594` literal state dir | a Qto `system` doc export: the edit goes in Qto, then `do_spl_doctree_export_md`; a doc lane's, or r64-01's if the holder adds it with the Qto seat named | 1.2 |
| `spl-cmd-guard-mode`, `fleet-logrotate-install`, `spl-file-erase`, `spl-reflection-gather` (4 files, 10 lines) | round 35 section 6: an org var dir export from `spl_run_paths` first; a protected-root deny list; open SPL-5825 follow-ups | 1.2 |
| SPL-5824 W1, N1, N2 (desk hop drops env) | changes what a caller's override does: a bug round's | 1.2 |
| p18-02 R7 N1 (`10_ci-quality.yml:444-445` wording) | a workflow comment; a perf round's follow-up or a docs fix | 1.2 |
| b12-02 N1-N4, r34 row 01 N1/N2, SPL-5825 W1-N4, SPL-5850 N1 | bug- or test-shaped | candidates file |

## 8. Changes

- v0.1 (c-816): first draft. A fresh round: 2 rows found on `32a261c24`. Row 01 the 4
  cron wrappers' literal state dirs (from r63-01 R7 W1, widened to the dir); row 02
  the `no-literal-paths` gate widened to non-test `*.sh`. Window W and the r64 slug
  proof recorded. Candidates already served (watchdog / lane-rotate login dir,
  uplink-probe comment) dropped with their reads.
- v1.0 (c-816): the panel seat m-828 (mistral) passed v0.1 `b8090a414`. W1: the `ORC=` cite of
  `reverse-tunnel-cron.sh` is `:18`, not `:17` (`git grep -n '^ORC=' 32a261c24 -- <file>` -> 18);
  fixed in 1.2. N1 (r63-01 R7 W1 re-verified on the tree), N2 (`origin/master` was still
  `32a261c24` at its read), N3 (lane map free, exit 0) and N4 (W and the 5 commits since
  W re-read): no change. Status line and sections 1.2, 8 and 9 only.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-816 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-828 (mistral) PASS** on `b8090a414331c125f457e46753af3675efdf327d`
  (spool msg 2ac0824a, task `dispatch-refactor-r64`); seat file on branch
  `review/c002-refactor-round-64-mistral-seat` (`e18392c8c`). W1 folded; N1-N4 notes.
- v1.0 signed: **m-828 (mistral) PASS** on `b9d80db5a8952fd5d177d54981ea71879d4cca2e`
  (spool msg a419e07e), seat file `a8a6b70f8`. W: none; N1-N4 notes, no change.
- Row R7 seats: section 4.
