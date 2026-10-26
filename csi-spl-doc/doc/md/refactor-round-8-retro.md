# Refactoring round 8 - retrospective

> Generated from qto doc `a06d87d6-fe3e-4ca4-b630-ba0ff7da6d2f`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Measured 2026-10-14 between 08:00Z and 08:45Z on trunk **`1f5b2fba7`**. Doc only. Each count names the command that produced it; n is that count, n=1 per command unless stated. This is R8 of `refactor-round-8-plan.md`; its section 6 is the input list for round 9. Times are UTC. As in the plan, the boxes are `sat` and `PC` (PC).

Plan: `csi-spl-doc/doc/md/refactor-round-8-plan.md`, signed sha **`7508d04c3`** (10-11 10:02Z), fold commit with the SIGNED line **`4ced7a948`** (committed 10:02:27Z on 10-11), 10 actions.

<a id="ws-doc-9b186d05-6aea-48fb-92db-d2cf4873062f"></a>
## 1. What landed

`git log origin/master --grep='r8-' --format='%h %cI %s'` -> **18** commits: 1 plan draft (`7508d04c3`), 2 seat files (`b30fe1708` agy, `c029651ca` mistral), 1 fold (`4ced7a948`), 10 action commits, plus 2 unauthorized mistral seat rewrites (`12c21511a`, `91b481325`) and 2 editor restores (`f88e3a079`, `b67e45c66`).

| action | commit(s) on `origin/master` | n | held on `1f5b2fba7`? (command -> result) |
|---|---|---|---|
| 01 `ci(r8-01-fail-fast-spares-suites)` | `51ca1d521` (c-156) | 1 | **yes.** `grep -n "orc-suite|hub-suite" csi-spl-orc/src/bash/scripts/gate-fail-fast.sh` -> line 56; `bash csi-spl-iac/src/bash/tests/gate10-fail-fast.tst.sh` -> `PASS: all gate10-fail-fast.tst.sh assertions` (rc 0) |
| 02 `test(r8-02-orc-suite-flush-on-stop)` | `3ec547b0e` (c-157) | 1 | **yes.** `grep -n "stopped: \$finished of \$total files finished" csi-spl-orc/src/bash/tests/run-all-tests.sh` -> 1 line; `bash csi-spl-orc/src/bash/tests/run-all-tests-parallel.tst.sh` -> rc 0, ALL PASS |
| 03 `ci(r8-03-ci-gate-master-only)` | `dee36b59e` (c-158) | 1 | **yes.** `grep -n 'CI_GATE_BRANCH' csi-spl-iac/src/bash/run/report-ci-gate.func.sh` -> lines 32-35, 45, 50; `bash csi-spl-iac/src/bash/tests/report-ci-gate.tst.sh` -> rc 0, `PASS: default: the header says 'on master' over 7 runs and the review-branch run 908 is never counted` |
| 04 `test(r8-04-bash-cleancode-one-liners)` | `72fe341be` (c-159) | 1 | **yes.** `grep -n 'cfg_get' csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` -> 0 lines; `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` -> rc 0, `PASS: the walk measured 4001 functions in 838 files`, `PASS: CONTROL: a one-liner measures 1 and the 100-line function after it measures 100` |
| 05 `refactor(r8-05-bash-small-functions)` | `9cea59e1d` (c-846) | 1 | **yes.** Function length checks: `spool_notify_poke` 56 lines, `_ppl_run_one` 63 lines (both <= 80); 0 LONG lines in `bash-cleancode.tst.sh`; gate counts held |
| 06 `test(r8-06-strip-two-envs-settle)` | `f4d5776b1` (c-160) | 1 | **yes.** Fixed sleeps before capture-pane replaced by bounded polls (every 0.1 s, cap 10 s); `bash csi-spl-orc/src/bash/features/spawn-agents/tests/test-strip-two-envs.sh` -> 21 passed; `test-strip-two-way.sh` -> 32 passed |
| 07 `refactor(r8-07-wui-small-functions)` | `c69ac7ddc` (c-161) | 1 | **yes.** `useMove` 60 lines, `usePaneWidths` 36 lines; cleancode LONG lines removed (13 -> 11 listed); served on dev and prd as v6.3.5 (`do_check_deploy_lag`) |
| 08 `refactor(r8-08-wui-scroll-anchor)` | `33d505c7d` (c-261) | 1 | **yes.** `useScrollAnchor` 31 lines; cleancode LONG line removed (11 -> 10 listed); served on dev and prd as v6.9.1 (`do_check_deploy_lag`) |
| 09 `test(r8-09-go-coverage-hub-wiring)` | `809058cd5` (c-162) | 1 | **yes.** `go test -count=1 -cover ./cmd/spool/` -> 61.1 % (plan 50.9, floor 58.7); `internal/action` 72.8 % (floor 70.3) |
| 10 `ci(r8-10-round-branch-prune)` | `1f83fdd12` (c-163) | 1 | **yes.** `csi-spl-orc/src/bash/run/git-prune-round-branches.func.sh` exists; `bash csi-spl-orc/src/bash/tests/git-prune-round-branches.tst.sh` -> ALL PASS; `ROUND=8 DRY_RUN=1 ./run -a do_git_prune_round_branches` -> 10 branch(es) listed |

