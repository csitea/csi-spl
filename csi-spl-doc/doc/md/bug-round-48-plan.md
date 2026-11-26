# Bug-fix round 48 - plan (3 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6544 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `a0c6695b-42f9-49a4-962d-dfc2501f6216` ("Bug round 48", opened by c-002@sat 23:31Z 2026-11-25, post `9d0319ac`). Round 47 ([bug-round-47-plan.md](bug-round-47-plan.md)) served all three rows b47-01 (`7fe50142d`, SPL-6535), b47-02 (`2ba02c0e2`, SPL-6538), and b47-03 (`a5cb972b7`, SPL-6539), and is closed (`fe99a5bc6`, written by this seat).  
Round focus: the sources of rounds 40 to 47 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since W, owner posts), round 47's first inputs, and the holder's candidate list on sat.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. Three disjoint candidates met the bar (section 3); bug share is 7% (band 30-40%: UNDER, 00:29Z).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-47-plan.md](bug-round-47-plan.md).

**Status: v1.0, W1 (1-line doc cite) and N1 to N5 folded from c-776 (claude) PASS on v0.1 `b3f91e7f7` (`do_spl_review_line_check` rc 0 on `<box2>`, `OK 3 of 3`; holder GO v1.0 `c97d8f96`), all 3 rows kept.** Pushed to `review/c002-bug-round-48-planner` for final panel signature before landing on master (rulebook 1.4 / 3.2).

Editor: **a-846@sat** (agy, `specs_and_docs`).  
Panel: **c-776@`<box2>`** (claude, cross-vendor; placed on `dispatch-bug-r48` at 23:40:43Z 2026-11-25; mistral sits on no review since 2026-11-25).

**One sha:** every site, line number and red control below is on **`fe99a5bc6`** (`origin/master` right after this seat's Task 1 close record landed, 2026-11-26T00:34Z). At v1.0 (01:0xZ), `origin/master` is `5aa360afc` and all 6 row files are unchanged (`git diff --stat fe99a5bc6 5aa360afc -- <the 6 row files>` -> empty), so every site and red control holds at that head. The sources of section 2 were read on sat, 00:27Z..00:37Z on 2026-11-26. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b47-plan')` read once at 00:27Z (before this seat's Task 1 close record landed) -> `Window: W=2026-11-25T21:40:33+02:00` (commit `d5a2422f4`, round 47's v1.0 plan). The close record `fe99a5bc6` (00:34Z) is a newer `docs(b47-plan` commit; the recorded W stays (5.3: the planner reads W once). Since W (`d5a2422f4..fe99a5bc6`), `origin/master` took 35 commits (7 with `review:` lines).

---

## 1. How to read this

- `<box2>` is the fleet's box that is not sat and `<dev-box>` one unpinned workstation box, as in rounds 21 to 47: the public repo names none of them.
- **Paths** are repo-relative. Line numbers are as of `fe99a5bc6`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red controls are printed verbatim in section 4. Each copies files from the named sha with `git archive` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout. Each site guard checks function names only, so `bash rc0N-b48.sh <fix sha>` (without `fix-shape`) exits 0 on a valid fix.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs).
- This seat runs on sat, so `/var/spool-hub/dispatch/c002-next-round-candidates.md`, `/var/spool-hub/dispatch/automation.log`, `/var/csi/csi-spl/review-go/cron.out`, the sat spool (`dispatch-bug-r47`, `dispatch-bug-r48`) and `c-001`/`c-002`/`c-003` archives were read directly.

---

## 2. Where rows could come from (measured since W)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=6h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (00:28Z) | 12 entries (11 since W `19:40:33Z`): 10 Cloud SQL entries (7 `FATAL: connection to client lost`, 2 `ERROR: operator does not exist: uuid ~~ unknown`, 1 `ERROR: relation "topics" does not exist`) + 1 Cloud Run 503 (`connection to the instance had an error`) | **0 rows.** The 3 SQL errors are ad-hoc `do_spl_db_query` reads with wrong table/type (rounds 41 to 47 shape); the 7 client-lost FATALs and 1 Cloud Run 503 are transient connection/roll errors (0 alert incidents). |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=6h ./run -a do_gcp_list_alert_incidents` (00:28:21Z) | 9 policies, 0 incidents in 18:28:21Z..00:28:21Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,120), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (00:28:33Z) | 6 issues (plus SPL-6544 this round): 3 `wip` in the release-transfer repo (SPL-6361, 6362, 6366), 3 `onhold` (SPL-5911, 5254, 4994) | **0 rows.** 0 open `csi-spl` `eval`/`todo`/`wip` bug issues outside this round (SPL-6527, 6528, 6531 all landed since W). |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (00:26Z..00:33Z, background) | 100 runs, 2026-11-25T05:45:30Z..2026-11-26T00:12:49Z: 72 success, 21 cancelled, 6 failure, 1 running; every job's p90 under 75% of its timeout (highest: hermetic 1/4 & 3/4, 60%). **0 failed runs since W** (all 6 failures pre-W: 2 `wui e2e 5/8` fixed by SPL-6531 `672162eb9`, 1 `orc feature` pre-W, 3 `release-note` on `222f6efe` fixed) | **0 rows**: section 3.4. Trunk is green on all wf 10 jobs (`last green 45726181846` on `3f138364`, `wui 5/8` `45723717737` on `6fd4c740`). |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 100 --json databaseId,workflowName,headSha,createdAt,conclusion` (00:28Z), `createdAt >= 2026-11-25T19:40:33Z` | **0 failed runs** across all workflows since W (`[]`); `do_check_deploy_lag` dev and prd both `current` (hub `85f11faa`, wui `9c27df09`, `n=0`) | **0 rows.** wf 40 turned green after SPL-6528 `36a3228f7` landed. |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=6h LINES=5000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (00:28Z; cap not reached), plus 16 h targeted `hours/minutes` read | 503 entries, 443 since W: 406 `upload token refused` (`unknown_token`), 10 `ws hello refused` (`unpinned_box`), 7 `GET /v1/view/netvisor/forecast` 404, 5 `GET /v1/.env` 404, 4 `github: request refused`, 3 `GET /v1/view/netvisor/forecast` 403, 3 `short/268185` 404, 2 `view/messages/<uuid>/move` 404, 2 `/robots.txt` 404, 1 `/v1/healthz` 404. Targeted 16 h `hours/minutes` read: **0 HTTP 400s and 0 `hours: minutes refused` warns** (only 2 HTTP 401s at 08:40Z and 09:46Z) | **0 rows**: section 3.5. |
| **7. R7 notes & automation logs since W** | `git log d5a2422f4..fe99a5bc6 --format=%B`, `c-001`/`c-002`/`c-003` spool archives since 19:40Z, and `/var/spool-hub/dispatch/automation.log` lines 3860..3875 | 35 commits, 7 `review:` lines; **live duplicate GO bug** in `automation.log:3867-3868` (SPL-6543 head `48cb5ad26` to `a-806`, c-002 `37cf115f`, c-001 `08587a39`) + recent R7 notes (`a-748`, `a-756`, `a-767`, `a-769`, `a-770`, `a-772`, `a-775`, `a-789`, `a-790`, `a-801`, `a-823`, `a-826`, `a-838`, `a-841`) | **Row b48-01** (section 3.1). `a-826` N2 on SPL-6517 stays with live lane `c-722@sat` (R3); other R7 notes accounted in section 3.6. |
| **8. Owner and member posts** | `ENV=prd SQL="select tenant_id, from_id, count(*), max(accepted_at) from messages where from_id like 'HUM-%' and accepted_at > '2026-11-25T19:40:33Z' group by 1, 2 order by 1, 2" ./run -a do_spl_db_query` (00:28:41Z) | 0 rows across all workspaces | **0 rows.** |
| **9. Round 47's first inputs** | `bug-round-47-plan.md` section 7, re-measured on `fe99a5bc6` | 14 named inputs + carried items: #1 `spl-customer-box-role-check.func.sh:115-122` SPL-6122 N3 (`ignore_errors`/`failed_when` in role 04, 0 hits in shipped roles) and `a-704` N1 (`tf_plan_resource_changes` in `tf-plan-pending.func.sh:35-40` counting `moved`/`import` `["no-op"]` plans as 0) both reproduce cleanly on `fe99a5bc6` | **Rows b48-02 and b48-03** (sections 3.2 and 3.3). Rest accounted in section 3.6. |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (read directly on sat, 00:26Z) | 142 lines; new entry at `:141-142` (`review-go` owner-go `DRY_RUN=0` false holds on inline backticks, `c-001` `0172a8fc`, `7b492c13`, `1dd01968`) | **0 rows directly**: naive backtick-skip contradicts `spl-review-go.func.sh:654-655` and `spl-review-go.tst.sh:111-113` case 24 (`a backticked prd step -> rc 4`); needs narrower design (section 3.6). |

---

## 3. The candidates, read

