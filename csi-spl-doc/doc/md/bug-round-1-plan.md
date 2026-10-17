# Bug-fix round 1 - plan (4 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 1 focus: **measured bug fixes across the fleet: harness stability, test isolation, runner robustness, and daemon resilience**.  
Concurrency: **build 2 row lanes in parallel at all times** (rounds-rulebook.md §1.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4; owner t1 dc15ad65 msg b8e22a15: "do not ask me for input - just reach consensus between all of the members of the panel and start implementation").  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1–R16), by pointer, not copied. Issue: SPL-2448.

**Status: v1.0, APPROVED BY EXPERT PANEL**. Folded cross-vendor review verdict from claude reviewer `c-835` (`csi-spl-doc/doc/md/bug-round-1/seat-claude.md`, landed `24e924c3b`).

Editor: **a-391@sat** (agy).  
Reviewer: **c-835** (claude).  

**One sha:** every count is measured on **`e4fb9bc6b`** / `19cfcb370` (`origin/master`, 2026-10-18), n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else, with a **red control**: the test or check fails on the buggy behavior before the change and passes after.
- **Paths:** repo-relative paths (`csi-spl-orc/`, `csi-spl-iac/`, `csi-spl-wui/`, `csi-spl-api/`). Lines as of `19cfcb370`.
- **Box:** the preferred box (`sat` or other available box); the spawner's placement may move a row (no pin).
- **Vendor:** the owner mix (`do_spl_lane_mix`: simple_coding -> mistral, backup claude; complex_coding -> claude, backup mistral; tests -> claude, backup mistral), then R14. (Mistral gets no UI coding per HUM-10 rule; Grok has no quota per c-002 note `6acfc32a`).
- **Subject** (R6 reads it): `<type>(b01-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line, this round:** the review line carries the run it claims:  
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.

---

## 2. Where the rows come from (measured on `e4fb9bc6b` / `19cfcb370`)

The 5 mandated candidate sources were investigated systematically:

| source | command | count (n) | status |
|---|---|---|---|
| **1. Owner & member reports in t1 topics (last 7 days)** | `cd csi-spl-orc && env ENV=prd SQL="select count(*) from messages where tenant_id='t1' and received_at > now() - interval '7 days' and (from_id like 'HUM%' or typed_by like 'HUM%')" ./run -a do_spl_db_query` | 785 messages scanned across t1 topics | Defect mentions examined: msg `3c89e266` (lone `-` query) fixed by SPL-2172 (`8f10f62e9`); msg `045c8dcd` (unread counter) fixed by SPL-2124 (`85225b513280`); msg `5e6f0db8` (Shift+W desktop pane close) is feature request; msg `0ff57084` item 5 (`SPOOL_LEGACY_INBOX_ROOT` dead code) owned by refactor SPL-2179 (queued as `002b87b7`). |
| **2. CI gate report (last 200 runs)** | `cd csi-spl-iac && env CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 107 success, 59 cancelled, 33 failure across last 200 runs | Every failure signature observed is already resolved on trunk; newest run for every failed job is green (`aa66bbfab`, `764c78e59`). Active trunk defects: n=0. |
| **3. Tests skipped or disabled in code & local flakes** | `git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(|ci-skip\.txt)" -- csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac` | 4 e2e skipped in `ci-skip.txt`; 38 Go store skips; 3 allowlisted tests in `tests-hermetic.tst.sh` | `scroll-anchor.test.mjs` waits on refactor round 13 row 07; 38 Go tests require postgres (`SPOOL_TEST_PG_DSN`); 3 tests allowlisted in `tests-hermetic.tst.sh` is gate tightening refactor (verified by c-835: removing allowlist fails on `desk-install-service-envs.tst.sh`). |
| **4. GC notes (last 24h) & repeating box alarms** | `spool tail --task gc-sat`, `spool tail --task desk-reconcile`, `spool tail --task agent-settings-check` | Repeating blocker in `desk-reconcile`: 16 blockers since 2026-10-02 (7 in 2026-10-11..17; 11 carry `dirty:`) | Stale checkout in `/opt/csi/csi-spl-desk-cron` occurs when uncommitted edits block `git checkout -q --detach origin/master`. Adopted in Row 03; root-cause tree-writing guard adopted in Row 04. |
| **5. Open issues describing defects** | `cd csi-spl-orc && env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list` | 271 open issues scanned | SPL-1945 (blocked, secret rotation); SPL-435/450/455 (Phase 1/3/4 verify rows); SPL-2254 (promotion drill failure). |
| **Reported candidate (c-390 / c-002 brief)** | `SPOOL_BOX_TAG=sat bash csi-spl-orc/src/bash/tests/wd-heldout-hand-restore.tst.sh` | Fails line 81 on unchanged HEAD | Confirmed and reproduced: host `SPOOL_BOX_TAG=sat` leaks into `hand()` sandbox, causing line 81 to expect `c-201@box1` while receiving `c-201@sat`. Already queued as ask `cc9fdc39` (`claude:c002-bug-wd-heldout-box-tag-isolation`). Adopted in Row 01. |
| **Suite discovery (spawn-agents suite)** | `timeout 40 script -qec 'bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-hook.sh' /dev/null < <(sleep 45)` | Hangs in `cat` indefinitely (rc 124 at 40s) when stdin unredirected | Confirmed and reproduced: `pre-push:42` reads `_pp_refs="$(cat)"` (added in `3e082c94c`), and 6 hook calls in `test-pre-push-hook.sh` run without redirecting stdin. Already queued as ask `e108c643` (`claude:c002-bug-pre-push-hook-test-stdin`). Adopted in Row 02. |

