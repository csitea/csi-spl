# Bug-fix round 2 - plan (3 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 2 focus: **measured bug fixes across the fleet: push verification, runner logging robustness, and cron checkout serialisation**.  
Concurrency: **build 2 row lanes in parallel at all times** (rounds-rulebook.md §1.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4; owner t1 dc15ad65 msg b8e22a15: "do not ask me for input - just reach consensus between all of the members of the panel and start implementation").  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1–R16), by pointer, not copied. Issue: SPL-2564.

**Status: v1.0, FOLDED CROSS-VENDOR REVIEW**. Awaiting reviewer sign-off.

Editor: **a-489@sat** (agy).  
Reviewer: **c-979@PC** (claude; verdict landed in `1ce8ae8e2` at `csi-spl-doc/doc/md/bug-round-2/seat-claude.md`; confirmed by duplicate seat `c-513@sat`, msg `93ed75d0`).  

**One sha:** every count is measured on **`20cdcd400`** (`origin/master`, 2026-10-19), n=1 per command unless stated; review verified on `ca03e5014` / `5953fdfee`.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else, with a **red control**: the test or check fails on the buggy behavior before the change and passes after.
- **Paths:** repo-relative paths (`csi-spl-orc/`, `csi-spl-iac/`, `csi-spl-wui/`, `csi-spl-api/`). Lines as of `20cdcd400` / `ca03e5014`.
- **Box:** the preferred box (`sat` or other available box); the spawner's placement may move a row (no pin).
- **Vendor:** the owner mix (`do_spl_lane_mix`: simple_coding -> claude, backup grok; complex_coding -> claude, backup grok; tests -> claude, backup grok), then R14. (Mistral writes no code per owner HUM-10 rule; Grok has no quota per c-002 note `6acfc32a`).
- **Subject** (R6 reads it): `<type>(b02-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line, this round:** the review line carries the run it claims:  
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.

---

## 2. Where the rows come from (measured on `20cdcd400` / reviewer on `ca03e5014`)

The 5 mandated candidate sources were investigated systematically:

| source | command | count (n) | status |
|---|---|---|---|
| **1. Owner & member reports in t1 topics / Round 1 retro inputs** | Re-measured 8 candidate inputs from `csi-spl-doc/doc/md/bug-round-1-retro.md` section 7 on `20cdcd400` | 8 inputs evaluated: 3 reproduced defects (adopted), 3 measured & not a bug, 1 not reproduced, 1 already fixed on trunk | Input 1 fixed in `ab017f0ad` (SPL-2525); Input 2 adopted in Row 01; Input 3 dropped to Section 4 per review; Input 4 measured & not a bug; Input 5 adopted in Row 02 (with all 3 `run.sh` sites); Input 6 dropped to Section 4 per review, replaced by Reviewer Proposal P1 as Row 03; Input 7 not reproduced; Input 8 measured & not a bug (refactor debt). |
| **2. CI gate report (last 40/200 runs)** | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 21 cancelled, 11 failure, 5 success, 3 running across last 40 runs | Every failed job observed (`wui e2e 6/8`, `wui e2e 5/8`, `distribution-hygiene`, `iac tfvars`) is green on the latest completed runs (`e428729e`, `d33f75a3`). Active trunk defects: n=0. |
| **3. Tests skipped or disabled in code & local flakes** | `git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" -- csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac` | 4 e2e skipped in `ci-skip.txt`; 0 in orc `ci-skip.txt`; 38 Go store skips; 3 allowlisted tests in `tests-hermetic.tst.sh` | 4 e2e in `csi-spl-wui/tests/e2e/ci-skip.txt` require hosting CSP headers, live hub, visual comparisons, or refactors; 38 Go store tests require postgres (`SPOOL_TEST_PG_DSN`); 3 tests in `tests-hermetic.tst.sh` is gate tightening refactor. |
| **4. GC notes (last 24h) & repeating box alarms** | `spool tail --task gc-sat` | 62 bypasses, 212 unclassified lanes; `c-469` waiting on ask `8683f470` | Blocker in `c-469` (tokens tab DejaVu fi360) landed in `da2d7dd28` (SPL-2589). |
| **5. Open issues describing defects** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list` | 268 open issues scanned | 18 bug-related issues scanned: SPL-1945 (blocked, secret rotation, needs owner); SPL-2556 (landed on master in `885470013`); SPL-2467 (todo, session usage limit dialog); remaining items belong to active feature epics. |

---

## 3. The 3 rows

| # | defect & practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b02-01-orc-push-master-review-regex)` | pre-push review check, gate robustness | `_spl_push_master_unreviewed` in `spl-push-master.func.sh` uses regex `^(test\|refactor\|ci\|fix\|feat\|perf)\((r[0-9]+-[0-9]{2})-` at line 203, which strictly matches only `rNN-NN-` refactor rounds. It skips bug rounds (`bNN-NN`) and perf rounds (`pNN-NN`), as well as the pre-push hook (`hooks/pre-push:83`, same function). In perf round 6, 1 of 10 row commits (`6422f06c6 fix(p6-02-...)`) had 0 `review:` lines and landed undetected. Briefs must carry the `b02-NN` subject so the check takes effect. | `csi-spl-orc/src/bash/run/spl-push-master.func.sh:198-203`<br>`csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-review-line.sh:1-60` | 1 skipped match pattern (reproduced on trunk) | Widen round letter to `([rbp][0-9]+-[0-9]{2})`. Red control: a `b11-99` test case in `test-pre-push-review-line.sh` (row commit with no review line is refused) is red on today's function, green after fix. | sat | claude | simple_coding | 1 (Lane 1 start) |
| 02 `fix(b02-02-orc-run-unwritable-log-dir-fallback)` | runner robustness, safe logging fallback | `run.sh` crashes fatally at line 430 (`FATAL Command '[[ "${RUN_LOG_COMPACT:-0}" == "1" ]]' failed at line 430 with status 1`) or line 459 (`Command 'tee -a $log_file' failed at line 459 with status 1`) when `dat/log/bash` cannot be created or written by unprivileged users (e.g. non-root agent user with `r-x` ACL on worktree where `PROJ_PATH/dat` cannot be created and `VAR_DIR` is unwritable). `do_set_vars` at line 495 clears `LOG_DIR=""`, so the crash triggers when both fallbacks (`VAR_DIR/<org>/<app>/<proj>/dat/log/bash` and `PROJ_PATH/dat/log/bash`) are unwritable. All three copies across the repo (`csi-spl-iac`, `csi-spl-orc`, `csi-spl-utl`) share this failure mode and differ only by header lines. | `csi-spl-iac/src/bash/run/run.sh:406-462`<br>`csi-spl-orc/src/bash/run/run.sh:406-462`<br>`csi-spl-utl/src/bash/run/run.sh:406-462`<br>`csi-spl-orc/src/bash/tests/run-log.tst.sh` | 2 fatal crash sites across 3 runner files | In all 3 copies of `run.sh`, check if `_log_dir` is writable after `mkdir -p`; if not, fall back to `${TMPDIR:-/tmp}/csi-spl-log/bash` or `/tmp`, or omit file redirection with a warning on stderr so logging failures never abort execution. Red control: A test setting `VAR_DIR` and `PROJ_PATH` to unwritable paths runs `do_log` in compact and full mode; fails with status 1 today (lines 430/459), passes with status 0 after fix. | sat | claude | simple_coding | 1 (Lane 2 start) |
| 03 `fix(b02-03-orc-cron-checkout-flock-serialisation)` | cron daemon stability, race prevention | 12 cron lines in crontab fetch and run `git checkout -q --detach origin/$trunk` concurrently on the shared `/opt/csi/csi-spl-desk-cron` checkout with no locking. `spool tail --task desk-reconcile` recorded 13 "not on trunk ... dirty" blockers since 2026-10-07; 12 of 13 blockers were checkouts caught half-way between commits (index and files between two trunk commits), not author edits or writer actions. | `csi-spl-orc/src/bash/run/*.func.sh` (15 cron installers) + `csi-spl-iac/src/bash/run/install-weekly-full-scan-cron.func.sh`<br>`csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh:194-245`<br>`csi-spl-orc/src/bash/tests/desk-cron-trunk.tst.sh` | 12 recurring blockers across 16 cron installers | Serialise the fetch and checkout of every cron line on `/opt/csi/csi-spl-desk-cron` with one shared `flock` helper on a lock file in the checkout's git directory across all 16 installers, and run `desk-reconcile-cron.sh` trunk check under the same lock. Red control: A test in `desk-cron-trunk.tst.sh` starting concurrent checkouts of different commits in a scratch clone while asserting `desk-reconcile-cron.sh` reports clean; fails today with dirty blocker, passes cleanly with flock serialisation. | sat | claude | complex_coding | 2 (Lane 1, after Batch 1) |