### 3.1 b48-01: `do_spl_review_go` (`spl-review-go.func.sh:175-177,777-813`) deduplicates only by `msg_id`, sending duplicate `GO`s for one `PASS` delivered under two message ids

- **What happens.** `_spl_review_go_seen` (`csi-spl-orc/src/bash/run/spl-review-go.func.sh:175-177`) checks `automation.log` only for the incoming message's `msg_id` (`grep -qE "^(PASS|WAIT) [^ ]+ $1 | review-go $1 " "$2"`), never for whether `automation.log` already holds a `PASS` row (`PASS <ts> <msg_id> <task_id> <author_id> <reviewer_id> <sha>`, written at `:905`) for the same `<author>` and `<sha>`. When one review PASS reaches the dispatch holder under two different `msg_id`s (e.g. the reviewer sends `result` to `c-003` and `note` to `c-002` across a lease handoff, or a PASS copy is forwarded), `_spl_review_go_seen` misses the second `msg_id`, `_spl_review_go_one` (`:777-813`) re-runs all checks, sends a **second `GO <sha>`** to the author, and appends a second `PASS` row to `automation.log`.
- **Seen.** Live incident on sat (2026-11-25 22:47Z..22:51Z, c-002 note `37cf115f`, c-001 confirmation `08587a39`), verified in `/var/spool-hub/dispatch/automation.log:3867-3868`:
  - `PASS 2026-11-25T22:47:07Z ff2937b0-da89-4ab6-8ad0-9b05d322f1f0 dispatch-c2838b08 a-806 c-814 48cb5ad2622c3e648e33ba13e44047c98eb1dc3e`
  - `PASS 2026-11-25T22:51:08Z 90ab22d0-b477-41bf-9699-1b4869179b01 dispatch-c2838b08 a-806 c-814 48cb5ad2622c3e648e33ba13e44047c98eb1dc3e`
  (`c-814` sent `ff2937b0` to `c-003` at 22:46:13Z and `90ab22d0` to `c-002` at 22:46:20Z; `c-003` sent GO #1, then `c-002` took the lease and sent GO #2). Verified on `fe99a5bc6` across `spl-review-go.func.sh:143-158,173-177,777-813,905` (`_spl_review_go_one` is 37 lines, `do_spl_review_go` is 33 lines; both well under 75 lines).
- **Red control** (`rc01-b48.sh`, section 4.1): extracts `csi-spl-orc` from `fe99a5bc6` and tests 4 cases against a throwaway git repo and spool root: (A) two copies of the same PASS (`result` + `note`, different `msg_id`s) in one batch run plus a second cron tick, (B) a third copy checked via `REVIEW_GO_MSG` (cross-holder replay after `PASS` already logged), (C) `DRY_RUN=1` on a fourth copy (must emit no `PLAN GO` and write nothing to `automation.log`), and (D) CONTROL: a PASS for the same author + reviewer on a **new** commit `SHA2` (must still send a GO). On `fe99a5bc6`: A sends 2 GOs (`2 GO(s) sent`, 2 PASS rows), B sends a 3rd GO, C prints `PLAN GO` -> `rc01 exit 1`. **Control**: `fix-shape` adds `_spl_review_go_seen_pass` + `_spl_review_go_dedup` right after `author` is resolved (`:793`) -> A sends 1 GO (`1 GO(s) sent`, 0 holds, 1 PASS row; 2nd tick `0 GO(s) sent`, log unchanged), B exits 0 with 0 new GOs, C prints 0 `PLAN GO` and leaves log unchanged, D sends GO #2 -> `rc01 exit 0`.
- **Fix scope.** `csi-spl-orc/src/bash/run/spl-review-go.func.sh`:
  - Add `_spl_review_go_seen_pass <author> <sha> <log>` (`grep -qE "^PASS [^ ]+ [^ ]+ [^ ]+ $1 [^ ]+ $2$" "$3" 2>/dev/null`) and `_spl_review_go_dedup <mid> <log> <dry> <author> <sha>` (on `dry == 1`: print `PLAN SKIP msg $mid (duplicate PASS for $author ${sha:0:12})`, write nothing; on `dry == 0`: append `<ts> review-go $mid action=dedup author=$author sha=$sha` to `$log` so `_spl_review_go_seen` skips it on subsequent ticks, log INFO, send no GO and no hold note; return `11`).
  - Call `_spl_review_go_seen_pass` in `_spl_review_go_one` right after `author` is resolved (`:793`, before checks [2]/[7]/[4]/[6]/[8]/[5]/[10] and `_spl_review_go_send`), returning `11` on hit (so batch mode `:155` does not count it in `n GO(s) sent`).
  - In `do_spl_review_go` (`:148`, `REVIEW_GO_MSG` single-message mode), map rc `11` to `return 0` (matching `@param REVIEW_GO_MSG`: `0 when already logged`). Update the header `@description` comment to document dedup on `(author, sha)` **on the same box** (panel N1: dedup reads only this box's `automation.log`, so a lease handoff across boxes can still double-GO). Keep every function <= 75 lines.
  - `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`: add case 33 after `:1286` covering (a) two copies of one PASS in batch mode -> 1 GO, 0 holds, 1 PASS row, `1 GO(s) sent`, 2nd tick `0 GO(s) sent` + log unchanged, (b) `REVIEW_GO_MSG` on a new `msg_id` for an already-logged `PASS` -> rc 0, 0 new GOs, 0 holds, (c) `DRY_RUN=1` on a duplicate -> no `PLAN GO`, log unchanged, (d) control: a new sha for the same author still sends a GO. Keep all existing cases 1 to 32 green. `Docs: none` (header comment updates the action doc; bug fix to existing spec 157 Rule 1 dedup invariant).

### 3.2 b48-02: `do_spl_customer_box_role_check` (`spl-customer-box-role-check.func.sh:45,115-122`) lets `ignore_errors`, `failed_when`, and single-quoted `when: 'false'` swallow role 04 desk start check refusals

- **What happens.** `do_spl_customer_box_role_check` (`csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh:36-48`) enforces spec 181 B6 / spec 127 5.3 ("the play fails when one refuses", `roles/04_desk_start_checks/tasks/main.yml:3`) by checking that `spl_desk_start_checks` is called (`:44`) and running `spl_cbr_when_false` (`:45`, `:115-122`). However:
  1. `spl_cbr_when_false` (`:120`) matches only `^[[:space:]]*when:[[:space:]]*(false|no|False|"false"|0)[[:space:]]*$`, missing single-quoted `'false'`, `"no"`, `'no'`, case variants (`FALSE`, `NO`), and trailing comments (`when: false # skip`).
  2. Nothing checks `ignore_errors:` or `failed_when:`. Adding `ignore_errors: true` (or `"yes"` / `1`) or `failed_when: false` (or `failed_when: dsc_out.rc == 99`) to `roles/04_desk_start_checks/tasks/main.yml` (or `ignore_errors: true` to `roles/03_workspace/tasks/main.yml`) passes `do_spl_customer_box_role_check` with `OK` (rc 0), silently swallowing a desk start check refusal on a misconfigured customer VM.
- **Seen.** Bug round 47 plan section 7 first input #1; `c002-next-round-candidates.md:95` (SPL-6122 R7 c-502 N3). Verified on `fe99a5bc6`: `git grep -n 'ignore_errors\|failed_when' fe99a5bc6 -- csi-spl-iac/src/ansible/customer-box/ | wc -l` -> **0** (while `changed_when: false` IS legitimately used at `roles/04_desk_start_checks/tasks/main.yml:19` and must stay allowed). Baseline `bash csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` -> 0 failures.
- **Red control** (`rc02-b48.sh`, section 4.2): runs `do_spl_customer_box_role_check` on copies of `src/ansible/customer-box` from `fe99a5bc6`: controls (shipped set with `changed_when: false` at role 04 `:19`; comment lines `# ignore_errors: true` / `# failed_when: false`) plus 6 planted bypasses (`ignore_errors: true`, `ignore_errors: "yes"`, `failed_when: false`, `failed_when: dsc_out.rc == 99`, `when: 'false'` in role 04, and `ignore_errors: true` in role 03). On `fe99a5bc6`: all 6 planted bypasses pass (`rc=0`, want `1`) -> `rc02 exit 1`. **Control**: `fix-shape` widens `spl_cbr_when_false` (case-insensitive, single/double quotes, optional trailing `# comment`) and adds `spl_cbr_no_swallow` (refusing truthy `ignore_errors` / falsy `failed_when` anywhere in the set and any non-comment `ignore_errors:` or `failed_when:` in `roles/04_desk_start_checks/`) -> both controls pass (`rc=0`), all 6 planted bypasses refused (`rc=1`) -> `rc02 exit 0`.
- **Fix scope.** `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh`:
  - Widen `spl_cbr_when_false` (`:115-122`) to `grep -rniE '^[[:space:]]*when:[[:space:]]*["'\'']?(false|no|0)["'\'']?[[:space:]]*(#.*)?$' "$d"`.
  - Add `spl_cbr_no_swallow "$d"` called from `do_spl_customer_box_role_check` (`:45`), emitting `REFUSED swallow-error: ...` for any non-comment truthy `ignore_errors:` (`true`/`yes`/`1`, optional quotes/case/comment) or falsy `failed_when:` (`false`/`no`/`0`, optional quotes/case/comment) across the whole role set `$d` (reaching beyond role 04, e.g. role 03 enrol; panel N3: slug `role04` kept), and for any non-comment `ignore_errors:` or `failed_when:` in `$d/roles/04_desk_start_checks/`. Do NOT match `changed_when:` or comment lines. Document `swallow-error` in the header `@description` and note in the ban-list limits that `rescue:`, `ignore_unreachable`, and templated falsy values stay outside the static ban list (panel N3). Keep all functions <= 75 lines.
  - `csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh`: add controls after `:121` proving `ignore_errors: true`, `ignore_errors: "yes"`, `failed_when: false`, `failed_when: dsc_out.rc == 99`, `when: 'false'` in role 04 and `ignore_errors: true` in role 03 are each refused (`REFUSED swallow-error:` / `REFUSED when-false:`), while comment lines naming `ignore_errors`/`failed_when` and the shipped set (`changed_when: false`) stay green. `Docs: none` (gate action header documents the new check; enforces existing spec 181 B6 / spec 127 5.3 contract).

### 3.3 b48-03: `tf_plan_resource_changes` (`tf-plan-pending.func.sh:35-40`) ignores `moved` and `import` blocks whose `.change.actions` is `["no-op"]`, misclassifying state-mutating dev plans as `clean (outputs only)`

- **What happens.** `tf_plan_resource_changes` (`csi-spl-iac/src/bash/run/tf-plan-pending.func.sh:35-40`, added by SPL-6528 `36a3228f7`) counts resource changes in `terraform show -json` with:
  `[.resource_changes[]? | .change.actions | select(. != ["no-op"] and . != ["read"])] | length`
  In Terraform's JSON plan format (`format_version: "1.2"`), a `moved {}` block sets `.previous_address` on a `resource_changes` entry whose `.change.actions` is `["no-op"]`, and an `import {}` block sets `.change.importing` (an object `{"id": "..."}`) on a `resource_changes` entry whose `.change.actions` can also be `["no-op"]` when the imported resource already matches configuration. Because `tf_plan_resource_changes` inspects `.change.actions` only, both return `0`, causing `do_tf_plan_pending` (`:64`) to declare dev `clean (outputs only)` and cache it, allowing a prd apply to run ahead of a pending dev state move or import.
- **Seen.** a-704@sat R7 N1 (`49a020e0`, 2026-11-25 18:53Z) on SPL-6528 (`36a3228f7`, landed); carried in `bug-round-47-plan.md` section 7. Verified on `fe99a5bc6` (`tf-plan-pending.func.sh:35-40`, sole `tf_plan_resource_changes` definition in repo; baseline `bash csi-spl-iac/src/bash/tests/env-order-gate.tst.sh` -> `PASS: all env-order-gate.tst.sh assertions`).
- **Red control** (`rc03-b48.sh`, section 4.3): sources `tf-plan-pending.func.sh` from `fe99a5bc6` with a stub `terraform` serving four `format_version: "1.2"` JSON plans: (1) `moved` (`previous_address` set + `actions: ["no-op"]`), (2) `import` (`change.importing` set + `actions: ["no-op"]`), (3) control (`previous_address: null`, `importing: null`, `["no-op"]` + `["read"]`), and (4) control (`["update"]`). On `fe99a5bc6`: `moved=0 (want 1); import=0 (want 1); ctrl_noop_read_nulls=0; ctrl_update=1` -> `rc03 exit 1`. **Control**: `fix-shape` updates the jq `select(...)` to also count `.previous_address != null or .change.importing != null` -> `moved=1; import=1; ctrl_noop_read_nulls=0; ctrl_update=1` -> `rc03 exit 0`.
- **Fix scope.** `csi-spl-iac/src/bash/run/tf-plan-pending.func.sh:31-40`: update `tf_plan_resource_changes`'s jq filter to `select((.change.actions != ["no-op"] and .change.actions != ["read"]) or .previous_address != null or .change.importing != null)` and update the 2-line function comment at `:31-32` to note `moved` / `import` entries. `csi-spl-iac/src/bash/tests/env-order-gate.tst.sh`: extend section 6b (`:151-173`) to prove a `moved` plan (`previous_address` + `["no-op"]`) and an `import` plan (`change.importing` + `["no-op"]`) both return `rc 2 pending` and are NOT cached, while an outputs-only `["no-op"]` plan with explicit `null` `previous_address`/`importing` still returns `rc 0 clean (outputs only)`. Per panel N4 (`rc03-b48.sh` stubs `terraform`), in the commit body cite or prove in the tf-runner (or Terraform 1.9.8 docs/run) that `-detailed-exitcode` exits 2 on a `moved`/`import`-only plan and that already-applied `moved`/`import` blocks (e.g. steps 025, 030, 070) stop reporting `previous_address`/`importing` on subsequent plans. Keep `tenant-host-workflow-40.tst.sh`, `tf-log-mask-billing-id.tst.sh`, and `csi-spl-orc/src/bash/tests/tf-runner-make-path.tst.sh` green. `Docs: none` (function comment documents the jq check; aligns SPL-6528 with dev-leads-prd state parity).

### 3.4 CI reds in the 100 runs, read

| run range | job | first red line | why not a row |
|---|---|---|---|
| **Since W (`19:40:33Z`)**: none | all jobs | 0 failed runs across wf 10 and every other workflow on master | **0 rows**: trunk is green (`45726181846` on `3f138364`, `wui 5/8` `45723717737` on `6fd4c740`). |
| `45678338355`, `45674842811` (18:24Z..18:45Z, pre-W) | wui e2e 5/8 | `FAIL 360 login no-bfcache L3>L2>L1>L1>out Back never re-parsed /login` | **Served**: fixed by SPL-6531 `672162eb9` (green since). |
| `45661882286` (17:10Z, pre-W) | orc feature tests | `FAIL - 1. sent, exit 0 (want '0', got '137')` | **Served**: pre-W, green since. |
| `45596579656`..`45598661206` (10:36Z..10:49Z, pre-W) | release-note | `FAIL release-note: 222f6efe (full) missing Lay-What ...` | **Served**: pre-W, green since. |

### 3.5 The prd WARNING lines, read

| candidate | read | why not a row |
|---|---|---|
| `upload token refused` (`unknown_token`), 406 since W | same box question carried since round 43 | **Not a row**: carried with holder. |
| `ws hello refused` (`unpinned_box`), 10 since W | `<dev-box>` unpinned client retries | **Not a row.** |
| `GET /v1/view/netvisor/forecast` 404 (7) & 403 (3); `GET /v1/.env` 404 (5); `github: request refused` (4); `short/268185` 404 (3); `view/messages/<uuid>/move` 404 (2); `/robots.txt` 404 (2); `/v1/healthz` 404 (1) | expected refusals, missing/deleted ids, or internet scanners | **Not a row.** |
| `PUT /v1/me/hours/minutes` >=400 / `hours: minutes refused` | 0 HTTP 400s and 0 warn lines in 16 h (only 2 HTTP 401s at 08:40Z and 09:46Z) | **Carried**: wait for a live `hours: minutes refused` warn before deciding spec 107 / WUI follow-up. |

### 3.6 Round 47's first inputs, tonight's other R7 notes, and the candidate list, re-read

| candidate | result on `fe99a5bc6` | verdict |
|---|---|---|
| `spl-review-go.func.sh:176` duplicate GO on forwarded/re-delivered PASS (brief, c-002 `37cf115f`, c-001 `08587a39`) | verified in `automation.log:3867-3868` and reproduced live in `rc01-b48.sh` | **Row b48-01** (section 3.1). |
| `spl-customer-box-role-check.func.sh:115-122` SPL-6122 N3 (`ignore_errors`/`failed_when` in role 04, round 47 first input #1) | 0 hits in shipped roles; all 6 planted bypasses pass `do_spl_customer_box_role_check` in `rc02-b48.sh` | **Row b48-02** (section 3.2). |
| `a-704` N1 (`tf-plan-pending.func.sh:35-40` `moved`/`import` `["no-op"]` counted as 0, round 47 first input) | reproduced cleanly in `rc03-b48.sh` | **Row b48-03** (section 3.3). |
| `c002-next-round-candidates.md:141-142` & round 47 first input #8 (`review-go` owner-go `DRY_RUN=0` false holds on inline backticks + non-instruction `apply` rule [4] holds, `c-001` `0172a8fc`, `7b492c13`, `1dd01968`, `904db995`; panel N5) | **Conflict found:** `spl-review-go.func.sh:654-655` intentionally keeps inline backticks ("a command the lane is told to run is written in backticks"), and `spl-review-go.tst.sh:111-113` case 24 explicitly asserts `a backticked prd step -> rc 4`. Skipping all inline backticks would break case 24 and let real backticked `DRY_RUN=0` / `ENV=prd` commands bypass check [4]; also same file as b48-01 (R1) | **Not taken as naive backtick-strip**: carried to round 49 with design note (needs narrow scope: e.g. plan-table `why`/description cells vs `Do`/command lines, without weakening case 24). |
| `a-826` N2 on SPL-6517 (`spool-live-ack.sh` log has no size cap, named in brief) | SPL-6517 is still live (`c-722@sat` + `a-826@sat` in `do_spl_lane_map` 00:29Z; waiting on `PRE_PUSH_TIER=full` for `11391fee0`) | **Left to `c-722@sat`** (R3; brief: leave unless it lands without it). |
| `a-801` N1 on b47-03 (`spl-spawn-place.func.sh:1448,1464` `IFS=$'\t' read` collapses empty vendor on colon-less `.placement`) | real Bash `IFS` whitespace trap (SPL-5612 shape), narrow edge case (colon-less `.placement`) | **Carried** to round 49 (4th candidate; round capped at 3 rows, 5.1). |
| `a-767` N2 on SPL-6516 (`spool-agent-hook.sh:683,771` `prev_session` updates on tool hook before `Stop` -> stale `stop_denies`), `a-823` N2 (`PreInvocation` in top-level `EVENTS`) | `spool-agent-hook.sh` / hook tests touched by live SPL-6517 (`c-722@sat`, R3) | **Carried** to round 49 once SPL-6517 lands. |
| `a-841` N1 on r03-02 (`setup-gh-runner-cpu-budget-cron.tst.sh:83-91` section 4 red control copies only one func file) | `c-784@<box2>` / `a-841@sat` live in `do_spl_lane_map` at 00:29Z (R3) | **Carried** to round 49. |
| `a-748` N3-N4 (`y9-vendor-lane-rule.sh:64-77` `_y9_qwen` non-`O_EXCL` backup / silent stderr), `a-769` N2-N3 (`tenant-host-reserve.tst.sh` symlink case; `private-overlay.md:112,118`), `a-790` N1 (`mcp_test.go:560-563` control runs on ambient env), `a-775` N1 (`spl-dispatch-subscribe.func.sh:89-95` comment), `a-756` N1 (`phone-back-matrix.test.mjs:429-436`) | non-blocking notes on commits landed since W | **Carried** to round 49 (`a-748` N3-N4 and `a-769` N2 worth a look next). |
| Round 47 carried inputs: `c-708` N1 (`BoxTaskEnvelopes` box-scoped probe on `spool-topic-kind.sh` when box has agent-only rows in an owner topic, SPL-6527 landed `1a8c1ce1c`), `a-683` N3 (non-`AgentsCommand` / embed / `channel_box_pins` posts in `hum\|`), `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`, `c-298@sat` still live R3), `a-490` N1 (`TestCategoryTestPathsZZIsolated` guard regex at `categories_test.go:388`, panel W1), `a-480` N1 (`syncWriter.Reset`), hours-minutes 400 follow-up (0 warns in 16 h), `i18n-lang-review-exempt.json:2` (still says `Lang-review: a-NNN` on `fe99a5bc6`, doc/refactor), `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget`, `unknown_token` box, hub dir mode, hermetic 2/4 timeout, composed testids, SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` | re-checked: unchanged / carried (`c-298@sat` live R3; `c-708` N1 requires hub-side endpoint change) | **Carried** to round 49. |

---

## 4. Red controls, as run

### 4.1 `rc01-b48.sh` (b48-01), sha256 first 12 hex `d93053b1a1f5`, 8514 B

Run from any checkout: `bash rc01-b48.sh fe99a5bc6` (exit 1), then `bash rc01-b48.sh fe99a5bc6 fix-shape` (exit 0). About 3 s each.

```bash
#!/usr/bin/env bash
# rc01-b48.sh <sha> [fix-shape]: b48-01 red control. On <sha>'s tree,
# do_spl_review_go (spl-review-go.func.sh:175-177,777-813) deduplicates only
# by msg_id, so a second copy of the same PASS under a new msg_id (e.g.
# reviewer sends result to c-003 and note to c-002 across a lease handoff)
# sends a second GO and appends a second PASS row to automation.log (c-002
# 37cf115f, c-001 08587a39). Runs against a throwaway git repo and spool root
# extracted from <sha> with git archive. fix-shape deduplicates PASS by
# author+sha before check [4]/[6]/[8]/[5]/send, writing an action=dedup record
# (no GO, no hold, not counted in GO(s) sent) on DRY_RUN=0 and skipping
# without PLAN GO or log writes on DRY_RUN=1.
set -uo pipefail
sha="${1:?usage: rc01-b48.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc csi-spl-iac | tar -x -C "$tmp"
fn="$tmp/csi-spl-orc/src/bash/run/spl-review-go.func.sh"
a=$(grep -c '^_spl_review_go_seen()' "$fn")
b=$(grep -c '^_spl_review_go_one()' "$fn")
echo "rc01 sites: seen=$a one=$b"
[ "$a" = 1 ] && [ "$b" = 1 ] || { echo "rc01 sites moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$fn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old_call = '    _spl_review_go_one "$holder" "$mid" "$task" "$line" "$log" "$dry" "$from"; return\n'
new_call = '    rc=0; _spl_review_go_one "$holder" "$mid" "$task" "$line" "$log" "$dry" "$from" || rc=$?; (( rc == 11 )) && return 0; return "$rc"\n'
assert s.count(old_call) == 1, "call target not unique"
s = s.replace(old_call, new_call, 1)

old_seen = '''_spl_review_go_seen() {
  grep -qE "^(PASS|WAIT) [^ ]+ $1 | review-go $1 " "$2" 2>/dev/null
}'''
new_seen = '''_spl_review_go_seen() {
  grep -qE "^(PASS|WAIT) [^ ]+ $1 | review-go $1 " "$2" 2>/dev/null
}
_spl_review_go_seen_pass() {
  grep -qE "^PASS [^ ]+ [^ ]+ [^ ]+ $1 [^ ]+ $2$" "$3" 2>/dev/null
}
_spl_review_go_dedup() {
  if [[ "$3" == 1 ]]; then
    echo "PLAN SKIP msg $1 (duplicate PASS for $4 ${5:0:12})"
    return 11
  fi
  printf '%s review-go %s action=dedup author=%s sha=%s\\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$4" "$5" >>"$2"
  do_log "INFO msg $1: skipped duplicate PASS for $4 ${5:0:12}"
  return 11
}'''
assert s.count(old_seen) == 1, "seen target not unique"
s = s.replace(old_seen, new_seen, 1)

old_one = '  [[ -n "${author:-}" ]] || { _spl_review_go_hold "$@" 3 "$(_spl_review_go_unplaced "$brief" "$sha" "$task")"; return 3; }\n'
new_one = old_one + '  _spl_review_go_seen_pass "$author" "$sha" "$log" && { _spl_review_go_dedup "$mid" "$log" "$dry" "$author" "$sha"; return 11; }\n'
assert s.count(old_one) == 1, "one target not unique"
s = s.replace(old_one, new_one, 1)
open(p, "w").write(s)
PY
  echo "rc01 fix-shape: dedup PASS by author+sha"
fi

G=(git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master)
"${G[@]}" init -q --bare "$tmp/origin.git"
"${G[@]}" clone -q "$tmp/origin.git" "$tmp/repo" 2>/dev/null
echo a >"$tmp/repo/a.txt" && "${G[@]}" -C "$tmp/repo" add a.txt && "${G[@]}" -C "$tmp/repo" commit -qm base
"${G[@]}" -C "$tmp/repo" push -q origin HEAD:master
echo b >"$tmp/repo/a.txt" && "${G[@]}" -C "$tmp/repo" commit -qam c1
SHA1=$("${G[@]}" -C "$tmp/repo" rev-parse HEAD)
"${G[@]}" -C "$tmp/repo" push -q origin HEAD:refs/heads/review/c002-x
echo c >"$tmp/repo/a.txt" && "${G[@]}" -C "$tmp/repo" commit -qam c2
SHA2=$("${G[@]}" -C "$tmp/repo" rev-parse HEAD)
"${G[@]}" -C "$tmp/repo" push -q origin HEAD:refs/heads/review/c002-x2

S="$tmp/spool"
LOG="$S/dispatch/automation.log"
TASK="1c120227-ce10-5ffd-895a-2168872fce83"
NOW="2026-10-28T12:00:00Z"
mkdir -p "$S/dispatch" "$S/c-002/inbox" "$S/c-002/archive" "$S/g-111/lifetime" "$S/c-222/lifetime" "$tmp/logs/-opt-csi-csi-spl-wt-g-111"
printf 'c-002@boxa %s\n' "$(( $(date +%s) - 5 ))" >"$S/dispatch/lease"
printf 'LEASE_ORCH=c-001\nLEASE_MACHINE=boxa\nLEASE_ENV=prd\n' >"$S/dispatch/lease.conf"
printf '#!/bin/sh\necho "SEND $*" >>"$SEND_LOG"\nexit 0\n' >"$tmp/send.sh"
chmod +x "$tmp/send.sh"
: >"$tmp/sent.log"
cat >"$S/g-111/lifetime/brief.md" <<BR
# Lane brief: review
| author | review branch | sha | base | task |
|---|---|---|---|---|
| c-222@boxa (claude) | review/c002-x | ${SHA1:0:12} | origin/master | $TASK |
| c-222@boxa (claude) | review/c002-x2 | ${SHA2:0:12} | origin/master | $TASK |
BR
printf '# Lane brief\n\nDo: a small orc fix.\n' >"$S/c-222/lifetime/brief.md"
python3 -c 'import json; print(json.dumps({"type":"assistant","input":{"command":"bash csi-spl-orc/src/bash/tests/foo.tst.sh"}}))' \
  >"$tmp/logs/-opt-csi-csi-spl-wt-g-111/s.jsonl"

mk_msg() {
  local ts="$1" mid="$2" sh="$3" kind="$4"
  local body="review: g-111@boxa grok PASS $sh ran: bash csi-spl-orc/src/bash/tests/foo.tst.sh | read: 1 PASS | log: g-111@boxa:$tmp/logs/-opt-csi-csi-spl-wt-g-111/s.jsonl"
  local f="$S/c-002/inbox/$ts--g-111@boxa--review-${mid:0:8}.json"
  python3 -c 'import json,sys; print(json.dumps({"body":sys.argv[1],"files":[],"from":"g-111@boxa","kind":sys.argv[4],"msg_id":sys.argv[2],"task_id":sys.argv[3],"to":"c-002","ts":sys.argv[5],"v":1}))' \
    "$body" "$mid" "$TASK" "$kind" "${ts:0:4}-${ts:4:2}-${ts:6:2}T${ts:9:2}:${ts:11:2}:${ts:13:2}Z" >"$f"
  echo "$f"
}

run_go() {
  env PROJ_PATH="$tmp/csi-spl-orc" APP_PATH="$tmp" SPOOL_ROOT="$S" SPL_STATE_DIR="$tmp/state" \
    REVIEW_GO_NOW="$NOW" REVIEW_GO_SEND="$tmp/send.sh" SEND_LOG="$tmp/sent.log" REVIEW_GO_REPO="$tmp/repo" \
    REVIEW_LINE_BOX=boxa DRY_RUN=0 "$@" bash -c '
      set -uo pipefail
      do_log() { echo "$*"; }
      do_require_bin() { return 0; }
      for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
      do_spl_review_go'
}

# A: two copies of the same PASS (result + note, different msg_ids) in one batch
mk_msg 20261028T115800Z 11111111-0000-4000-8000-000000000001 "$SHA1" result >/dev/null
mk_msg 20261028T115810Z 22222222-0000-4000-8000-000000000002 "$SHA1" note >/dev/null
out_a="$(run_go 2>&1)"
gos_a=$(grep -c -- ' --kind task ' "$tmp/sent.log" || true)
holds_a=$(grep -c -- ' --kind note --task review-go ' "$tmp/sent.log" || true)
pass_a=$(grep -c '^PASS ' "$LOG" 2>/dev/null || true)
sent_a=$(grep -oE '[0-9]+ GO\(s\) sent' <<<"$out_a" | tail -1)
# Second tick must send 0 GOs and append nothing
lines_a=$(wc -l <"$LOG" 2>/dev/null || echo 0)
out_a2="$(run_go 2>&1)"
lines_a2=$(wc -l <"$LOG" 2>/dev/null || echo 0)
sent_a2=$(grep -oE '[0-9]+ GO\(s\) sent' <<<"$out_a2" | tail -1)

# B: third copy checked with REVIEW_GO_MSG (cross-holder forward after PASS already logged)
f3="$(mk_msg 20261028T115820Z 33333333-0000-4000-8000-000000000003 "$SHA1" note)"
out_b="$(run_go REVIEW_GO_MSG="$f3" 2>&1)"; rc_b=$?
gos_b=$(grep -c -- ' --kind task ' "$tmp/sent.log" || true)
pass_b=$(grep -c '^PASS ' "$LOG" 2>/dev/null || true)

# C: DRY_RUN=1 on a fourth duplicate copy -> no PLAN GO, log unchanged
f4="$(mk_msg 20261028T115825Z 44444444-0000-4000-8000-000000000004 "$SHA1" note)"
lines_before=$(wc -l <"$LOG" 2>/dev/null || echo 0)
out_c="$(run_go DRY_RUN=1 REVIEW_GO_MSG="$f4" 2>&1)"
lines_after=$(wc -l <"$LOG" 2>/dev/null || echo 0)
plan_go_c=$(grep -c '^PLAN GO ' <<<"$out_c" || true)

# D: CONTROL: new sha SHA2 for same author+reviewer -> must STILL send GO
f5="$(mk_msg 20261028T115830Z 55555555-0000-4000-8000-000000000005 "$SHA2" result)"
out_d="$(run_go REVIEW_GO_MSG="$f5" 2>&1)"; rc_d=$?
gos_d=$(grep -c -- ' --kind task ' "$tmp/sent.log" || true)
pass_d=$(grep -c '^PASS ' "$LOG" 2>/dev/null || true)

echo "rc01 batch(A): gos=$gos_a (want 1) holds=$holds_a (want 0) pass=$pass_a (want 1) summary='$sent_a' tick2='$sent_a2' log=${lines_a}->${lines_a2}"
echo "rc01 single(B): rc=$rc_b (want 0) gos=$gos_b (want 1) pass=$pass_b (want 1)"
echo "rc01 dry(C): plan_go=$plan_go_c (want 0) log_lines=${lines_before}->${lines_after} (want equal)"
echo "rc01 new_sha(D): rc=$rc_d (want 0) gos=$gos_d (want 2) pass=$pass_d (want 2)"
rc=0
[ "$gos_a" = 1 ] && [ "$holds_a" = 0 ] && [ "$pass_a" = 1 ] && [ "$sent_a" = "1 GO(s) sent" ] && [ "$sent_a2" = "0 GO(s) sent" ] && [ "$lines_a" = "$lines_a2" ] || rc=1
[ "$rc_b" = 0 ] && [ "$gos_b" = 1 ] && [ "$pass_b" = 1 ] || rc=1
[ "$plan_go_c" = 0 ] && [ "$lines_before" = "$lines_after" ] || rc=1
[ "$rc_d" = 0 ] && [ "$gos_d" = 2 ] && [ "$pass_d" = 2 ] || rc=1
echo "rc01 exit $rc"
exit "$rc"
```

Output on `fe99a5bc6` (sat, 00:40Z):

| run | output |
|---|---|
| `bash rc01-b48.sh fe99a5bc6` | `rc01 sites: seen=1 one=1` / `rc01 batch(A): gos=2 (want 1) holds=0 (want 0) pass=2 (want 1) summary='2 GO(s) sent' tick2='0 GO(s) sent' log=2->2` / `rc01 single(B): rc=0 (want 0) gos=3 (want 1) pass=3 (want 1)` / `rc01 dry(C): plan_go=1 (want 0) log_lines=3->3 (want equal)` / `rc01 new_sha(D): rc=0 (want 0) gos=4 (want 2) pass=4 (want 2)` / `rc01 exit 1` |
| `bash rc01-b48.sh fe99a5bc6 fix-shape` | `rc01 sites: seen=1 one=1` / `rc01 fix-shape: dedup PASS by author+sha` / `rc01 batch(A): gos=1 (want 1) holds=0 (want 0) pass=1 (want 1) summary='1 GO(s) sent' tick2='0 GO(s) sent' log=2->2` / `rc01 single(B): rc=0 (want 0) gos=1 (want 1) pass=1 (want 1)` / `rc01 dry(C): plan_go=0 (want 0) log_lines=3->3 (want equal)` / `rc01 new_sha(D): rc=0 (want 0) gos=2 (want 2) pass=2 (want 2)` / `rc01 exit 0` |

### 4.2 `rc02-b48.sh` (b48-02), sha256 first 12 hex `ee327a2fa8e7`, 4452 B

Run from any checkout: `bash rc02-b48.sh fe99a5bc6` (exit 1), then `bash rc02-b48.sh fe99a5bc6 fix-shape` (exit 0). Under 2 s each.

```bash
#!/usr/bin/env bash
# rc02-b48.sh <sha> [fix-shape]: b48-02 red control. On <sha>'s tree,
# do_spl_customer_box_role_check (spl-customer-box-role-check.func.sh:115-122)
# checks only literal falsy `when:` values (missing single-quoted 'false' /
# "no"), and never refuses `ignore_errors:` or `failed_when:` in role 04
# (04_desk_start_checks) or truthy ignore_errors / falsy failed_when in the
# role set (SPL-6122 R7 c-502 N3). Extracts csi-spl-iac from <sha> into a
# mktemp dir. fix-shape extends spl_cbr_when_false for quotes/case and adds
# spl_cbr_no_swallow.
set -uo pipefail
sha="${1:?usage: rc02-b48.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-iac | tar -x -C "$tmp"
fn="$tmp/csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh"
a=$(grep -c '^do_spl_customer_box_role_check()' "$fn")
b=$(grep -c '^spl_cbr_when_false()' "$fn")
echo "rc02 sites: main=$a when_false=$b"
[ "$a" = 1 ] && [ "$b" = 1 ] || { echo "rc02 sites moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$fn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old_call = '  spl_cbr_when_false "$d" || bad=1\n'
new_call = '  spl_cbr_when_false "$d" || bad=1\n  spl_cbr_no_swallow "$d" || bad=1\n'
assert s.count(old_call) == 1
s = s.replace(old_call, new_call, 1)

old_wf = '''spl_cbr_when_false() {
  local d="$1" hit bad=0
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    spl_cbr_refuse when-false "${hit#"$d"/}"; bad=1
  done < <(grep -rnE '^[[:space:]]*when:[[:space:]]*(false|no|False|"false"|0)[[:space:]]*$' "$d" 2>/dev/null)
  return "$bad"
}'''
new_wf = '''spl_cbr_when_false() {
  local d="$1" hit bad=0
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    spl_cbr_refuse when-false "${hit#"$d"/}"; bad=1
  done < <(grep -rniE '^[[:space:]]*when:[[:space:]]*["'"'"']?(false|no|0)["'"'"']?[[:space:]]*(#.*)?$' "$d" 2>/dev/null)
  return "$bad"
}

spl_cbr_no_swallow() {
  local d="$1" hit bad=0 r4="$1/roles/04_desk_start_checks"
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    spl_cbr_refuse swallow-error "${hit#"$d"/}"; bad=1
  done < <(
    { grep -rniE '^[[:space:]]*ignore_errors:[[:space:]]*["'"'"']?(true|yes|1)["'"'"']?[[:space:]]*(#.*)?$|^[[:space:]]*failed_when:[[:space:]]*["'"'"']?(false|no|0)["'"'"']?[[:space:]]*(#.*)?$' "$d" 2>/dev/null
      [[ -d "$r4" ]] && grep -rniE '^[[:space:]]*(ignore_errors|failed_when):' "$r4" 2>/dev/null
    } | sort -u
  )
  return "$bad"
}'''
assert s.count(old_wf) == 1
s = s.replace(old_wf, new_wf, 1)
open(p, "w").write(s)
PY
  echo "rc02 fix-shape: when-false handles quotes/case + spl_cbr_no_swallow refuses ignore_errors/failed_when"
fi

SET="$tmp/csi-spl-iac/src/ansible/customer-box"
run_chk() {
  env PROJ_PATH="$tmp/csi-spl-iac" CUSTOMER_BOX_ROLE_DIR="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-customer-box-role-check.func.sh"
    do_spl_customer_box_role_check'
}
copy_set() { rm -rf "$tmp/s"; cp -a "$SET" "$tmp/s"; }

rc=0
# 1. CONTROL: shipped role set (includes changed_when: false in role 04) passes
out="$(run_chk "$SET" 2>&1)"; r=$?
echo "rc02 ctrl_shipped: rc=$r (want 0)"
[ "$r" = 0 ] || rc=1

# 2. CONTROL: comments naming ignore_errors / failed_when pass
copy_set; printf '# ignore_errors: true\n# failed_when: false\n' >>"$tmp/s/roles/04_desk_start_checks/tasks/main.yml"
out="$(run_chk "$tmp/s" 2>&1)"; r=$?
echo "rc02 ctrl_comments: rc=$r (want 0)"
[ "$r" = 0 ] || rc=1

# 3..7. RED cases in role 04
for pair in \
  "r4_ignore_true|  ignore_errors: true" \
  "r4_ignore_quoted|  ignore_errors: \"yes\"" \
  "r4_failed_false|  failed_when: false" \
  "r4_failed_expr|  failed_when: dsc_out.rc == 99" \
  "r4_when_sq_false|  when: 'false'"; do
  lbl="${pair%%|*}"; line="${pair#*|}"
  copy_set; printf '%s\n' "$line" >>"$tmp/s/roles/04_desk_start_checks/tasks/main.yml"
  out="$(run_chk "$tmp/s" 2>&1)"; r=$?
  echo "rc02 $lbl: rc=$r (want 1)"
  [ "$r" != 0 ] || rc=1
done

# 8. RED case in role 03 (enrol): ignore_errors: true
copy_set; printf '  ignore_errors: true\n' >>"$tmp/s/roles/03_workspace/tasks/main.yml"
out="$(run_chk "$tmp/s" 2>&1)"; r=$?
echo "rc02 r3_ignore_true: rc=$r (want 1)"
[ "$r" != 0 ] || rc=1

echo "rc02 exit $rc"
exit "$rc"
```

Output on `fe99a5bc6` (sat, 00:38Z):

| run | output |
|---|---|
| `bash rc02-b48.sh fe99a5bc6` | `rc02 sites: main=1 when_false=1` / `rc02 ctrl_shipped: rc=0 (want 0)` / `rc02 ctrl_comments: rc=0 (want 0)` / `rc02 r4_ignore_true: rc=0 (want 1)` / `rc02 r4_ignore_quoted: rc=0 (want 1)` / `rc02 r4_failed_false: rc=0 (want 1)` / `rc02 r4_failed_expr: rc=0 (want 1)` / `rc02 r4_when_sq_false: rc=0 (want 1)` / `rc02 r3_ignore_true: rc=0 (want 1)` / `rc02 exit 1` |
| `bash rc02-b48.sh fe99a5bc6 fix-shape` | `rc02 sites: main=1 when_false=1` / `rc02 fix-shape: when-false handles quotes/case + spl_cbr_no_swallow refuses ignore_errors/failed_when` / `rc02 ctrl_shipped: rc=0 (want 0)` / `rc02 ctrl_comments: rc=0 (want 0)` / `rc02 r4_ignore_true: rc=1 (want 1)` / `rc02 r4_ignore_quoted: rc=1 (want 1)` / `rc02 r4_failed_false: rc=1 (want 1)` / `rc02 r4_failed_expr: rc=1 (want 1)` / `rc02 r4_when_sq_false: rc=1 (want 1)` / `rc02 r3_ignore_true: rc=1 (want 1)` / `rc02 exit 0` |

### 4.3 `rc03-b48.sh` (b48-03), sha256 first 12 hex `80c654bd3ffc`, 3489 B

Run from any checkout: `bash rc03-b48.sh fe99a5bc6` (exit 1), then `bash rc03-b48.sh fe99a5bc6 fix-shape` (exit 0). Under 1 s each.

```bash
#!/usr/bin/env bash
# rc03-b48.sh <sha> [fix-shape]: b48-03 red control. On <sha>'s tree,
# tf_plan_resource_changes (tf-plan-pending.func.sh:35-40) inspects only
# .change.actions != ["no-op"] and != ["read"], so a Terraform plan holding a
# moved {} block (.previous_address set) or an import {} block
# (.change.importing set) whose actions are ["no-op"] returns 0 and makes
# do_tf_plan_pending report "clean (outputs only)" (a-704 N1 on SPL-6528).
# fix-shape also counts entries with .previous_address != null or
# .change.importing != null.
set -uo pipefail
sha="${1:?usage: rc03-b48.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-iac | tar -x -C "$tmp"
fn="$tmp/csi-spl-iac/src/bash/run/tf-plan-pending.func.sh"
a=$(grep -c '^tf_plan_resource_changes()' "$fn")
echo "rc03 site: tf_plan_resource_changes=$a"
[ "$a" = 1 ] || { echo "rc03 site moved"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$fn" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = '''    [.resource_changes[]? | .change.actions
      | select(. != ["no-op"] and . != ["read"])] | length end' 2>/dev/null'''
new = '''    [.resource_changes[]?
      | select((.change.actions != ["no-op"] and .change.actions != ["read"])
               or .previous_address != null
               or .change.importing != null)] | length end' 2>/dev/null'''
assert s.count(old) == 1, "jq filter target not unique"
open(p, "w").write(s.replace(old, new, 1))
PY
  echo "rc03 fix-shape: count .previous_address != null and .change.importing != null"
fi

mkdir -p "$tmp/bin"
cat >"$tmp/bin/terraform" <<'STUB'
#!/bin/sh
cat "$STUB_SHOW"
STUB
chmod +x "$tmp/bin/terraform"

cat >"$tmp/moved.json" <<'JSON'
{"format_version":"1.2","resource_changes":[{"address":"google_storage_bucket.new","previous_address":"google_storage_bucket.old","change":{"actions":["no-op"]}}],"output_changes":{"o":{"actions":["update"]}}}
JSON
cat >"$tmp/import.json" <<'JSON'
{"format_version":"1.2","resource_changes":[{"address":"google_storage_bucket.imp","change":{"actions":["no-op"],"importing":{"id":"my-bucket"}}}],"output_changes":{"o":{"actions":["update"]}}}
JSON
cat >"$tmp/noop.json" <<'JSON'
{"format_version":"1.2","resource_changes":[{"address":"x.y","previous_address":null,"change":{"actions":["no-op"],"importing":null}},{"address":"data.x.z","change":{"actions":["read"]}}],"output_changes":{"o":{"actions":["update"]}}}
JSON
cat >"$tmp/update.json" <<'JSON'
{"format_version":"1.2","resource_changes":[{"address":"x.y","change":{"actions":["update"]}}]}
JSON

run_cnt() {
  env PATH="$tmp/bin:/usr/bin:/bin" STUB_SHOW="$1" PROJ_PATH="$tmp/csi-spl-iac" bash -c '
    set -uo pipefail
    env_order_cache_put() { :; }
    do_tf_log_mask() { cat; }
    source "$PROJ_PATH/src/bash/run/tf-plan-pending.func.sh"
    tf_plan_resource_changes "$1" plan.tfplan' _ "$tmp"
}

c_moved="$(run_cnt "$tmp/moved.json")"
c_import="$(run_cnt "$tmp/import.json")"
c_noop="$(run_cnt "$tmp/noop.json")"
c_update="$(run_cnt "$tmp/update.json")"
echo "rc03 moved=$c_moved (want 1); import=$c_import (want 1); ctrl_noop_read_nulls=$c_noop (want 0); ctrl_update=$c_update (want 1)"
rc=0
[ "$c_moved" = 1 ] || rc=1
[ "$c_import" = 1 ] || rc=1
[ "$c_noop" = 0 ] || rc=1
[ "$c_update" = 1 ] || rc=1
echo "rc03 exit $rc"
exit "$rc"
```

Output on `fe99a5bc6` (sat, 00:38Z):

| run | output |
|---|---|
| `bash rc03-b48.sh fe99a5bc6` | `rc03 site: tf_plan_resource_changes=1` / `rc03 moved=0 (want 1); import=0 (want 1); ctrl_noop_read_nulls=0 (want 0); ctrl_update=1 (want 1)` / `rc03 exit 1` |
| `bash rc03-b48.sh fe99a5bc6 fix-shape` | `rc03 site: tf_plan_resource_changes=1` / `rc03 fix-shape: count .previous_address != null and .change.importing != null` / `rc03 moved=1 (want 1); import=1 (want 1); ctrl_noop_read_nulls=0 (want 0); ctrl_update=1 (want 1)` / `rc03 exit 0` |

---

## 5. Rows

| # | id | practice | sites (file:line on `fe99a5bc6`) | evidence | red control (fails on `fe99a5bc6`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b48-01-orc-review-go-dedup-author-sha` | one `GO` per `(author, sha)` even when a `PASS` is delivered under two `msg_id`s | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:148,175-177,792-794`; `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (new case 33 after `:1286`) | live double GO in `/var/spool-hub/dispatch/automation.log:3867-3868` (SPL-6543 `48cb5ad26` to `a-806`, c-002 `37cf115f`, c-001 `08587a39`); section 4.1 | `bash rc01-b48.sh fe99a5bc6` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` | `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (cases 1 to 33); `bash csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh`; `bash rc01-b48.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x` on both files; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.1: add `_spl_review_go_seen_pass` + `_spl_review_go_dedup`, call right after `author` resolution at `:793`, return `11` (mapped to `0` for `REVIEW_GO_MSG` at `:148`, skipped by `n` count at `:155`), log `action=dedup` on live runs (`dry == 0`) and no-op on dry runs (`dry == 1`); header comment states same-box `automation.log` (panel N1); keep all functions <= 75 lines; add case 33; `Docs: none` | `<box2>` or sat (`do_spl_box_pick` 00:29Z: `<box2>` 124% pick, sat 179%) | claude | agy (`BOX_PICK_KIND=agy` 00:29Z: both boxes `agy weekly unknown`, placed anyway; pick `<box2>` 124%), else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |
| 02 | `b48-02-iac-customer-box-role04-swallow-refusal` | customer-box role gate refuses error-swallowing directives and quoted/case falsy `when:` | `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh:36-48,114-122`; `csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` (new controls after `:121`) | round 47 first input #1 (`c002-next-round-candidates.md:95`, SPL-6122 R7 c-502 N3); 0 `ignore_errors`/`failed_when` hits in `src/ansible/customer-box/`; section 4.2 | `bash rc02-b48.sh fe99a5bc6` -> `rc02 exit 1`; control `fix-shape` -> `rc02 exit 0` | `bash csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh`; `bash rc02-b48.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x` on both files; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `bash csi-spl-iac/src/bash/tests/action-header-tags.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.2: widen `spl_cbr_when_false` for quotes/case/comments; add `spl_cbr_no_swallow` refusing truthy `ignore_errors` / falsy `failed_when` across the role set and any non-comment `ignore_errors:`/`failed_when:` in `roles/04_desk_start_checks/` (keeping `changed_when: false` at `:19` and comment lines green); update header `@description` naming `rescue:`, `ignore_unreachable`, and templated falsy values as ban-list limits (panel N3); add controls; `Docs: none` | `<box2>` or sat (`do_spl_box_pick` 00:29Z: `<box2>` pick) | claude | agy if quota, else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |
| 03 | `b48-03-iac-tf-plan-pending-moved-import` | env-order gate treats `moved` and `import` plan entries as pending, not outputs-only | `csi-spl-iac/src/bash/run/tf-plan-pending.func.sh:31-40` (`tf_plan_resource_changes`); `csi-spl-iac/src/bash/tests/env-order-gate.tst.sh:151-173` (section 6b) | a-704@sat R7 N1 (`49a020e0`, SPL-6528 `36a3228f7`), round 47 section 7; sole `tf_plan_resource_changes` definition in repo; section 4.3 | `bash rc03-b48.sh fe99a5bc6` -> `rc03 exit 1`; control `fix-shape` -> `rc03 exit 0` | `bash csi-spl-iac/src/bash/tests/env-order-gate.tst.sh`; `bash csi-spl-iac/src/bash/tests/tenant-host-workflow-40.tst.sh`; `bash csi-spl-iac/src/bash/tests/tf-log-mask-billing-id.tst.sh`; `bash csi-spl-orc/src/bash/tests/tf-runner-make-path.tst.sh`; `bash rc03-b48.sh <fix sha>` -> exit 0 (without `fix-shape`); `shellcheck -S warning -x` on both files; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`; `cd csi-spl-iac && ./run -a do_check_pre_push` | section 3.3: update `tf_plan_resource_changes` jq `select(...)` to also count `.previous_address != null` and `.change.importing != null`; update comment at `:31-32`; extend section 6b in `env-order-gate.tst.sh` with `moved` (pending, uncached), `import` (pending, uncached), and explicit-null `["no-op"]` control (clean); cite/prove tf 1.9.8 `-detailed-exitcode` 2 + applied `moved`/`import` behaviour in body (panel N4); `Docs: none` | `<box2>` or sat (`do_spl_box_pick` 00:29Z: `<box2>` pick) | claude | agy if quota, else claude waiver seat (`1a7c70da`) | `simple_coding` | 1 |

- **R1 (disjoint files):** all 3 rows are Batch 1 and share 0 files:
  - b48-01: `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`
  - b48-02: `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh`, `csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh`
  - b48-03: `csi-spl-iac/src/bash/run/tf-plan-pending.func.sh`, `csi-spl-iac/src/bash/tests/env-order-gate.tst.sh`
- **R3** (checked 2026-11-26T00:36:59Z and re-checked at v1.0 2026-11-26T01:03:39Z, panel N2): `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh,csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh,csi-spl-iac/src/bash/run/tf-plan-pending.func.sh,csi-spl-iac/src/bash/tests/env-order-gate.tst.sh,csi-spl-doc/doc/md/bug-round-48-plan.md --agent a-846` -> **exit 4**: 0 live lanes list these 7 paths, but 17 live lanes on `<box2>` record no files at 01:03:39Z (`unknown:` c-029, c-041, c-086, c-146, c-187, c-398, c-407, c-416, c-474, c-535, c-728, c-741, c-776, c-927, c-936, c-957, c-965; panel also saw `a-852@sat` refactor round 04 planner with no files recorded during review): **not free until the holder re-runs `--check` at placement**. By `do_spl_lane_map` scopes (00:29Z), live lanes on sat (`a-808` r03 planner, `c-625` Taxes R7, `a-826` SPL-6517 R7, `a-841` r03-02 R7, `c-298` Taxes tab, `a-835` SPL-6542 R7, `c-722` SPL-6517) and `<box2>` (`c-741` SPL-6542 WUI, `c-784` r03-02, `c-726` r03 panel, `c-776` b48 panel, `c-957`/`c-965` spec 125, private workspace seats) touch none of these 6 row files. The queue, `./run -a do_spl_spawn_queue` (00:28:43Z): 1 queued ask (`5b1b7d82`, `c001-s186-m9-n2-qto-sync`, feature), disjoint by slug.
- **R7:** claude-authored code rows: agy R7 seat if `BOX_PICK_KIND=agy ./run -a do_spl_box_pick` shows agy quota (00:29Z: both boxes `agy weekly unknown`, placed anyway; pick `<box2>` 124%), else claude waiver seat (`1a7c70da`). No grok (c-001 `dc84300a`). No mistral (no review seat since 2026-11-25, and no coding kind).
- **Rhythm (1.4):** rows queue once the panel signs and `do_spl_review_line_check` exits 0; phase is night (since 19:00Z).
- **Pushes:** aim 1 per row (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug`.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| `a-826` N2 on SPL-6517 (`spool-live-ack.sh` log size cap) and `spool-agent-hook.sh` (`a-767` N2, `a-823` N2) | `c-722@sat` + `a-826@sat` | live lane SPL-6517 (R3); stay off. |
| `c-625` N1-N3 (Taxes tab `/v1/view/tax/overview`) | `c-298@sat` + `c-625@sat` | live lane SPL-6438 (R3); stay off. |
| `a-841` N1 (`setup-gh-runner-cpu-budget-cron.tst.sh:83-91`) | `c-784@<box2>` + `a-841@sat` | live lane r03-02 SPL-6546 (R3); stay off. |
| WUI notes Delete key (SPL-6542), spec 125 (SPL-6409), refactor round 03 (SPL-6540), private workspace seats | live / queued lanes per `do_spl_lane_map` and `do_spl_spawn_queue` | owned; stay off. |
| Release-transfer repo open bug issues (SPL-6361, 6362, 6366) | live lanes on `<box2>` | different repository, not `csi-spl`. |
| The `unknown_token` box (406 prd WARNINGs since W) | the holder, as a box question | carried. |
| `review-go` inline-backtick `DRY_RUN=0` false holds (`c002-next-round-candidates.md:141-142`) | design / round 49 planner | naive backtick-skip conflicts with `spl-review-go.tst.sh:111-113` case 24; needs narrower design. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 3 (all Batch 1, R1 disjoint) |
| inputs re-measured | 10 sources; 11 prd ERROR entries since W (6 h read); 443 prd WARNING entries since W (401s left out, cap not reached) + 16 h `hours/minutes` read (0 400s, 0 warns, 2 401s); 9 alert policies (0 incidents); 6 open t1 bug issues + SPL-6544 (0 `csi-spl` wip/todo/eval outside this round); 100 wf 10 runs (6 failures, **0 since W**); **0 failed runs** since W across all other master workflows; 35 commits and 7 `review:` lines since W + `c-001`/`c-002`/`c-003` archives + `automation.log:3860-3875`; 0 HUM posts since W; round 47's first inputs; holder's candidate list (142 lines on sat); `rc01-b48.sh`, `rc02-b48.sh`, `rc03-b48.sh` n=1 each way on `fe99a5bc6`; baseline `customer-box-role-set.tst.sh` (0 failures), `env-order-gate.tst.sh` (PASS all), and `spl-review-go.tst.sh` (0 failures) |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b48-'` -> 0; `git ls-remote origin 'refs/heads/review/b48-*' 'refs/heads/wip/*b48*' 'refs/heads/*-b48-*' 'refs/heads/*bug-round-48*'` -> nothing (rc 0); briefs on sat matching `b48\|bug-round-48`: only `hand-sat-c002-bug-round-48-planner.md`, `c002-bug-round-48-claude-panel-seat.md` (plus unrelated `c-002-7b48293b-...` uuid match) (00:27Z) |
| R7 seat | agy if quota (`BOX_PICK_KIND=agy` 00:29Z: both boxes `agy weekly unknown`, placed anyway), else claude waiver seat (`1a7c70da`) |
| first inputs for round 49 | `review-go` owner-go false holds on plan-table / backticked code quotes (`c002-next-round-candidates.md:141-142`, designing around case 24 `a backticked prd step -> rc 4`); `a-801` N1 (`spl-spawn-place.func.sh:1448,1464` `IFS=$'\t' read` empty-field collapse on colon-less `.placement`); `a-767` N2 (`spool-agent-hook.sh:683,771` stale `stop_denies` on tool-before-Stop) and `a-823` N2 (`PreInvocation` in `EVENTS`, once SPL-6517 lands); `a-826` N2 (`spool-live-ack.sh` log size cap, only if SPL-6517 lands without it); `a-841` N1 (`setup-gh-runner-cpu-budget-cron.tst.sh:83-91` section 4 red control); `a-748` N3-N4 (`y9-vendor-lane-rule.sh:64-77` `_y9_qwen` backup race / stderr); `a-769` N2 (`tenant-host-reserve.tst.sh` symlink control); `a-790` N1 (`mcp_test.go:560-563` control ambient env); hours-minutes whole-batch 400 follow-up (once a live `hours: minutes refused` warn fires); `c-708` N1 (`BoxTaskEnvelopes` box-scoped probe); `a-683` N3 (non-`AgentsCommand` / embed / `channel_box_pins` posts in `hum\|`); `c-625` N1-N3 (Taxes tab, once SPL-6438 lands); `a-490` N1 (`TestCategoryTestPathsZZIsolated` regex); `a-480` N1 (`syncWriter.Reset`); `TestHiddenUnreadBufferBudget` / `TestMarkedUnreadBufferBudget`; `unknown_token` box; hub dir mode; hermetic 2/4 timeout; composed testids; `i18n-lang-review-exempt.json:2`; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797` as carried |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** a-846@sat (agy, `specs_and_docs`).
- **Panel:** c-776@`<box2>` (claude, cross-vendor; placed on `dispatch-bug-r48` at 23:40:43Z 2026-11-25).
- **Row reviewer (R7):** section 5.
- **Review history:**
  - 2026-11-26 00:46Z: v0.1 `b3f91e7f7`, pushed to `review/c002-bug-round-48-planner` (3 rows: b48-01, b48-02, b48-03; rebased on `ffba81845` with 0 drift). Sent to `c-776@<box2>` (`4446fa93`) and holder `c-003@sat` (`e14109be`) on task `dispatch-bug-r48`.
  - 2026-11-26 01:02Z: panel `c-776@<box2>` (claude) **PASS** on v0.1 `b3f91e7f7` (msg `d49ead8c` to this seat; seat file `csi-spl-doc/doc/md/bug-round-48/seat-claude.md` on `review/c002-bug-round-48-claude-seat` `e288e8714`). Verified slug proof, 0 drift `fe99a5bc6..origin/master` across all 6 row files, every site on `fe99a5bc6`, all three rc hashes/sizes (`d93053b1a1f5`/8514, `ee327a2fa8e7`/4452, `80c654bd3ffc`/3489), each rc exit 1 on base and exit 0 with `fix-shape` (live `automation.log` and inboxes unchanged), all three baseline suites green (`customer-box-role-set` 0 fail, `env-order-gate` PASS, `spl-review-go` 0 fail in 324 s), R3 `lane-map.sh --check` (exit 4), and `do_check_dist_hygiene`. Findings: W1 (1-line doc cite: line 119 `a-490` N1 -> `TestCategoryTestPathsZZIsolated` at `categories_test.go:388`); N1 (b48-01 header comment states same-box `automation.log`); N2 (R3 refreshed + note `a-852@sat` at placement); N3 (b48-02 wider role-set scope + `rescue:`/`ignore_unreachable`/templated falsy ban-list limits in header); N4 (b48-03 implementer cites/proves tf 1.9.8 `-detailed-exitcode` 2 + applied `moved`/`import` behaviour in tf-runner); N5 (line 113 names b47 first input #8).
  - 2026-11-26 01:04Z: holder `c-002@sat` (msg `c924331c`): keep all 3 rows (bug share UNDER); fold W1 + N1 to N5 into v1.0 (rc scripts byte-identical); full `do_spl_review_line_check` requested on `<box2>` (`d7203c3c`).
  - Review line checked (v0.1): `do_spl_review_line_check` rc 0 on `<box2>` (`c-001@<box2>` `163f799a`: `OK 3 of 3`, no MISSING; holder `c-002@sat` GO v1.0 `c97d8f96`).
  - 2026-11-26 01:05Z: v1.0 folds W1 and N1 to N5 (all 3 rc scripts byte-identical: `d93053b1a1f5`/8514 B, `ee327a2fa8e7`/4452 B, `80c654bd3ffc`/3489 B; 0 drift on all 6 row files `fe99a5bc6..5aa360afc`), fast-forward on `b3f91e7f7` on `review/c002-bug-round-48-planner` for final panel signature by `c-776@<box2>`.
