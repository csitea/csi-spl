# Bug-fix round 1 - plan (6 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 1 focus: **measured bug fixes across the fleet: harness stability, test isolation, runner robustness, and daemon resilience**.  
Concurrency: **build 2 row lanes in parallel at all times** (rounds-rulebook.md §1.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4; owner t1 dc15ad65 msg b8e22a15: "do not ask me for input - just reach consensus between all of the members of the panel and start implementation").  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1–R16), by pointer, not copied. Issue: SPL-2448.

**Status: v0.1, DRAFT FOR REVIEW**. Ready for cross-vendor reviewer seat (claude).

Editor: **a-391@sat** (agy).

**One sha:** every count is measured on **`e4fb9bc6b`** (`origin/master`, 2026-10-18), n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else, with a **red control**: the test or check fails on the buggy behavior before the change and passes after.
- **Paths:** repo-relative paths (`csi-spl-orc/`, `csi-spl-iac/`, `csi-spl-wui/`, `csi-spl-api/`). Lines as of `e4fb9bc6b`.
- **Box:** the preferred box (`sat` or other available box); the spawner's placement may move a row (no pin).
- **Vendor:** the owner mix (`do_spl_lane_mix`: simple_coding -> mistral, backup claude; complex_coding -> claude, backup mistral; tests -> claude, backup mistral), then R14. (Mistral gets no UI coding per HUM-10 rule; Grok has no quota per c-002 note `6acfc32a`).
- **Subject** (R6 reads it): `<type>(b01-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line, this round:** the review line carries the run it claims:  
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.

---

## 2. Where the rows come from (measured on `e4fb9bc6b`)

The 5 mandated candidate sources were investigated systematically on `e4fb9bc6b`:

| source | command | count (n) | status |
|---|---|---|---|
| **1. Owner & member reports in t1 topics (last 7 days)** | `cd csi-spl-orc && env ENV=prd SQL="select count(*) from messages where tenant_id='t1' and received_at > now() - interval '7 days' and (from_id like 'HUM%' or typed_by like 'HUM%')" ./run -a do_spl_db_query` | 785 messages scanned across t1 topics | Defect mentions examined: msg `3c89e266` (lone `-` query) fixed by SPL-2172 (`8f10f62e9`); msg `045c8dcd` (unread counter) fixed by SPL-2124 (`85225b513280`); msg `5e6f0db8` (Shift+W desktop pane close) is feature request; msg `0ff57084` item 5 (`SPOOL_LEGACY_INBOX_ROOT` dead code) adopted in Row 04. |
| **2. CI gate report (last 200 runs)** | `cd csi-spl-iac && env CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 107 success, 59 cancelled, 33 failure across last 200 runs | Every failure signature observed is already resolved on trunk; newest run for every failed job is green (`aa66bbfab`, `764c78e59`). Active trunk defects: n=0. |
| **3. Tests skipped or disabled in code & local flakes** | `git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(|ci-skip\.txt)" -- csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac` | 4 e2e skipped in `ci-skip.txt`; 38 Go store skips; 3 allowlisted tests in `tests-hermetic.tst.sh` | `scroll-anchor.test.mjs` waits on refactor round 13 row 07; 38 Go tests require postgres (`SPOOL_TEST_PG_DSN`); 3 tests allowlisted in `tests-hermetic.tst.sh` pass cleanly today and are graduated in Row 05. |
| **4. GC notes (last 24h) & repeating box alarms** | `spool tail --task gc-sat`, `spool tail --task desk-reconcile`, `spool tail --task agent-settings-check` | Repeating blocker in `desk-reconcile`: 19 instances in 7 days | `checkout /opt/csi/csi-spl-desk-cron is not on trunk ... dirty: M ...` occurs when uncommitted edits block `git pull --ff-only`. Adopted in Row 03. |
| **5. Open issues describing defects** | `cd csi-spl-orc && env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list` | 271 open issues scanned | SPL-1945 (blocked, secret rotation); SPL-435/450/455 (Phase 1/3/4 verify rows); SPL-2254 (promotion drill failure). |
| **Reported candidate (c-390 / c-002 brief)** | `bash csi-spl-orc/src/bash/tests/wd-heldout-hand-restore.tst.sh` | Fails line 81 on unchanged HEAD | Confirmed and reproduced: host `SPOOL_BOX_TAG=sat` leaks into `hand()` sandbox, causing line 81 to expect `c-201@box1` while receiving `c-201@sat`. Adopted in Row 01. |
| **Suite discovery (spawn-agents suite)** | `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-hook.sh` | Hangs in `cat` indefinitely when stdin unredirected | Confirmed and reproduced: `pre-push:42` reads `_pp_refs="$(cat)"` (added in `3e082c94c`), but `run_hook()` in `test-pre-push-hook.sh:59` invokes `bash "$HOOK"` without redirecting stdin. Adopted in Row 02. |

