# Refactoring round 63 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5912  
Topic: 675dfea3-7648-47e2-b751-08eb68160a53  
Discussion: 675dfea3-7648-47e2-b751-08eb68160a53 (t1 #refactoring, "Refactor round 63", opener msg f8eabb08)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r63**, plan `refactor-round-63-plan.md`, rows `r63-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Refactor round 35 ([refactor-round-35-plan.md](refactor-round-35-plan.md),
v1.0, panel m-392 mistral PASS) planned 6 rows `r61-01..06`. Under the cadence of
rulebook 5 (SPL-5879) it is split: rows 01 and 02 landed as r61, rows 03 and 04 are r62
([refactor-round-62-plan.md](refactor-round-62-plan.md)), and **r63 = ex r61-05 + ex
r61-06**, the last two rows of round 35. **The rows are not re-planned here: each one
cites round 35's signed row** (its section 3 cell, 3.1-3.3 and 4, signed in
`e563bf623`, which is `08efd6484` on today's `origin/master`, r62 plan 1.2); this plan
only re-measures each row's sites, its literal grep and its test list on today's
`origin/master` and says what moved (section 2).

**Status: v1.0**: panel seat m-582 (mistral) PASS on v0.1 `621788d9b`, W none, N1-N4
notes (section 9); m-582 signs this v1.0 commit's sha next. Rows unchanged from v0.1.
Editor: **c-915** (claude).

