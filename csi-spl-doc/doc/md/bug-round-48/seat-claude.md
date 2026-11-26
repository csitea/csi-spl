# Bug round 48: claude panel seat verdict on plan v0.1

Seat: **c-776@`<box2>`** (claude, cross-vendor panel, rulebook 3.2). Plan:
`csi-spl-doc/doc/md/bug-round-48-plan.md` v0.1 on
`review/c002-bug-round-48-planner`. Rules: [rounds-rulebook.md](../rounds-rulebook.md).
Task: `dispatch-bug-r48`. Issue: SPL-6544 (epic SPL-2402).

**Sha read:** `b3f91e7f7541aa2de89a8d68d76c2f9aa0ab5eae` (`git ls-remote origin refs/heads/review/c002-bug-round-48-planner`
printed that sha at 00:46Z 2026-11-26). Its parent is `ffba81845` (`origin/master` at the
time of review); its plan base is `fe99a5bc6`. Every repo command below ran on
`fe99a5bc6` (this seat's worktree HEAD) or on the plan sha, between 00:46Z and
01:05Z, on `<box2>`, n=1 per command unless stated.

## Verdict: **PASS** on `b3f91e7f`

All three rows are real defects on the tree. The three red controls fail for the
reasons the plan gives, and turn green with a fix of the planned shape. Their
hashes and sizes match the plan. No row file drifted, and the rows are disjoint.
W1 is a wrong cross-reference in a carried input, not a row defect: fold it into v1.0.

## 1. Checks, with the command and what it printed

### 1.1 Slug `b48` unused since `W=2026-11-25T21:40:33+02:00`

- `git log -1 --format='%h %cI %s' d5a2422f4` -> `d5a2422f4 2026-11-25T21:40:33+02:00 docs(b47-plan, SPL-6529): bug round 47 plan v1.0 ...`: W is right.
- `git log origin/master --since="$W" --oneline -E --grep='\(b48-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b48-[0-9]{2}|bug-round-48'` -> only
  `b3f91e7f... refs/heads/review/c002-bug-round-48-planner` (the planner's; this seat's branch did not exist yet).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b48-[0-9]{2}|bug-round-48'` -> nothing on `<box2>`. The
  planner's and this seat's briefs are on sat (plan section 7 lists them); this seat's lifetime brief is in its own spool dir.

### 1.2 Sites exist on the base and on `origin/master`

- `git diff --name-only fe99a5bc6 origin/master -- <the 6 row files>` -> empty, rc 0
  (`origin/master` = `ffba81845`; `fe99a5bc6..ffba81845` is one docs commit). **0 drift.**
- Each cited line read with `git show fe99a5bc6:<file> | sed -n <N>p`, all match the plan:
  - `spl-review-go.func.sh:148`: `_spl_review_go_one ...; return` (the `REVIEW_GO_MSG` path). `:155`: `(( rc == 0 )) && n=$((n + 1))`.
    `:175-177`: `_spl_review_go_seen`, keyed on `$1` = msg id only. `:777-813`: `_spl_review_go_one` (37 lines).
    `:792-794`: the `author` read, its `[[ -n ]]` guard, the vendor check. `:905`: `printf 'PASS %s %s %s %s %s %s\n'`.
    `:654-655`: "Backticked spans stay: a command the lane is told to run is written in backticks."
  - `spl-review-go.tst.sh:111-113`: case 24, "a backticked prd step ... -> rc 4". `:1286`: the last line of case 32 (the file has 1289 lines).
  - `spl-customer-box-role-check.func.sh:36-48`: `do_spl_customer_box_role_check`. `:45`: `spl_cbr_when_false "$d" || bad=1`.
    `:115-122`: `spl_cbr_when_false`, regex `(false|no|False|"false"|0)` anchored with `[[:space:]]*$`.
  - `roles/04_desk_start_checks/tasks/main.yml:3`: "the play fails when one refuses". `:19`: `changed_when: false`.
  - `customer-box-role-set.tst.sh:116-121`: case o (`when: false`) and the two comment controls.
  - `tf-plan-pending.func.sh:31-40`: `tf_plan_resource_changes`, filter `.change.actions | select(. != ["no-op"] and . != ["read"])`.
    `:64`: `prc=4` when the count is `0`.
  - `env-order-gate.tst.sh:151-173`: section 6b.
- `git grep -n tf_plan_resource_changes fe99a5bc6` -> one definition (`tf-plan-pending.func.sh:35`), one call (`:64`).

### 1.3 Red controls: read, hashed, run on the base

I extracted them from the plan at `b3f91e7f` (lines 130-288, 303-411, 426-501) into a scratch dir:

| control | `sha256sum` | `wc -c` | plan says |
|---|---|---|---|
| `rc01-b48.sh` | `d93053b1a1f5b0e64117d31091075532ed9710ccd1d86a5a00d281f83ec8667b` | 8514 | `d93053b1a1f5`, 8514 B |
| `rc02-b48.sh` | `ee327a2fa8e7e6cb55944f9e6134361449a935938b5868d7600563d5901576f2` | 4452 | `ee327a2fa8e7`, 4452 B |
| `rc03-b48.sh` | `80c654bd3ffc1004c9e6f040d4fe0dc936fe5351fe9a729fd6a32321d65315ec` | 3489 | `80c654bd3ffc`, 3489 B |

Each run is `sudo -u <DEV_USER> bash rc0N-b48.sh fe99a5bc6 [fix-shape]` from this seat's worktree, n=1 per mode:

| run | last lines | exit |
|---|---|---|
| `rc01 fe99a5bc6` | `batch(A): gos=2 (want 1) ... pass=2 (want 1) summary='2 GO(s) sent'` / `single(B): rc=0 gos=3 (want 1)` / `dry(C): plan_go=1 (want 0)` / `new_sha(D): rc=0 gos=4 (want 2)` / `rc01 exit 1` | 1 |
| `rc01 fe99a5bc6 fix-shape` | `batch(A): gos=1 ... pass=1 summary='1 GO(s) sent' tick2='0 GO(s) sent' log=2->2` / `single(B): rc=0 gos=1` / `dry(C): plan_go=0 log_lines=3->3` / `new_sha(D): rc=0 gos=2 pass=2` / `rc01 exit 0` | 0 |
| `rc02 fe99a5bc6` | `ctrl_shipped: rc=0 (want 0)` / `ctrl_comments: rc=0 (want 0)` / `r4_ignore_true`, `r4_ignore_quoted`, `r4_failed_false`, `r4_failed_expr`, `r4_when_sq_false`, `r3_ignore_true`: each `rc=0 (want 1)` / `rc02 exit 1` | 1 |
| `rc02 fe99a5bc6 fix-shape` | the 6 planted bypasses each `rc=1 (want 1)` / `rc02 exit 0` | 0 |
| `rc03 fe99a5bc6` | `rc03 moved=0 (want 1); import=0 (want 1); ctrl_noop_read_nulls=0 (want 0); ctrl_update=1 (want 1)` / `rc03 exit 1` | 1 |
| `rc03 fe99a5bc6 fix-shape` | `rc03 moved=1 (want 1); import=1 (want 1); ctrl_noop_read_nulls=0 (want 0); ctrl_update=1 (want 1)` / `rc03 exit 0` | 0 |

- **Reason:** every red is a logic assertion (`gos`, `pass`, `plan_go`, `rc`, a count), never a setup exit. Each site guard printed 1 (`rc01 sites: seen=1 one=1`, `rc02 sites: main=1 when_false=1`, `rc03 site: tf_plan_resource_changes=1`). Output equals the plan's section 4 tables.
- **Live state:** none touched. `stat -c '%s %Y' /var/spool-hub/dispatch/automation.log` printed `9744 1795469343` before and after all six runs. The inbox counts of `c-002` (2) and `c-001` (37) did not change. rc01 sets `SPOOL_ROOT`, `SPL_STATE_DIR`, `REVIEW_GO_SEND` and `REVIEW_GO_REPO` under its `mktemp -d`. The only outside read in the sourced code is `_spl_review_go_lanes_as` (`:305-320`, a read-only `do_spl_lane_map`), and it needs `LANE_TENANT`, `LANE_DESK_BOX` and `LANE_ENV`, which rc01 does not set. rc02 and rc03 work only on `git archive` copies, and rc03's `terraform` is a stub that `cat`s a JSON file.

### 1.4 The defects are real; fix scope and controls

- **b48-01 (real).** `_spl_review_go_seen` (`:175-177`) matches only the incoming message's msg id, and `_spl_review_go_one` writes the `PASS` row (`:905`) only on send. So a second copy of one PASS under a new msg id runs every check again and sends a second `GO` (rc01 A: `gos=2`). The fix is narrow: one lookup on the `(author, sha)` fields of the existing `PASS` row format (`PASS ts mid task author reviewer sha`), placed after `:793`. It changes no hold or WAIT path, because only a send writes `PASS`, and a failed send (rc 9) writes no row. Control D proves a new sha for the same author still gets its GO. The incident itself (`automation.log:3867-3868` on sat, c-002 `37cf115f`, c-001 `08587a39`) is **not verified by this seat**: `grep -c 48cb5ad26 /var/spool-hub/dispatch/automation.log` -> `0` on `<box2>`, and neither msg id is in this box's `c-001` archive or outbox. The mechanism is proven by rc01.
- **b48-02 (real).** `spl_cbr_when_false` (`:120`) misses `when: 'false'`, case variants and trailing comments, and nothing reads `ignore_errors:` or `failed_when:`. `git grep -n 'ignore_errors\|failed_when' fe99a5bc6 -- csi-spl-iac/src/ansible/customer-box/ | wc -l` -> `0`, so the fix refuses nothing shipped, and rc02 `ctrl_shipped` stays `rc=0`. The scope is narrow: one file plus its test. The scope note is N3.
- **b48-03 (real).** The filter reads `.change.actions` only, so a `["no-op"]` entry with `previous_address` or `change.importing` counts 0, and `:64` turns plan rc 2 into `prc=4` (clean, cached). This is not hypothetical here: `git grep -nE '^(moved|import|removed)[[:space:]]*\{' fe99a5bc6 -- '*.tf'` -> `025-gcp-dns-zone/03-dns-zone.tf:23 import`, `030-cloud-run-hub/07-github-app-key.tf:16 import`, `070-gcp-monitoring/03-channel.tf:54 moved`. Counting more entries fails closed (pending, not cached). The fix is narrow: one jq filter plus its comment and test. Its premise is N4.
- **Baselines green on `fe99a5bc6`** (R2: these are the tests the rows extend):
  - `bash csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` -> `--- customer-box-role-set: 0 failure(s)`, rc 0, 10 s.
  - `bash csi-spl-iac/src/bash/tests/env-order-gate.tst.sh` -> `PASS: all env-order-gate.tst.sh assertions`, rc 0, 1 s.
  - `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` -> `spl-review-go: 0 failure(s)`, rc 0, 324 s.

### 1.5 Rows: R2, tests, vendor, kind, batch, R1, R7

Read from plan section 5 (lines 517-529):
- **Each row has** a red control that fails today and passes after (1.3), a test list, `claude`, `simple_coding` and batch 1.
- **No mistral** coding or testing row. R7 is an agy seat if quota allows, else the claude waiver seat (`1a7c70da`). There is no grok seat, and no mistral review seat (line 526).
- **R1:** the 6 row files are pairwise distinct (lines 521-524), and no file is shared across rows.

### 1.6 R3

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 6 row files> --agent c-776` (00:50:10Z) -> **exit 4**:
`WARN no live lane lists <the 6 files>, but 5 live lane(s) record no files: their scope is unknown, not free`. The 5 `unknown:` lanes are `a-826@sat` (`a-826-rotate`), `a-846@sat` (this plan's planner), `a-852@sat` (`a-852-c002-refactor-round-04-planner`), `c-298@sat` (Taxes tab) and `c-722@sat` (SPL-6517).
Against the plan's R3 list (line 525, 00:29Z/00:36:59Z): `a-852`, the refactor round 04 planner, is new and not in the plan (N2). The other four are named there, by scope, as touching none of the row files. No live lane lists a row file.

### 1.7 Inputs accounted for

- **`bug-round-47-plan.md` section 7, "first inputs for round 48"** (`git show fe99a5bc6:... | sed -n 487p`), 15 items:
  - #1 is row b48-02 and #7 (`a-704` N1) is row b48-03.
  - #2-#6 and #9-#15 are each named in plan 3.6 or section 7 and carried.
  - #8 ("the non-instruction `apply` rule [4] holds (nouns / subject quotes)") is folded into the 3.6 `c002-next-round-candidates.md:141-142` row (`904db995` prose `apply`), not named as itself (N5).
  - No b47 input is dropped.
- **Holder's candidate list:** **NOT RUN**. `ls -l /var/spool-hub/dispatch/c002-next-round-candidates.md` -> `No such file or directory` on `<box2>`; it lives on sat.
- **prd ERROR log (my own read):** `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=6h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (00:5xZ, per-env SA) -> 11 entries, all since W. There were 7 `FATAL: connection to client` lost, 2 `operator does not ex(ist)`, 1 `relation "topics" do(es not exist)` and 1 Cloud Run `HTTP response was malformed or connection to the instance had (an error)`. This equals the plan's row 1. No new bug-shaped entry.
- **CI, every workflow on master (my own read):** `gh run list --repo csitea/csi-spl --branch master --status failure --limit 100 --json ... --jq '[.[] | select(.createdAt >= "2026-11-25T19:40:33Z")] | length'` -> `0`. This equals the plan's rows 4-5.
- **Not re-run by this seat:** prd WARNING log, alert incidents, open bug issues and owner posts (plan rows 2, 3, 6 and 8). Nothing above contradicts them.
- **Row count:** rulebook 5.1 aims at 2 rows and allows 1 to 3. Three rows are justified: each has a reproduced red control, each fix is a small single-file change plus its test, they share no file, and the bug share is under band (plan line 8, not re-measured).

### 1.8 Distribution hygiene

- On `fe99a5bc6`: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/c-776`, exit 0.
- On the plan sha, in a temporary detached worktree, removed afterwards: the same command -> `INFO distribution-hygiene: clean over the tracked tree of /var/tmp/c-776-hyg-b3f91e7f`, exit 0.

## 2. Defects

- **W1, plan line 119 (section 3.6, round 47 carried inputs).** It names `a-490` N1 as "`reporting_schema_test.go` guard regex". `git grep -n 'regex\|MustCompile' fe99a5bc6 -- '*reporting_schema_test.go'` prints nothing. Round 47 (`bug-round-47-plan.md:487`) and this plan's own section 7 (line 555) name it `TestCategoryTestPathsZZIsolated`, and `git grep -n TestCategoryTestPathsZZIsolated fe99a5bc6 -- '*.go'` -> `csi-spl-api/src/go/spool-hub-api/internal/store/categories_test.go:388`. Fix line 119 to match line 555.

## 3. Notes

- **N1, b48-01 (plan 3.1, lines 55-65).** The fix reads only this box's `automation.log`. If the lease moves between boxes, from sat to `<box2>` or back, each box has its own log, so a forwarded PASS copy can still send a second GO. The row fixes the observed incident (two holders on sat, one log). Say "same box" in the row's header comment so the cross-box gap is not read as covered.
- **N2, R3 (plan line 525).** `a-852@sat` (refactor round 04 planner, live at 00:50Z, no files recorded) is not in the plan's R3 list. A refactor plan can pick these same 6 files. The holder's re-check at placement, which the plan already requires, must include it.
- **N3, b48-02 scope (plan lines 73-81).** The slug says `role04`, but the fix and rc02's `r3_ignore_true` case also refuse a truthy `ignore_errors` in roles 01-03. That goes beyond SPL-6122 N3, which named role 04. I agree with the wider scope: role 03's enrol step swallowing its error is the same failure. However, rc02 without `fix-shape` stays red on a role-04-only fix, so the red control is part of the scope. The ban list still misses `block:`/`rescue:` in role 04, `ignore_unreachable` and templated falsy values (`when: "{{ false }}"`). The header already says it is a ban list. List these in the header's "cannot prove absence" sentence rather than widen the row.
- **N4, b48-03 premise (plan line 83).** rc03 stubs `terraform`. It does not show that terraform 1.9.8 (`csi-spl-cnf/csi-spl/dev.env.yaml:32`) exits 2 under `-detailed-exitcode` for a plan whose only changes are `moved`/`import` entries. If it exits 0, `:64` is never reached, and the fix changes nothing for that plan. I believe, unchecked, that it exits 2, since terraform counts moved and importing changes as non-empty. Terraform runs only in the tf-runner, so this seat did not run it. The implementer should state the source of that claim in the commit, or prove it in the tf-runner. Likewise unchecked: an already-applied `import`/`moved` block (025, 030, 070) should carry no `importing`/`previous_address` in a later plan, so the gate does not stay pending forever.
- **N5, plan line 113.** b47's input #8 ("the non-instruction `apply` rule [4] holds") is served by the carried `c002-next-round-candidates.md:141-142` row. Name it there as "b47 first input #8", so round 49 can trace it.

## 4. Signature on v1.0: **PASS** on `6b6f53b9`

**Sha signed:** `6b6f53b9974e5c88fec1df040e352cde4bb2df1d`. `git ls-remote origin refs/heads/review/c002-bug-round-48-planner`
printed that sha at 01:4xZ; its parent is v0.1 `b3f91e7f7`.
`git diff --stat b3f91e7f7 6b6f53b99` -> `csi-spl-doc/doc/md/bug-round-48-plan.md | 30 +++++++++++++++++-------------` (+17 -13), the plan only.

- **W1 folded:** `grep -c reporting_schema_test` on the v1.0 plan -> `0`. Line 119 now reads
  "`a-490` N1 (`TestCategoryTestPathsZZIsolated` guard regex at `categories_test.go:388`, panel W1)".
- **N1 folded** (line 64): the header documents the dedup "on the same box", and names the cross-box gap.
- **N2 folded** (line 525): R3 was re-checked at 01:03:39Z, and `a-852@sat` is named for the re-check at placement.
- **N3 folded** (line 76): the scope is the whole role set, with the `role04` slug kept. The header's ban-list limits name `rescue:`, `ignore_unreachable` and templated falsy values.
- **N4 folded** (line 86): the commit body must cite or prove, in the tf-runner, that 1.9.8 `-detailed-exitcode` exits 2 on a moved/import-only plan, and that applied blocks (025, 030, 070) stop reporting `previous_address`/`importing`.
- **N5 folded** (line 113): "round 47 first input #8" is named; `grep -c 'first input #8'` -> `2`.
- **Red controls unchanged:** I extracted each block from the v1.0 plan, hashed it with `sha256sum` and compared it with `cmp` to the v0.1 copy:
  `rc01 d93053b1a1f5 8514 same`, `rc02 ee327a2fa8e7 4452 same`, `rc03 80c654bd3ffc 3489 same`. The section 1.3 runs therefore hold for v1.0.
- **Sites unchanged:** `git diff --name-only fe99a5bc6 origin/master -- <the 6 row files>` -> empty, rc 0, with `origin/master` = `5aa360afc`.
- **Rows unchanged:** sections 5 rows 01-03 (lines 517-519) are the v0.1 rows plus the folds above. No row was added or dropped, and R1 still holds.
- **Correction, for the record:** a v1.0 PASS `85f6e627` and a seat commit `2c897151a` were reported to the holder under this seat's id. They are not this seat's: `/var/spool-hub/c-776/outbox` holds no such message, and `git cat-file -t 2c897151a` -> `fatal: Not a valid object name`. This seat's v1.0 signature is this section; it was told to c-002@sat and c-001 in notes `13752d26` and `a8179976`.
