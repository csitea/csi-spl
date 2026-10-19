# Bug-fix round 2 - plan (4 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Round 2 focus: **measured bug fixes across the fleet: push verification, exit gate issue closer, runner logging robustness, and cron tree writer protection**.  
Concurrency: **build 2 row lanes in parallel at all times** (rounds-rulebook.md §1.1).  
Consensus: **no owner go, no question to the owner** (rulebook §1.4; owner t1 dc15ad65 msg b8e22a15: "do not ask me for input - just reach consensus between all of the members of the panel and start implementation").  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, push caps, bands, R1–R16), by pointer, not copied. Issue: SPL-2564.

**Status: v0.1, DRAFT FOR CROSS-VENDOR REVIEW**. Awaiting cross-vendor reviewer seat (claude).

Editor: **a-489@sat** (agy).  
Reviewer: **pending placement** (claude).  

**One sha:** every count is measured on **`20cdcd400`** (`origin/master`, 2026-10-19), n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else, with a **red control**: the test or check fails on the buggy behavior before the change and passes after.
- **Paths:** repo-relative paths (`csi-spl-orc/`, `csi-spl-iac/`, `csi-spl-wui/`, `csi-spl-api/`). Lines as of `20cdcd400`.
- **Box:** the preferred box (`sat` or other available box); the spawner's placement may move a row (no pin).
- **Vendor:** the owner mix (`do_spl_lane_mix`: simple_coding -> claude, backup grok; complex_coding -> claude, backup grok; tests -> claude, backup grok), then R14. (Mistral writes no code per owner HUM-10 rule; Grok has no quota per c-002 note `6acfc32a`).
- **Subject** (R6 reads it): `<type>(b02-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line, this round:** the review line carries the run it claims:  
  `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.

---

## 2. Where the rows come from (measured on `20cdcd400`)

The 5 mandated candidate sources were investigated systematically:

| source | command | count (n) | status |
|---|---|---|---|
| **1. Owner & member reports in t1 topics / Round 1 retro inputs** | Re-measured 8 candidate inputs from `csi-spl-doc/doc/md/bug-round-1-retro.md` section 7 on `20cdcd400` | 8 inputs evaluated: 4 reproduced defects, 2 measured & not a bug, 1 not reproduced, 1 already fixed on trunk | Input 1 fixed in `ab017f0ad` (SPL-2525); Input 2 adopted in Row 01; Input 3 adopted in Row 02; Input 4 measured & not a bug; Input 5 adopted in Row 03; Input 6 adopted in Row 04; Input 7 not reproduced; Input 8 measured & not a bug (refactor debt). |
| **2. CI gate report (last 40/200 runs)** | `cd csi-spl-iac && CI_GATE_RUNS=200 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` | 21 cancelled, 11 failure, 5 success, 3 running across last 40 runs | Every failed job observed (`wui e2e 6/8`, `wui e2e 5/8`, `distribution-hygiene`, `iac tfvars`) is green on the latest completed runs (`e428729e`, `d33f75a3`). Active trunk defects: n=0. |
| **3. Tests skipped or disabled in code & local flakes** | `git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" -- csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac` | 4 e2e skipped in `ci-skip.txt`; 0 in orc `ci-skip.txt`; 38 Go store skips; 3 allowlisted tests in `tests-hermetic.tst.sh` | 4 e2e in `csi-spl-wui/tests/e2e/ci-skip.txt` require hosting CSP headers, live hub, visual comparisons, or refactors; 38 Go store tests require postgres (`SPOOL_TEST_PG_DSN`); 3 tests in `tests-hermetic.tst.sh` is gate tightening refactor. |
| **4. GC notes (last 24h) & repeating box alarms** | `spool tail --task gc-sat` | 62 bypasses, 212 unclassified lanes; `c-469` waiting on ask `8683f470` | Blocker in `c-469` (tokens tab DejaVu fi360) is already queued as bug ask `8683f470` (`claude:c002-tokens-tab-fix-c-dejavu-fi360`, row 5/40 in spawn queue); owned elsewhere. |
| **5. Open issues describing defects** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd TENANT_ID=t1 DESK_AGENT=c-002 ISSUE_ASSIGNEE='' ISSUE_LIMIT=500 DRY_RUN=0 ./run -a do_spl_issue_list` | 268 open issues scanned | 18 bug-related issues scanned: SPL-1945 (blocked, secret rotation, needs owner); SPL-2556 (wip on c-486@sat); SPL-2467 (todo, session usage limit dialog); remaining items belong to active feature epics. |

---

## 3. The 4 rows

| # | defect & practice | why | sites file:line (max 5) | n | test or red control | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b02-01-orc-push-master-review-regex)` | pre-push review check, gate robustness | `_spl_push_master_unreviewed` in `spl-push-master.func.sh` uses regex `^(test\|refactor\|ci\|fix\|feat\|perf)\((r[0-9]+-[0-9]{2})-`, which strictly matches only `rNN-NN-` refactor rounds. It skips bug rounds (`bNN-NN`) and perf rounds (`pNN-NN`), as well as commits carrying issue keys in scope like `fix(b01-03-orc-desk-cron-safe-dirty-recovery, SPL-2490): ...`. In Bug Round 1, this allowed unreviewed round commits or commits with malformed review lines to land undetected. | `csi-spl-orc/src/bash/run/spl-push-master.func.sh:198-202`<br>`csi-spl-orc/src/bash/features/spawn-agents/tests/test-pre-push-review-line.sh:1-60` | 1 skipped match pattern | Expand regex to match all round prefixes (`(r\|b\|p)[0-9]+-[0-9]{2}`) and allow optional `, SPL-[0-9]+` in subject scope; update test cases in `test-pre-push-review-line.sh`. **Red control:** `python3 -c 'import re; rx = re.compile(r"^(test|refactor|ci|fix|feat|perf)\((r[0-9]+-[0-9]{2})-"); print(bool(rx.match(\"fix(b01-03-orc-desk-cron-safe-dirty-recovery, SPL-2490): test\")))'` returns `False` today; with fix, matches correctly (`True`). | sat | claude | tests | 1 (Lane 1 start) |
| 02 `fix(b02-02-orc-issue-close-landed-worktree-gitdir)` | exit gate issue closer, worktree compatibility | `issue-close-landed.py --keys` fails fatally with exit 128 when git dir is a linked worktree `.git` file (`git -C .git log -1 ...` aborts with `fatal: cannot change to '.git': Not a directory`). In linked worktrees created for agent lanes, `.git` is a regular file containing `gitdir: <path>`, breaking `issue-close-landed.py` when called directly with `.git` or when resolving worktree paths. | `csi-spl-orc/src/bash/scripts/issue-close-landed.py:95-106,221-238`<br>`csi-spl-orc/src/bash/tests/spl-issue-close-landed.tst.sh` | 1 fatal exception (rc 128) | In `issue-close-landed.py` (`keys_of` and `commits`), detect if `gdir` is a file; if so, resolve to its containing directory or parse the gitdir pointer. **Red control:** `python3 csi-spl-orc/src/bash/scripts/issue-close-landed.py --keys .git HEAD` crashes with `subprocess.CalledProcessError: Command '['git', '-C', '.git', 'log', ...]' returned non-zero exit status 128` today; with fix, resolves worktree and prints closed keys cleanly (rc 0). | sat | claude | simple_coding | 1 (Lane 2 start) |
| 03 `fix(b02-03-orc-run-unwritable-log-dir-fallback)` | runner robustness, safe logging fallback | `run.sh` crashes fatally at line 430 (`FATAL Command '[[ "${RUN_LOG_COMPACT:-0}" == "1" ]]' failed at line 430 with status 1`) or line 459 (`Command 'tee -a $log_file' failed at line 459 with status 1`) when `dat/log/bash` cannot be created or written by unprivileged users (e.g. non-root agent). `mkdir -p "$_log_dir"` fails silently (`2>/dev/null || true`), but `LOG_DIR` is still exported to the unwritable directory, causing file redirection `>>"$log_file"` or `tee -a` to fail under `set -e -o pipefail`. | `csi-spl-iac/src/bash/run/run.sh:406-462`<br>`csi-spl-orc/src/bash/run/run.sh:406-462`<br>`csi-spl-orc/src/bash/tests/run-log.tst.sh` | 2 fatal crash sites (line 430, 459) | In `run.sh`, check if `_log_dir` is writable after `mkdir -p`; if not, fall back to `${TMPDIR:-/tmp}/csi-spl-log/bash` or `/tmp`, or omit file redirection with a warning on stderr, so logging failures never abort execution. **Red control:** `RUN_LOG_COMPACT=1 LOG_DIR=/proc/unwritable ./run -a do_check_dist_hygiene` returns status 1 today; with fix, falls back to writable temp directory or stderr warning and completes action cleanly (status 0). | sat | claude | complex_coding | 2 (Lane 1, after 01) |
| 04 `fix(b02-04-iac-guard-tpl-gen-desk-cron-tree)` | tree writer guard, prevent cron checkout pollution | Root-cause defense for recurring cron checkout blockers: `spl_refuse_desk_cron_tree` was introduced in bug round 1 row 04 (`40262df55`) to prevent tree-writing actions from mutating self-updating `*-desk-cron` checkouts. However, `csi-spl-iac` was omitted: `do_tpl_gen` renders files directly into `$cnf_proj` (`csi-spl-cnf/`) without checking `spl_refuse_desk_cron_tree`, allowing cron checkout pollution. | `csi-spl-iac/src/bash/run/tpl-gen.func.sh:13-25`<br>`csi-spl-iac/lib/bash/funcs/spl-desk-cron-tree-guard.func.sh`<br>`csi-spl-iac/src/bash/tests/desk-cron-write-guard.tst.sh` | 0 guards in iac tree writers | Share or add `spl_refuse_desk_cron_tree` in `csi-spl-iac` and wire into `do_tpl_gen` before rendering. **Red control:** `git grep "spl_refuse_desk_cron_tree" csi-spl-iac/src/bash/run/tpl-gen.func.sh | wc -l` is 0 today. Mock cron worktree `APP_PATH=/tmp/mock-desk-cron ./run -a do_tpl_gen` writes files today; with fix, logs `FATAL` and refuses with status 1 without writing. | sat | claude | tests | 2 (Lane 2, after 02) |

