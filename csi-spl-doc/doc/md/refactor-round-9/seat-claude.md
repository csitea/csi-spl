# Refactor round 9 - claude seat review (c-500)

The claude seat's review of `../refactor-round-9-plan.md` at plan sha **`afbd48aaa`**. A seat commits this file and nothing else (R7.6). Editor: a-497.

**Trees measured:** the plan's trunk `e05383148` and today's `origin/master` = `afbd48aaa`. Between them no row site changed: `git diff --stat e05383148 afbd48aaa -- csi-spl-api csi-spl-wui/src csi-spl-wui/tests/unit csi-spl-orc/src/bash/run csi-spl-orc/src/bash/features/spawn-agents/tests csi-spl-iac/lib csi-spl-iac/src/bash/run csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` -> 1 file, `check-pre-push-e2e.func.sh`, which is in no row. So every count below holds for both shas. n=1 per count unless stated otherwise.

## 1. Re-measured rows

| row | command (on `afbd48aaa`) | n | plan says | measured |
|---|---|---|---|---|
| 01, 02 | `go test -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out` (Go 1.25.14) | 1 | `cmd/spool` 61.1 %, floor 58.7 | 61.2 % (1578 of 2580 statements); floor line `cmd/spool 58.7` |
| 01 | statements at 0 % in `archive.go` 13, `move.go` 14, `react.go` 16, `edit.go` 28 (same profile) | 1 | target >= 64.0 % | 71 statements = **+2.75 points at most** -> 63.95 % even at 100 % of them |
| 02 | the same for `topics.go` 23, `flow.go` 46, `lane.go` 25, `box_beat.go` 35 | 1 | target >= 66.0 % | 129 statements = +5.0 points at most; 66.0 % is reachable after 01 |
| 03, 04 | `node csi-spl-wui/tests/unit/cleancode.test.mjs` | 1 | 9721 functions, 10 long; `createSpoolClient` 542 vs 565 | same: `9721 functions, 10 listed long`; NOTE 542 under 565 |
| 05, 06, 07 | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | 1 | 17 listed | **18 listed** (its PASS line: `(18 listed)`); all assertions PASS |
| 08 | `git ls-remote origin 'refs/heads/review/r7-*' 'refs/heads/wip/*r7*' \| wc -l`, then `r8` | 1 | 15 + 10 | 15 + 10 |
| 09 | `gh api repos/<repo>/actions/jobs/<job>/logs` of runs 38080037175 and 38118720855, job `orc: feature tests` | 2 | 2 red sightings | 2 of 2 show `FAIL - hub: agent announced (missing 'CLE-3 announced on box-a')`; those runs also had 5 and 7 other jobs red |
| 10 | `git grep -n 'local _spl_sdk_saved="\${CLOUDSDK_CONFIG' csi-spl-iac/ \| wc -l` | 1 | 26 files | 26 lines in 26 files (`git grep -l ... \| wc -l` -> 26) |

## 2. Per-row checks

| row | one practice | disjoint in its batch | test or red control | box + vendor | lane map |
|---|---|---|---|---|---|
| 01 | yes | yes | yes, but target unreachable (obj. 1) | PC, vendor not named (obj. 6) | rc 4, no owner |
| 02 | yes | yes (after 01) | yes | PC, (obj. 6) | rc 4 |
| 03 | yes | yes | yes | PC, (obj. 6) | rc 4 |
| 04 | yes | yes (after 03) | yes | PC, (obj. 6) | rc 4 |
| 05 | no: source edit named as the gate fix (obj. 2) | yes | control does not test the gate (obj. 2) | sat, (obj. 6) | rc 4 |
| 06 | yes | yes (after 05) | yes | sat, (obj. 6) | rc 4 |
| 07 | yes | yes (after 06) | yes | sat, (obj. 6) | rc 4 |
| 08 | yes | yes | yes; the live prune conflicts with the action's own rule (obj. 4) | sat, (obj. 6) | rc 4 |
| 09 | yes | yes | the fix shape cannot work (obj. 3) | sat, (obj. 6) | rc 4 |
| 10 | yes | yes | the helper as written breaks isolation (obj. 5) | sat, (obj. 6) | rc 4 |

