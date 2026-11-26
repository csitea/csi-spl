# Bug-fix round 50 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6559 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `24945ee2-1ff1-432f-9773-d9d20376ce55` ("Bug round 50", opened by c-002@sat 04:56Z 2026-11-26, post `199274ac`). Round 49 ([bug-round-49-plan.md](bug-round-49-plan.md)) served both rows b49-01 (`83f76bb5f`, SPL-6555) and b49-02 (`460750a35`, SPL-6556), and is closed (`50f2cbfa5`, written by a-895@sat; holder R6 post `2b5a5c47`, topic `4dcc34cd` archived).  
Round focus: the sources of rounds 40 to 49 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since b49 open and W, owner posts), round 49's first inputs, and the holder's candidate list on sat.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. Two disjoint candidates met the bar (section 3), matching the aim of 2; bug share is 15% (band 30-40%: UNDER, 05:01Z, `do_spl_spawn_share`).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-49-plan.md](bug-round-49-plan.md).

**Status: v1.0, signed: c-902 (claude) PASS on v0.7 `ce2c75f9f` (landed `fee404830`), W none, N12 noted; W1 to W6, N1 to N3, and N5 to N11 folded (section 8).** **Closed**: rows b50-01 (`3ce429f73`, SPL-6574) and b50-02 (`86ac09501`, SPL-6576) both landed and served (section 8).

Editor: **a-927@sat** (agy, `specs_and_docs`).  
Panel: **c-902@<box2>** (claude, cross-vendor; placed on `dispatch-bug-r50`, ask `22fd2cf9`, named by holder `c-002@sat` msg `4ab85f5a`; mistral sits on no review since 2026-11-25).

**One sha:** every site, line number and red control below is on **`6b216a319`** (`origin/master`, `2026-11-26T04:54:24Z` / `2026-11-26T06:54:24+02:00`, r05-01 `refactor(r05-01-orc-orch-rotate-simple-cron-apply, SPL-6557)`). Re-checked at v0.7 (`08:04Z`): `origin/master` is `c28e628f2` (`git diff --name-only 6b216a319 origin/master -- <the 3 row files>` -> empty, 0 drift). The sources of section 2 were read on sat, 04:59Z..05:09Z on 2026-11-26 (and candidate-list git history checked at 05:35Z). n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b49-plan')` read once at 05:00:01Z -> `Window: W=2026-11-26T06:53:46+02:00` (commit `50f2cbfa5`, round 49's close record). Because only 1 commit (`6b216a319`, r05-01) landed since W, section 2 also audited the full round 49 window since `0d5e0b252` (b48 close record / b49 open, `03:15:24Z`, 11 commits, 6 `review:` lines) so no R7 note or incident between `0d5e0b252` and `6b216a319` was missed.

---

## 1. How to read this