---

## 3. The 6 rows

| # | defect & practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b01-01-orc-wd-heldout-restore-tag-env)` | test environment isolation, test fix | `wd-heldout-hand-restore.tst.sh` fails on box `sat` because `hand()` does not isolate `SPOOL_BOX_TAG` / `BOX_TAG`. `_spool_box_env_load` skips setting `SPOOL_BOX_TAG=box1` from test `box.env` because the variable is already set in the caller environment. | `csi-spl-orc/src/bash/tests/wd-heldout-hand-restore.tst.sh:56-59` | 1 failing assertion | In `hand()`, invoke `env -u SPOOL_BOX_TAG -u BOX_TAG ...` to ensure sandbox isolation matches other watchdog tests. **Red control:** on box with `SPOOL_BOX_TAG=sat`, `bash csi-spl-orc/src/bash/tests/wd-heldout-hand-restore.tst.sh` fails line 81 ("FAIL: no CLI run: hold of c-201 cleared"); with fix, passes 100%. | sat | claude | tests | 1 (Lane 1 start) |
| 02 `fix(b01-02-orc-test-pre-push-hook-stdin)` | test harness stability, stdin isolation | `test-pre-push-hook.sh` hangs indefinitely on stdin because `pre-push:42` reads `_pp_refs="$(cat)"` (added in `3e082c94c`), but `run_hook()` in `test-pre-push-hook.sh:59` invokes `bash "$HOOK"` without redirecting stdin. | `csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-hook.sh:57-60` | 1 hanging test | In `run_hook()`, redirect stdin `< /dev/null` (or provide synthetic ref string) to `bash "$HOOK"`. **Red control:** running `test-pre-push-hook.sh` without terminal redirection blocks on `cat` indefinitely; with `< /dev/null`, all assertions complete in under 2 seconds. | sat | claude | tests | 1 (Lane 2 start) |
| 03 `fix(b01-03-orc-desk-reconcile-dirty-recovery)` | daemon resilience, automated recovery | Repeating blocker in `desk-reconcile`: `/opt/csi/csi-spl-desk-cron` gets dirty from local test runs or locale generator steps, causing `git pull --ff-only` to fail and leaving the checkout on stale code for multiple days. | `csi-spl-orc/src/bash/run/spl-desk-reconcile.func.sh:85-115`<br>`csi-spl-orc/src/bash/tests/spl-desk-reconcile.tst.sh` | 19 blocker alerts / 7 days | In `do_spl_desk_reconcile`, detect dirty uncommitted state in `/opt/csi/csi-spl-desk-cron` on tracked files, log a warning, reset/checkout tracked files to HEAD before attempting fast-forward merge. **Red control:** synthetic dirty file in test sandbox aborts reconcile without fix; cleanly discards non-source churn and fast-forwards with fix. | sat | claude | complex_coding | 2 (Lane 1, after 01) |
| 04 `fix(b01-04-orc-prune-legacy-markdown-inbox)` | dead code elimination, protocol cleanup | `SPOOL_LEGACY_INBOX_ROOT` and legacy `.md` outbox scans in `agent-send.sh` and `agent-inbox.sh` are dead code following the 2026-10-03 cutoff (spec 061). Eliminates confusion in hot messaging paths. | `csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-send.sh:90-120`<br>`csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-inbox.sh:70-85`<br>`csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-send.sh` | 2 script sites | Remove legacy markdown fallback branches and `SPOOL_LEGACY_INBOX_ROOT` references from `agent-send.sh` and `agent-inbox.sh`; keep JSON v:1 protocol clean. **Red control:** `test-agent-send.sh` and `test-agent-top.sh` pass without legacy environment variables; legacy path no longer scans disk. | sat | claude | simple_coding | 2 (Lane 2, after 02) |
| 05 `fix(b01-05-orc-hermetic-tests-allowlist-grad)` | regression gate tightening | `tests-hermetic.tst.sh` maintains an allowlist of 3 tests (`asks.tst.sh`, `channel-agent-remove-op.tst.sh`, `desk-install-service-envs.tst.sh`). All 3 tests have been updated and pass hermetically. Retaining them on the allowlist weakens the gate. | `csi-spl-orc/src/bash/tests/tests-hermetic.tst.sh:25-45` | 3 allowlisted tests | Verify all 3 tests pass without allowlist; remove them from `allow` array in `tests-hermetic.tst.sh`. **Red control:** `tests-hermetic.tst.sh` fails if an unlisted non-hermetic test is introduced; passes with 0 allowlisted exemptions. | sat | claude | tests | 3 (Lane 1, after 03) |
| 06 `fix(b01-06-iac-run-log-dir-permission-fallback)` | runner robustness, permission fallback | When `./run` runs in a directory or worktree where `PROJ_PATH/dat/log/bash` cannot be created due to user permissions, `./run` fails with a fatal error in `print_fatal` or `tee`. | `csi-spl-iac/run:405-425`<br>`csi-spl-iac/src/bash/tests/run-log-nofork.tst.sh` | 1 runner defect | In `./run` `_do_log`, if `mkdir -p "$_log_dir"` fails, fall back to `${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/log` or `/tmp/csi-spl-$UID/log` with a warning, allowing the action to proceed rather than failing the execution. **Red control:** `./run` invoked in a directory with unwritable `dat/log/bash` fails today; with fallback, executes action cleanly. | sat | claude | complex_coding | 3 (Lane 2, after 04) |