Lane map: `lane-map.sh --check <row paths> --agent c-500`, one call per row -> rc 4 for all 10, **no rc 3** (no row path is owned). The 4 `unknown:` lanes (no files recorded) are c-908, c-915, c-982, c-995, all `@sat`; c-982 (`ui-item4-offscreen-cards`) and c-995 (`attach-rename-old`) are WUI lanes, so rows 03 and 04 ask them before the spawn (R3).

## 3. Objections

1. **Row 01: target 64.0 % is out of reach, and the subcommands are not "pure filesystem".** Command + n: the coverage profile above, n=1: the four files hold 71 uncovered statements of 2580 = +2.75 points, so 100 % of them reaches 63.95 %. And `grep -n hubclient csi-spl-api/src/go/spool-hub-api/internal/action/archive.go` -> `hc = hubclient.New(cfg)`: `cmdArchive`, `cmdMove`, `cmdReact`, `cmdEdit`, `cmdDelete`, `cmdTopics`, `cmdFlow`, `cmdLane`, `cmdBoxBeat` all call the hub over HTTP through `internal/action`; a temp spool root alone does not drive them. Also the floor path `api:csi-spl-api/src/bash/tests/go-coverage-floor.txt` expands wrongly under the `api:` prefix.
   Replacement text, section 2 row 1, section 3 row 01 "test or red control" and section 4 row 01:
   > CLI subcommands that call the hub through `internal/action` run at 0 %. New `cmd/spool/cli_fs_test.go` drives `archive`, `move`, `react`, `edit`, `delete` against an `httptest.Server` stub hub (the pattern of `doc_test.go` `newDocsHub`), no Postgres, no real network. Raise the `cmd/spool` line of `csi-spl-api/src/bash/tests/go-coverage-floor.txt` to the measured value (target >= 63.0 %; the four files hold +2.75 points at most). **Red control:** deleting `cli_fs_test.go` fails the raised floor in `run-all-tests.sh`.

   Row 02 the same: "with mock outbox/inbox files" -> "against an `httptest.Server` stub hub"; its 66.0 % target stands.

2. **Row 05: the fix lives in the source, the defect lives in the gate.** Command + n=1: an awk pass over the same file set as `bash-cleancode.tst.sh` reporting a column-1 function header met while another function is open -> 8 files, among them `report-ci-gate.func.sh`, `report-ci-axes.func.sh`, `report-ci-red-note.func.sh` (bodies `do_x() { (` ... `) }`, which `^\}` never closes, so `_rcg_list_failed`, `_rca_fetch_runs`, `_crn_holder` are never measured) and the stripe file. Moving one `}` fixes one of the 8. Measured with the walker changed as below (n=1, `afbd48aaa`): the only new function over 80 lines is `do_spl_provision_stripe_endpoints` **118** (plan: 119; it spans lines 71-188), and `_spl_stripe_json_get` leaves LONG. The commit also changes a `func.sh`, so `test(` is the wrong prefix.
   Replacement text, section 3 row 05 and section 4 row 05:
   > `refactor(r9-05-bash-cleancode-walker)`, practice: a gate measures what it claims. In `measure()` of `bash-cleancode.tst.sh`, a column-1 function header closes the function still open (length = header line - start), and `^\)[[:space:]]*\}` closes a function like `^\}` does. Split `do_spl_provision_stripe_endpoints` (118) into named steps under 80 lines in the same commit (the fixed walker fails on it otherwise). Delete `_spl_stripe_json_get 130` from `LONG` (18 -> 17 listed). **Red control:** two new CONTROL fixtures in `bash-cleancode.tst.sh`: a multi-line body closed inline (`' "$1"; }`) followed by a 100-line function -> the 100-line function measures 100; a `f() { (` ... `) }` body followed by a 100-line function -> the same. Both fail on the old walker. `bash-cleancode.tst.sh`, `curl-time-bounded.tst.sh`.

   Sites: `iac:src/bash/tests/bash-cleancode.tst.sh:37` (not :34; see obj. 7).