**One sha:** every count is measured on **`e7ff0e347`** (`origin/master`
e7ff0e3474e5e85c582961b982ce86b216b9f2ef, committed 2026-11-18T18:08:12+01:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`. Queue, lane
map and vendor readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-18T15:20:32+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r62-plan'` -> commit
  `f67007b80` "refactor round 62 plan v1.0, panel m-514 mistral PASS on v0.2 94bde6673".
  Every later read of r63 uses this W.
- **`r63` is free** (2026-11-18T17:11:47Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r63-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r63-*' 'refs/heads/wip/*r63*' 'refs/heads/*-r63-*'`
    -> **nothing** (rc 0); `git ls-remote origin 'refs/heads/*r63*' 'refs/heads/*round-63*'`
    -> nothing.
  - `grep -rlE 'r63-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote`
    (run as root, one brief there is not readable by the lane user) on this lane's box
    -> 1 file, this planner's own brief. The holder's box was not read by this lane.
  - Control: the same log read for `r62` -> 5 lines (`4ca86a9c3`, `b36b20577` r62-01 and
    the 3 r62 plan commits, all committed at or after W), so the read sees a used id.
- **No `refactor-round-63*` file** exists under `csi-spl-doc/doc/md` on `e7ff0e347`, so
  the plan takes the plain name (5.3 "Files").

## 2. The rows, re-measured on `e7ff0e347`

The literal grep, per file (round 35 section 2):
`git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' e7ff0e347 -- <file>`.

| row | ex | sites on `f284b4148` (r35) | sites on `e7ff0e347` | moved? |
|---|---|---|---|---|
| r63-01 | r61-05 | `orc:run/spl-workspace-docs-purge.func.sh:36,48,135`, `orc:run/prune-docker-images-install-cron.func.sh:8,27`, `orc:run/setup-reverse-tunnel.func.sh:30,40` (7 lines, 3 files) | the same 7 lines, 3 files | **no**: `git log --oneline f284b4148..e7ff0e347 -- <each of the 3>` -> 0 each |
| r63-02 | r61-06 | `orc:run/spl-desk-up.func.sh:66`, `orc:run/spl-m3-e2e.func.sh:85`, `orc:run/spl-desk-install-service.func.sh:327,329` (4 lines, 3 files) | the same 4 lines, 3 files | **no**: the same log -> 0 each |

The lines, as they read on `e7ff0e347`:
- `spl-workspace-docs-purge:36` the `@param PURGE_EXPORT_DIR` default,
  `:48` `dir="${PURGE_EXPORT_DIR:-/var/csi/csi-spl/workspace-docs-purge/$ENV/$tenant/<utc ts>}"`,
  `:135` a comment ("/var/csi carries one", the parent's default ACL).
- `prune-docker-images-install-cron:8` the `@description` log path,
  `:27` `logdir="${PRUNE_CRON_LOG_DIR:-/var/csi/csi-spl/docker-prune}"`.
- `setup-reverse-tunnel:30` the `@param REVERSE_TUNNEL_STATE_DIR` default,
  `:40` `dir="${REVERSE_TUNNEL_STATE_DIR:-/var/csi/csi-spl/reverse-tunnel}"`.
- `spl-desk-up:66` and `spl-m3-e2e:85`: `@example ... ROOT_KEY_JSON=/var/csi/csi-spl/tenants/dev/t1.<ts>.json ...`.
- `spl-desk-install-service:327,329`: an incident comment naming the mounts and a
  `>> /var/csi/...` redirect. No executable line in row 02.

**The baseline:** `git show e7ff0e347:csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -vE '^\s*(#|$)' | awk '{s+=$1} END{print NR, s}'`
-> **11 files, 23 lines** (r62 read 14 / 30 on `04ca1d897`; r62-01 took 3 files / 7
lines). The row files' entries in it: `3 spl-workspace-docs-purge.func.sh`,
`2 prune-docker-images-install-cron.func.sh`, `2 setup-reverse-tunnel.func.sh` (r63-01:
3 entries, 7 lines go), `1 spl-desk-up.func.sh`, `1 spl-m3-e2e.func.sh`,
`2 spl-desk-install-service.func.sh` (r63-02: 3 entries, 4 lines go). It still holds
`2 spl-spawn-place.func.sh`, r62-02's entry: that row is not on `origin/master`
(`git log origin/master --oneline -E --grep='\(r62-02'` -> 0; section 3.2).

**The derived form** (round 35 section 1), as r62-01 landed it (`b36b20577`): an env
override, else `${SPL_VAR_APP_DIR}/<sub>` after `spl_run_paths`
(`orclib:spl-run-paths.func.sh`, sourced on first use as
`declare -F spl_run_paths >/dev/null || source ...`, so the `./run` loader keeps the
file lazy, `run-eager-files.tst.sh`), and a FATAL line with rc 1 when no dir can be
derived.

**The tests (R2, C4)**, round 35's 3.3 command with `NAMES` the row's basenames, on
`e7ff0e347` and on `f284b4148`:

`pat=$(for n in $NAMES; do printf '%s' "|\b$n(\.func\.sh)?([^a-z0-9_-]|\$)|\bdo_${n//-/_}\b"; done); git grep -lE "${pat#|}" <sha> -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' 'csi-spl-utl/**/tests/*' | grep -v baseline`

- r63-01 -> **4** files on both shas, `diff` empty: `prune-docker-images.tst.sh`,
  `reverse-tunnel.tst.sh`, `spl-workspace-docs-purge.tst.sh` (all `orc:tests/`) and
  `orc-shard-weights.txt` (not a test).
- r63-02 -> **60** files on both shas, `diff` empty (`spl-desk-up` is named across the
  desk tests).
- Row 02's named subset exists on `e7ff0e347` (`git ls-tree -r --name-only`):
  `iac:tests/action-header-tags.tst.sh`, `orc:tests/m3-e2e-none.tst.sh`,
  `orc:tests/desk-install-service-envs.tst.sh`, `orc:tests/desk-install-service-user.tst.sh`,
  `orc:tests/boot-cron-gate.tst.sh`.
- R2 bullet 2, the 30-character strings of row 02's lines, in any `csi-spl-*` tests
  dir (`git grep -lF '<string>' e7ff0e347 -- 'csi-spl-*/**/tests/*'`) for
  `DESK_AGENT=CLE-00 ROOT_KEY_JSON`, `ROOT_KEY_JSON=/var/csi/csi-spl/tenants`,
  `jobs at 18:38:48Z while /opt`, `redirect failed ("Directory nonexistent")` -> **0
  files** each. The lane re-runs it on its own lines (round 35 row 06).

## 3. The 2 rows

Each cell is round 35's signed row ([refactor-round-35-plan.md](refactor-round-35-plan.md)
section 3, rows 05 and 06), with the line numbers and the test list of section 2 above.
Paths: `orc:` = `csi-spl-orc/src/bash/`, `orclib:` = `csi-spl-orc/lib/bash/funcs/`,
`iac:` = `csi-spl-iac/src/bash/`.

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r63-01-orc-feature-state-dirs)` | no literal box path (developer guide 2.3.1) | 3 actions default their state or log dir to `/var/<org>/<app>/<sub>` (r35 row 05) | `orc:run/spl-workspace-docs-purge.func.sh:36,48,135`<br>`orc:run/prune-docker-images-install-cron.func.sh:8,27`<br>`orc:run/setup-reverse-tunnel.func.sh:30,40`<br>`orc:tests/no-literal-paths.baseline` (3 entries) | 3 files, 7 lines | As r35 row 05: `${PURGE_EXPORT_DIR:-$SPL_VAR_APP_DIR/workspace-docs-purge/...}`, `${PRUNE_CRON_LOG_DIR:-$SPL_VAR_APP_DIR/docker-prune}`, `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`; the comments `:8` and `:135` name the derived dir. The cron line prune-docker installs keeps its path as installed today (the lane prints the crontab line before and after). Tests: the 3 of section 2 (`prune-docker-images`, `reverse-tunnel`, `spl-workspace-docs-purge`), `no-literal-paths`, `spl-run-paths`, `run-eager-files`; `iac:tests/action-header-tags.tst.sh`. **Control:** below. | either | claude | simple_coding | 1 (after r62-02) |
| 02 `refactor(r63-02-orc-key-path-examples)` | as row 01 | two `@example` lines carry a key file path; a comment names the box mount layout (r35 row 06) | `orc:run/spl-desk-up.func.sh:66`<br>`orc:run/spl-m3-e2e.func.sh:85`<br>`orc:run/spl-desk-install-service.func.sh:327,329`<br>`orc:tests/no-literal-paths.baseline` (3 entries) | 3 files, 4 lines | As r35 row 06: `ROOT_KEY_JSON=<root key file>`, no path; the comment says `<var>/<org>` for `/var/csi`. Comment and example lines only; `git diff` shows no executable line. Tests: R2's name match gives 60 files (section 2), matched on the names only: the lane runs `iac:tests/action-header-tags.tst.sh`, `no-literal-paths.tst.sh`, `m3-e2e-none.tst.sh`, `desk-install-service-envs.tst.sh`, `desk-install-service-user.tst.sh`, `boot-cron-gate.tst.sh`, and every test holding a 30-character string of the changed lines (R2 bullet 2; 0 on `e7ff0e347`, the lane re-greps); the other name matches are `NOT RUN` with that reason (C4). **Control:** the ratchet, below. | either | claude | simple_coding | 2 (after 01) |

**Control for both rows** (r35 section 1, unchanged): row 01: on the box the derived dir
equals the old literal (the lane prints both, with APP_PATH unset, a worktree and the
main checkout, and each env override); `SPL_RUN_PATHS_TOP=` (no tree) gives the row's
no-dir answer. Both rows: the fixed files with their baseline entries kept ->
`no-literal-paths.tst.sh` rc 1 `STALE baseline ... drop its line`; deleted -> pass.
Both outputs in the body.

**Re-measure first:** each row lane re-runs the literal grep and the test command of
section 2 on the `origin/master` it starts from and says in its result if they moved.

**Subject** (R6 reads it): `<type>(r63-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r63-NN` (R7, 2.7.4; the line box-free in a commit body).

### 3.1 Batches (R1, R16)

- **Batch 1: row 01, after r62-02 lands.** r62-02 (`c002-r62-02-orc-spawn-place-token-burn-dir`,
  SPL-5910, live, section 3.2) also edits `no-literal-paths.baseline` (R1). Placed
  within 30 minutes of r62-02's landing (R16); the queue can hold it as a dependent
  row: `SPAWN_AFTER=c002-r62-02-orc-spawn-place-token-burn-dir` (one prerequisite,
  `orc:run/spl-spawn-after.func.sh`), `SPAWN_AFTER_DELAY` at most 30.
- **Batch 2: row 02, after row 01 lands**: both edit `no-literal-paths.baseline` (R1);
  `SPAWN_AFTER=c002-r63-01-orc-feature-state-dirs`, within 30 minutes (R16).
- The two rows share no file but the baseline. Neither edits a migration,
  `csi-spl-cnf/`, a workflow, terraform or a file under `csi-spl-wui/`.

### 3.2 Off every live lane, every queued row and every unlanded row (R3)

The 7 written paths: `orc:run/spl-workspace-docs-purge.func.sh`,
`orc:run/prune-docker-images-install-cron.func.sh`, `orc:run/setup-reverse-tunnel.func.sh`,
`orc:run/spl-desk-up.func.sh`, `orc:run/spl-m3-e2e.func.sh`,
`orc:run/spl-desk-install-service.func.sh`, `orc:tests/no-literal-paths.baseline`.

- **Lane map, every machine:** `lane-map.sh --check <the 7, comma separated> --agent c-915`
  at 2026-11-18T17:12:20Z -> **exit 3**: `no-literal-paths.baseline owned by c-908
  c-908-c002-r62-02-orc-spawn-place-token-burn-dir (changed in its worktree; no files
  recorded)`. No other path owned. n=1. That is r62-02 (SPL-5910): its branch carries
  1 commit (`70732f2a5`, `refactor(r62-02-...)`) not yet on `origin/master`. **Row 01
  waits for it** (3.1). The holder's R3 check before each row's spawn governs.
  The panel seat's re-read -> **exit 4**: no lane owns any of the 7 paths, 15 live
  lanes record no files (m-582 N2). Exit 4 is not free; the spawn-time R3 check
  governs. At its read r62-02's branch head was `91b450be9` (still 1 commit off
  `origin/master`, the same 2 files; m-582 N1).
- **Live worktrees on this lane's box** (2026-11-18T17:12:59Z, 267 under the worktree
  root): each one's `git diff --name-only origin/master...HEAD` plus
  `git status --porcelain`, matched against the 7 basenames -> **1 hit**, c-908's
  baseline (above).
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-18T17:12:25Z):
  10 queued, 0 placing, none refactor (bug 2, feature 8). Live share
  `refactor 3 13% (band 10-20%: ok)`; last 24 h `refactor 10% (band 20-30%: UNDER)`;
  `phase day`. The queue as JSON (`SPAWN_QUEUE_FORMAT=json`) grepped for the 6 row
  basenames and `no-literal-paths` -> 0 hits; a queued row carries a summary only, its
  brief is on the box that wrote it.
- **Briefs on this lane's box** changed since W (`find /var/spool-hub/dispatch/briefs
  /var/spool-hub/spawn-remote/briefs -newermt 2026-11-18T14:20:32Z`) that name a row
  basename or the baseline, 2026-11-18T17:12:49Z: 5. This planner's own; r62-01's
  brief and its R7 reviewer's (landed, `b36b20577` / `4ca86a9c3`); r62-02's brief (the
  baseline, its 1 entry; above); the p18 planner's (names r62's files only). None
  names a row 01 or row 02 code file. n=1.
- **Open plans:** `perf-round-18-plan.md` and `bug-round-18-plan.md` on `e7ff0e347`
  name none of the 6 code files (`git grep -l` over them -> 0).
- **Unlanded round rows:** r62-02 (above). r61 rows 01-02 and r62-01 landed.

## 4. Per row: what the lane does

- **r63-01:** After r62-02: the docs-purge, docker-prune and reverse-tunnel dirs are
  derived; 3 baseline entries go.
- **r63-02:** After r63-01: two examples lose a key path, one comment loses the mount
  path; 3 baseline entries go.

## 5. Panel and reviewers (R7)

- Editor: c-915 (claude). Both seats sign the plan sha (rulebook 3.2).
- **Vendor state** (2026-11-18T17:13:33Z, n=1 each, `BOX_PICK_KIND=<k> ./run -a do_spl_box_pick`):
  grok `pick=hold` (weekly 99% >= 95% on both boxes); agy picks the other box (usage
  unknown, placed anyway); mistral picks this lane's box (usage unknown, placed
  anyway); claude picks the other box (weekly 0%).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r63`):
  one **mistral** doc seat, as rounds 35 and 62 (mistral may take docs and reviews,
  owner 10-17, t1 b61851fb msg 91bf8278); else an **agy** seat. The seat reviews this
  plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2): an **agy** seat per row while
  its pick names a box. When it cannot be placed, the holder's call per row, as round
  35 section 5 (r62-01's reviewer was a fresh claude seat under waiver 1a7c70da). Not a
  mistral code R7. The holder re-reads the grok pick before each row's reviewer is
  queued.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 6. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one
(rulebook 4.3), the sites and line numbers of section 2, its R7 reviewer seat, and
"re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r63-01 | `c002-r63-01-orc-feature-state-dirs` | `refactor(r63-01-orc-feature-state-dirs, SPL-<row issue>): ...` | `review/r63-01` | 1, `SPAWN_AFTER=c002-r62-02-orc-spawn-place-token-burn-dir` |
| r63-02 | `c002-r63-02-orc-key-path-examples` | `refactor(r63-02-orc-key-path-examples, SPL-<row issue>): ...` | `review/r63-02` | 2, `SPAWN_AFTER=c002-r63-01-orc-feature-state-dirs` |

**r63-01 brief, Files: ONLY** `orc:run/spl-workspace-docs-purge.func.sh`,
`orc:run/prune-docker-images-install-cron.func.sh`, `orc:run/setup-reverse-tunnel.func.sh`,
`orc:tests/no-literal-paths.baseline` (the 3 entries of these files). Do: plan section 3
row 01 verbatim; control as section 3 (derived dir = old literal in a worktree and the
main checkout, APP_PATH unset, each override; `SPL_RUN_PATHS_TOP=`; baseline kept -> rc
1 STALE, deleted -> pass); print the prune-docker crontab line before and after. Gates:
the 3 row tests, `no-literal-paths`, `spl-run-paths`, `run-eager-files`,
`action-header-tags`; `cd csi-spl-iac && ./run -a do_check_pre_push`.

**r63-02 brief, Files: ONLY** `orc:run/spl-desk-up.func.sh`, `orc:run/spl-m3-e2e.func.sh`,
`orc:run/spl-desk-install-service.func.sh`, `orc:tests/no-literal-paths.baseline` (the 3
entries of these files). Do: plan section 3 row 02 verbatim; comment and `@example`
lines only (`git diff` shows no executable line). Gates: the 6 named tests, the
30-character-string tests it finds, the rest of the 60 name matches `NOT RUN` with the
reason; the baseline control; `cd csi-spl-iac && ./run -a do_check_pre_push`.

## 7. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash 2) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: row 01 (after r62-02); batch 2: row 02 (the baseline) |
| `no-literal-paths` baseline | 11 files / 23 lines -> 10 / 21 after r62-02 -> 7 / 14 after r63-01 -> 4 / 10 after r63-02 |
| measured on | `e7ff0e347`, n=1 per command unless stated |

The 4 files left after this round are round 35's "left out" (its section 6):
`spl-reflection-gather`, `spl-cmd-guard-mode`, `fleet-logrotate-install`,
`spl-file-erase`; round 35 is then served in full.

## 8. Changes

- v0.1 (c-915): first draft. Two rows, ex r61-05 and r61-06 of round 35's signed plan,
  cited, not re-planned; re-measured on `e7ff0e347`: both rows unchanged (no commit on
  their 6 files since `f284b4148`, same lines, same test lists 4 and 60). Window W and
  the r63 slug proof recorded. Row 01 waits for r62-02 (live, the baseline).
- v1.0 (c-915): the panel seat m-582 (mistral) passed v0.1 `621788d9b`, W none, N1-N4
  notes. N1 (r62-02's branch head moved to `91b450be9`) and N2 (lane map exit 4 on its
  re-read) are recorded in 3.2. N3 (row 01 names 7 line sites in 3 files, rulebook 3.1
  says at most 5) is round 35's signed row 05 shape, read as at most 5 files: no change.
  N4 (its re-read of every site line and the baseline on a newer `origin/master`,
  `232902108`: identical, 11 / 23): no drift. Status line and sections 3.2, 8 and 9
  only.

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-915 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-582 (mistral) PASS** on `621788d9b2f9ce68b53b6c36074d2755e000a2fa`
  (spool msg 559ea34e, task `dispatch-refactor-r63`); seat file
  `csi-spl-doc/doc/md/refactor-round-63/seat-mistral.md` on branch
  `review/c003-refactor-round-63-mistral-seat` (`258760a21`). W: none. N1-N4: notes,
  rows unchanged.
- Row R7 seats: section 5.
- v1.0 signed: **m-582 (mistral) PASS** on `cc2d7a91ee98c81d118aeaabac6c929f5b169445`
  (spool msg ba958eff), seat file `b5b96a5bd`. W: none; N1-N4 stand as folded.

## 10. Close

- v1.0 `cc2d7a91e` (the sha m-582 signed) is on `origin/master`; workflow 10 on it
  succeeded (run 44365338095).
- The holder c-002@sat ACCEPTED this editor seat (msg 07855387) and queued rows
  r63-01 and r63-02 (asks 9f26ba0f, 8c6a5ecd) in the 3.1 order.