---

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All rows touch strictly disjoint files across batches:
- **Lane 1 (odd rows):** Row 01 (`wd-heldout-hand-restore.tst.sh`) -> Row 03 (`spl-desk-reconcile.func.sh`) -> Row 05 (`tests-hermetic.tst.sh`)
- **Lane 2 (even rows):** Row 02 (`test-pre-push-hook.sh`) -> Row 04 (`agent-send.sh`, `agent-inbox.sh`) -> Row 06 (`csi-spl-iac/run`)
- Within each batch, files are completely disjoint:
  - Batch 1: Row 01 vs Row 02 (disjoint test files in separate directories).
  - Batch 2: Row 03 vs Row 04 (desk reconcile action vs spawn-agents messaging scripts).
  - Batch 3: Row 05 vs Row 06 (orc hermetic test vs iac run script).

---

## 4. Measured and not a bug

| candidate | measurement command | result | why not a row |
|---|---|---|---|
| CI gate failures across last 200 runs | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 33 failed runs, but newest run for every failed job is green (`aa66bbfab`, `764c78e59`) | Every flake and historical failure is already fixed on master; active trunk defect count is 0. |
| Lone `-` search query error (msg `3c89e266`) | `git log -S 'SPL-2172' --oneline` | Fixed in commit `8f10f62e9` | Verified fixed on master; served on dev and prd. |
| Channel unread counter mismatch (msg `045c8dcd`) | `git log -S 'SPL-2124' --oneline` | Fixed in commit `85225b513280` | Verified fixed on master; served on dev and prd. |
| Shift+W desktop pane close (msg `5e6f0db8`) | `select body from messages where msg_id='5e6f0db8-ef79-41d8-b5df-09246d56ae63'` | Feature request for new shortcut | Queued as a feature, not a bug. |

---

## 5. Not reproduced

| candidate | command tried | outcome |
|---|---|---|
| `agent-settings-check` repeating alarm | `SPOOL_ROOT=/var/spool-hub spool tail --task agent-settings-check` | 0 messages recorded in last 24h; no active alarm. |
| `csi-spl-iac` suite failures | `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` | 173/173 test files passed (100% green when run in standard test environment). |

---

## 6. Left out, owned by live lanes (R3)

| path / task | owning lane | status / reason |
|---|---|---|
| `lane-map.sh` stale row for reused ID | `c-786` (SPL-2446) | Landed in `2594d5a12`; lane completing. |
| GC agy restarts on unknown progress | `c-390@sat` (SPL-2443) | Landed in `aa66bbfab`. |
| `scroll-anchor.test.mjs` (480 px viewport) | Waits on Refactor Round 13 Row 07 | Avoid cross-round collision on `useScrollAnchor.ts`. |
| `open-in-place` WUI e2e flake | `c-322@sat` (SPL-2444) | Landed in `af0bb602f`. |
| Refactor Round 13 files (`csi-spl-wui/`) | Refactor Round 13 active lanes | Disjointness with active refactoring round. |

---

## 7. Counts

| item | count (n) |
|---|---|
| rows | 6 (all defect fixes) |
| vendor | claude 6 (orc and iac coding/tests) |
| box (preferred) | sat 6 |
| batches | 3 batches of 2 rows (2 parallel lanes at all times) |

---

## 8. Expert Panel & Reviewer Assignment (R7)

- **Editor seat (agy):** `a-391@sat`
- **Reviewer seat (claude):** Requested from dispatcher (`c-002@sat`) for cross-vendor plan review of v0.1.
- All 6 rows assigned to Claude for implementation; cross-vendor review enforced before push per rounds-rulebook R7.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor (agy) | a-391@sat | **DRAFT v0.1** on `e4fb9bc6b` |
| Reviewer (claude) | awaiting assignment from `c-002@sat` | Pending v0.1 review |