3. **Row 09: a poll on the test's assertion cannot help; the wait is the harness's.** Command: `sed -n 120,136p csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-harness.sh` -> `export ... SPOOL_HARNESS_WAIT_SECS=5`, then `err="$(bash "$H" ...)"`, then `has ... "$err"`: `$err` is the captured output of a finished harness, it never changes. `spool-harness.sh:156` already polls the roster up to `SPOOL_HARNESS_WAIT_SECS` (default 25) and prints `warning: CLE-3 not yet announced` on time-out. n=2 sightings (section 1): the 5 s cap ran out under load.
   Replacement text, section 3 row 09 and section 4 row 09:
   > In `test-spool-harness.sh`, raise the test's `SPOOL_HARNESS_WAIT_SECS` from 5 to 30: the harness polls the roster and returns at the first announcement, so a green run waits no longer. **Red control:** the fake sidecar writes `roster.json` after `sleep 6` -> the old cap 5 fails `hub: agent announced`, the new cap passes; a fake sidecar that never writes the roster -> the harness prints `not yet announced` and the assertion fails (with `SPOOL_HARNESS_STRICT=1`, exit 69). Run 20/20 locally.

4. **Row 08: the row lane must not run the live prune.** Command: `sed -n 12,13p csi-spl-orc/src/bash/run/git-prune-round-branches.func.sh` -> "Run with DRY_RUN=0 only by the round's retro lane, after the retro has run C7 over the review branches (round plan R7.4, R8)". The plan's own R8 says the retro lane prunes. Deleting 25 remote branches is not a refactor lane's step. Two runs (`ROUND=7`, `ROUND=8`) already do it today, so the row is a convenience, which is fine, but not a live delete.
   Replacement text, section 4 row 08, last sentence:
   > The lane runs `ROUND="7,8" ./run -a do_git_prune_round_branches` (DRY_RUN=1) and quotes the 25 listed branches; the round 9 retro lane runs it with `DRY_RUN=0` (R8), as `ROUND="7,8,9"`.

   And its agent kind: `tests` -> `simple_coding` (it changes an action; R14 keeps it on claude either way).