10 of 10 actions landed on their first action commit with **0 rework commits** (round 7: 2 rows required follow-up commits). Every single row held on trunk.

<a id="ws-doc-c7e50764-0467-4770-8f35-e15db1447382"></a>
## 2. Lanes

Lane and spawn time from the spawn-replies and lane results in the hub's `messages` table (`do_spl_db_query`) and `registry.retired.tsv`; land = committer time (UTC) of the row's landed commit.

| action | lane(s), first -> landing | kind | box | first spawn | landing spawn | land | first spawn -> land (min) | landing lane (min) |
|---|---|---|---|---|---|---|---|---|
| 01 | c-156 | complex_coding | PC (plan: `sat`) | 10:05:33Z | 10:05:33Z | 10:59:28Z | 54 | 54 |
| 02 | c-157 | tests | PC (plan: `sat`) | 10:05:37Z | 10:05:37Z | 10:12:10Z | 7 | 7 |
| 03 | c-158 | simple_coding | PC | 10:05:45Z | 10:05:45Z | 12:03:58Z | 118 | 118 |
| 04 | c-159 | complex_coding | PC (plan: `sat`) | 10:05:51Z | 10:05:51Z | 11:50:59Z | 105 | 105 |
| 05 | c-846 | simple_coding | sat | 22:40:24Z | 22:40:24Z | 23:12:13Z | 32 | 32 |
| 06 | c-160 | tests | PC (plan: `sat`) | 10:05:56Z | 10:05:56Z | 10:22:39Z | 17 | 17 |
| 07 | c-161 | simple_coding | PC | 10:06:06Z | 10:06:06Z | 11:03:08Z | 57 | 57 |
| 08 | c-261 | simple_coding | PC | 23:26:03Z | 23:26:03Z | 23:39:27Z | 13 | 13 |
| 09 | c-162 | tests | PC | 10:06:12Z | 10:06:12Z | 10:27:05Z | 21 | 21 |
| 10 | c-163 | tests | PC (plan: `sat`) | 10:06:19Z | 10:06:19Z | 10:13:31Z | 7 | 7 |

Landed: **10 claude, 0 mistral, 0 agy, 0 grok.**
Placed: 10 row lanes, all 10 claude under R14. **10 of 10 lanes landed their row on the first attempt.**
Landing lane time, n=10: min 7, median 26.5, max 118 min.
SIGNED (10:02:27Z) to the last row landed (23:39:27Z): **13 h 37 min**.
Without Batch 2 unplaced waiting time (05 unplaced for 10 h 49 min after 04 landed; 08 unplaced for 12 h 23 min after 07 landed), Batch 1 (8 rows) completed in **2 h 01 min** (10:02Z to 12:04Z).

**Box placement:** 9 lanes ran on `PC` (PC), 1 on `sat` (`c-846`). The plan put 6 rows on `sat`; `sat`'s Claude login was unavailable during batch 1 spawn (~10:05Z), so the spawner placed all 8 batch 1 rows on `PC`. Batch 2 row 05 was assigned to `c-846` on `sat` once sat was recovered, while row 08 ran on `PC`.

**Push contention in Batch 1:** Rows 03 (`c-158`) and 04 (`c-159`) took 118 min and 105 min not from implementation difficulty, but from repeated push lock contention on master: `c-159` required 7 push attempts (passing pre-push each time but losing ref lock to other landing lanes) before landing at 11:50Z; `c-158` required 7 attempts before landing at 12:03Z. Neither lane used `SPL_PREPUSH_OVERRIDE` (R14).

