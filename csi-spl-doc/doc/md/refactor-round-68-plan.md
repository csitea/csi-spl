# Refactoring round 68 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-5982  
Topic: 0a622877-52ce-4ed3-b2e9-a11d95d602fb  
Discussion: 0a622877-52ce-4ed3-b2e9-a11d95d602fb (t1 #refactoring, "Refactor round 68", opener msg 469e43b8)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r68**, plan `refactor-round-68-plan.md`, rows `r68-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 67 ([refactor-round-67-plan.md](refactor-round-67-plan.md),
v1.1, signature commit `bb5657d3f`): r67-01 landed `1d0c30d99` (SPL-5972), r67-02 landed
`c4c841171` (SPL-5974), r67-03 (SPL-5975, `review/r67-03` = `b07291555`) is in R7
review, not landed. r67 hands no signed row on, so r68 is a fresh round. The perf floor
(rulebook 4.4) read `perf 29 refactor 96 perf-share 23.2% floor-met` on `23864a224`
(the holder's read), so the next round is a refactor round.

r67-01 and r67-02 took the SC2034 lines under `csi-spl-iac/` that no code reads. This
round takes the same ratchet (`.shellcheck-warning-baseline.txt`, developer guide 2.4.3)
into `csi-spl-orc/`: test files that capture a value with `$(...)`, or read a field,
only for its side effect, and never read the variable. Both rows are test code only, no
action, no lib.

**Status: v0.2, draft**, for the panel (rulebook 3.2). Editor: **c-526** (claude). No row
lane starts before the panel signs the plan sha.

**One sha:** every count is measured on **`23864a224`** (`origin/master`
23864a22465b2c8409da9129614d07bc8a3ffc2f, committed 2026-11-19T19:11:16+02:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep`, shellcheck
0.10.0 and the tests on this lane's worktree at that sha. Queue, lane map, brief and
vendor readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-19T16:42:53+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r67-plan'` -> commit
  `bb5657d3f` "refactor round 67 plan records the v1.1 signature, m-977 mistral PASS on
  38b7f1596". Every later read of r68 uses this W.
- **`r68` is free** (2026-11-19T17:28:40Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r68-'` -> **0**.
  - `git ls-remote origin 'refs/heads/review/r68-*' 'refs/heads/wip/*r68*' 'refs/heads/*-r68-*'`
    -> **nothing** (rc 0).
  - `grep -rlE 'r68-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote/briefs`
    (run as root) on this lane's box -> **0 files**. The other box's briefs were not
    read by this lane (the holder read them all 0 at 17:2xZ).
  - Control: the same log read for `r67` -> 2 lines (`c4c841171` r67-02, `bb5657d3f`
    the plan; r67-01 `1d0c30d99` is older than this W), so the read sees a used id.
- **No `refactor-round-68*` file** exists under `csi-spl-doc/doc/md` on `23864a224`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-68` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The candidates, re-measured

| input | source | on `23864a224` | here |
|---|---|---|---|
| `.shellcheck-warning-baseline.txt` | the ratchet (2.4.3), r67 section 7 | `grep -vcE '^\s*(#\|$)'` -> **80 lines**: SC2034 35, SC2154 20, SC2120 7, SC1090 5, SC2088 4, SC2046 3, SC2319 2, SC2164 2, SC2155 2. SC2034: 4 iac (r67 section 7 left them), 31 orc | **rows 01 and 02** (1.3), the rest section 7 |
| Go clean-code gate `wideFuncs`: `MoveMessage`, `MergeTopic` pairs | r67 section 7, "input for round 68" | `git grep -nE '\bMoveMessage\(' origin/master -- '*.go' \| wc -l` -> 28, `MergeTopic` -> 19. Each row deletes its 2 lines in `api:internal/cleancode/cleancode_test.go`, a file the unlanded r67-03 also edits (`git diff --name-only origin/master...b07291555` lists it) | left out (R3, section 7): after r67-03 lands |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | r67 section 7 | 63 positional caller lines in 35 files (r67's read on `86babad74`), a WUI row with its e2e gate | left out (section 7) |
| `no-literal-paths.baseline` | the brief | `git show 23864a224:csi-spl-orc/src/bash/tests/no-literal-paths.baseline \| grep -vcE '^\s*(#\|$)'` -> **1**, `spl-file-erase.func.sh`: a deny list r66 and r67 ruled a behaviour change | left out (section 7) |
| r67 R7 findings | the brief | the r67 plan's panel notes N1-N9 are folded (its section 8: no change asked); the row R7 seat files of r67-01 and r67-02 were not read by this lane; r67-03's review is open | nothing taken; the holder may add one |
| the dispatcher's candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`) | the brief | on the other box; this lane could not read it (`ls` -> No such file on this box) | the holder checks it for a refactor-shaped item (section 7) |
| spec 011 tasks | the brief | the spec folder unchanged since W (`git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0) | left out (section 7), r65 to r67's reasons hold |

### 1.3 The SC2034 sites

`shellcheck -S warning -i SC2034 -f gcc <file>` on the orc files the baseline lists under
SC2034. The rows take the ones in test files where the variable is a capture or a read
field kept only for its side effect, and no line reads it:

| file:line | variable | read anywhere? | here |
|---|---|---|---|
| `orc:tests/release-stable.tst.sh:46,48,49,78` | `c1`, `c3`, `c4`, `c6` = `$(commit "<subject>" [file])`: the fixture commit is the point, the sha is not | `grep -nE '\$(c1\|c3\|c4\|c6)\b\|\$\{(c1\|c3\|c4\|c6)'` in the file -> **0**; `c2`, `c5` are read (`vtag`, `:52`, and the `want $c5` checks) and stay | **row 01** |
| `orc:tests/responder-run.tst.sh:120` | `i`, the counter of `for i in 1 2 3 4` (four sweeps) | the loop body never reads it | **row 01** |
| `orc:tests/spec-import-issues.tst.sh:504` | `item`, `labels`, `desc` in `IFS=$'\x1f' read -r action item ref pkey pitem status labels desc kind title_b64` | the check at `:506` reads `action ref pkey pitem status kind title`; the 3 fields hold their column only | **row 01** |
| `sa:tests/test-agent-watch.sh:22,25,26,27,29` | `P1`, `P4`, `P5`, `P6`, `P8` = `$(agent ...)` / `$(t_window ...)` (the window is the point; the helper prints its pane id) | `grep -nE '\bP[0-9]+\b'` in the file: `P2`, `P3`, `P7` are read (`:40-51`); these 5 only at their assignment | **row 02** |
| `sa:tests/test-agent-top.sh:40` | `P6` = `$(t_window 'tbx: AGY-11 legacy' ...)` | `grep -nE '\bP6\b'` -> `:40` only; `:41` already writes the same kind of window as `t_window 'notes' 'sleep 600' >/dev/null` | **row 02** |
| `sa:tests/test-strip-agy-optin.sh:47,52` | `P4`, `P5` = `$(t_window AGY-7x 'sleep 600')` | `grep -nE '\bP[45]\b'` -> the two assignments only | **row 02** |
| `sa:tests/test-strip-two-envs.sh:107` | `P91` = `$(t_window CLE-91 'sleep 600')` | `grep -n P91` -> `:107` only | **row 02** |

The helpers keep no state in the caller's shell, so dropping the `$(...)` subshell
changes nothing but the discarded stdout: `commit()` (`orc:tests/release-stable.tst.sh:29-34`)
uses `local` only and prints the sha last; `t_window()` (`sa:tests/lib.inc.sh:86-88`) is one
`tmux new-window -P -F '#{pane_id}'`; `agent()` (`sa:tests/test-agent-watch.sh:20`) calls
`t_window`. Each file runs under `set -uo pipefail` (no `-e`), so the exit status of the
bare call is not acted on, as the assignment's was not.

The gate: `do_sec_shellcheck` (`iac:run/sec-shellcheck.func.sh`) holds the count per
(code, file) **equal** to the baseline: a new pair fails, and so does a count below its
line. So each row drops its baseline lines in the same commit, and the red control is
that drop left out (r67-01, r67-02).

### 1.4 The tests (R2, C4)

`NAMES` = the row's basenames:
`for n in $NAMES; do git grep -lE "\b$n(\.sh|\.tst\.sh)?([^a-z0-9_-]|$)" 23864a224 -- 'csi-spl-orc/**/tests/*' 'csi-spl-iac/**/tests/*' 'csi-spl-utl/**/tests/*' 'csi-spl-api/**/tests/*' '.github/workflows/*'; done`

- r68-01 (`release-stable responder-run spec-import-issues`) -> `orc-shard-weights.txt`
  (a weight per test name, not a test), `.github/workflows/55_release-stable.yml` (its
  concurrency group name), `test-spool-test-guard.sh` (a comment) and
  `desk-agent-ids.tst.sh` (the action `spl-responder-run.func.sh`),
  `spec-tasks-reconcile.tst.sh` (the script `spec-import-issues.py`): none reads a
  changed line. The column is the three test files.
- r68-02 (`test-agent-watch test-agent-top test-strip-agy-optin test-strip-two-envs`) ->
  each file names only itself; `sa:tests/run-all-tests.sh` runs them by its
  `test-*.sh` glob (`:10`). The column is the four test files.
- Both rows, the gate's readers of the baseline (r67 1.4): `sec-shellcheck.tst.sh`,
  `sec-shellcheck-par.tst.sh`, `check-pre-push-lint.tst.sh` write their own fixture
  baseline; `action-header-tags.tst.sh` names the file in a comment. None reads the
  real lines. The row runs `sec-shellcheck.tst.sh`.
- **Before**, on `23864a224` (this lane, n=1, `SPOOL_TEST=1`, as the box user):
  `release-stable.tst.sh` rc 0, 12 `^PASS` lines, `fails=0`; `responder-run.tst.sh`
  rc 0, 14 `^PASS` lines, `ALL PASS`; `spec-import-issues.tst.sh` rc 0, 81 `^PASS`
  lines, `ALL PASS`; `test-agent-watch.sh` `12 passed, 0 failed`; `test-agent-top.sh`
  `40 passed, 0 failed`; `test-strip-agy-optin.sh` `15 passed, 0 failed`;
  `test-strip-two-envs.sh` `21 passed, 0 failed`. Each row's after counts match these.
- The gate itself: `cd csi-spl-iac && ./run -a do_check_pre_push_lint` (its
  `lint-shellcheck` part, touched files) and `.github/workflows/67_shellcheck.yml`.

## 2. The 2 rows

Paths: `orc:` = `csi-spl-orc/src/bash/`, `sa:` = `csi-spl-orc/src/bash/features/spawn-agents/`,
`iac:` = `csi-spl-iac/src/bash/`, `base:` = `.shellcheck-warning-baseline.txt` (repo root).

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r68-01-orc-tests-shellcheck-dead-vars)` | bash that fails safely (developer guide 2.4.3): the shellcheck WARNING ratchet only shrinks | three orc tests keep a capture, a loop counter or read fields no line reads; each file's baseline line would hide a real new SC2034 there | `orc:tests/release-stable.tst.sh:46,48,49,78`<br>`orc:tests/responder-run.tst.sh:120`<br>`orc:tests/spec-import-issues.tst.sh:504`<br>`base:` its 3 SC2034 lines | 3 files, 8 warnings | `c1=$(commit ...)` -> `commit ... >/dev/null` (the 4 lines; `c2`, `c5` stay); `for i in` -> `for _ in`; `read -r action item ref pkey pitem status labels desc kind title_b64` -> `read -r action _ ref pkey pitem status _ _ kind title_b64`. The 3 lines `SC2034\|<file>\|<n>` leave `base:`. **Red control:** sites fixed, baseline left -> `do_sec_shellcheck` FAILS (a count below its line) on the 3 pairs; lines dropped -> PASS. **Behaviour:** each test's rc and PASS count the same before and after (1.4), both in the body. Tests: the three files, `iac:tests/sec-shellcheck.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push_lint`. | either | claude | simple_coding | 1 |
| 02 `refactor(r68-02-spawn-tests-shellcheck-pane-ids)` | as row 01 | four spawn-agents tests keep a pane id they never read; the file already shows the form for a window kept only for its side effect (`test-agent-top.sh:41`, `>/dev/null`) | `sa:tests/test-agent-watch.sh:22,25-27,29`<br>`sa:tests/test-agent-top.sh:40`<br>`sa:tests/test-strip-agy-optin.sh:47,52`<br>`sa:tests/test-strip-two-envs.sh:107`<br>`base:` its 4 SC2034 lines | 4 files, 9 warnings | each `Pn="$(agent ...)"` / `Pn="$(t_window ...)"` of 1.3 -> the same call `>/dev/null`; the read `P2`, `P3`, `P7` stay. The 4 lines leave `base:`. **Red control:** as row 01, for the 4 pairs. **Behaviour:** each test's `N passed, 0 failed` the same before and after (1.4), both in the body. Tests: the four files, `bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh` (a test red on the parent too is named, not fixed), `iac:tests/sec-shellcheck.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push_lint`. | either | claude | simple_coding | 2 (after 01) |

**Re-measure first:** each row lane re-runs `shellcheck -S warning -i SC2034 -f gcc` on its
files and the baseline grep of 1.2 on the `origin/master` it starts from, and says in its
result if they moved. A fix that unmasks another warning (r67-01's `tf_proj` SC2154) is
handled as r67's row-scope note did: the lane reports it and the editor records it.

**Subject** (R6 reads it): `<type>(r68-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r68-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** no documented behaviour changes, test code only: each row carries
`Docs: none (<why>)`. The baseline's header stays true.

### 2.1 Batches (R1, R16)

- **Batch 1: row 01.** Nothing it touches is held by a live or queued lane (2.2).
- **Batch 2: row 02, after row 01 lands**: both rows edit `base:`, so R1 serialises
  them. Queued as `SPAWN_AFTER=c002-r68-01-orc-tests-shellcheck-dead-vars`, within 30
  minutes (R16). Row 02 reads no line row 01 changes; the order is the shared file only.
- No row edits an action, a lib, a migration, `csi-spl-cnf/`, a workflow, terraform or
  a file under `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

The 8 written paths: `orc:tests/release-stable.tst.sh`, `orc:tests/responder-run.tst.sh`,
`orc:tests/spec-import-issues.tst.sh`, `sa:tests/test-agent-watch.sh`,
`sa:tests/test-agent-top.sh`, `sa:tests/test-strip-agy-optin.sh`,
`sa:tests/test-strip-two-envs.sh`, `base:`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-526`, one call per
  path, 2026-11-19T17:29:24Z, n=1 -> **exit 4** for each: no live lane lists any of
  them; one live lane records no files, c-946 (WUI calendar, members' entries; the
  brief places it under api `internal/hub/calendar*`): it writes no row path. The
  holder's R3 check before each row's spawn governs.
- **The live lanes the brief names** (17:2xZ): r67-03 (its 9 api files, store fleet
  lease, `crosstenant_test.go`, hub box lease, `cleancode_test.go`), spec 179 B1
  SPL-5980 (a new rdb migration, api store topic pauses, `crosstenant_test.go`),
  SPL-5963 (api `internal/hub/calendar*`): api and rdb paths, none under `csi-spl-orc/`
  or `base:`. This is why the `wideFuncs` pairs wait (section 7).
- **Commits:** `git log origin/master --since="$W" -- <the 8 paths>` -> **1**,
  `c4c841171` (r67-02, landed, `base:`). The newest change of each other path:
  `f2ec7d955` (09-29, `release-stable`), `35458b740` (10-10, `responder-run`),
  `b3fc696fd` (10-31, `spec-import-issues`), `1d5843c62` (10-18, `test-agent-watch`),
  `a454a2a66` (11-12, `test-agent-top`), `8c8e1530b` (09-25, `test-strip-agy-optin`),
  `f4d5776b1` (10-11, `test-strip-two-envs`).
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 2026-11-19T17:29:58Z):
  **0 queued, 0 placing**. Live share `refactor 3 21% (band 10-20%: OVER)`; last 24 h
  `refactor 12% (band 20-30%: UNDER)`; `phase day`.
- **Briefs on this lane's box** that name a row basename or the baseline
  (`grep -rlE 'release-stable\.tst|responder-run\.tst|spec-import-issues\.tst|test-agent-watch|test-agent-top|test-strip-agy-optin|test-strip-two-envs|shellcheck-warning-baseline'`
  over `/var/spool-hub/dispatch/briefs` and `/var/spool-hub/spawn-remote/briefs`, as
  root, 2026-11-19T17:30:04Z): 5 files, each naming only the baseline: the r67-01 and
  r67-02 R7 reviewer briefs, the r67-02 and r67-03 row briefs (r67-01 and r67-02
  landed; r67-03 writes only api paths), and this planner's brief.
- **Unlanded round rows:** r67-03 only; it writes no row path.

## 3. Per row: what the lane does

- **r68-01:** three orc tests stop keeping a capture, a counter or read fields no line
  reads; their 3 SC2034 baseline lines go.
- **r68-02:** after r68-01: four spawn-agents tests stop keeping a pane id no line
  reads; their 4 SC2034 baseline lines go.

## 4. Panel and reviewers (R7)

- Editor: c-526 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Vendor state** (2026-11-19T17:32:07Z, n=1 each, `BOX_PICK_KIND=<k> ./run -a do_spl_box_pick`,
  read on this lane's box): agy, mistral and claude `pick=` this box; grok `pick=hold`.
  This box has an agy CLI (`command -v agy` -> found); the pick does not read agy's
  quota, so the holder knows whether agy is out.
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r68`):
  one **agy** doc seat, the main vendor for spec and plan reviews; mistral as its
  backup, as r62 to r67 had. The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2): agy if its pick still holds
  when the row is queued, else the holder's call (a fresh claude seat under the claude
  waiver, as r63 to r67). Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one
(rulebook 4.3), the sites and line numbers of 1.3, its R7 reviewer seat, and
"re-measure first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r68-01 | `c002-r68-01-orc-tests-shellcheck-dead-vars` | `refactor(r68-01-orc-tests-shellcheck-dead-vars, SPL-<row issue>): ...` | `review/r68-01` | 1 |
| r68-02 | `c002-r68-02-spawn-tests-shellcheck-pane-ids` | `refactor(r68-02-spawn-tests-shellcheck-pane-ids, SPL-<row issue>): ...` | `review/r68-02` | 2, `SPAWN_AFTER=c002-r68-01-orc-tests-shellcheck-dead-vars` |

**r68-01 brief, Files: ONLY** `orc:tests/release-stable.tst.sh`,
`orc:tests/responder-run.tst.sh`, `orc:tests/spec-import-issues.tst.sh`,
`.shellcheck-warning-baseline.txt` (its 3 SC2034 lines). Do: plan section 2 row 01
verbatim; red control the sites fixed with the baseline lines left (`do_sec_shellcheck`
FAIL on the 3 pairs) then dropped (PASS), both outputs in the body; each test's rc and
PASS count before and after in the body (plan 1.4). Run the tests with `SPOOL_TEST=1`.
Gates: the three files, `bash csi-spl-iac/src/bash/tests/sec-shellcheck.tst.sh`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r68-02 brief, Files: ONLY** `sa:tests/test-agent-watch.sh`, `sa:tests/test-agent-top.sh`,
`sa:tests/test-strip-agy-optin.sh`, `sa:tests/test-strip-two-envs.sh`,
`.shellcheck-warning-baseline.txt` (its 4 SC2034 lines). Do: plan section 2 row 02
verbatim; red control as row 01 for the 4 pairs; each test's `N passed, 0 failed` the
same before and after. Gates: the four files,
`bash csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh` (a test red on
the parent too is named, not fixed), `bash csi-spl-iac/src/bash/tests/sec-shellcheck.tst.sh`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (refactor 2; Bash test code 2) |
| vendor | claude 2 |
| kind | simple_coding 2 |
| batches | batch 1: row 01; batch 2: row 02 (after 01) |
| `.shellcheck-warning-baseline.txt` lines | 80 today -> 77 after r68-01 -> 73 after r68-02 |
| SC2034 lines in it | 35 -> 32 -> 28 |
| SC2034 warnings removed | 8 (row 01) + 9 (row 02) = 17 |
| SC2034 lines under `csi-spl-orc/` | 31 -> 28 -> 24 |
| measured on | `23864a224`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| Go `wideFuncs`: `MoveMessage` (28 grep lines) and `MergeTopic` (19) pairs | each row deletes its 2 lines in `cleancode_test.go`, which the unlanded r67-03 also edits (R3: off every unlanded row's files); the first candidate of round 69 once r67-03 lands | 1.2 |
| WUI `WIDE` `src/stores/channel.ts send` (6 params) | 63 positional caller lines in 35 files, a WUI row with its e2e gate: input for a later round | 1.2 |
| `orc:run/spl-spec-import-issues.func.sh:300-304` (4 SC2034: `DRY_RUN`, `ISSUE_ASSIGNEE`, `ISSUE_EPIC`, `ISSUE_SORT`) | set in a subshell for `do_spl_issue_list` to read: the baseline's "read by a called function" case, not dead code | 1.3 |
| `sa:scripts/trust-workdir.sh:368` (2), `sa:scripts/agent-top.sh:77` (1) | action code: `SPOOL_AGENT_USER`, `SPOOL_AGENT_PTY`, `AGENT_TOP_TAG` may be read by sourced code; each needs the per-variable read check of r67 1.3 | shellcheck, 1.3 |
| `sa:tests/test-spool-poke-queue.sh:254,269` (2), `test-agent-identity-reconcile.sh:55,75` (2), `test-agent-identity-restore.sh:95` (1), `sa:tests/lib.inc.sh` (1) | test code like row 02's, not yet read one by one (`A_PANE`, `pane`, `before`, `RUNNER`); `lib.inc.sh` is sourced by every spawn-agents test. A 4th set: input for round 69 (rulebook 5.1) | shellcheck, 1.3 |
| the spawn and restore scripts (`spawn-*.sh` 8 each, `restore-*.sh` 6 each, the `spool-*.inc.sh` libs, `spawn-*-chain/task.sh`) | vars a sourced lib or a launcher may read; one script family per row, each with the per-variable read check | `.shellcheck-warning-baseline.txt` |
| iac SC2034 (4 lines) | r67 section 7: read by a sourcing caller or a test (3), a dead guard, a bug row (1) | r67 1.3 |
| SC2154 (20), SC2120 (7), SC1090 (5), SC2088 (4), SC2046 (3), SC2319 (2), SC2164 (2), SC2155 (2) | the baseline's header names these kinds deliberate; not re-measured one by one here | the baseline's header |
| `spl-file-erase` (`no-literal-paths.baseline`, 1 line) | a protected-root deny list, a behaviour change (r66, r67 section 7) | 1.2 |
| candidates file (a): `orc:scripts/reverse-tunnel-cron.sh:23` literal state dir (r63-01 R7 W1) | **served** in code: `:23-26` on `23864a224` derive it (`REVERSE_TUNNEL_STATE_DIR`, else `spl_run_paths` -> `$SPL_VAR_APP_DIR/reverse-tunnel`, else FATAL). Left: the guide's prose, `csi-spl-doc/doc/md/guides/installation-and-configuration-guide.md:594` still prints `/var/csi/csi-spl/reverse-tunnel`: a docs follow-up, not a refactor row (as r65, r67) | `git show 23864a224:<file> \| sed -n 18,28p` |
| candidates file (b): literal `/var` at `orc:run/spl-watchdog.func.sh:72,1311` (`LOGIN_STATE_DIR`) and `orc:run/spl-lane-rotate.func.sh:112` | **served**: `:72` is the `@param` text, the default is `spl_claude_login_state_dir`; `:1318` and `spl-lane-rotate.func.sh:116` call that function (`git grep -n LOGIN_STATE_DIR 23864a224 -- <2 files>`, `git grep -nE '/var/' ...` -> no `/var/` line in `spl-lane-rotate.func.sh`) | holder's note msg 5c30249d |
| the same kind, still live: a computed `/var/<org>/<org>-<app>/agent-boot-restore` default in `orc:run/spl-watchdog.func.sh:539` (`spl_wd_boot_retired`) and `orc:run/spl-agent-boot-restore-install-cron.func.sh:57` (`logdir`) | `/var/${oa%%-*}/$oa` is a box path built from the app name, so `no-literal-paths.tst.sh` (literal `/(opt\|var)/<org>`) does not see it. A refactor only if `$SPL_VAR_APP_DIR/agent-boot-restore` is the same path on every box (the two must move together: the watchdog reads the marker the cron writes); not measured here: input for round 69 | `git grep -nE 'agent-boot-restore' 23864a224 -- 'csi-spl-orc/src/bash/run/*.sh'` |
| the candidates file's other items | bug-shaped items are not refactor rows (the brief); the holder named (a) and (b) as its refactor-shaped ones | holder msg 5c30249d |
| spec 011 T001-T008, T018-T021, T023, T026-T028, T031, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour (T028's assertions), terraform layout (T026) or docs (T031); the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-526): first draft. A fresh round: 2 rows found on `23864a224`, SC2034 sites in
  orc test files whose variable no line reads. Window W and the r68 slug proof recorded.

- v0.2 (c-526, the holder's note c-002@sat msg 5c30249d): section 7 only. The candidates
  file's refactor-shaped items (a) and (b) re-measured on `23864a224`: both served in code;
  the guide's `:594` prose and a computed `/var/<org>/<org>-<app>` default (watchdog
  `:539` + boot-restore install-cron `:57`) recorded as round 69 input beside the
  `wideFuncs` pairs. Rows 01 and 02 unchanged.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-526 (claude): v0.1, v0.2.
- Panel reviewer seat: requested of the dispatch lease holder (section 4).
- Row R7 seats: section 4.