5. **Row 10: a helper that sets the RETURN trap restores the config when the HELPER returns.** Command + n=1, bash 5.2.37: a probe with the 4-line block moved into `helper()` and called from `caller()` -> `in caller after helper: CLOUDSDK_CONFIG=/shared/gcloud dir_exists=no`. Every gcloud call in the caller would then run under the shared config, the exact thing the block exists to prevent. A probe with the trap kept in the caller and the body in two helpers -> inside: private dir exists; after return: caller value restored (set or unset), dir gone. `gcp-actions-isolated-config.tst.sh` checks the restore and `trap -p RETURN` being empty, and must stay green.
   Replacement text, section 3 row 10 and section 4 row 10:
   > Create `iac:lib/bash/funcs/gcp-temp-sdk-config.func.sh` with `spl_gcp_temp_sdk_config` (saves `CLOUDSDK_CONFIG` into the caller's `_spl_sdk_saved`, makes `_spl_sdk_dir`, exports it) and `spl_gcp_temp_sdk_config_restore` (removes the dir, restores or unsets). The RETURN trap stays in the caller, one line: `local _spl_sdk_saved _spl_sdk_dir; spl_gcp_temp_sdk_config || return 1; trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN`. Convert the 3 caller files. **Red control:** `gcp-temp-sdk-config.tst.sh` proves the private dir exists inside the caller, is removed after return, and the caller's value comes back (set and unset); a variant with the trap inside the helper fails it. `gcp-actions-isolated-config.tst.sh`, `gcp-temp-sdk-config.tst.sh`.

6. **Vendor per row is not named.** Command, n=1 each: `LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` -> `tests` pick=claude, `complex_coding` pick=claude, `simple_coding` **pick=mistral** today. R14 overrides the last to claude.
   Replacement text, a column `vendor` in section 3, after `agent kind`:
   > claude for all 10 rows (01, 02, 05, 08, 09: the mix's pick; 03, 04, 06, 07, 10: R14 over the mix's mistral pick). Under R7, agy reviews all 10.

7. **Line numbers (section 1 says "as of `e05383148`").** Command: `grep -n` on each file, n=1.
   Replacement text, section 3 sites:
   > `wui:src/stores/topic.ts:37`, `wui:src/stores/viewer.ts:11`, `wui:src/stores/session.ts:65` (the `defineStore` lines; plan 25, 28, 32); `orc:src/bash/run/spl-checkout-fake-buy.func.sh:34` and `orc:src/bash/run/spl-checkout-stripe-test-buy.func.sh:34` (plan 22); `iac:src/bash/tests/bash-cleancode.tst.sh:35,36` (row 06, plan 32,33) and `:37` (row 05, plan 34); `:23` (row 07) is right.

   Counts follow: LONG holds 18, so row 05 -> 17, row 06 -> 15, row 07 -> 14 (the plan's 15 and 14 stand).

Not objected: rows 03, 04 (LONG lines 39-41 and 44, the 542 ceiling, all measured as written); batch order and the 3 shared-file serialisations (section 3.1) hold.

## 4. Signature

not signed: c-500 on `afbd48aaa`. Objections 1, 3 and 5 change what a lane does (an unreachable floor, a fix that cannot pass its own control, a helper that breaks config isolation) and 2 and 4 change its scope; I sign the version that folds 1-5, re-checking only what changed. 6 and 7 are text.

## 5. Re-check of v1.0 (`9296e7b99`)

Only what changed against objections 1-5, read with `git diff afbd48aaa 9296e7b99 -- csi-spl-doc/doc/md/refactor-round-9-plan.md`; the row sites did not move (`git diff --quiet afbd48aaa origin/master -- <test-spool-harness.sh> <bash-cleancode.tst.sh>` -> rc 0).

| obj. | v1.0 (section 3 row, section 4) | verdict |
|---|---|---|
| 1 | rows 01, 02: `httptest.Server` stub hub, `newDocsHub` pattern; targets >= 63.0 % and >= 66.0 % | folded |
| 2 | row 05: `refactor(r9-05-bash-cleancode-walker)`, column-1 header and `^\)[[:space:]]*\}` close, 118-line split, two CONTROL fixtures | folded |
| 3 | row 09: `SPOOL_HARNESS_WAIT_SECS` 5 -> 30, delayed and never-written roster controls | folded |
| 4 | row 08: lane runs `DRY_RUN=1` only, retro runs `DRY_RUN=0` (R8); kind `simple_coding` | folded |
| 5 | row 10: helper pair, trap kept in the caller, control "trap inside helper fails" | folded |
| 6, 7 | vendor column (claude x10), line numbers | folded |

Text left for the lanes, not objections (each lane reads the real file first):

- row 09 site: the `SPOOL_HARNESS_WAIT_SECS=5` line is `test-spool-harness.sh:128`, not `:124` (`grep -n SPOOL_HARNESS_WAIT_SECS` -> 128, 150, 153; lines 150 and 153 set 1 on purpose and stay).
- row 05 site: `measure()` spans `bash-cleancode.tst.sh:47-55`, not `51-54` (`grep -n '^measure()'` -> 47).
- rows 01, 02: the floor site reads `api:csi-spl-api/src/bash/tests/go-coverage-floor.txt`; the file is `csi-spl-api/src/bash/tests/go-coverage-floor.txt` (no `api:` prefix). Section 2 row 1 and section 4 still say "pure" CLI subcommands; they call the hub (obj. 1).

signed: c-500 on `9296e7b99` (v1.0, which folds objections 1-7 raised on `afbd48aaa`).