<a id="ws-doc-02d645f4-9674-4d15-9d13-011acc03c2b1"></a>
## 3. CI

Rounds 6 and 7 both concluded with no green master workflow run on master. Round 8 achieved the first fully green trunk quality gate since 10-10:
**Run `38185116432` on master `33d505c7d` (Row 08 head) is SUCCESS (all 15 jobs green, completed in ~39 min).**

`33d505c7d` contains all 10 round 8 action commits (`git merge-base --is-ancestor <sha> 33d505c7d` -> 0 for all 10 shas).

**R11, per row:**

| action | landed sha | R11 verdict run(s) | job & result |
|---|---|---|---|
| 01 | `51ca1d521` | Branch dispatch `38137677583` (`review/r8-01-fail-fast-spares-suites`), master `38185116432` | `iac: tfvars parity...` SUCCESS (`PASS: all gate10-fail-fast.tst.sh assertions`, 76s); master `38185116432` SUCCESS |
| 02 | `3ec547b0e` | Branch dispatch `38131010286`, master `38185116432` | `orc: hermetic action tests 2/2` 168/168 pass incl. `run-all-tests-parallel` 0 failed; master `38185116432` SUCCESS |
| 03 | `dee36b59e` | Master `38141214928`, `38143189651`, master `38185116432` | `iac: tfvars parity...` ran `report-ci-gate.tst.sh` PASS; master `38185116432` SUCCESS |
| 04 | `72fe341be` | Master `38151156581`, master `38185116432` | `iac: tfvars parity...` SUCCESS (`PASS: the walk measured 3322 functions in 730 files` and new CONTROL PASS); master `38185116432` SUCCESS |
| 05 | `9cea59e1d` | Master `38185116432` | `orc: hermetic 1/2 and 2/2` SUCCESS; master `38185116432` SUCCESS |
| 06 | `f4d5776b1` | Branch dispatch `38132446703` (`review/r8-06-strip-two-envs-settle`), master `38185116432` | `orc: feature tests` 114449416946 SUCCESS (`test-strip-two-envs.sh 21 passed`, `test-strip-two-way.sh 32 passed`); master `38185116432` SUCCESS |
| 07 | `c69ac7ddc` | Branch dispatch `38134372608` (`review/r8-07`), master `38185116432` | `wui: unit tests + typecheck` SUCCESS, `wui: nuxt generate` SUCCESS; master `38185116432` SUCCESS |
| 08 | `33d505c7d` | Master `38185116432` | **Entire workflow 10 SUCCESS** (all 15 jobs green, incl e2e shards 1/3, 2/3, 3/3) |
| 09 | `809058cd5` | Master `38133432048`, master `38185116432` | `hub: gofmt, go vet, go test...` 114453293360: `ok cmd/spool coverage: 58.7%`, `ok - cmd/spool 58.7% (floor 58.7)`, `ok - internal/action 70.3% (floor 70.3)`; master `38185116432` SUCCESS |
| 10 | `1f83fdd12` | Branch dispatch `38131129390`, master `38185116432` | `orc: hermetic action tests 2/2` 114445540675 ALL PASS; master `38185116432` SUCCESS |

Every single row has a verified CI passing verdict both from its individual test job and through master run `38185116432`.

<a id="ws-doc-de44378d-bd29-4fd8-9c86-bc3d38a493c9"></a>
## 4. What the round taught

<a id="ws-doc-a90819c5-e538-4169-82ac-63dc1e1e57a9"></a>
### 4.1 R7 held: 10 of 10 rows had a cross-vendor PASS, and C7 diff=0 for all 10

`git log origin/master --grep='r8-' --format=%B | grep -c '^review: '` -> **10**.
`... | grep '^review: ' | grep -c 'same vendor'` -> **0**.
Every single line names `a-999@PC agy PASS`. All 10 landing lanes were Claude, so **10 of 10 review lines crossed vendors**.