---

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All rows touch strictly disjoint files across batches:
- **Lane 1 (odd rows):** Row 01 (`spl-push-master.func.sh`, `test-pre-push-review-line.sh`) -> Row 03 (`desk-reconcile-cron.sh`, cron installers, `desk-cron-trunk.tst.sh`)
- **Lane 2 (even rows):** Row 02 (`run.sh` in iac/orc/utl, `run-log.tst.sh`)
- Within each batch, files are completely disjoint:
  - Batch 1: Row 01 vs Row 02 (push review regex in `spl-push-master.func.sh` vs runner logging fallback in `run.sh`). Both start concurrently in parallel.
  - Batch 2: Row 03 (cron checkout flock in `desk-reconcile-cron.sh` and cron installers) touches none of the files from Batch 1.

---

## 4. Measured and not a bug

| candidate | measurement command | result | why not a row |
|---|---|---|---|
| `issue-close-landed.py --keys` on `.git` file (v0.1 Row 02) | `python3 .../issue-close-landed.py --keys .git HEAD` vs `python3 .../issue-close-landed.py --keys . HEAD` | `--keys .git HEAD` crashes with exit 128, but `--keys . HEAD` exits 0 cleanly in linked worktrees | Measured and not a bug: The crash requires passing the literal string argument `.git`. Every real caller in the repo (`spl-issue-close-landed.func.sh:67`, `spl-issue-close-check.func.sh:31`, `lane-issue.inc.sh:142`) passes a checkout directory path, which `git -C` resolves cleanly without error. No caller is affected. Dropped per reviewer verdict. |
| `do_tpl_gen` desk-cron guard (v0.1 Row 04) | `ls /opt/csi/csi-spl-desk-cron/tpl-gen` | `No such file`, stops at line 24 before write | Measured and not a bug: `tpl-gen` is not present in the shared cron checkout; `do_tpl_gen` exits at line 24 before writing. Investigation by reviewer c-979 confirmed that 12 of 13 dirty blockers on desk-cron are racing checkouts between cron lines (P1 / Row 03), not writer actions. Dropped per reviewer verdict and replaced by Row 03. |
| CI gate failures across last 40/200 runs | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 11 failed runs, but newest completed run for every failed job is green (`e428729e`, `d33f75a3`) | Every flake and historical failure is already fixed on master; active trunk defect count is 0. |
| `spl-review-line-check.func.sh` on spool task id (`log: <id>@<box>:<task>`) | `cd csi-spl-orc && sudo -u <DEV_USER> env REVIEW_LINE='... \| log: a-391@sat:dispatch-bug-round-1' ./run -a do_spl_review_line_check` | `FATAL log dispatch-bug-round-1 is not readable on sat as <user>` | Measured and not a bug: `do_spl_review_line_check` correctly refuses non-file task identifiers. Per rounds-rulebook R7 §2.7.4, `log:` must cite an absolute file path to the reviewer's session journal (`transcript.jsonl` / `journal.jsonl`). A task topic has no tool call logs. |
| Hermetic allow-list graduation | `grep -c "desk-install-service-envs.tst.sh" csi-spl-orc/src/bash/tests/tests-hermetic.tst.sh` | 1 (allowlist size = 3) | Gate tightening refactor, not a defect; all 3 allowlisted tests pass cleanly today (`desk-install-service-envs: 0 failure(s)`). Removing allowlist turns gate red today. |