---

### 3.1 Disjoint files (R1) & 2 Parallel Lanes

All rows touch strictly disjoint files across batches:
- **Lane 1 (odd rows):** Row 01 (`spl-push-master.func.sh`, `test-pre-push-review-line.sh`) -> Row 03 (`csi-spl-iac/src/bash/run/run.sh`, `csi-spl-orc/src/bash/run/run.sh`, `run-log.tst.sh`)
- **Lane 2 (even rows):** Row 02 (`issue-close-landed.py`, `spl-issue-close-landed.tst.sh`) -> Row 04 (`tpl-gen.func.sh`, `spl-desk-cron-tree-guard.func.sh`, `desk-cron-write-guard.tst.sh`)
- Within each batch, files are completely disjoint:
  - Batch 1: Row 01 vs Row 02 (push review regex in `spl-push-master.func.sh` vs exit closer in `issue-close-landed.py`).
  - Batch 2: Row 03 vs Row 04 (runner logging fallback in `run.sh` vs config tree guard in `tpl-gen.func.sh`).

---

## 4. Measured and not a bug

| candidate | measurement command | result | why not a row |
|---|---|---|---|
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
| `do_spl_push_master` pushes/checks HEAD not logged sha | `claude:c001-push-master-push-logged-sha` (ask `d3ed55d7`, SPL-2531) | Queued in spawn queue (row 2/40); owned by queue ask. |
| Agent kill guard (`pid 0/1`, tmux/cron/systemd) | `claude:c002-bug-agent-kill-guard` (ask `ca4b116f`) | Queued in spawn queue (row 3/40); owned by queue ask. |
| Workdir fence instance race | `claude:c001-wd-fence-instance-race` (ask `dc456553`) | Queued in spawn queue (row 4/40); owned by queue ask. |
| Tokens tab fix C (DejaVu fi360 font) | `claude:c002-tokens-tab-fix-c-dejavu-fi360` (ask `8683f470`) | Queued in spawn queue (row 5/40); owned by queue ask. |
| Terraform plan branch tree | `claude:c001-tf-plan-branch-tree` (ask `b9a1bea8`) | Queued in spawn queue (row 6/40); owned by queue ask. |
| Hub issue get archived auto-closed | `claude:c002-hub-issue-get-archived-autoclosed` (ask `7563641a`) | Queued in spawn queue (row 7/40); owned by queue ask. |
| Seed no self-poll loop | `claude:c001-seed-no-self-poll-loop` (ask `c04d3f65`) | Queued in spawn queue (row 8/40); owned by queue ask. |
| Role failover able needs ack | `claude:c002-bug-failover-able-needs-ack` (ask `10240876`) | Queued in spawn queue (row 9/40); owned by queue ask. |
| Sign-out leaves read cursors behind | `c-486@sat` (`SPL-2556`) | **Landed on master** in `885470013` (SPL-2556). |

---

## 7. Counts

| item | count (n) |
|---|---|
| rows | 4 (all defect fixes) |
| vendor | claude 4 (orc/iac coding/tests) |
| box (preferred) | sat 4 |
| batches | 2 batches of 2 rows (2 parallel lanes at all times) |

---

## 8. Expert Panel & Reviewer Assignment (R7)

- **Editor seat (agy):** `a-489@sat`
- **Reviewer seat (claude):** pending placement by dispatcher upon v0.1 push.
- All rows assigned to Claude for implementation; cross-vendor review enforced before push per rounds-rulebook R7.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor (agy) | a-489@sat | **PASS v0.1 draft** (initial draft submitted for cross-vendor expert review) |
| Reviewer (claude) | pending | Awaiting reviewer seat placement by dispatcher |