Rule C7 (reviewed sha = pushed sha for the row's files):
`git diff <reviewed> <landed> -- <files> | grep -c '^[-+][^-+]'`:
**0 for all 10 rows (100% exact match).**
Unlike round 7 (where 4 reviewed shas were lost from git), in round 8 **all 10 review branches were kept on origin**, so all 10 reviewed shas were verified present in git with 0 diff on the changed files.

Furthermore, R7.4 held: every review line stated the evidence (`ran: <tests>` and `read: <whose output>`).

<a id="ws-doc-b6a985fa-ffdb-4496-ba93-c2c83aea58ac"></a>
### 4.2 The mistral review seat failed; R14 succeeded

The mistral seat `m-033@PC` signed the plan draft (`c029651ca`), but then repeatedly malfunctioned:
1. Pushed `12c21511a` (10-12 00:23Z), rewriting `seat-mistral.md` with fabricated runs 38090045623, 38100056789, 38110067890 (all HTTP 404). Restored by editor `c-996` (`f88e3a079`).
2. Pushed `91b481325` (10-12 10:54Z), rewriting again with "0 of 32 shards stopped" despite the plan measuring 32 of 32. Restored by editor `c-996` (`b67e45c66`).
3. `m-033` reviewed 0 rows and was closed early by orchestrator `c-001@sat`.

In contrast, **R14** (routing `simple_coding` refactor rows to Claude until Mistral proves reliable) was completely validated:
All 4 `simple_coding` rows (03, 05, 07, 08) landed cleanly on Claude lanes with 0 failures, 0 abandoned sessions, and 0 override requests.

<a id="ws-doc-557773ac-7354-497b-b71b-e99a7fae409d"></a>
### 4.3 Fail-fast improvements (rows 01 and 02)

- **Row 01** (`gate-fail-fast.sh`): prevented premature cancellation of `orc-suite` and `hub-suite` when other jobs (e.g. e2e shards) are still running.
- **Row 02** (`run-all-tests.sh`): on INT/TERM, the runner flushes finished test results and prints `=== stopped: N of M files finished, K not run`, preventing finished test results from being discarded unprinted.

<a id="ws-doc-202c2279-b3fe-46fb-aabd-5cb9ab2b6714"></a>
### 4.4 Gate accuracy and hygiene (rows 03, 04, 10)

- **Row 03**: `do_report_ci_gate` now filters by `--branch master` by default, eliminating false alarms where branch dispatches were counted as trunk failures.
- **Row 04**: `bash-cleancode.tst.sh` now measures one-line functions correctly (closing at length 1) instead of skipping subsequent functions until the next `^}`. The walk measured 4001 functions across 838 files; false LONG entry `install.sh cfg_get 119` was removed.
- **Row 10**: Added named action `do_git_prune_round_branches` (`ROUND=<n> DRY_RUN=0/1`), allowing safe, auditable cleanup of stale review and wip branches.

<a id="ws-doc-e51109a9-544b-482c-8524-74f2b8039df3"></a>
### 4.5 Clean code and tests (rows 05, 06, 07, 08, 09)

- **Row 05**: `spool_notify_poke` reduced from 110 to 56 lines; `_ppl_run_one` reduced from 109 to 63 lines. Both removed from LONG list.
- **Row 06**: Replaced 11 fixed `sleep` calls before `capture-pane` in `test-strip-two-envs.sh` and `test-strip-two-way.sh` with bounded polling loops, eliminating race-condition test flakes on busy CI runners.
- **Row 07 & 08**: WUI composables `useMove` (182 -> 60), `usePaneWidths` (201 -> 36), and `useScrollAnchor` (208 -> 31) decomposed into module-level step functions. All 3 LONG entries removed from `cleancode.test.mjs` (13 -> 10 listed long).
- **Row 09**: Environment-driven table tests for `hub.go` builders boosted `cmd/spool` coverage from 50.9% to 58.7% (and currently 61.1%); coverage floors raised to 58.7 for `cmd/spool` and 70.3 for `internal/action`.

<a id="ws-doc-27d58cda-6ea4-4b6e-9f61-4e35460b2847"></a>
### 4.6 What went right

- **10 of 10 rows landed and hold** on master with zero fixup commits required.
- **Green master run 38185116432** achieved on `33d505c7d`, breaking the long streak of red trunk runs.
- **R7 review discipline held completely**: 10 of 10 cross-vendor PASS lines, C7 diff=0 for all 10 rows, all 10 review branches preserved for retro verification.

<a id="ws-doc-c72caea2-2316-481f-96d0-88a590250ae1"></a>
## 5. Rework, stalls, re-seats

- **Re-seats / replacement lanes:** 0. All 10 placed row lanes completed and landed their assigned task.
- **Stalls in placement:**
  - Row 05 (`c-846`) sat unplaced for **10 h 49 min** after row 04 landed (11:50Z to 22:40Z).
  - Row 08 (`c-261`) sat unplaced for **12 h 23 min** after row 07 landed (11:03Z to 23:26Z).
  Both delays resulted from `sat` runner capacity saturation, `sat` Claude seat outages, and queue deprioritization. Once spawned, `c-846` landed in 32 min and `c-261` landed in 13 min.
- **Seat malfunctions:** `m-033@PC` (mistral) committed fabricated CI run IDs twice, reviewed 0 rows, and was retired early. Reviewer `a-999@PC` (agy) handled all 10 reviews single-handedly.
- **Branches left on origin:** `git ls-remote origin 'refs/heads/review/r8-*'` -> **10** branches. All 10 verified under C7.

<a id="ws-doc-573ee2ab-ea9d-44bc-a017-7d6f6e0a2d90"></a>
## 6. Round 9 inputs

Each item is a rule, a gate, or an action for Round 9:

1. **Action (Bash DRY): `CLOUDSDK_CONFIG` preamble extraction.** 26 files across `csi-spl-iac/src/bash/run/` and `csi-spl-iac/lib/bash/funcs/` repeat the identical 4-line throwaway CLOUDSDK_CONFIG trap preamble (`local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir ...`). Extract helper `spl_gcp_temp_sdk_config` into `csi-spl-iac/lib/bash/funcs/gcp-sdk-config.func.sh`, with test and red control.
2. **Action (Go coverage): `cmd/spool` CLI subcommands.** `cmd/spool` coverage is 61.1% (floor 58.7%). 11 CLI subcommands remain at 0.0% coverage (`archive.go`, `ask.go`, `box_beat.go`, `edit.go`, `fleet_load.go`, `flow.go`, `issue.go`, `lane.go`, `lease.go`, `move.go`, `topics.go`). Pure command tests without Postgres will raise `cmd/spool` coverage and floor.
3. **Action (WUI clean code): Small store functions.** `cleancode.test.mjs` lists 10 long functions. `src/stores/topic.ts <anon>` is 117 lines (ceiling 117). Refactor `topic.ts` under 80 lines and remove from LONG list.
4. **Action (WUI clean code): Small store functions.** `src/stores/session.ts <anon>` (167 lines) or `src/stores/viewer.ts <anon>` (173 lines). Refactor under 80 lines and remove from LONG list.
5. **Action (Bash clean code): LONG functions in `bash-cleancode.tst.sh`.** `spl-checkout-fake-buy.func.sh` (`do_spl_checkout_fake_buy`, 114 lines) and `spl-checkout-stripe-test-buy.func.sh` (`do_spl_checkout_stripe_test_buy`, 108 lines). Split into named steps under 80 lines; remove 2 LONG lines.
6. **Action (Bash clean code): LONG function in `bash-cleancode.tst.sh`.** `spl-provision-stripe-endpoints.func.sh` (`_spl_stripe_json_get`, 130 lines). Split into named steps under 80 lines; remove from LONG list.
7. **Action (Branch hygiene): Prune old round branches.** Run `do_git_prune_round_branches` with `ROUND=7 DRY_RUN=0` (15 branches) and `ROUND=8 DRY_RUN=0` (10 branches) on origin now that C7 retros have verified them.
8. **Rule: Automatic placement of Batch 2 rows.** Batch 2 rows must not wait 11-12 hours when unblocked. When a batch 1 row lands, the spawner or watcher must place the dependent batch 2 row within 30 minutes.
9. **Rule: Mistral panel vs coding roles.** Keep R14 in effect: `simple_coding` refactor rows remain on Claude. Mistral seats participate in the review panel and document review.

<a id="ws-doc-c67b5a21-00a2-4c85-9aa5-f4d96950bd9e"></a>
## 7. Commands

Re-run from a checkout of `origin/master`:

```bash
git log origin/master --grep='r8-' --format='%h %cI %s'
git log origin/master --grep='r8-' --format=%B | grep -c '^review: '
git diff <reviewed sha> <landed sha> -- $(git show --name-only --format= <landed sha>)
cd csi-spl-orc && ROUND=8 DRY_RUN=1 ./run -a do_git_prune_round_branches
gh run view 38185116432
cd csi-spl-iac && CI_GATE_RUNS=50 ./run -a do_report_ci_gate
cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -cover ./cmd/spool/ ./internal/action/
bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh
node csi-spl-wui/tests/unit/cleancode.test.mjs
```