- `<box2>` is the fleet's box that is not sat and `<dev-box>` one unpinned workstation box, as in rounds 21 to 49: the public repo names none of them.
- **Paths** are repo-relative. Line numbers are as of `6b216a319`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red controls are printed verbatim in section 4 (`rc01-b50.sh` updated at v0.7 per panel W1 to W6 & N7; `rc02-b50.sh` kept byte-identical from v0.1 `add3ec96f` so the panel's verified v0.1..v0.6 runs hold). Each is self-contained (zero box paths, runnable on any machine including `<box2>`), copies files from the named sha with `git archive` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout or live spool. Each site guard checks function names only, so `bash rc0N-b50.sh <fix sha>` (without `fix-shape`) exits 0 on a valid fix.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs).
- This seat runs on sat, so `/var/spool-hub/dispatch/c002-next-round-candidates.md`, `/var/spool-hub/dispatch/automation.log`, recent author briefs under `/var/spool-hub/dispatch/briefs/`, and `c-001`/`c-002`/`c-003` + recent R7 outboxes/archives were read directly; sat-only evidence is quoted inline below so the `<box2>` panel seat can audit it directly.

---

## 2. Where rows could come from (measured since `0d5e0b252` and W)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=6h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (05:00:30Z) | 8 entries in 6 h (**0 since W** `04:53:46Z`; 4 since b49 open `03:15:24Z`, all Cloud SQL `spool_hub_rt` ad-hoc SQL errors at `03:57:44Z..03:59:31Z`: `operator does not exist: uuid ~~ unknown`, `relation "topics" does not exist`, `column "id" does not exist`, `column "created_at" does not exist`) | **0 rows.** Repeating ad-hoc `do_spl_db_query` SQL errors (section 3.4); 0 Cloud Run errors since `01:39:34Z`. |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=6h ./run -a do_gcp_list_alert_incidents` (05:00:15Z) | 9 policies, 0 incidents in 23:00:15Z..05:00:15Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,120), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (05:00:31Z) | 6 issues (3 `wip` in the release-transfer repo: SPL-6361, 6362, 6366; 3 `onhold`: SPL-5911, 5254, 4994) plus SPL-6559 (this round, priority 2) | **0 rows.** 0 open `csi-spl` `eval`/`todo`/`wip` bug-labelled issues outside this round. |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (04:59:36Z..05:04:13Z, background) | 100 runs, 2026-11-25T10:36:20Z..2026-11-26T04:54:17Z: 68 success, 23 cancelled, 6 failure, 3 running; every job's p90 under 75% of its timeout (highest: hermetic 3/4, 61%). **0 failed runs since b49 open (`03:15:24Z`) or W (`04:53:46Z`)** (all 6 pre-b49: 3 `release-note`, 2 `wui e2e 5/8`, 1 `orc feature`) | **0 rows**: section 3.3. Trunk is green (`last green 45754642858` on `83f76bb5`, `04:21:04Z`). |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 25 --json databaseId,workflowName,headSha,createdAt,conclusion` (05:00:25Z), `createdAt >= 2026-11-26T03:15:24Z` | **0 failed runs** across all workflows since b49 open (`03:15:24Z`) or W (`04:53:46Z`) (newest failure is pre-b49 `45678338355` at `2026-11-25T18:45:14Z`); `do_check_deploy_lag` dev and prd both `current` (hub `5aa360af`, wui `7e7962df`, `n=0`) | **0 rows.** |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=6h LINES=5000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (05:00:30Z; cap not reached), plus 16 h targeted `hours/minutes` read (05:01Z) | 445 entries in 6 h (**0 since W** `04:53:46Z`; 12 since b49 open `03:15:24Z`: 4 `unpinned_box`, 8 internet/scanner 404s; `unknown_token` = 372 in 6 h, 0 since `03:15:24Z`). Targeted 16 h `hours/minutes` read: 169 entries (146 HTTP 200, 23 HTTP 204), **0 HTTP 400s and 0 `hours: minutes refused` warns** | **0 rows**: section 3.4. |
| **7. R7 notes & automation logs since `0d5e0b252`** | `git log 0d5e0b252..6b216a319 --format=%B`, `c-001`/`c-002`/`c-003` spool archives & R7 outboxes (`a-909`, `a-911`, `a-920`, `a-922`, `a-826`, `c-722`), and `/var/spool-hub/dispatch/automation.log` tail | 11 commits (`0d5e0b252..6b216a319`, 1 since W), 6 `review:` lines (4 code R7: `a-909` b49-02, `a-911` b49-01, `a-920` r05-02, `a-922` r05-01; 2 plan panel: `c-896` b49, `c-893` r05): `a-909` N1-N2 (`eaf6e4d6`, `_y9_qwen_backup` silences non-`EEXIST` OS errors + mode/k2 test); `a-911` N1-N2 (`2496d1bf`, documented YAML ban-list limits + `d6` rc); `a-920` N1-N2 (`37b77b72`/`a1686f64`, eager `id -un` + header list); `a-922` N1-N2 (`c222573b`, eager `printf` + body sha); `review-go` rc 4 false holds on r05-02 (`51ae6640`, `dd406194`) and r05-01 (`ba3dbedb`), ruled false (`0da5ca10`, `27e89eef`) | **Row b50-01** (section 3.1). `a-826` N2 on SPL-6517 stays with live lane `c-722@sat` (R3, unlanded at 05:04Z); `a-909` N1-N2 carried as first input for b51 (section 3.5). |
| **8. Owner and member posts** | `ENV=prd SQL="select tenant_id, from_id, count(*), max(accepted_at) from messages where from_id like 'HUM-%' and accepted_at > '2026-11-26T00:00:00Z' group by 1, 2 order by 1, 2" ./run -a do_spl_db_query` (05:00:41Z) | 0 rows across all workspaces | **0 rows.** |
| **9. Round 49's first inputs** | `bug-round-49-plan.md` section 7 and seat file (`review/c002-bug-round-49-claude-seat` `eecbe84a3`), re-measured on `6b216a319` | `a-841` N1 (`setup-gh-runner-cpu-budget-cron.tst.sh:83-91` section 4 red control copies only one `.func.sh` into `$T/`, crashing with rc 127 / 3 stderr errors on relative `source` before running the function) reproduces cleanly on `6b216a319`; r05 is landed so cron tests are free | **Row b50-02** (section 3.2). Rest accounted in section 3.5. |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (145 lines, read on sat 04:59Z; older bug sections cross-checked against `git log 6b216a319` at 05:35Z, panel N3) | `:141-145` (`review-go` owner-go rc 4 false holds on r03..r05; direct run on newest 100 author briefs: **6/6** r03..r05 briefs falsely held, 10/10 other held briefs stay held). Older bug sections (`:1-140`): majority already served on `6b216a319` (`b20-01`..`b49-01`, incl. `b27-01`, `b28-01`, `b29-02`, `b48-01`), remainder carried or explicitly marked not re-measured (section 3.5) | **Row b50-01** (section 3.1), with empirical root-cause correction: identifiers `_spl_simple_cron_apply` / branch slugs ALREADY pass SPL-5798; actual triggers are `"Apply ... verbatim ... hunks"` and standalone `` `DRY_RUN=0` ``. |

---

## 3. The candidates, read

### 3.1 b50-01: `_spl_review_go_instr` (`spl-review-go.func.sh:695-741`) falsely holds refactor author briefs (rc 4) on code-hunk `"Apply ... verbatim ... hunks"` prose and standalone backticked `` `DRY_RUN=0` `` flag literals

- **What happens.** Running `_spl_review_go_owner_go` (`csi-spl-orc/src/bash/run/spl-review-go.func.sh:772-800`) on `6b216a319` across the newest 100 author briefs on sat held 16 briefs — and **6 of 6** refactor briefs from rounds r03, r04, and r05 (generating 7 live rc 4 false holds in 6 hours, each forcing manual inspection and manual GO by the holder and `c-001`):
  - **Empirical correction to `c002-next-round-candidates.md:145`:** helper names (`_spl_simple_cron_apply`, `_spl_run_cron_apply`) and branch slugs (`r05-02-orc-run-cron-apply-wave1`) do **not** trigger `'Apply'` — SPL-5798 (`spl-review-go.func.sh:773`) already excludes `apply` joined by `_`, `-`, `.`, or `/`. Direct execution of `_spl_review_go_owner_go` on all 6 briefs shows TWO exact false-hold triggers:
  1. **Code-hunk apply prose (`r04-01:24`, `r04-02:24`, `r05-01:48`, `r05-02:56`):** every refactor brief's step 2 instructs the lane to edit source files with `"2. Apply section 1.3's verbatim hunks to ONLY the row's files..."` (r05-01), `"2. Apply section 1.4's verbatim hunks to ONLY the row's files..."` (r05-02), `"2. Apply 1.3's verbatim helper, caller, and test hunks to ONLY those 4 files..."` (r04-01), or `"2. Apply 1.4's verbatim helper, caller, and test hunks to ONLY those 5 files..."` (r04-02). `_spl_review_go_instr` strips negated `apply` (`does not apply`, `no terraform apply`), not `apply` whose direct object is `verbatim ... hunk(s)` / `patch(es)`.
  2. **Standalone backticked flag literal `` `DRY_RUN=0` `` (`r03-01:19`, `r03-02:40`, `r05-01:32`, `r05-02:39`):** test descriptions and plan-table rows name the flag token alone in single backticks — e.g. `` standalone `DRY_RUN=0` install/check/remove lifecycle check `` (r05-01), `` standalone lazy-load `check`-missing and `DRY_RUN=0` install `ok_msg` checks `` (r05-02), `` `DRY_RUN=1` preview log, and `DRY_RUN=0` `ORDERED_BY` check `` (r03-01, inside a 10-column plan-table cell), `` standalone `DRY_RUN=0` install `ok_msg` checks covering all three installers `` (r03-02) — with no command on that line (or table cell) or on the next non-blank line. Even with trigger 1 fixed, both `r05-01` and `r05-02` still hold rc 4 on `'DRY_RUN=0'` without trigger 2.
- **Why this resolves round 49's design tension AND panel W1 without weakening any real owner-go hold:**
  - **(a) Verbatim code-hunk/patch `apply` (narrowed per panel W1):** strip ONLY the word `apply` when `verbatim` stands between `apply` and `hunks?` / `patch(?:es)?` on the same line (up to 4 words before `verbatim`, up to 6 words after), **AND** the line names no target/infra word anywhere (`prd|prod|production|dev|live|database|db|schema|sql|migrations?|steps?|terraform|tf|tfvars|gcp|cloud|iam|billing|infra|provision`, word-bounded so identifiers like `do_spl_cloud_cnf` do not false-trigger). Every non-verbatim or target-bearing apply holds rc 4 — including `Apply the patch on dev and prd.`, `Apply the tfvars patch for step 016.`, `Apply the SQL hunks to the live database.`, `Apply the schema patch to the hub database.`, `Apply 1.3's verbatim SQL hunks to the live database.`, `terraform apply`, `apply the migration to prd`.
  - **(b) Standalone backticked `` `DRY_RUN=0` `` (narrowed per panel W1 + W2 + W3 + W4 + W5 + W6 + N7 + N8 + N10 + N11):** strip `` (?<!`)`DRY_RUN=0`(?!`)(?=[^\S\n]+(?:`ORDERED_BY`|install[^\S\n]+`ok_msg`|install/check/remove[^\S\n]+lifecycle)[^\S\n]+(?i:checks?|tests?|cases?)\b) `` ONLY when the exact uppercase flag token `` `DRY_RUN=0` `` is followed on the same line by **one of the three literal real gaps** (`` `ORDERED_BY` ``, ``install `ok_msg` ``, or `install/check/remove lifecycle` — **no open slot at all**, W6/N11) and `(?i:checks?|tests?|cases?)` (N7/N8: `(?i)` dropped on the `` `DRY_RUN=0` `` flag token so non-canonical lowercase spellings are not freed by the fix — note `dry_run=0` is rc 0 on the base too because `:778` greps without `-i` — while `(?i:...)` is kept on the test nouns; N6: `install/check/remove lifecycle check` is verbatim from `/var/spool-hub/dispatch/briefs/c002-r05-01-orc-orch-rotate-simple-cron-apply.md:32`, and all 4 real `DRY_RUN=0` false-hold lines use only those exact three literal gaps before `check`/`checks`: `` `DRY_RUN=0` `ORDERED_BY` check ``, `` `DRY_RUN=0` install `ok_msg` checks ``, `` `DRY_RUN=0` install/check/remove lifecycle check ``) **AND** neither its line nor the next non-blank line holds a command token (`./run`, `&&`, `-a do_`, `--prd`/`--prod`, `terraform`, `gcloud`, `do_provision`/`do_tf_*`/`do_gcp_*`/`do_spl_desk_up`/`do_spl_issue_*`/`do_spl_topic_*`/`do_spl_private_*`/`do_spl_tenant_*`, or a space-followed shell/tool command `make|sudo|python[0-9]*|bash|sh|perl|node|psql|kubectl|docker|curl|ssh|cd` with `(?<!\.)` so `.sh` filenames on a next line do not false-match). For wide Markdown plan tables (`l.lstrip().startswith("|")` with `>= 4` columns, i.e. `l.count("|") >= 5`, and no command on the next non-blank line), check the command regex per `|`-delimited cell so a test-column `cd csi-spl-iac && ./run -a do_check_pre_push` does not poison another cell, while a 4-column table cell containing bare `` `DRY_RUN=0` `` with no literal gap + `check/test/case` (W2) or a 2-column command table still holds rc 4. Because the three gaps are literal with zero open slots (W6/N10/N11), any future real test-description shape becomes a false hold (cleared by hand and added as a fourth literal in a later round) rather than a false GO; the 42 HOLD controls serve as the regression floor, and the b50-01 R7 seat writes its own independent write-now probes (panel N9).
  - Every single one of panel `c-902` W1's 9 step shapes (+ blank-line continuation & 2-column table), panel `c-902` W2's 4 write-now shapes (4-col next-cell command, previous-line dry-run + "run it again with `` `DRY_RUN=0` ``", direct script path `` `DRY_RUN=0` `.../box-disk-sweep.sh` ``, plain prose ``with `DRY_RUN=0` to write the hub``), panel `c-902` W3's 4 prose write-now shapes naming a test (`and test the hub`, `so the check passes`, `for all cases`, dry-run then `repeat with DRY_RUN=0 and test it`), panel `c-902` W4's 3 temporal/conditional prose write-now shapes naming a test (`when tests pass`, `after checks pass`, `before every check`), panel `c-902` W5's 5 wide-slot write-now shapes (`` `do_spl_lane_issue` test ``, `` `ENV=dev` check ``, `install test`, `dev/prd check`, `` `bin/sweep.sh` check ``), panel `c-902` W6's 6 free-slot write-now shapes (`` `psql` check ``, `` `make` test ``, `` `sudo` check ``, `` `PRD` check ``, `` `live_hub` check ``, `lifecycle test`), case 4 (bare `DRY_RUN=0`), and case 24 (`` `ENV=prd DRY_RUN=0 ./run -a do_x` ``) **holds rc 4** (42 HOLD controls total).
  - Re-checked on the newest 100 author briefs on sat (08:06Z, excluding `-(reviewer|seat|planner).md`: `base_held=18`, `w6_held=10`): **only** the 8 r03..r06 refactor briefs (`r03-01`..`r05-02` plus newly queued `r06-01`, `r06-02`) flip `HOLD -> GO`, all 10 other held briefs **stay `HOLD`**, and 0 previously-passing briefs flip (0 false negatives).
- **Seen.** Live holds in `/var/spool-hub/dispatch/automation.log` and `c-001` spool messages: `r03-01` (`7b492c13`), `r03-02` (`1dd01968`), `r04-01` (`aa88f70c`, `56a64404`), `r04-02` (`31c581c0`, `d05ddaad`), `r05-02` (`51ae6640`, `dd406194`, ruled false `0da5ca10`), `r05-01` (`ba3dbedb`, ruled false `27e89eef`); `c002-next-round-candidates.md:141-145`. Verified on `6b216a319` (`_spl_review_go_instr` is 47 lines at `:695-741`, 63 lines with v0.7 fix-shape <= 75; `_spl_review_go_owner_go` is 29 lines at `:772-800`; baseline `spl-accepted-close.tst.sh` -> `0 failure(s)`, `spl-review-go.tst.sh` -> `0 failure(s)` on base and on v0.7 W1-W6 fix-shape).
- **Red control** (`rc01-b50.sh`, section 4.1, updated at v0.7 per panel W1-W6 & N6-N11): self-contained (inline brief snippets from r03-01..r05-02, zero box paths; `red_r05_01` `install/check/remove lifecycle check` verbatim from `c002-r05-01-orc-orch-rotate-simple-cron-apply.md:32`). Extracts `spl-review-go.func.sh` from `6b216a319` and runs `_spl_review_go_owner_go` on 1 identifier control (`_spl_simple_cron_apply` / `_spl_run_cron_apply` / `r05-02-orc-run-cron-apply-wave1` -> `rc=0` on both base and fix), 6 RED cases (real r05-01, r05-02, r04-01, r04-02, r03-01 [4-col table with `cd csi-spl-iac && ./run -a do_check_pre_push`], r03-02 lines -> want `rc=0`), and **42 HOLD controls** (9 original + 11 panel `c-902` W1 probes + 4 panel `c-902` W2 probes + 4 panel `c-902` W3 probes + 3 panel `c-902` W4 probes + 5 panel `c-902` W5 probes + 6 panel `c-902` W6 probes -> want `rc=1`). On `6b216a319`: all 6 RED cases return `rc=1` -> `rc01 exit 1`. **Control:** `fix-shape` applies the narrowed W1-W6 rules in `_spl_review_go_instr` -> all 6 RED cases return `rc=0` and all 42 HOLD controls stay `rc=1` -> `rc01 exit 0`.
- **Fix scope.** `csi-spl-orc/src/bash/run/spl-review-go.func.sh:670-741`:
  - Update `_spl_review_go_instr`'s comment (`:670-694`) and Python body (`:739`) with the narrowed W1-W6 rules (a) and (b) above (exact uppercase `` `DRY_RUN=0` `` followed by one of the three literal gaps `` `ORDERED_BY` ``, ``install `ok_msg` ``, or `install/check/remove lifecycle` and `(?i:checks?|tests?|cases?)`, zero open slots). Keep `_spl_review_go_instr` <= 75 lines (47 -> ~63 lines).
  - `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`: add case 34 after `:1332` (and document it in the header comment) covering all 6 false-hold shapes (r03..r05 lines -> GO) and all **42 HOLD controls** (original 9 + 11 panel `c-902` W1 shapes + 4 panel `c-902` W2 shapes + 4 panel `c-902` W3 shapes + 3 panel `c-902` W4 shapes + 5 panel `c-902` W5 shapes + 6 panel `c-902` W6 shapes -> rc 4). `Docs: none` (narrows owner-go false-positive filter in existing spec 157 rule 1 automation; action comment updated).

### 3.2 b50-02: `setup-gh-runner-cpu-budget-cron.tst.sh:83-91` section 4 red control is vacuous — copies one `.func.sh` into `$T/`, crashing on relative `source` before running the action

- **What happens.** `csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh:83-91` tests that stripping `CPU_BUDGET_GATE_FLOOR_PCT=%s` from `setup-gh-runner-cpu-budget-cron.func.sh` causes `check_default` to fail:
  ```bash
  sed -e 's/%sCPU_BUDGET_GATE_FLOOR_PCT=%s CPU/%sCPU/' -e 's/"\$pre" "\$floor" "\$reserve"/"$pre" "$reserve"/' "$FUNC" >"$T/nofloor.func.sh"
  ...
  elif check_default "$T/nofloor.func.sh"; then
    fail "red control: a copy without the floor still passed check 1"
  else
    pass "red control: an installer without the floor fails check 1"
  ```
  However, `setup-gh-runner-cpu-budget-cron.func.sh:35-40,69` resolves its sibling helpers relative to `"$(dirname "${BASH_SOURCE[0]}")"` (`../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh` and `./setup-box-stats-cron.func.sh`). Because `$T/nofloor.func.sh` lives directly in `$T/` with no relative `lib/` or sibling `.func.sh` files, `setup "$T/nofloor.func.sh" DRY_RUN=0` crashes with `rc=127` and emits 3 stderr errors on every run of the test:
  ```
  .../nofloor.func.sh: line 40: .../../../../lib/bash/funcs/spl-desk-cron-checkout.func.sh: No such file or directory
  .../nofloor.func.sh: line 69: .../setup-box-stats-cron.func.sh: No such file or directory
  .../nofloor.func.sh: line 70: _spl_simple_cron_apply: command not found
  ```
  Because `check_default` returns 1 whenever `setup` exits non-zero, **even an unmodified copy of `$FUNC` in `$T/` fails `check_default`**, and a mutated installer whose `sed`-stripped copy STILL emits `CPU_BUDGET_GATE_FLOOR_PCT=500` still passes section 4 with `rc=0`. Section 4 never exercises `do_setup_gh_runner_cpu_budget_cron` at all.
- **Seen.** `a-841@sat` R7 N1 (r03-02); carried as first input #1 in `bug-round-49-plan.md` section 7. Reproduced live on `6b216a319` (`bash csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh` exits 0 while printing the 3 stderr errors above; running `setup` on an unmodified copy in `$T/` exits 127; baseline `apply-gh-runner-cpu-budget.tst.sh` -> `all passed`). Confirmed ready as written by panel `c-902@<box2>` on v0.1 (`b423c21a5`).
- **Red control** (`rc02-b50.sh`, section 4.2, kept byte-identical from v0.1): self-contained (extracts `csi-spl-orc/lib/bash/funcs`, `csi-spl-orc/src/bash/run`, and `setup-gh-runner-cpu-budget-cron.tst.sh` from `6b216a319` into `mktemp -d`, mutating zero lines of the test under test):
  - **Case A (`clean_run`):** runs `bash "$tst"` capturing stderr -> requires `rc=0` and **0** `No such file or directory|command not found` lines on stderr. On `6b216a319`: `rc=0`, `stderr_source_errs=3 (want 0)`.
  - **Case B (`non_vacuous_mutant`):** inserts one line after `setup-gh-runner-cpu-budget-cron.func.sh:67` in a temp copy so that even after section 4's `sed` strips `%sCPU_BUDGET_GATE_FLOOR_PCT=%s CPU`, `$line` restores `CPU_BUDGET_GATE_FLOOR_PCT=500`. Runs `bash "$mtst"` -> a non-vacuous section 4 MUST fail (`rc!=0`) with `FAIL: red control: a copy without the floor still passed check 1`. On `6b216a319`: `rc=0 (want 1) caught=0 (want 1)` -> `rc02 exit 1`.
  - **Control (`fix-shape`):** stages section 4 in `$T/rc/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh` with symlinks to `"$PROJ_ROOT/lib"` and sibling `"$PROJ_ROOT/src/bash/run/"*.func.sh`, proves an unmodified copy passes `check_default`, and proves the stripped copy runs cleanly (`setup "$RC_FUNC" DRY_RUN=0` exits 0) yet fails `check_default` -> Case A `rc=0 stderr_source_errs=0`, Case B `rc=1 caught=1` -> `rc02 exit 0`.
- **Fix scope.** `csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh:83-91`:
  - Stage section 4 under `$T/rc/src/bash/run` with `$T/rc/lib -> $PROJ_ROOT/lib` and symlinks for sibling `*.func.sh` files (excluding `setup-gh-runner-cpu-budget-cron.func.sh`).
  - Add a positive control asserting an unmodified copy in `$T/rc/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh` passes `check_default`.
  - Write the `sed`-stripped copy to that same staged path; assert `setup "$RC_FUNC" DRY_RUN=0` itself exits 0 (no broken relative `source` or `command not found`) before asserting `! check_default "$RC_FUNC"`. Keep all existing assertions (sections 1..3 and 5) green with zero stderr noise. `Docs: none` (test-only fix to a vacuous red control; no runtime behaviour changes).

### 3.3 CI reds in the 100 runs, read

| run range | job | first red line | why not a row |
|---|---|---|---|
| **Since b49 open (`03:15:24Z`) and W (`04:53:46Z`)**: none | all jobs | 0 failed runs across wf 10 and every other workflow on master | **0 rows**: trunk is green (`last green 45754642858` on `83f76bb5`, `04:21:04Z`). |
| `45678338355`, `45674842811` (2026-11-25 18:24Z..18:45Z, pre-b49) | wui e2e 5/8 | `FAIL 360 login no-bfcache L3>L2>L1>L1>out Back never re-parsed /login` | **Served**: fixed by SPL-6531 `672162eb9` (green since). |
| `45661882286` (2026-11-25 17:10Z, pre-b49) | orc feature tests | `FAIL - 1. sent, exit 0 (want '0', got '137')` | **Served**: pre-b49, green since. |
| `45596579656`..`45598661206` (2026-11-25 10:36Z..10:49Z, pre-b49) | release-note | `FAIL release-note: 222f6efe (full) missing Lay-What ...` | **Served**: pre-b49, green since. |

### 3.4 The prd WARNING and repeating ERROR lines, read

| candidate | read | why not a row |
|---|---|---|
| Cloud SQL `spool_hub_rt` ad-hoc SQL errors (`03:57:44Z..03:59:31Z`, 4 entries since b49 open, 0 since W): `uuid ~~ unknown`, `relation "topics" does not exist`, `column "id" does not exist`, `column "created_at" does not exist` | exploratory ad-hoc `do_spl_db_query` queries (no repo code runs them) | **Not a row**: ad-hoc operator/agent SQL. |
| `upload token refused` (`unknown_token`), 372 in 6 h (**0 since `03:15:24Z` and 0 since W**) | same box question carried since round 43 | **Not a row**: carried with holder. |
| `ws hello refused` (`unpinned_box`), 12 in 6 h (4 since `03:15:24Z`, 0 since W) | `<dev-box>` unpinned client retries | **Not a row.** |
| Internet/scanner 404s (8 since `03:15:24Z`, 0 since W) | expected `/sftp-config.json`, `robots.txt`, `/v1/catalog/services`, WordPress scanner probes | **Not a row.** |
| `PUT /v1/me/hours/minutes` >=400 / `hours: minutes refused` | 169 entries in 16 h (146 HTTP 200, 23 HTTP 204), 0 HTTP 400s and 0 warn lines | **Carried**: wait for a live `hours: minutes refused` warn before deciding spec 107 / WUI follow-up. |

### 3.5 Round 49's first inputs, recent R7 notes, and the candidate list, re-read

| candidate | result on `6b216a319` | verdict |
|---|---|---|
| `review-go` owner-go rc 4 false holds (`c002-next-round-candidates.md:141-145`; r03..r05, n=7 live holds in 6 h, brief input) | re-measured directly on newest 100 author briefs: 8/8 r03..r06 briefs falsely held on `"Apply ... verbatim ... hunks"` and standalone `` `DRY_RUN=0` `` naming a check (SPL-5798 already covers `_spl_simple_cron_apply` / slugs); narrowed per panel W1-W6 & N7 in `rc01-b50.sh` (all 42 HOLD controls stay rc 1) | **Row b50-01** (section 3.1). |
| `a-841` N1 (`setup-gh-runner-cpu-budget-cron.tst.sh:83-91` vacuous section 4 red control, b49 first input #1) | verified on `6b216a319` (3 stderr errors on normal run; mutant passes with rc 0); reproduced in `rc02-b50.sh`; r05 is landed so cron tests are free | **Row b50-02** (section 3.2). |
| `a-909` N1 & N2 (`eaf6e4d6`, b49-02 `460750a35`): `_y9_qwen_backup` (`y9-vendor-lane-rule.sh:102,107`) silences non-`EEXIST` OS errors (e.g. read-only `~/.qwen`, `ENOSPC`) and loops 99x reporting `no free backup name`; `test-agy-qwen-fleet-rules.sh` lacks direct mode `0600` & `k=1 -> k=2` assertions | real parity gap vs `y8-vibe-agents.py:60` (still fails closed, `QWEN.md` untouched); round already at rulebook 5.1 aim of 2 | **Carried** as first input #1 for round 51. |
| `apply-gh-runner-cpu-budget.tst.sh` red control (`/tmp/.../red/spl-lane-map.func.sh:72,74` relative `source` `No such file or directory` x6 on stderr during baseline run at 05:08Z) | observed live during b50-02 sibling baseline run (`apply-gh-runner-cpu-budget.tst.sh`); same single-file-copy pattern as b50-02 | **Carried** as first input #2 for round 51 (separate file, keeps b50-02 narrow). |
| `a-911` N1 & N2 (`2496d1bf`, b49-01 `83f76bb5f`): YAML flow mappings / multi-line `when:` lists / space-before-colon (already documented ban-list limits at `:37-43`); `customer-box-role-set.tst.sh:160-165` `d6` omits explicit `rc != 0` check | N1 documented; N2 minor test check (same directive already checked by `p1`) | **Carried** (low priority). |
| `a-920` N1-N2 (`37b77b72`/`a1686f64`, r05-02 `62c5bea32`) & `a-922` N1-N2 (`c222573b`, r05-01 `6b216a319`) | eager `$(id -un)` / `$(printf '%02d' "$min")` (zero behaviour change, already in r05 plan N6), test header comment stops at section 10, commit body sha note | **Not bug rows** (zero runtime defect). |
| `a-826` N2 on SPL-6517 (`spool-live-ack.sh` log size cap, brief input) and `a-767` N2 / `a-823` N2 (`spool-agent-hook.sh`) | SPL-6517 is STILL live (`git log origin/master --grep=SPL-6517` -> 0; `c-722@sat` and `a-826@sat` both live in `do_spl_lane_map` at 05:00Z) | **Left to `c-722@sat`** (R3; brief: leave unless SPL-6517 lands without it). |
| `a-769` N1 (`check-pre-push-lint.func.sh:618-643` `_ppl_run_timed` checks `trc` from `tail` = 124, never 137 even when `kill -KILL -- -$pg` fires at `:639`) & `a-769` N2 (`tenant-host-reserve.tst.sh` symlink control); `a-790` N1 (`internal/mcp/mcp_test.go:560-563` control ambient env) | verified on `6b216a319` (`_ppl_run_timed` is R9 gate code and `_pp_run` at `check-pre-push.func.sh:1114` treats 124 and 137 identically) | **Carried** to round 51. |
| `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`) | SPL-6438 landed (`5aa360afc`, `c-298@sat` `done` at 05:00Z); unblocked for re-measurement next round | **Carried** to round 51 (now unblocked). |
| Candidate list older bug sections (`c002-next-round-candidates.md:1-140`, panel N3; checked against `git log 6b216a319` at 05:35Z) | **Served on `6b216a319`:** `b20-01` (`2f634fbd4` retired-author GO loop), `b21-02` (`1ce9158a1` msg sweep skips master), `b22-02` (`3e46a758c` review-notify Author: line), `b23-02`/`b31-02` (`a6f5a723d`/`0e9efb6c2` done-claim sha256), `b26-01` (`c540aca24` blog switcher e2e), `b27-01` (`656ab3389` review-go `elsewhere` on master + loop), `b27-02`/`b28-01`/`b29-02` (`21abdb87e`/`2547249ec`/`ae4898ae1` `-panel-seat` UI swap), `b29-01`/`b33-02` (`ac367b7a5`/`22f50f64f` quota reading on cred copy & token-key private 0600 off argv), `b30-01` (`9b680e7b5` CI-first queue), `b30-02` (`b341f7bb8` dead `/tmp` worktrees sweep), `b30-03` (`6f2a343bb` `After:` far-box key), `b31-01` (`8b7828a6b` bare `Author:` box), `b32-02` (`1fadfb77b` review-notify `wip/` branch), `b33-01`/`b34-02` (`d42ec95e8`/`0d0797fde` docs lane `Issue-Role: shared`), `b36-02`/`b48-02`/`b49-01` (`cd1c499ee`/`917d60ce4`/`83f76bb5f` customer-box role check), `b42-01`/`b44-02` (`c41b7080e`/`158664186` duplicate `component` key), `b44-01`/`b45-01`/`b46-03`/`b48-01` (`14b6055c2`/`958049e92`/`f2cb19298`/`61a325ebc` review-go prohibition/conditional/dedup), `b46-02` (`fe9df375a` store categories `zz` prefix). **Carried:** `TestHiddenUnreadBufferBudget`/`TestMarkedUnreadBufferBudget`, `i18n-lang-review-exempt.json:2`, composed testids, SPL-6174 cross-workspace commit-links & gct scope. **Not re-measured this round:** OS-user non-hermetic suites (11-19), unanswered-sweep detectors A/B, `unanswered-sweep.tst.sh` section 12, `b29-01` N1/N6, `topic_loop_fire.go` concurrent cap atomicity, stale per-seat report, AltGr `kind-picker-keys.ts` (11-18), lease vendor order failover revert (11-21), release-transfer repo duplicate zip (other repo) | **Accounted** (served / carried / not re-measured). |
| Round 49 carried inputs: `c-708` N1 (`BoxTaskEnvelopes` box-scoped probe), `a-683` N3 (non-`AgentsCommand` / embed / `channel_box_pins` posts in `hum\|`), `a-490` N1 (`TestCategoryTestPathsZZIsolated` regex at `categories_test.go:388`), `a-480` N1 (`syncWriter.Reset`), hours-minutes 400 follow-up (0 warns in 16 h), `i18n-lang-review-exempt.json:2` (verified still says `Lang-review: a-NNN` on `6b216a319`), `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget`, `unknown_token` box, hub dir mode, hermetic 2/4 timeout, composed testids, SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` | re-checked: unchanged / carried | **Carried** to round 51. |

---

## 4. Red controls, as run

### 4.1 `rc01-b50.sh` (b50-01, updated at v0.7 per panel W1 to W6 & N6 to N11), sha256 first 12 hex `b07ef5e3cfc7`, 10116 B

Run from any checkout: `bash rc01-b50.sh 6b216a319` (exit 1), then `bash rc01-b50.sh 6b216a319 fix-shape` (exit 0). Under 3 s each. Self-contained (zero box paths).

```bash
#!/usr/bin/env bash
# rc01-b50.sh <sha> [fix-shape]: b50-01 red control (v0.7, folds panel c-902 W1-W6, N6-N11).
# On <sha>'s tree, _spl_review_go_instr / _spl_review_go_owner_go
# (csi-spl-orc/src/bash/run/spl-review-go.func.sh:695-800):
#   (1) false rc 4 HOLD on refactor briefs opening with "Apply section N.M's
#       verbatim hunks..." / "Apply N.M's verbatim helper, caller, and test
#       hunks..." (r04-01, r04-02, r05-01, r05-02);
#   (2) false rc 4 HOLD on standalone backticked flag literals `DRY_RUN=0` in
#       plan-table rows or test descriptions naming a check/test/case
#       (r03-01, r03-02, r05-01, r05-02).
# Extracts spl-review-go.func.sh from <sha> into a mktemp dir. Self-contained
# (no box paths). fix-shape strips:
#   (a) `apply` only when `verbatim` precedes `hunks?|patch(es)?` on the same
#       line AND the line holds no target/infra word;
#   (b) standalone backticked `DRY_RUN=0` (exact uppercase flag spelling) only
#       when followed on the same line by one of the three literal real gaps
#       (`ORDERED_BY`, install `ok_msg`, or install/check/remove lifecycle)
#       and `checks?|tests?|cases?` (no open slot) AND neither its line (or
#       cell, for >=4-col markdown tables) nor the next non-blank line holds
#       a command.
# Verifies all 6 r03..r05 lines pass AND all 42 HOLD controls (9 original +
# 11 panel c-902 W1 probes + 4 W2 probes + 4 W3 probes + 3 W4 probes +
# 5 W5 probes + 6 W6 probes) still hold rc 1.
set -uo pipefail
sha="${1:?usage: rc01-b50.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc/src/bash/run/spl-review-go.func.sh | tar -x -C "$tmp"
fn="$tmp/csi-spl-orc/src/bash/run/spl-review-go.func.sh"
a=$(grep -c '^_spl_review_go_instr()' "$fn")
b=$(grep -c '^_spl_review_go_owner_go()' "$fn")
echo "rc01 sites: instr=$a owner_go=$b"
[ "$a" = 1 ] && [ "$b" = 1 ] || { echo "rc01 sites moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$fn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = 'print(re.sub(neg, unneg, txt))\n'
new = '''txt = re.sub(neg, unneg, txt)
TGT = re.compile(r"(?i)\\b(?:prd|prod|production|dev|live|database|db|schema|sql|migrations?|steps?|terraform|tf|tfvars|gcp|cloud|iam|billing|infra|provision)\\b")
HUNK = re.compile(r"(?i)\\bapply(?=(?:[^\\S\\n]+[A-Za-z0-9._,'\\u2019-]+){0,4}[^\\S\\n]+verbatim(?:[^\\S\\n]+[A-Za-z0-9._,'\\u2019-]+){0,6}[^\\S\\n]+(?:hunks?|patch(?:es)?)\\b)")
CMD = re.compile(r"(?i)(?:\\./run|&&|-a\\s+do_|--(?:prd|prod)\\b|\\b(?:terraform|gcloud)\\b|(?<!\\.)\\b(?:make|sudo|python[0-9]*|bash|sh|perl|node|psql|kubectl|docker|curl|ssh|cd)\\s|\\bdo_(?:provision|tf_|gcp_|spl_desk_up|spl_issue_|spl_topic_|spl_private_|spl_tenant_))")
DRY = re.compile(r"(?<!`)`DRY_RUN=0`(?!`)(?=[^\\S\\n]+(?:`ORDERED_BY`|install[^\\S\\n]+`ok_msg`|install/check/remove[^\\S\\n]+lifecycle)[^\\S\\n]+(?i:checks?|tests?|cases?)\\b)")
ls = txt.split("\\n")
for i, l in enumerate(ls):
    if HUNK.search(l) and not TGT.search(l):
        l = HUNK.sub("", l)
    if DRY.search(l):
        nxt = next((ls[j] for j in range(i + 1, len(ls)) if ls[j].strip()), "")
        if l.lstrip().startswith("|") and l.count("|") >= 5 and not CMD.search(nxt):
            l = "|".join(DRY.sub("", c) if not CMD.search(c) else c for c in l.split("|"))
        elif not CMD.search(l) and not CMD.search(nxt):
            l = DRY.sub("", l)
    ls[i] = l
print("\\n".join(ls))
'''
assert s.count(old) == 1, f"old count={s.count(old)}"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "rc01 fix-shape: strip verbatim hunk/patch apply (no target word) + standalone backticked DRY_RUN=0 before literal gap + check/test/case (no cmd on line/next)"
fi

run_og() {
  local f="$tmp/brief.md"
  printf '%s\n' "$1" >"$f"
  env SPOOL_ROOT="$tmp/spool" bash -c '
    set -uo pipefail
    source "$1"
    _spl_review_go_owner_go "$2" c-002' _ "$fn" "$f" 2>&1
}

rc=0
check_case() {
  local lbl="$1" want="$2" body="$3" out r
  out="$(run_og "$body")"; r=$?
  echo "rc01 $lbl: rc=$r (want $want)${out:+ [$out]}"
  [ "$r" = "$want" ] || rc=1
}

# Control (passes on both base and fix): SPL-5798 already exempts identifiers/slugs
check_case "ctrl_ident_slug" 0 $'## Do\n1. Call `_spl_simple_cron_apply` and `_spl_run_cron_apply` on branch `r05-02-orc-run-cron-apply-wave1`.'

# RED 1..6: real lines from r05-01, r05-02, r04-01, r04-02, r03-01, r03-02 briefs
check_case "red_r05_01" 0 $'## Do\n2. Apply section 1.3'\''s verbatim hunks to ONLY the row'\''s files.\n4. Run standalone `DRY_RUN=0` install/check/remove lifecycle check.'
check_case "red_r05_02" 0 $'## Do\n2. Apply section 1.4'\''s verbatim hunks to ONLY the row'\''s files.\n4. Run standalone lazy-load `check`-missing and `DRY_RUN=0` install `ok_msg` checks.'
check_case "red_r04_01" 0 $'## Do\n2. Apply 1.3'\''s verbatim helper, caller, and test hunks to ONLY those 4 files.'
check_case "red_r04_02" 0 $'## Do\n2. Apply 1.4'\''s verbatim helper, caller, and test hunks to ONLY those 5 files.'
check_case "red_r03_01" 0 $'## Row\n| 01 | one copy | `DRY_RUN=1` preview log, and `DRY_RUN=0` `ORDERED_BY` check differing in 1 line only | `cd csi-spl-iac && ./run -a do_check_pre_push` |'
check_case "red_r03_02" 0 $'## Do\n3. standalone `DRY_RUN=0` install `ok_msg` checks covering all three installers.'

# CONTROLS 1..9 (original): real owner-go steps MUST still hold (rc 1)
check_case "ctrl_case24_prd_cmd" 1 $'## Do\n1. Run `ENV=prd DRY_RUN=0 ./run -a do_x` once.'
check_case "ctrl_backtick_dry_cmd" 1 $'## Do\n1. Run `DRY_RUN=0 ./run -a do_spl_issue_update` once.'
check_case "ctrl_split_dry_cmd" 1 $'## Do\n1. Run `DRY_RUN=0` `./run -a do_x` once.'
check_case "ctrl_bare_dry" 1 $'## Do\n1. Run with DRY_RUN=0.'
check_case "ctrl_tf_apply" 1 $'## Do\n1. Run `terraform apply` for step 016.'
check_case "ctrl_mig_apply" 1 $'## Do\n1. apply the migration to prd.'
check_case "ctrl_tf_hunks" 1 $'## Do\n1. Apply terraform hunks to step 016.'
check_case "ctrl_mig_patch" 1 $'## Do\n1. Apply the migration patch now.'
check_case "ctrl_patch_to_prd" 1 $'## Do\n1. Apply the patch to prd.'

# CONTROLS 10..20 (panel c-902 W1 probes): all 9 shapes (+ blank-line & 2-col table) MUST hold (rc 1)
check_case "ctrl_w1_cd_run" 1 $'## Do\n1. `DRY_RUN=0` `cd csi-spl-iac && ./run -a do_provision`'
check_case "ctrl_w1_set_and_run" 1 $'## Do\n1. Set `DRY_RUN=0` and run `./run -a do_spl_desk_up`'
check_case "ctrl_w1_next_line" 1 $'## Do\n1. With `DRY_RUN=0`:\n   `./run -a do_spl_desk_up`'
check_case "ctrl_w1_next_blank" 1 $'## Do\n1. With `DRY_RUN=0`:\n\n   `cd csi-spl-iac && ./run -a do_provision`'
check_case "ctrl_w1_sudo" 1 $'## Do\n1. `DRY_RUN=0` `sudo -u x ./run -a do_x`'
check_case "ctrl_w1_python_prd" 1 $'## Do\n1. `DRY_RUN=0` `python3 x.py --prd`'
check_case "ctrl_w1_patch_dev_prd" 1 $'## Do\n1. Apply the patch on dev and prd.'
check_case "ctrl_w1_tfvars_patch" 1 $'## Do\n1. Apply the tfvars patch for step 016.'
check_case "ctrl_w1_sql_hunks" 1 $'## Do\n1. Apply the SQL hunks to the live database.'
check_case "ctrl_w1_schema_patch" 1 $'## Do\n1. Apply the schema patch to the hub database.'
check_case "ctrl_w1_2col_table" 1 $'## Do\n| `DRY_RUN=0` | `cd csi-spl-iac && ./run -a do_provision` |'

# CONTROLS 21..24 (panel c-902 W2 probes): real write-now shapes MUST hold (rc 1)
check_case "ctrl_w2_4col_next_cell" 1 $'## Do\n| 01 | prd write | `DRY_RUN=0` | `cd csi-spl-iac && ./run -a do_spl_desk_up` |'
check_case "ctrl_w2_prev_line_cmd" 1 $'## Do\n1. Run `cd csi-spl-orc && ./run -a do_spl_desk_up` once as a dry run.\n2. Then run it again with `DRY_RUN=0`.'
check_case "ctrl_w2_direct_script" 1 $'## Do\n1. `DRY_RUN=0` `csi-spl-orc/src/bash/scripts/box-disk-sweep.sh`'
check_case "ctrl_w2_prose_write" 1 $'## Do\n1. Re-run the same action with `DRY_RUN=0` to write the hub.'

# CONTROLS 25..28 (panel c-902 W3 probes): prose write-now steps naming a test MUST hold (rc 1)
check_case "ctrl_w3_and_test" 1 $'## Do\n1. Re-run the same action with `DRY_RUN=0` and test the hub.'
check_case "ctrl_w3_so_check" 1 $'## Do\n1. Re-run it with `DRY_RUN=0` so the check passes.'
check_case "ctrl_w3_for_cases" 1 $'## Do\n1. Write the prd rows with `DRY_RUN=0` for all cases.'
check_case "ctrl_w3_repeat_test" 1 $'## Do\n1. Run `cd csi-spl-orc && ./run -a do_spl_desk_up` as a dry run.\n2. Then repeat with `DRY_RUN=0` and test it.'

# CONTROLS 29..31 (panel c-902 W4 probes): temporal/conditional prose write-now steps naming a test MUST hold (rc 1)
check_case "ctrl_w4_when_tests" 1 $'## Do\n1. Re-run the action with `DRY_RUN=0` when tests pass.'
check_case "ctrl_w4_after_checks" 1 $'## Do\n1. Re-run the action with `DRY_RUN=0` after checks pass.'
check_case "ctrl_w4_before_check" 1 $'## Do\n1. Write the hub with `DRY_RUN=0` before every check.'

# CONTROLS 32..36 (panel c-902 W5 probes): wide allow-list slot write-now shapes MUST hold (rc 1)
check_case "ctrl_w5_do_action" 1 $'## Do\n1. Run it with `DRY_RUN=0` `do_spl_lane_issue` test.'
check_case "ctrl_w5_env_dev" 1 $'## Do\n1. Re-run with `DRY_RUN=0` `ENV=dev` check.'
check_case "ctrl_w5_install_test" 1 $'## Do\n1. Re-run the cron install with `DRY_RUN=0` install test.'
check_case "ctrl_w5_dev_prd" 1 $'## Do\n1. Write the rows with `DRY_RUN=0` dev/prd check.'
check_case "ctrl_w5_script_path" 1 $'## Do\n1. Run `DRY_RUN=0` `bin/sweep.sh` check on the box.'

# CONTROLS 37..42 (panel c-902 W6 probes): free-slot write-now shapes MUST hold (rc 1)
check_case "ctrl_w6_psql" 1 $'## Do\n1. Run it with `DRY_RUN=0` `psql` check.'
check_case "ctrl_w6_make" 1 $'## Do\n1. Re-run with `DRY_RUN=0` `make` test.'
check_case "ctrl_w6_sudo" 1 $'## Do\n1. Re-run with `DRY_RUN=0` `sudo` check.'
check_case "ctrl_w6_prd" 1 $'## Do\n1. Write it with `DRY_RUN=0` `PRD` check.'
check_case "ctrl_w6_live_hub" 1 $'## Do\n1. Write it with `DRY_RUN=0` `live_hub` check.'
check_case "ctrl_w6_lifecycle" 1 $'## Do\n1. Run the cron with `DRY_RUN=0` lifecycle test.'

echo "rc01 exit $rc"
exit "$rc"
```

Output on `6b216a319` (sat, 08:05Z):

| run | output |
|---|---|
| `bash rc01-b50.sh 6b216a319` | `rc01 sites: instr=1 owner_go=1` / `rc01 ctrl_ident_slug: rc=0 (want 0)` / `rc01 red_r05_01..red_r04_02: rc=1 (want 0) [... 'Apply' ...]` / `rc01 red_r03_01..red_r03_02: rc=1 (want 0) [... 'DRY_RUN=0' ...]` / all 42 HOLD controls `rc=1 (want 1)` / `rc01 exit 1` |
| `bash rc01-b50.sh 6b216a319 fix-shape` | `rc01 sites: instr=1 owner_go=1` / `rc01 fix-shape: strip verbatim hunk/patch apply (no target word) + standalone backticked DRY_RUN=0 before literal gap + check/test/case (no cmd on line/next)` / `rc01 ctrl_ident_slug: rc=0 (want 0)` / all 6 `red_r05_01..red_r03_02: rc=0 (want 0)` / all 42 HOLD controls (`ctrl_case24_prd_cmd`..`ctrl_w6_lifecycle`) `rc=1 (want 1)` / `rc01 exit 0` |

### 4.2 `rc02-b50.sh` (b50-02, kept byte-identical from v0.1), sha256 first 12 hex `4f69adbf30f4`, 5549 B

Run from any checkout: `bash rc02-b50.sh 6b216a319` (exit 1), then `bash rc02-b50.sh 6b216a319 fix-shape` (exit 0). Under 4 s each. Self-contained (zero box paths).

```bash
#!/usr/bin/env bash
# rc02-b50.sh <sha> [fix-shape]: b50-02 red control. On <sha>'s tree,
# csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh:83-91
# (section 4 red control) writes $T/nofloor.func.sh directly into $T/, where
# setup-gh-runner-cpu-budget-cron.func.sh's relative `source` lines (:35-40,69)
# fail with "No such file or directory" and "_spl_simple_cron_apply: command
# not found" (rc 127) before do_setup_gh_runner_cpu_budget_cron executes.
# Consequently:
#   (A) running the test as-is leaks 3 missing-file/command-not-found errors
#       to stderr while falsely reporting section 4 PASS;
#   (B) mutating setup-gh-runner-cpu-budget-cron.func.sh so the sed-stripped
#       copy STILL writes CPU_BUDGET_GATE_FLOOR_PCT=500 still exits 0 (vacuous
#       red control: section 4 never ran the function).
# Extracts csi-spl-orc from <sha> into a mktemp dir. fix-shape stages section 4
# in a mirrored relative tree ($T/rc/src/bash/run + symlinked lib & siblings),
# checks an unmodified copy passes check_default, and checks the stripped copy
# executes cleanly (setup rc 0) yet fails check_default.
set -uo pipefail
sha="${1:?usage: rc02-b50.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc/lib/bash/funcs csi-spl-orc/src/bash/run csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh | tar -x -C "$tmp"
tst="$tmp/csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh"
fn="$tmp/csi-spl-orc/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh"
a=$(grep -c '^setup()' "$tst")
b=$(grep -c '^check_default()' "$tst")
c=$(grep -c '^do_setup_gh_runner_cpu_budget_cron()' "$fn")
echo "rc02 sites: setup=$a check_default=$b action=$c"
[ "$a" = 1 ] && [ "$b" = 1 ] && [ "$c" = 1 ] || { echo "rc02 sites moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$tst" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = '''# 4. red control: the installer without the floor
sed -e 's/%sCPU_BUDGET_GATE_FLOOR_PCT=%s CPU/%sCPU/' -e 's/"\\$pre" "\\$floor" "\\$reserve"/"$pre" "$reserve"/' "$FUNC" >"$T/nofloor.func.sh"
if grep -q 'CPU_BUDGET_GATE_FLOOR_PCT=%s' "$T/nofloor.func.sh"; then
  fail "red control: could not strip the floor from the copy"
elif check_default "$T/nofloor.func.sh"; then
  fail "red control: a copy without the floor still passed check 1"
else
  pass "red control: an installer without the floor fails check 1"
fi'''
new = '''# 4. red control: the installer without the floor (staged in a relative tree so sibling sources resolve)
RC_RUN="$T/rc/src/bash/run"
mkdir -p "$RC_RUN"
ln -s "$PROJ_ROOT/lib" "$T/rc/lib"
for sib_f in "$PROJ_ROOT"/src/bash/run/*.func.sh; do
  [[ "$(basename "$sib_f")" == "setup-gh-runner-cpu-budget-cron.func.sh" ]] && continue
  ln -s "$sib_f" "$RC_RUN/$(basename "$sib_f")"
done
RC_FUNC="$RC_RUN/setup-gh-runner-cpu-budget-cron.func.sh"
cp "$FUNC" "$RC_FUNC"
check_default "$RC_FUNC" && pass "red control: unmodified copy in staged tree passes check 1" || fail "red control: unmodified staged copy failed check 1"
sed -e 's/%sCPU_BUDGET_GATE_FLOOR_PCT=%s CPU/%sCPU/' -e 's/"\\$pre" "\\$floor" "\\$reserve"/"$pre" "$reserve"/' "$FUNC" >"$RC_FUNC"
if grep -q 'CPU_BUDGET_GATE_FLOOR_PCT=%s' "$RC_FUNC"; then
  fail "red control: could not strip the floor from the copy"
elif ! setup "$RC_FUNC" DRY_RUN=0 >/dev/null; then
  fail "red control: stripped copy failed to run (broken source or helper)"
elif check_default "$RC_FUNC"; then
  fail "red control: a copy without the floor still passed check 1"
else
  pass "red control: an installer without the floor fails check 1"
fi'''
assert s.count(old) == 1, f"old count={s.count(old)}"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "rc02 fix-shape: stage section 4 copy in mirrored relative tree + assert unmodified passes and stripped runs cleanly"
fi

rc=0
# A: run unmodified test -> must exit 0 with ZERO missing-file/command-not-found stderr lines
bash "$tst" >"$tmp/a.out" 2>"$tmp/a.err"; rA=$?
errsA=$(grep -cE 'No such file or directory|command not found' "$tmp/a.err" || true)
echo "rc02 A(clean_run): rc=$rA (want 0) stderr_source_errs=$errsA (want 0)"
[ "$rA" = 0 ] && [ "$errsA" = 0 ] || rc=1

# B: mutant .func.sh where the sed-stripped copy STILL emits CPU_BUDGET_GATE_FLOOR_PCT=500 ->
# a non-vacuous section 4 MUST catch it (rc!=0 and FAIL message)
cp -a "$tmp/csi-spl-orc" "$tmp/mut-orc"
mfn="$tmp/mut-orc/src/bash/run/setup-gh-runner-cpu-budget-cron.func.sh"
mtst="$tmp/mut-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh"
python3 - "$mfn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
needle = '    "$pre" "$floor" "$reserve" "$weight" "$ns" "$script" "$logdir" "$tag")"\n'
inject = '    "$pre" "$floor" "$reserve" "$weight" "$ns" "$script" "$logdir" "$tag")"\n  [[ "$line" == *CPU_BUDGET_GATE_FLOOR_PCT=* ]] || line="${line/\\* \\* \\* \\* \\* /\\* \\* \\* \\* \\* CPU_BUDGET_GATE_FLOOR_PCT=500 }"\n'
assert s.count(needle) == 1, f"needle count={s.count(needle)}"
open(p, "w").write(s.replace(needle, inject, 1))
PY
bash "$mtst" >"$tmp/b.out" 2>"$tmp/b.err"; rB=$?
caughtB=$(grep -c 'FAIL: red control: a copy without the floor still passed check 1' "$tmp/b.out" || true)
echo "rc02 B(non_vacuous_mutant): rc=$rB (want 1) caught=$caughtB (want 1)"
[ "$rB" != 0 ] && [ "$caughtB" = 1 ] || rc=1

echo "rc02 exit $rc"
exit "$rc"
```

Output on `6b216a319` (sat, 05:08Z; confirmed by panel `c-902@<box2>` on v0.1 `add3ec96f`):

| run | output |
|---|---|
| `bash rc02-b50.sh 6b216a319` | `rc02 sites: setup=1 check_default=1 action=1` / `rc02 A(clean_run): rc=0 (want 0) stderr_source_errs=3 (want 0)` / `rc02 B(non_vacuous_mutant): rc=0 (want 1) caught=0 (want 1)` / `rc02 exit 1` |
| `bash rc02-b50.sh 6b216a319 fix-shape` | `rc02 sites: setup=1 check_default=1 action=1` / `rc02 fix-shape: stage section 4 copy in mirrored relative tree + assert unmodified passes and stripped runs cleanly` / `rc02 A(clean_run): rc=0 (want 0) stderr_source_errs=0 (want 0)` / `rc02 B(non_vacuous_mutant): rc=1 (want 1) caught=1 (want 1)` / `rc02 exit 0` |

---

## 5. Rows

| # | id | practice | sites (file:line on `6b216a319`) | evidence | red control (fails on `6b216a319`) | test column (R2; R7 must run EVERY entry in `ran:`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b50-01-orc-review-go-hunk-apply-and-bare-dry-run` | `do_spl_review_go` stops false rc 4 holds on code-hunk `"Apply ... verbatim ... hunks"` prose and standalone backticked `` `DRY_RUN=0` `` check/test literals while keeping every real owner-go hold intact (incl. all 31 panel W1-W6 probes) | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:670-741`; `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (new case 34 after `:1332`) | 7 live rc 4 false holds on r03..r05 (`7b492c13`, `1dd01968`, `56a64404`, `d05ddaad`, `51ae6640`, `dd406194`, `ba3dbedb`; ruled false `0da5ca10`, `27e89eef`); `c002-next-round-candidates.md:141-145`; panel `c-902` W1-W6 (`b423c21a5`, `fc0f6bf6b`, `22c149f69`, `5f28ab3ea`, `a6dd22a62`, `5a634fee4`); section 4.1 | `bash rc01-b50.sh 6b216a319` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` | `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`; `bash csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh`; `bash rc01-b50.sh <fix sha>` -> exit 0 (without `fix-shape`, proving all 42 HOLD controls); `shellcheck -S warning -x csi-spl-orc/src/bash/run/spl-review-go.func.sh csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `bash csi-spl-iac/src/bash/tests/action-header-tags.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.1: in `_spl_review_go_instr` strip (a) `apply` only when `verbatim` precedes `hunks?\|patch(?:es)?` on the same line AND the line holds no target/infra word (`prd\|prod\|production\|dev\|live\|database\|db\|schema\|sql\|migrations?\|steps?\|terraform\|tf\|tfvars\|gcp\|cloud\|iam\|billing\|infra\|provision`) and (b) standalone single-backticked exact-uppercase `` `DRY_RUN=0` `` only when followed on the same line by one of the three literal real gaps (`` `ORDERED_BY` ``, ``install `ok_msg` ``, or `install/check/remove lifecycle` — zero open slots) and `(?i:checks?\|tests?\|cases?)` AND neither its line (or cell, for `>=4`-col markdown tables) nor the next non-blank line holds a command token; update comment; keep `_spl_review_go_instr` <= 75 lines; add case 34 in `spl-review-go.tst.sh` with all 6 GO cases and all 42 HOLD controls; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` claude 05:00Z: `<box2>` 91% / 41% weekly pick, sat 98% / 37% weekly) | claude | agy (`BOX_PICK_KIND=agy` 05:01Z: `<box2>` 91% pick, both `agy weekly unknown`, placed anyway), else claude waiver seat (`1a7c70da`); R7 `ran:` includes `rc01-b50.sh <fix sha>` (42 HOLD probes, panel N1) AND the R7 seat writes and runs its own independent write-now probes (panel N9; literal-gap rule per W6/N11 so unknown shapes fail closed as false holds) | `complex_coding` (panel N1) | 1 |
| 02 | `b50-02-orc-cpu-budget-cron-red-control` | `setup-gh-runner-cpu-budget-cron.tst.sh` section 4 stages its red-control copy in a mirrored relative tree so sibling `source` lines resolve and the control actually tests floor removal | `csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh:83-91` | `a-841@sat` R7 N1 (r03-02); `bug-round-49-plan.md` section 7 first input #1; section 4.2 | `bash rc02-b50.sh 6b216a319` -> `rc02 exit 1`; control `fix-shape` -> `rc02 exit 0` | `bash csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh`; `bash csi-spl-orc/src/bash/tests/apply-gh-runner-cpu-budget.tst.sh`; `bash rc02-b50.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh`; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.2: stage section 4 under `$T/rc/src/bash/run` with symlinks to `$PROJ_ROOT/lib` and sibling `*.func.sh`; assert unmodified copy passes `check_default`; assert `sed`-stripped copy runs cleanly (`setup` rc 0) yet fails `check_default`; zero stderr `No such file or directory` / `command not found`; `Docs: none` | sat or `<box2>` (`do_spl_box_pick` 05:00Z: `<box2>` pick) | claude | agy if quota, else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |

- **R1 (disjoint files):** both rows are Batch 1 and share 0 files:
  - b50-01: `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`
  - b50-02: `csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh`
- **R3** (checked 2026-11-26T05:04:07Z and re-checked at v0.2 2026-11-26T05:33:44Z, panel N2): `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-orc/src/bash/tests/setup-gh-runner-cpu-budget-cron.tst.sh,csi-spl-doc/doc/md/bug-round-50-plan.md --agent a-927` -> **exit 4**: 0 live lanes list these 4 paths, but 18 live lanes on `<box2>` record no files at 05:33:44Z (`unknown:` c-029, c-041, c-086, c-146, c-187, c-398, c-407, c-416, c-474, c-535, c-728, c-902 [b50 panel seat], c-904 [s187-s1], c-907 [s196-t1-topic-tags-store], c-927, c-936, c-957, c-965; panel also saw 6 sat unknowns at 05:25Z including new `a-934@sat` s182 cl-build planner, and verified `c-722`'s review heads `ac63b9e88` / `11391fee0` touch 0 of these row files): **not free until the holder re-runs `--check` at placement**. By `do_spl_lane_map` scopes, live lanes on sat and `<box2>` touch none of these 3 row files. The queue, `./run -a do_spl_spawn_queue` (05:00:16Z): 2 queued asks (`22fd2cf9` b50 panel seat `c-902@<box2>`, now placed; `5b1b7d82` `c001-s186-m9-n2-qto-sync`, feature), disjoint by slug.
- **R7:** claude-authored code rows: agy R7 seat if `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` shows agy quota (05:01Z: both boxes `agy weekly unknown`, placed anyway; pick `<box2>` 91%), else claude waiver seat (`1a7c70da`). No grok (c-001 `dc84300a`). No mistral (no review seat since 2026-11-25, and no coding kind). Every test in the row's R2 test column (including `cd csi-spl-iac && ./run -a do_check_pre_push` and `rc01-b50.sh <fix sha>` / `rc02-b50.sh <fix sha>`) MUST appear in R7's `ran:` (rulebook C4, c-001 `0da5ca10`).
- **Rhythm (1.4):** rows queue once the panel signs and `do_spl_review_line_check` exits 0; rows run at night.
- **Pushes:** aim 1 per row (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug`.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| `a-826` N2 on SPL-6517 (`spool-live-ack.sh` log size cap) and `spool-agent-hook.sh` (`a-767` N2, `a-823` N2) | `c-722@sat` + `a-826@sat` | live lane SPL-6517 (R3, unlanded at 05:04Z; panel verified review heads `ac63b9e88`/`11391fee0` touch 0 b50 files); stay off. |
| Refactor round 05 closing (`a-891`, `c-913`, `c-914`, `a-920`, `a-922`), b49 closing (`c-874`, `a-911`), spec 125 (`c-957`, `c-965`), `a-934@sat` (s182 planner), `c-904@<box2>` (s187-s1), `c-907@<box2>` (s196 tags store), private workspace seats | live / queued lanes per `do_spl_lane_map` and `do_spl_spawn_queue` | owned; stay off. |
| Release-transfer repo open bug issues (SPL-6361, 6362, 6366) | live lanes on `<box2>` | different repository, not `csi-spl`. |
| The `unknown_token` box (372 prd WARNINGs in 6 h, 0 since `03:15:24Z` and 0 since W) | the holder, as a box question | carried. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 (all Batch 1, R1 disjoint; matches rulebook 5.1 aim of 2) |
| inputs re-measured | 10 sources; 8 prd ERROR entries in 6 h (**0 since W**, 4 ad-hoc Cloud SQL since `03:15:24Z`); 445 prd WARNING entries in 6 h (401s left out, cap not reached; **0 since W**, 12 since `03:15:24Z`) + 16 h `hours/minutes` read (169 entries: 146 HTTP 200, 23 HTTP 204, 0 400s, 0 warns); 9 alert policies (0 incidents); 6 open t1 bug-labelled issues + SPL-6559 (0 `csi-spl` wip/todo/eval outside this round); 100 wf 10 runs (68 success, 23 cancelled, 6 failure, 3 running; **0 failed since `03:15:24Z` or W**); **0 failed runs** since `03:15:24Z` or W across all other master workflows; 11 commits and 6 `review:` lines in `0d5e0b252..6b216a319` (1 commit / 1 `review:` line since W) + `c-001`/`c-002`/`c-003` archives + recent R7 outboxes + `automation.log` tail + newest 100 author briefs on sat; 0 HUM posts since `00:00:00Z`; round 49's first inputs + seat file (`eecbe84a3`); holder's candidate list (145 lines on sat, older bug sections cross-checked against `git log 6b216a319`); `rc01-b50.sh` (v0.7 `b07ef5e3cfc7`, 10116 B) and `rc02-b50.sh` (`4f69adbf30f4`, 5549 B, unchanged from v0.1) n=1 each way on `6b216a319` (`shellcheck -S warning` rc 0); baselines `spl-accepted-close.tst.sh` (`0 failure(s)`), `setup-gh-runner-cpu-budget-cron.tst.sh` (`all passed`, with 3 stderr source errors), `apply-gh-runner-cpu-budget.tst.sh` (`all passed`), `bash-cleancode.tst.sh` (`all assertions`), `action-header-tags.tst.sh` (`ALL PASS`), `spl-review-go.tst.sh` (`0 failure(s)` on `6b216a319` baseline AND `0 failure(s)` on v0.7 W1-W6 `fix-shape` via `REVIEW_GO_FUNC`) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b50-'` -> 0; `git ls-remote origin 'refs/heads/review/b50-*' 'refs/heads/wip/*b50*' 'refs/heads/*-b50-*' 'refs/heads/*bug-round-50*'` -> nothing (rc 0); briefs on sat matching `*b50*` / `*bug-round-50*`: only `hand-sat-c002-bug-round-50-planner.md` and `c002-bug-round-50-claude-panel-seat.md` (plus unrelated historical Nov 18 sha prefix `b5029895`; 05:00Z; confirmed by panel `c-902@<box2>`) |
| R7 seat | agy if quota (`BOX_PICK_KIND=agy` 05:01Z: `<box2>` 91% pick, both boxes `agy weekly unknown`, placed anyway), else claude waiver seat (`1a7c70da`) |
| first inputs for round 51 | `c-902` N5 (`spl-review-go.func.sh:774` owner-go `fixed` list lacks `do_spl_desk_up`, so a brief naming `./run -a do_spl_desk_up` without `ENV=prd`/`DRY_RUN=0`/`apply` is not held today); `a-909` N1 & N2 (`y9-vendor-lane-rule.sh:102,107` `_y9_qwen_backup` silences non-`EEXIST` OS errors and loops 99x reporting `no free backup name`, plus mode `0600` & `k=1 -> k=2` tests in `test-agy-qwen-fleet-rules.sh`); `apply-gh-runner-cpu-budget.tst.sh` red control (`/tmp/.../red/spl-lane-map.func.sh:72,74` relative `source` `No such file or directory` x6 on stderr during baseline run); `a-826` N2 (`spool-live-ack.sh` log size cap, only if SPL-6517 lands without it); `a-767` N2 (`spool-agent-hook.sh:683,771` stale `stop_denies`) and `a-823` N2 (`PreInvocation` in `EVENTS`, once SPL-6517 lands); `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`, now unblocked after SPL-6438 landed `5aa360afc`); `a-769` N1 (`check-pre-push-lint.func.sh:618-643` `_ppl_run_timed` returns 124 instead of 137 on SIGKILLed group) & N2 (`tenant-host-reserve.tst.sh` symlink control); `a-790` N1 (`internal/mcp/mcp_test.go:560-563` control ambient env); `a-911` N2 (`customer-box-role-set.tst.sh:160-165` `d6` explicit `rc != 0`); hours-minutes whole-batch 400 follow-up (once a live `hours: minutes refused` warn fires); `c-708` N1 (`BoxTaskEnvelopes` box-scoped probe); `a-683` N3 (non-`AgentsCommand` / embed / `channel_box_pins` posts in `hum\|`); `a-490` N1 (`TestCategoryTestPathsZZIsolated` regex at `categories_test.go:388`); `a-480` N1 (`syncWriter.Reset`); `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget`; `unknown_token` box; hub dir mode; hermetic 2/4 timeout; composed testids; `i18n-lang-review-exempt.json:2`; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` as carried |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** a-927@sat (agy, `specs_and_docs`).
- **Panel:** c-902@<box2> (claude, cross-vendor; placed on `dispatch-bug-r50`, ask `22fd2cf9`).
- **Row reviewer (R7):** section 5.
- **Review history:**
  - 2026-11-26 05:15Z: v0.1 `add3ec96f`, pushed to `review/c002-bug-round-50-planner` (2 rows: b50-01, b50-02; on `6b216a319`). Sent to `c-902@<box2>` (`aeabfbfb`) and holder `c-002@sat` (`c4b46420`) on task `dispatch-bug-r50`.
  - 2026-11-26 05:33Z: panel `c-902@<box2>` (claude) **FAIL** on v0.1 `add3ec96f` (msg `d3172393`; seat file `csi-spl-doc/doc/md/bug-round-50/seat-claude.md` on `review/c002-bug-round-50-claude-seat` `b423c21a5`; holder send-back `f939485f`). Verified slug proof, 0 drift on `6b216a319`, every cited line, `rc01`/`rc02` hashes/sizes/red-green, baseline suites (`setup-gh-runner-cpu-budget-cron`, `apply-gh-runner-cpu-budget`, `spl-review-go`, `spl-accepted-close`), and `do_check_dist_hygiene`; confirmed b50-02 ready as written. Findings: **W1** (b50-01 v0.1 fix-shape stripped owner-go keywords from 9 real step shapes incl. `` `DRY_RUN=0` `cd ... && ./run -a do_provision` ``, next-line commands, `sudo`/`python3 --prd`, and target-bearing `Apply ... patch/hunks`); **N1** (consider `complex_coding` for b50-01 and HOLD probes in R7 `ran:`); **N2** (R3 moved at 05:25Z, 6 sat unknowns incl. `a-934@sat`; `c-722` heads touch 0 row files); **N3** (account for older candidate-list bug sections served/carried/not re-measured).
  - 2026-11-26 05:38Z: v0.2 `8e0df7ffc` folds W1, N1, N2, N3; pushed fast-forward on `add3ec96f` to `review/c002-bug-round-50-planner`. Sent to `c-902@<box2>` (`19989938`) and holder `c-003@sat` (`1aa06efd`).
  - 2026-11-26 05:50Z: panel `c-902@<box2>` (claude) **FAIL** on v0.2 `8e0df7ffc` (msg `a3510ae0`; seat file section 4 on `review/c002-bug-round-50-claude-seat` `fc0f6bf6b`). Confirmed W1, N1 to N3 folded, `rc01` v0.2 (`b5c2e0fa3479`, 6907 B) & `rc02` (`4f69adbf30f4`, 5549 B, unchanged) verified, 0 drift on `f9521a941`. Findings: **W2** (v0.2 rule (b) still freed 4 real write-now shapes: 4-col table next-cell command, previous-line dry-run + "run it again with `` `DRY_RUN=0` ``", direct script path, plain prose ``with `DRY_RUN=0` to write the hub``; tested fix: also require `checks?|tests?|cases?` within 3 words after `` `DRY_RUN=0` ``); **N5** (`do_spl_desk_up` is not in `:774` `fixed` list — pre-existing gap, add as round 51 input).
  - 2026-11-26 06:10Z: v0.3 `529958c01` folds W2 and N5; pushed fast-forward on `8e0df7ffc` to `review/c002-bug-round-50-planner`. Sent to `c-902@<box2>` (`2dcaaff3`) and holder `c-002@sat` (`ecc21456`).
  - 2026-11-26 06:37Z: panel `c-902@<box2>` (claude) **FAIL** on v0.3 `529958c01` (msg `6cb6ee81`; seat file section 5 on `review/c002-bug-round-50-claude-seat` `22c149f69`; holder send-back `6f7c57d5`). Confirmed W2 and N5 folded, `rc01` v0.3 (`289009e93244`, 7698 B) & `rc02` (`4f69adbf30f4`, 5549 B, unchanged) verified, full `spl-review-go.tst.sh` `0 failure(s)`, `do_check_dist_hygiene` clean, 0 drift on `c05833b1c`. Findings: **W3** (v0.3's 0..3-word lookahead still freed 4 prose write-now shapes naming a test: `and test the hub`, `so the check passes`, `for all cases`, dry-run then `repeat with DRY_RUN=0 and test it`; tested fix: refuse function words in the 0..3-word gap); **N6** (name which `red_r05_01` wording is verbatim on sat); **N7** (keep or drop `(?i)` on `DRY` on purpose).
  - 2026-11-26 06:40Z: v0.4 `8e66f0126` folds W3, N6, N7; pushed fast-forward on `529958c01` to `review/c002-bug-round-50-planner`. Sent to `c-902@<box2>` (`b1f4472b`) and holder `c-002@sat` (`a2259df5`).
  - 2026-11-26 07:15Z: panel `c-902@<box2>` (claude) **FAIL** on v0.4 `8e66f0126` (msg `f5023a64`; seat file section 6 on `review/c002-bug-round-50-claude-seat` `5f28ab3ea`; holder send-back `470c9091`). Confirmed W3, N6, N7 folded, `rc01` v0.4 (`d79aff776f1f`, 8424 B) & `rc02` (`4f69adbf30f4`, 5549 B, unchanged) verified, full `spl-review-go.tst.sh` `0 failure(s)`, `do_check_dist_hygiene` clean, 0 drift on `a248ed371`. Findings: **W4** (v0.4's function-word ban list still freed 3 temporal/conditional prose write-now shapes naming a test: `when tests pass`, `after checks pass`, `before every check`; tested fix: replace ban list with an allow-list for the 0..3-token gap — backticked identifier, `install`, `remove`, `lifecycle`, or `[a-z]+(?:/[a-z]+)+` — so unknown shapes fail closed as false holds); **N8** (plan `:61` should say lowercase spellings "are not freed by the fix", not "stay held", since `dry_run=0` is rc 0 on base too because `:778` has no `-i`); **N9** (b50-01 R7 seat brief should require the seat to write its own independent write-now probes).
  - 2026-11-26 07:31Z: v0.5 `70bf54ef8` folds W4, N8, N9; pushed fast-forward on `8e66f0126` to `review/c002-bug-round-50-planner`. Sent to `c-902@<box2>` (`ef163f80`) and holder `c-002@sat` (`5e997285`).
  - 2026-11-26 07:41Z: panel `c-902@<box2>` (claude) **FAIL** on v0.5 `70bf54ef8` (msg `e2eba5d6`; seat file section 7 on `review/c002-bug-round-50-claude-seat` `a6dd22a62`; holder send-back `4191fbce`). Confirmed W4, N8, N9 folded, `rc01` v0.5 (`0220c8497420`, 8928 B) & `rc02` (`4f69adbf30f4`, 5549 B, unchanged) verified, `do_check_dist_hygiene` clean, 0 drift on `551b3c601`. Findings: **W5** (v0.5's allow-list slots were wider than the 6 real lines need and still freed 5 write-now probes: `` `do_spl_lane_issue` test ``, `` `ENV=dev` check ``, `install test`, `dev/prd check`, `` `bin/sweep.sh` check ``; tested fix: narrow each slot to bare non-`do_*` backticked identifier, `install` before backticked identifier, `lifecycle`, or lowercase slash word without env words); **N10** (matching exactly the 6 real lines is the safe end state: anything new becomes a false hold cleared by hand, never a false GO).
  - 2026-11-26 07:52Z: v0.6 `6f07282f0` folds W5 and N10; pushed fast-forward on `70bf54ef8` to `review/c002-bug-round-50-planner`. Sent to `c-902@<box2>` (`7d6dc5ed`) and holder `c-002@sat` (`9a216ad4`).
  - 2026-11-26 08:03Z: panel `c-902@<box2>` (claude) **FAIL** on v0.6 `6f07282f0` (msg `97ec9dad`; seat file section 8 on `review/c002-bug-round-50-claude-seat` `5a634fee4`; holder send-back `f2c53255`). Confirmed W5 and N10 folded, `rc01` v0.6 (`1212af0191fc`, 9686 B) & `rc02` (`4f69adbf30f4`, 5549 B, unchanged) verified, `do_check_dist_hygiene` clean, 0 drift on `c28e628f2`. Findings: **W6** (v0.6's allow-list still left a free slot — any bare backticked name or standalone `lifecycle` passed — freeing 6 write-now probes: `` `psql` check ``, `` `make` test ``, `` `sudo` check ``, `` `PRD` check ``, `` `live_hub` check ``, `lifecycle test`; tested fix: match the three real gaps literally — `` `ORDERED_BY` ``, ``install `ok_msg` ``, `install/check/remove lifecycle` — with zero open slots); **N11** (W3 to W6 each fixed a rule proposed the round before; with no open slot left, next check verifies only that the literal rule is applied as tested).
  - 2026-11-26 08:09Z: v0.7 folds W6 (replaces the allow-list `DRY` line with the literal three-gap regex from seat section 8.2, zero open slots; adds all 6 W6 probes as HOLD controls 37..42 in `rc01-b50.sh` `b07ef5e3cfc7` 10116 B and case 34 -> 42 HOLD controls total) and N11 (records zero-open-slot literal rule on plan `:61` and notes); re-verified `rc01`/`rc02` red/green (`rc01` 6/6 RED rc 0, 42/42 HOLD rc 1 + extra `write/apply check` rc 1), `shellcheck -S warning` rc 0, 100 newest sat author briefs (08:06Z: `base_held=18 -> w6_held=10`, ONLY 8/8 r03..r06 refactor briefs freed, 10/10 other held stay HELD, 0 newly held), and full `spl-review-go.tst.sh` `0 failure(s)` on v0.7 W1-W6 `fix-shape`; `rc02-b50.sh` (`4f69adbf30f4`, 5549 B) kept byte-identical from v0.1; 0 drift on `origin/master` `c28e628f2`; pushed fast-forward on `6f07282f0` to `review/c002-bug-round-50-planner` for final panel signature by `c-902@<box2>`.
  - 2026-11-26 08:25Z..08:42Z: panel `c-902@<box2>` (claude) final **PASS** on v0.7 `ce2c75f9f` (msgs `b1275bfe` / `0dd33944`, W none, N12 noted with no change needed; seat file `3463648a0` on `review/c002-bug-round-50-claude-seat`); `do_spl_review_line_check` `SYNTAX OK` rc 0 by `c-002@sat`; holder `c-002@sat` GO LAND `f122b5d4`. Landed on `origin/master` as `fee404830` (`2026-11-26T08:36:56Z`; CI wf 10 `45784772406` / `45785790535`, 15 `45784772198`, 21 `45785103922`, 25 `45784772220`, 26 `45784772333`, 32 `45784772214`, 40 `45785024683`, 64 `45784772183` all **success**), carrying `c-902`'s box-free review line in the commit body; both row briefs queued by holder `c-002@sat`.
  - Round closed (`a-927@sat`, round 50's editor), no version bump: rows 01 and 02 both landed and are served. Re-measured on `origin/master` `bf585dc99`, `2026-11-26T12:01Z..12:03Z`, n=1 per command.
    - **b50-01** `3ce429f73` (SPL-6574, committed `2026-11-26T11:06:07Z`, author `c-011@sat` claude): R7 `a-027@sat` agy **PASS** on `cc47e31d4036` (in commit body; msg `28fbc856`, every test-column entry incl. `rc01-b50.sh` and `do_check_pre_push` plus 14/14 independent N9 write-now probes and `/tmp` mutant red control in `ran:`; `do_spl_review_line_check` rc 0 `OK 4 of 4`, 17 commands read; holder `c-002@sat` GO LAND `11:05:38Z`, ACCEPTED `11:50Z`). `git patch-id --stable` equal on reviewed `cc47e31d4036` and landed `3ce429f73f03` (`6f7736a13cf9`); diffstat 2 files +117 -1 (`spl-review-go.func.sh`, `spl-review-go.tst.sh`). R5 (tooling): `git merge-base --is-ancestor 3ce429f73 origin/master` rc 0; sat main and desk checkouts (`bf585dc99`) rc 0. R11: wf 10 on its own sha (`45810065700`) **success**; wf 15 (`45810065686`), 21 (`45810390825`, `45812568623`), 25 (`45810065782`), 26 (`45810065657`), 40 (`45810304202`, `45812436387`), 64 (`45810065530`), 67 (`45810065907`) **success**, 0 red.
    - **b50-02** `86ac09501` (SPL-6576, committed `2026-11-26T10:47:12Z`, author `c-018@sat` claude): R7 `a-025@sat` agy **PASS** on `8a92bfcb7780` (in commit body; every test-column entry incl. `rc02-b50.sh` and `do_check_pre_push` plus `/tmp` flat-staging control in `ran:`; `do_spl_review_line_check` rc 0 `OK 3 of 3`, 15 commands read; holder `c-002@sat` ACCEPTED `11:08:58Z`). `git patch-id --stable` equal on reviewed `8a92bfcb7780` and landed `86ac09501802` (`ee77db8e7297`); diffstat 1 file +22 -6 (`setup-gh-runner-cpu-budget-cron.tst.sh`). R5 (tooling): `git merge-base --is-ancestor 86ac09501 origin/master` rc 0; sat main and desk checkouts (`bf585dc99`) rc 0. R11: wf 10 on its own sha (`45804720145`) **success**; wf 15 (`45804719936`), 20 (`45805714996`), 21 (`45805659871`), 25 (`45804720170`), 26 (`45804720153`), 40 (`45805481182`), 64 (`45804720112`), 67 (`45804719891`) **success**, 0 red.
    - Close record requested by dispatch holder `c-002@sat` (`37c586f7` 12:03Z; preceded by `c-001@sat` GC nudge `c2fb4f78` 12:00Z).
    - **R8 seats & branches** (rulebook 2.8):
      - `lane-map.sh --all` (`12:01Z`): `c-011@sat` (b50-01 author, claude), `a-027@sat` (b50-01 R7, agy, 1 review), `c-018@sat` (b50-02 author, claude), `a-025@sat` (b50-02 R7, agy, 1 review), and `c-902@<box2>` (panel, claude, 7 reviews: v0.1..v0.6 FAIL and v0.7 PASS) are all `done`. Only `a-927@sat` (editor, agy) remains `live`, awaiting holder `ACCEPTED`. No seat performed zero reviews.
      - Remote branches (`git ls-remote origin`, `12:02Z`): row review branches for `b50-01` and `b50-02` are already absent from origin; `review/c002-bug-round-50-planner` (`ce2c75f9f`) and `review/c002-bug-round-50-claude-seat` (`3463648a0`) remain on origin until post-`ACCEPTED` prune by the holder/retro.