---

## 5. Not reproduced

| candidate | command tried | outcome |
|---|---|---|
| `TestWUIWakeFansOutAcrossProcesses` race between process A and process B | `cd csi-spl-api/src/go/spool-hub-api && go test -count=5 -run TestWUIWakeFansOutAcrossProcesses ./internal/hub` | Passed 5 of 5 runs cleanly (`PASS: TestWUIWakeFansOutAcrossProcesses (1.32s)` per run, 0 failures). |
| `csi-spl-orc` hermetic test suite failures | `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` | 0 test assertion failures observed in executed suites. |

---

## 6. Left out, owned by live lanes or queued elsewhere (R3)

| path / task | owning lane / queue ask | status / reason |
|---|---|---|
| `do_git_prune_round_branches` rejects non-numeric rounds (`ROUND=b01`) | `claude:c001-prune-round-branches-named-rounds` (ask `aa10cf16`) | **Landed on master** in `ab017f0ad` (SPL-2525); verified `ROUND=b01 ./run -a do_git_prune_round_branches` exits 0 on `20cdcd400`. |
| `do_spl_push_master` pushes/checks HEAD not logged sha | `claude:c001-push-master-push-logged-sha` (ask `d3ed55d7`, SPL-2531) | **Landed on master** in `9a6297cca` (SPL-2574). |
| Agent kill guard (`pid 0/1`, tmux/cron/systemd) | `claude:c002-bug-agent-kill-guard` (ask `ca4b116f`) | **Landed on master** in `fd3beda1b` (SPL-2583). |
| Workdir fence instance race | `claude:c001-wd-fence-instance-race` (ask `dc456553`) | **Landed on master** in `2204806c0` (SPL-2599). |
| Tokens tab fix C (DejaVu fi360 font) | `claude:c002-tokens-tab-fix-c-dejavu-fi360` (ask `8683f470`) | **Landed on master** in `da2d7dd28` (SPL-2589). |
| Terraform plan branch tree | `claude:c001-tf-plan-branch-tree` (ask `b9a1bea8`) | **Landed on master** in `cc20ba1c8` (SPL-2602). |
| Hub issue get archived auto-closed | `claude:c002-hub-issue-get-archived-autoclosed` (ask `7563641a`) | **Landed on master** in `5953fdfee` (SPL-2607). |
| Seed no self-poll loop | `claude:c001-seed-no-self-poll-loop` (ask `c04d3f65`) | **Landed on master** in `58a3741c4` (SPL-2608). |
| Role failover able needs ack | `claude:c002-bug-failover-able-needs-ack` (ask `10240876`) | **Landed on master** in `7f4a82df6` (SPL-2609). |
| Sign-out leaves read cursors behind | `c-486@sat` (`SPL-2556`) | **Landed on master** in `885470013` (SPL-2556). |