---

## 3. The 4 rows

| # | defect & practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b01-01-orc-wd-heldout-restore-tag-env)` | test environment isolation, test fix | `wd-heldout-hand-restore.tst.sh` fails on box `sat` because `hand()` does not isolate `SPOOL_BOX_TAG` / `BOX_TAG`. `_spool_box_env_load` skips setting `SPOOL_BOX_TAG=box1` from test `box.env` because the variable is already set in the caller environment. **Note:** ALREADY QUEUED as lane by dispatcher (ask `cc9fdc39`, `claude:c002-bug-wd-heldout-box-tag-isolation`); **LANDED** on origin/master in `8ac0f7d62` (SPL-2457). Do not queue again. | `csi-spl-orc/src/bash/tests/wd-heldout-hand-restore.tst.sh:1-30` | 1 failing assertion | Clear or pin every host spool identity variable (`SPOOL_BOX_TAG`, `BOX_TAG`, `SPOOL_BOX`, `SPOOL_AGENT_ID`) at the test's top; test file only; restore code untouched. **Red control:** on box with `SPOOL_BOX_TAG=sat`, `bash csi-spl-orc/src/bash/tests/wd-heldout-hand-restore.tst.sh` fails line 81 ("FAIL: no CLI run: hold of c-201 cleared"); with fix, passes 100%. | sat | claude | tests | 1 (Lane 1 start, LANDED `8ac0f7d62`) |
| 02 `fix(b01-02-orc-test-pre-push-hook-stdin)` | test harness stability, stdin isolation | `test-pre-push-hook.sh` hangs indefinitely on stdin because `pre-push:42` reads `_pp_refs="$(cat)"` (added in `3e082c94c`), and 6 hook invocations in `test-pre-push-hook.sh` invoke `bash "$HOOK"` without redirecting stdin. **Note:** ALREADY QUEUED as lane by dispatcher (ask `e108c643`, `claude:c002-bug-pre-push-hook-test-stdin`); **LANDED** on origin/master in `ef312bbcc` (SPL-2458). Do not queue again. | `csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-hook.sh:59,94,144,146,174,192` | 6 unredirected calls | Feed explicit stdin or synthetic ref lines (`</dev/null` or case-appropriate ref lines for non-ff / wip cases) to all 6 hook invocations; test file only, hook untouched. **Red control:** `timeout 40 script -qec 'bash .../test-pre-push-hook.sh' /dev/null < <(sleep 45)` times out (rc 124) after 40s on master; passes with explicit stdin in under 2 seconds. | sat | claude | tests | 1 (Lane 2 start, LANDED `ef312bbcc`) |
| 03 `fix(b01-03-orc-desk-cron-safe-dirty-recovery)` | daemon resilience, safe recovery | Repeating blocker in `desk-reconcile`: uncommitted edits in `/opt/csi/csi-spl-desk-cron` block the crontab line `git checkout -q --detach origin/master`, causing stale code execution across multiple ticks (16 blockers since Oct 2, 7 in Oct 11..17). Staged and modified files represent uncommitted work, so a destructive reset would cause data loss. | `csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh:194-245`<br>`csi-spl-orc/src/bash/tests/desk-cron-trunk.tst.sh` | 16 blocker alerts | In `desk-reconcile-cron.sh`, if tracked files are dirty, safely snapshot staged and unstaged changes into a rescue ref (`git stash create` and `git update-ref refs/rescue/desk-cron/<YYYYMMDDTHHMMSSZ>`), restore tracked files to clean HEAD and complete checkout; cite the rescue ref in the blocker message. NEVER run `git clean` or touch untracked files; never run while another tick holds lock. **Red control:** `desk-cron-trunk.tst.sh` test with staged, unstaged, and untracked files: after recovery, rescue ref contains staged/unstaged changes, untracked file is untouched on disk, blocker cites rescue ref. | sat | claude | complex_coding | 2 (Lane 1, after 01) |
| 04 `fix(b01-04-orc-guard-desk-cron-tree-writers)` | tree guard, prevent cron checkout pollution | Root-cause defense for Row 03: tree-writing actions (`do_spl_doctree_export_md`, i18n writers) do not verify whether `PROJ_PATH` points to the shared `/opt/csi/csi-spl-desk-cron` checkout before creating or modifying files, leaving staged/unstaged changes that break subsequent cron checkouts. | `csi-spl-orc/src/bash/run/spl-doctree-export-md.func.sh`<br>`csi-spl-orc/src/bash/tests/desk-cron-write-guard.tst.sh` | Root cause of 11 dirty blockers | Make tree-writing actions check `PROJ_PATH` and refuse with non-zero exit and explicit error when run inside `/opt/csi/csi-spl-desk-cron` (or any `*-desk-cron` directory). **Red control:** test invokes action pointing `PROJ_PATH` at mock cron checkout directory; today it writes files; with fix it cleanly refuses and writes nothing. | sat | claude | tests | 2 (Lane 2, after 02) |

