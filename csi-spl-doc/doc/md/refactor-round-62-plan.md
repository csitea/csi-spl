# Refactoring round 62 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5885  
Topic: 7f658d58-4b41-4b39-be56-a1a691ee4351  
Discussion: 7f658d58-4b41-4b39-be56-a1a691ee4351 (t1 #refactoring, "Refactor round 62", opener msg a6a072b8)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r62**, plan `refactor-round-62-plan.md`, rows `r62-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Refactor round 35 ([refactor-round-35-plan.md](refactor-round-35-plan.md),
v1.0, panel m-392 mistral PASS) planned 6 rows `r61-01..06`. Under the new cadence
(SPL-5879, rulebook 5) it is split: rows 01 and 02 landed as r61, **r62 = ex r61-03 +
ex r61-04**, and ex r61-05 + r61-06 are a later round (r63). **The rows are not
re-planned here: each one cites round 35's signed row** (its section 3 cell, 3.1-3.3
and 4); this plan only re-measures each row's sites, its literal grep and its test
list on today's `origin/master` and says what moved (section 2).

**Status: v0.2**, draft for the panel (section 5); v0.1 `aa8f25ec4` was the sha queued for the panel, v0.2 folds the holder's overlap read (section 8). Editor: **c-815** (claude).

**One sha:** every count is measured on **`04ca1d897`** (`origin/master`
04ca1d8970f6fe8899a24d42b814a777697387e6, 2026-11-18T12:36:36Z), n=1 per command
unless stated. Reads are on that sha with `git show` / `git grep`. Queue, lane map and
vendor readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-18T10:17:09+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(refactor-round-35-plan'`
  (the r62-only scope of 5.3) -> commit `08efd6484` "refactor round 35 plan v1.0, panel
  m-392 mistral PASS on v0.2 a73b73d47". Every later read of r62 uses this W.
- **`r62` is free** (2026-11-18T13:49:46Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r62-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r62-*' 'refs/heads/wip/*r62*' 'refs/heads/*-r62-*'`
    -> **nothing**; `git ls-remote origin 'refs/heads/*r62*' 'refs/heads/*round-62*'`
    -> nothing.
  - `grep -rlE 'r62-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote`
    on this lane's box -> 1 file, this planner's own brief. On the holder's box the
    holder ran it over `dispatch/briefs` (c-002, msg e32b6d60) -> only
    `c002-refactor-round-62-planner.md`; `spawn-remote` does not exist there.
  - Control: the same log read for `r61` -> 3 lines (`954b10ad5`, `dfe7fd9a1`,
    `61bdcbd1c`), so the read sees a used id.
- **No `refactor-round-62*` file** exists under `csi-spl-doc/doc/md` on `04ca1d897`, so
  the plan takes the plain name (5.3 "Files").

### 1.2 The round 35 shas after the history rewrite (R15)

`origin/master` was rewritten on 2026-11-18 (`git reflog show origin/master` ->
`forced-update` at 11:16Z). The shas this round's brief names are no longer ancestors
of `origin/master`; resolved by subject (R15), n=1 each:

| brief sha | on `04ca1d897` | subject |
|---|---|---|
| `e563bf623` (r35 plan v1.0, signed) | `08efd6484` | `docs(refactor-round-35-plan, SPL-5831): ... v1.0 ...`; `git diff --quiet e563bf623 08efd6484 -- <the plan>` -> no difference |
| `cebfa7004` / `2e55f493d` | `954b10ad5` / `dfe7fd9a1` | `refactor(r61-01-orc-uplink-probe-exit-text, SPL-5868)` |
| `89b331061` | `61bdcbd1c` | `refactor(r61-02-orc-login-check-dir-callers, SPL-5870)` |
| `b33f2a306` | `dc3f39027` | `docs(rounds, SPL-5879)`, the cadence rule |

Round 35's own measurement sha `f284b4148` is off `origin/master` now too; this plan's
diffs against it read the object, which is still in the local store.

## 2. The rows, re-measured on `04ca1d897`

The literal grep, per file (round 35 section 2):
`git grep -nE '/(opt|var)/csi($|[^A-Za-z0-9_-])' 04ca1d897 -- <file>`.

| row | ex | sites on `f284b4148` (r35) | sites on `04ca1d897` | moved? |
|---|---|---|---|---|
| r62-01 | r61-03 | `orc:run/install-box-crons.func.sh:36,51`, `orc:run/spl-box-state-backup.func.sh:11,163,204`, `utl:run/external-api-health.func.sh:28,62` (7 lines, 3 files) | the same 7 lines, 3 files | **no**: no commit touched the 3 files since (`git log f284b4148..04ca1d897 -- <the 3>` -> 0) |
| r62-02 | r61-04 | `orc:run/spl-spawn-place.func.sh:206,672` (2 lines) | `orc:run/spl-spawn-place.func.sh:213,684` (the `@param TOKEN_BURN_STATE_DIR` line, and `f="${TOKEN_BURN_STATE_DIR:-/var/csi/csi-spl/token-burn}/buckets.tsv"` in `spl_spawn_place_progress`) | **lines only**: shifted +7 and +12 by SPL-5874 (`510c1f5a7` spec 157 4.2, +14 -1; `0d2e3d37c`, +1 -1), at other hunks (`git log --numstat f284b4148..04ca1d897 -- <it>`); the literal and the `[[ -r "$f" ]] \|\| return 1` after it (`:685`) are unchanged |

**The baseline:** `git show 04ca1d897:csi-spl-orc/src/bash/tests/no-literal-paths.baseline | grep -vE '^\s*(#|$)' | awk '{s+=$1} END{print NR, s}'`
-> **14 files, 30 lines** (r35 read 17 / 34; r61-02 took 3 files / 4 lines). The row
files' entries in it: `2 install-box-crons.func.sh`, `3 spl-box-state-backup.func.sh`,
`2 external-api-health.func.sh` (r62-01: 3 entries, 7 lines go), `2 spl-spawn-place.func.sh`
(r62-02: 1 entry, 2 lines go).

**The helpers** (round 35 section 1, "the derived form"), on `04ca1d897`:
- `spl_uplink_probe_dir` is at `orc:run/spl-uplink-probe.func.sh:77` (r35: `:73`; moved by
  r61-01). Its order is `UPLINK_PROBE_DIR`, else `${BOX_CRONS_STATE_DIR}/uplink-probe`,
  else `${SPL_VAR_APP_DIR}/uplink-probe`, else FATAL rc 1: the same order
  external-api-health's `:62` reads today after its own `EXTERNAL_API_DIR`.
- `spl_token_burn_state_dir` is at `orc:run/spl-token-burn-collect.func.sh:37` (unchanged).
  It calls `spl_run_paths` without sourcing it, so its caller sources
  `orclib:spl-run-paths.func.sh` first (the `declare -F ... || source` form).
- The utl source form: `utl:run/orphan-process-reap.func.sh:58` (unchanged).

**The tests (R2, C4)**, round 35's 3.3 command with `NAMES` the row's basenames, on
`04ca1d897`:

`pat=$(for n in $NAMES; do printf '%s' "|\b$n(\.func\.sh)?([^a-z0-9_-]|\$)|\bdo_${n//-/_}\b"; done); git grep -lE "${pat#|}" 04ca1d897 -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' 'csi-spl-utl/**/tests/*' | grep -v baseline`

- r62-01 -> **11** files, as r35 (1 of them `orc-shard-weights.txt`, not a test).
- r62-02 -> **15** files (r35: 14). New: `orc:tests/spl-spawn-after.tst.sh` (SPL-5874,
  `510c1f5a7`); a `diff` against the same command on `f284b4148` shows only that line.

## 3. The 2 rows

Each cell is round 35's signed row ([refactor-round-35-plan.md](refactor-round-35-plan.md)
section 3, rows 03 and 04), with the line numbers and the test list of section 2 above.
Paths: `orc:` = `csi-spl-orc/src/bash/`, `orclib:` = `csi-spl-orc/lib/bash/funcs/`,
`utl:` = `csi-spl-utl/src/bash/`, `iac:` = `csi-spl-iac/src/bash/`.

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r62-01-orc-box-crons-state-root)` | no literal box path (developer guide 2.3.1) | the box crons' state root defaults to `/var/<org>/<app>` in 3 files (r35 row 03) | `orc:run/install-box-crons.func.sh:36,51`<br>`orc:run/spl-box-state-backup.func.sh:11,163,204`<br>`utl:run/external-api-health.func.sh:28,62`<br>`orc:tests/no-literal-paths.baseline` (3 entries) | 3 files, 7 lines | As r35 row 03: `${BOX_CRONS_STATE_DIR:-$SPL_VAR_APP_DIR}`; external-api-health's dir is `${EXTERNAL_API_DIR:-<the uplink probe's dir>}` through `spl_uplink_probe_dir` (`:77`), sourcing the orc files as orphan-process-reap does; the backup's `:11` description says `<SPL_VAR_APP_DIR>`. Tests: the 10 of section 2 (`install-box-crons`, `spl-box-state-backup`, `spl-box-state-restore`, `boot-cron-gate`, `box-name-from-cnf`, `cron-no-stack`, `reliability-checks-cron`, `spl-box-deploy`, `utl:tests/external-api-health.tst.sh`, `box-crons-desk-reach.py`), `no-literal-paths`, `spl-run-paths`, `run-eager-files`. **Control:** below. | either | claude | simple_coding | 1 |
| 02 `refactor(r62-02-orc-spawn-place-token-burn-dir)` | as row 01 | the placer reads the token-burn dir from a literal (r35 row 04) | `orc:run/spl-spawn-place.func.sh:213,684`<br>`orc:tests/no-literal-paths.baseline` (1 entry) | 1 file, 2 lines | As r35 row 04: `:684` reads the dir from `spl_token_burn_state_dir` (sourced on first use, `spl-run-paths` first); no dir -> `return 1` (no progress proof), as an unreadable file does today at `:685`. Tests: the 15 of section 2, `spl-token-burn-collect.tst.sh`, `no-literal-paths`, `spl-run-paths`, `run-eager-files`. **Control:** below, plus: a fixture `buckets.tsv` under the derived dir gives the same progress verdict before and after. | either | claude | simple_coding | 2 (after 01) |

**Control for both rows** (r35 section 1, unchanged): on the box the derived dir equals
the old literal (the lane prints both, with APP_PATH unset, a worktree and the main
checkout, and each env override); `SPL_RUN_PATHS_TOP=` (no tree) gives the row's
no-dir answer; the fixed files with their baseline entries kept ->
`no-literal-paths.tst.sh` rc 1 `STALE baseline ... drop its line`; deleted -> pass.
Both outputs in the body.

**Re-measure first:** each row lane re-runs the literal grep and the test command of
section 2 on the `origin/master` it starts from and says in its result if they moved.

**Subject** (R6 reads it): `<type>(r62-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r62-NN` (R7, 2.7.4; the line box-free in a commit body).

### 3.1 Batches (R1, R16)

- **Batch 1: row 01.** Its prerequisites in r35 (rows 01 and 02, for
  `spl_uplink_probe_dir` and the baseline) are landed (section 1.2).
- **Batch 2: row 02, after row 01 lands**: both edit `no-literal-paths.baseline` (R1);
  placed within 30 minutes of row 01's landing (R16). The queue can hold it as a
  dependent row: `SPAWN_AFTER=c002-r62-01-orc-box-crons-state-root`, the placement
  slug, whose brief `<slug>.md` the placer reads (`orc:run/spl-spawn-after.func.sh`,
  spec 157 4.2, SPL-5874), with `SPAWN_AFTER_DELAY` at most 30.
- **Row 02 also waits for bug ask `1801656f`** (`c002-spl5874-held-row-end-and-alarm`,
  section 3.2): both edit `orc:run/spl-spawn-place.func.sh` (R1). The dependent row
  takes ONE prerequisite (`spl_spawn_after_of` reads one `After:` line, `| tail -1`),
  so the holder queues row 02 with `SPAWN_AFTER` on row 01 only once that bug row's
  issue has landed (or, if row 01 lands first, with `SPAWN_AFTER=<the bug row's issue
  key>`). Row 01 does not touch that file and does not wait.
- The two rows share no file but the baseline. Neither edits a migration,
  `csi-spl-cnf/`, a workflow, terraform or a file under `csi-spl-wui/`.

### 3.2 Off every live lane, every queued row and every unlanded row (R3)

The 5 written paths: `orc:run/install-box-crons.func.sh`,
`orc:run/spl-box-state-backup.func.sh`, `utl:run/external-api-health.func.sh`,
`orc:run/spl-spawn-place.func.sh`, `orc:tests/no-literal-paths.baseline`.

- **Lane map, every machine:** `lane-map.sh --check <the 5, comma separated> --agent c-815`
  at 2026-11-18T13:50:34Z -> **`free`, exit 0**. n=1. (r35 read exit 4, 13 `unknown:`
  lanes on the other box; today none.)
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-18T13:50:42Z):
  15 queued, 0 placing, none refactor. Live share `refactor 2 15% (band 10-20%: ok)`;
  last 24 h `refactor 10% (band 20-30%: UNDER)`; `phase day`. Each queued row
  (`SPAWN_QUEUE_FORMAT=json`, the `queue` array) grepped for the 5 basenames and
  `token-burn` -> 0 hits; but a queued row carries a summary only, its brief is on the
  box that wrote it. **One queued row touches row 02's file**: ask `1801656f`,
  `c002-spl5874-held-row-end-and-alarm` (bug row, SPL-5874 follow-up). Its brief is on
  the holder's box; the holder read it (c-002, msg e32b6d60): line 17, item N1, edits
  `orc:run/spl-spawn-place.func.sh` (it names `spl_spawn_place_seat_alarm`, no line);
  its scope is two func files, their tests and spec 157. **Row 02 waits for it** (3.1).
  Not read by this lane; the holder's reading, n=1.
- **Briefs on this lane's box** changed since W (`find /var/spool-hub/dispatch/briefs
  /var/spool-hub/spawn-remote/briefs -newermt 2026-11-18T08:17:09Z`) that name a row
  basename, 2026-11-18T13:51:05Z: 4. This planner's own; the p17 planner (SPL-5872)
  and p17-02 (`do_spl_lane_mix`), which both name `spl-spawn-place.func.sh` only to stay
  off it ("refactor round 35 row 04 ... not landed"); SPL-5874's feature brief, landed
  (`510c1f5a7`). The p17 plan's section 6 leaves `spl_spawn_place_brief`'s `| tail -1`
  to a later perf round once this row (ex r61-04) lands. n=1.
- **Unlanded round rows:** r61 rows 01 and 02 landed (section 1.2); ex r61-05 and
  r61-06 are r63 and also edit the baseline (r35 section 3), so r63's rows are placed
  after row 02 lands (R1). Perf round 17: `p17-01` landed (`b97a764ff`), `p17-02` is
  not on `origin/master` (`git log origin/master -E --grep='\(p17-02'` -> 0); its brief
  keeps off `spl-spawn-place.func.sh`.

## 4. Per row: what the lane does

- **r62-01:** The box crons' state root is derived in install-box-crons, the state
  backup and external-api-health; 3 baseline entries go.
- **r62-02:** After r62-01: the placer reads the token-burn dir from its helper; 1
  baseline entry goes.

## 5. Panel and reviewers (R7)

- Editor: c-815 (claude). Both seats sign the plan sha (rulebook 3.2).
- **Vendor state** (2026-11-18T13:52:30Z, n=1 each, `BOX_PICK_KIND=<k> ./run -a do_spl_box_pick`):
  grok `pick=hold` (weekly 99% >= 95% on both boxes); agy picks this lane's box (usage
  unknown, placed anyway); mistral picks the other box (usage unknown, placed anyway);
  claude picks this lane's box.
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r62`):
  one **mistral** doc seat, as round 35's m-392 (mistral may take docs and reviews,
  owner 10-17, t1 b61851fb msg 91bf8278); else an **agy** seat. The seat reviews this
  plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2): an **agy** seat per row while
  its pick names a box. When it cannot be placed, the holder's call per row, as round
  35 section 5. Not a mistral code R7. The holder re-reads the grok pick before each
  row's reviewer is queued.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 6. Proposed row briefs

The ready brief for ex row 03 (`briefs/c002-r61-03-orc-box-crons-state-root.md`) is on
the holder's box; it is **not on this lane's box** and was not read. Its slug, subject
and review branch move as below; the rest of each brief carries the plan row verbatim
(R4):

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r62-01 | `c002-r62-01-orc-box-crons-state-root` | `refactor(r62-01-orc-box-crons-state-root, SPL-<row issue>): ...` | `review/r62-01` | 1 |
| r62-02 | `c002-r62-02-orc-spawn-place-token-burn-dir` | `refactor(r62-02-orc-spawn-place-token-burn-dir, SPL-<row issue>): ...` | `review/r62-02` | 2, `SPAWN_AFTER=c002-r62-01-orc-box-crons-state-root`, queued once bug ask `1801656f` has landed (3.1) |

Each brief also carries `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one
(rulebook 4.3), the sites and line numbers of section 2 (not r35's), its R7 reviewer
seat, and "re-measure first".

## 7. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash 2) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: row 01; batch 2: row 02 (the baseline) |
| `no-literal-paths` baseline | 14 files / 30 lines -> 11 / 23 after r62-01 -> 10 / 21 after r62-02 |
| measured on | `04ca1d897`, n=1 per command unless stated |

## 8. Changes

- v0.1 (c-815): first draft. Two rows, ex r61-03 and r61-04 of round 35's signed plan,
  cited, not re-planned; re-measured on `04ca1d897`: r62-01 unchanged, r62-02's lines
  moved (206 -> 213, 672 -> 684) and its test list grew by `spl-spawn-after.tst.sh`.
  Window W and the r62 slug proof recorded; the brief's round 35 shas resolved by
  subject after the 2026-11-18 rewrite (R15).
- v0.2 (c-815), from the holder c-002 (msg e32b6d60): bug ask `1801656f` edits
  `spl-spawn-place.func.sh`, so row 02 also waits for it (3.1, 3.2, 6); `SPAWN_AFTER`
  names the placement slug `c002-r62-01-...` (v0.1 wrote the row slug) and takes one
  prerequisite; the holder's slug grep on its box recorded (1.1). Rows unchanged.

## 9. Consensus

Both seats sign this plan (rulebook 3.2).

- Editor seat: c-815 (claude): v0.1, v0.2.
- Panel reviewer seat: requested (section 5).