---

## 7. Counts

| item | count (n) |
|---|---|
| rows | 3 (all defect fixes) |
| vendor | claude 3 (orc/iac coding/tests) |
| box (preferred) | sat 3 |
| batches | 2 batches (Batch 1: 2 parallel lanes; Batch 2: 1 lane) |

---

## 8. Expert Panel & Reviewer Assignment (R7)

- **Editor seat (agy):** `a-489@sat`
- **Reviewer seat (claude):** `c-979@PC` (verdict landed in `1ce8ae8e2` at `csi-spl-doc/doc/md/bug-round-2/seat-claude.md`; confirmed by duplicate seat `c-513@sat`, msg `93ed75d0`).
- All 3 rows assigned to Claude for implementation; cross-vendor review enforced before push per rounds-rulebook R7.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor (agy) | a-489@sat | **PASS v1.0** (folded reviewer verdict: widened Row 01 regex and replaced red control; adopted Row 02 logging fallback across all 3 `run.sh` copies; dropped v0.1 Row 02 and Row 04 to Section 4; adopted reviewer proposal P1 as Row 03; updated batches and counts) |
| Reviewer (claude) | c-979@PC | Review completed on v0.1 (`1ce8ae8e2`: 0 agree / 2 agree with changes / 2 disagree / 1 proposal; confirmed by c-513 in msg `93ed75d0`). Awaiting sign-off on v1.0 sha. |