---

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All rows touch strictly disjoint files across batches:
- **Lane 1 (odd rows):** Row 01 (`wd-heldout-hand-restore.tst.sh`) -> Row 03 (`desk-reconcile-cron.sh`, `desk-cron-trunk.tst.sh`)
- **Lane 2 (even rows):** Row 02 (`test-pre-push-hook.sh`) -> Row 04 (`spl-doctree-export-md.func.sh`, `desk-cron-write-guard.tst.sh`)
- Within each batch, files are completely disjoint:
  - Batch 1: Row 01 vs Row 02 (disjoint test files in separate directories).
  - Batch 2: Row 03 vs Row 04 (`desk-reconcile-cron.sh` recovery vs `spl-doctree-export-md.func.sh` writer guard).

---

## 4. Measured and not a bug

| candidate | measurement command | result | why not a row |
|---|---|---|---|
| CI gate failures across last 200 runs | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 33 failed runs, but newest run for every failed job is green (`aa66bbfab`, `764c78e59`) | Every flake and historical failure is already fixed on master; active trunk defect count is 0. |
| Lone `-` search query error (msg `3c89e266`) | `git log -S 'SPL-2172' --oneline` | Fixed in commit `8f10f62e9` | Verified fixed on master; served on dev and prd. |
| Channel unread counter mismatch (msg `045c8dcd`) | `git log -S 'SPL-2124' --oneline` | Fixed in commit `85225b513280` | Verified fixed on master; served on dev and prd. |
| Shift+W desktop pane close (msg `5e6f0db8`) | `select body from messages where msg_id='5e6f0db8-ef79-41d8-b5df-09246d56ae63'` | Feature request for new shortcut | Queued as a feature, not a bug. |
| Hermetic allow-list graduation | `bash tests-hermetic.tst.sh` with empty allowlist | Fails on `desk-install-service-envs.tst.sh` | Gate tightening refactor, not a defect; removing allowlist turns gate red today. |

---

## 5. Not reproduced

| candidate | command tried | outcome |
|---|---|---|
| `agent-settings-check` repeating alarm | `SPOOL_ROOT=/var/spool-hub spool tail --task agent-settings-check` | 0 messages recorded in last 24h; no active alarm. |
| `csi-spl-iac` suite failures | `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` | 173/173 test files passed (100% green when run in standard test environment). |
| `./run` log-dir fallback | `env LOG_DIR=/proc/c835-unwritable ./run -a do_check_dist_hygiene` | Exits 0 cleanly; fallback in `run.sh:406-423` already handles non-writable dirs. |

---

## 6. Left out, owned by live lanes (R3)

| path / task | owning lane | status / reason |
|---|---|---|
| `agent-send.sh`, `agent-inbox.sh` (legacy inbox prune) | `c002-harness-05-legacy-inbox-takeover-claude` | Refactor SPL-2179, queued as ask `002b87b7` (row 3/27). Dropped from bug round to avoid collision. |
| `lane-map.sh` stale row for reused ID | `c-786` (SPL-2446) | Landed in `2594d5a12`; lane completing. |
| GC agy restarts on unknown progress | `c-390@sat` (SPL-2443) | Landed in `aa66bbfab`. |
| `scroll-anchor.test.mjs` (480 px viewport) | Waits on Refactor Round 13 Row 07 | Avoid cross-round collision on `useScrollAnchor.ts`. |
| `open-in-place` WUI e2e flake | `c-322@sat` (SPL-2444) | Landed in `af0bb602f`. |
| Refactor Round 13 files (`csi-spl-wui/`) | Refactor Round 13 active lanes | Disjointness with active refactoring round. |

---

## 7. Counts

| item | count (n) |
|---|---|
| rows | 4 (all defect fixes) |
| vendor | claude 4 (orc coding/tests) |
| box (preferred) | sat 4 |
| batches | 2 batches of 2 rows (2 parallel lanes at all times) |

---

## 8. Expert Panel & Reviewer Assignment (R7)

- **Editor seat (agy):** `a-391@sat`
- **Reviewer seat (claude):** `c-835` (brief `c002-bug-round-1-reviewer-claude.md`, seat verdict landed in `24e924c3bac5b8667864dc735eb1fb3be8920ff1` at `csi-spl-doc/doc/md/bug-round-1/seat-claude.md`).
- All rows assigned to Claude for implementation; cross-vendor review enforced before push per rounds-rulebook R7.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor (agy) | a-391@sat | **PASS v1.0** (folded reviewer verdict, updated rows 01-04, updated counts and batches) |
| Reviewer (claude) | c-835 | Review completed on v0.1 (`24e924c3b`). Awaiting sign-off on v1.0 sha. |
