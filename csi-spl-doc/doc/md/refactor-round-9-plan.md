# Refactoring round 9 - plan: clean code round 20261014-a (10 actions)

> Generated from qto doc `0407cc80-ff27-4d90-80eb-1ef0de0190c0`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Owner HUM-10, prd t1, topic `4f46ce09-15ee-4b9a-b05f-edd9812b51fb`, msg 3d22fcea: rounds run continuously, **no owner go is needed for this round, its panel or its lanes** (rule home: `SPEC-spool-fleet-roles.md` section 1.2). Requested by the dispatch holder c-002@sat (msg 14132589) per round 8 plan R8, once `refactor-round-8-retro.md` was on trunk (`afbd48aaa`).

**Status: SIGNED.** All three seats signed plan sha **`afbd48aaa`** with panel objections folded into this v1.0 commit (section 10). Batch 1 = 01, 03, 05, 08, 09, 10; Batch 2 = 02 (after 01), 04 (after 03), 06 (after 05); Batch 3 = 07 (after 06). The row lanes are spawned by the orchestrator from this signed plan. Reviewer seats a-497@PC (agy), c-500@PC (claude) and m-501@PC (mistral) stay up until all 10 rows are on trunk (R7.1).

Panel: the agy seat (planner and editor a-497, `PC`; proposal `refactor-round-9/seat-agy.md`), the claude seat c-500@PC (`refactor-round-9/seat-claude.md`, `db56c80ea`) and the mistral seat m-501@PC (`refactor-round-9/seat-mistral.md`, `39a662c30`), placed by the orchestrator c-001@sat. Inputs: the shape and rules R1-R15 of `refactor-round-8-plan.md`; **`refactor-round-8-retro.md` section 6** (items 1-9); round 8's section 8 (left out).

Every site was measured on ONE trunk sha: **`e05383148`** (`origin/master`, 2026-10-14T08:09:42Z), n=1 per count unless stated otherwise. CI was read over the 30 newest master runs of workflow 10 (`do_report_ci_gate`).

<a id="ws-doc-48f02459-601e-401f-92bc-0647746ed150"></a>
## 1. How to read this

- One action = one practice = one lane. The lane applies the practice at the sites named and nowhere else, with a test that proves behaviour did not change, or, for a gate or a test fix, a **red control** that proves the check now fails on the bad input.
- **Paths:** `api:` = `csi-spl-api/src/go/spool-hub-api/`, `wui:` = `csi-spl-wui/`, `orc:` = `csi-spl-orc/src/bash/`, `iac:` = `csi-spl-iac/src/bash/`, everything else is from the repo root. Line numbers are as of `e05383148`.
- **Boxes:** `sat` and `PC`, as in round 8. `sat` 6, `PC` 4.
- **Agent kind** = a `do_spl_lane_mix` kind: `LANE_MIX_KIND=<kind> ./run -a do_spl_lane_mix` per row at spawn time, **then R14**. Kinds here: `complex_coding` 1, `tests` 3, `simple_coding` 6.
- **Vendor:** `claude` for all 10 rows (01, 02, 05, 08, 09: the mix's pick; 03, 04, 06, 07, 10: R14 over the mix's mistral pick). Under R7, `agy` reviews all 10 rows.
- **No new dependency.** 05 and 08 change what a gate or tool does; 01, 02, 09 change tests only; 03, 04, 06, 07, 10 are behaviour-preserving refactors.
- **Commit subject** (R6 reads it): `refactor(r9-NN-<slug>, SPL-1818): ...` for 03, 04, 05, 06, 07, 10; `ci(r9-NN-<slug>, SPL-1818): ...` for 08; `test(r9-NN-<slug>, SPL-1818): ...` for 01, 02, 09.
- **Off every live lane:** `lane-map.sh --check <the 24 paths> --agent a-497` -> rc 4: no path owned. Re-run per action before its spawn (R3).

<a id="ws-doc-80c3e939-6050-4255-8098-d186f39f05f5"></a>
## 2. Where the actions come from (measured)

| source | command on `e05383148` | n | action |
|---|---|---|---|
| retro 6.2: `cmd/spool` CLI subcommands at 0 % coverage | `go test -coverprofile=/tmp/cov.out ./cmd/spool/ && go tool cover -func=/tmp/cov.out \| awk '$3=="0.0%"'` | `cmd/spool` 61.1 % (floor 58.7 %); **11** pure CLI subcommands at 0.0 % (`archive.go`, `ask.go`, `box_beat.go`, `edit.go`, `fleet_load.go`, `flow.go`, `issue.go`, `lane.go`, `lease.go`, `move.go`, `react.go`, `topics.go`). Subcommands that call the hub through `internal/action` run against an `httptest.Server` stub hub | 01, 02 |
| retro 6.3: small functions (WUI stores) | `node csi-spl-wui/tests/unit/cleancode.test.mjs` -> `9721 functions, 10 listed long` | `src/stores/topic.ts <anon>` is 117 lines (target < 80); `src/stores/viewer.ts <anon>` is 173 lines (target < 80) | 03 |
| retro 6.4: small functions (WUI stores) & ceiling | `node csi-spl-wui/tests/unit/cleancode.test.mjs` | `src/stores/session.ts <anon>` is 167 lines (target < 80); `createSpoolClient` measured at 542 lines vs ceiling 565 | 04 |
| retro 6.6: bash clean-code gate measuring defect | `awk` function walk on `bash-cleancode.tst.sh` file set | 8 files have open functions met at column 1; `spl-provision-stripe-endpoints.func.sh:69` inline closing brace hides `do_spl_provision_stripe_endpoints` (**118 lines**) and lists `_spl_stripe_json_get` as fake LONG **130 lines** (real: 11 lines) | 05 |
| retro 6.5: small functions (bash checkout) | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | `do_spl_checkout_fake_buy` is **114 lines**; `do_spl_checkout_stripe_test_buy` is **108 lines**; both in `LONG` list | 06 |
| small functions (bash IAC secrets) | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` | `do_gcp_fetch_secrets` is **107 lines** in `csi-spl-iac/src/bash/run/gcp-fetch-secrets.func.sh` | 07 |
| retro 6.7: stale round branches on origin | `git ls-remote origin 'refs/heads/review/r7-*' 'refs/heads/wip/*r7*' \| wc -l` (15); `... r8-*` (10) | **25 stale branches** on origin; `do_git_prune_round_branches` only supports a single round number (`ROUND=<n>`) | 08 |
| retro 3.2: flake watch (spool-harness settle) | `grep -n "CLE-3 announced on box-a" csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-harness.sh:136` | **2 red sightings** on master (runs 38080037175, 38118720855); harness polls roster up to `SPOOL_HARNESS_WAIT_SECS`, test's 5 s cap ran out under heavy load | 09 |
| retro 6.1: bash DRY (CLOUDSDK_CONFIG preamble) | `git grep -n 'local _spl_sdk_saved="\${CLOUDSDK_CONFIG' csi-spl-iac/ \| wc -l` | **26 files** repeat the identical 4-line throwaway CLOUDSDK_CONFIG trap block | 10 |

<a id="ws-doc-484e424c-9dda-415e-a0de-8fc9c5983b87"></a>
## 3. The 10 actions

| # | practice | why (one line) | sites file:line (max 5) | n + command | test or red control | box | vendor | agent kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `test(r9-01-go-coverage-spool-cli-fs)` | comprehensive tests, high coverage | CLI subcommands through `internal/action` run at 0 % coverage | `api:cmd/spool/archive.go:14`<br>`api:cmd/spool/move.go:14`<br>`api:cmd/spool/react.go:15`<br>`api:cmd/spool/edit.go:15,36`<br>`api:csi-spl-api/src/bash/tests/go-coverage-floor.txt` | 4 subcommands at 0.0 %; spool cov 61.1 % | New `cmd/spool/cli_fs_test.go` drives `archive`, `move`, `react`, `edit`, `delete` against an `httptest.Server` stub hub (`newDocsHub` pattern), no Postgres, no real network. Raise `cmd/spool` line in `go-coverage-floor.txt` to measured value (target >= 63.0 %). **Red control:** deleting `cli_fs_test.go` fails raised floor in `run-all-tests.sh` | PC | claude | tests | 1 |
| 02 `test(r9-02-go-coverage-spool-cli-inspect)` | comprehensive tests, high coverage | Pure CLI inspection subcommands in `cmd/spool` run at 0 % coverage | `api:cmd/spool/topics.go:21`<br>`api:cmd/spool/flow.go:22,72`<br>`api:cmd/spool/lane.go:15`<br>`api:cmd/spool/box_beat.go:19`<br>`api:csi-spl-api/src/bash/tests/go-coverage-floor.txt` | 4 subcommands at 0.0 % | New `cmd/spool/cli_inspect_test.go` drives `topics`, `flow`, `lane`, `box_beat` against `httptest.Server` stub hub. Raise `cmd/spool` floor in `go-coverage-floor.txt` to new value (target >= 66.0 %). **Red control:** deleting `cli_inspect_test.go` fails coverage floor | PC | claude | tests | 2 (after 01: shares `go-coverage-floor.txt`) |
| 03 `refactor(r9-03-wui-small-stores-topic-viewer)` | small functions | Two store anonymous setup bodies exceed MAX_LINES | `wui:src/stores/topic.ts:37`<br>`wui:src/stores/viewer.ts:11`<br>`wui:tests/unit/cleancode.test.mjs:40,41` | 2 LONG entries (117 and 173 lines) | Decompose inner actions into named module-level step functions under 80 lines; preserve store interface and reactivity. Delete both lines from `cleancode.test.mjs` LONG map (10 -> 8 listed). **Red control:** dummy 81-line function in `topic.ts` fails `cleancode.test.mjs`. `topic-kind.test.mjs`, typecheck | PC | claude (R14) | simple_coding | 1 |
| 04 `refactor(r9-04-wui-small-store-session)` | small functions | Session store exceeds MAX_LINES; `createSpoolClient` ceiling stale | `wui:src/stores/session.ts:65`<br>`wui:tests/unit/cleancode.test.mjs:39,44` | 1 LONG entry (167 lines) + 1 ceiling lower | Decompose `session.ts` into named functions under 80 lines; remove from LONG map; lower `createSpoolClient` ceiling from 565 to 542. **Red control:** dummy 81-line function in `session.ts` fails `cleancode.test.mjs`. `page-session-gates.test.mjs`, typecheck | PC | claude (R14) | simple_coding | 2 (after 03: shares `cleancode.test.mjs`) |
| 05 `refactor(r9-05-bash-cleancode-walker)` | a gate measures what it claims | Walker closes open functions at header or subshell; stripe function split | `orc:src/bash/run/spl-provision-stripe-endpoints.func.sh:69,71`<br>`iac:src/bash/tests/bash-cleancode.tst.sh:37,51-54` | 1 fake LONG (130) + 1 hidden function (118) | In `measure()` of `bash-cleancode.tst.sh`, a column-1 function header closes open function, and `^\)[[:space:]]*\}` closes like `^\}`. Split `do_spl_provision_stripe_endpoints` (118) under 80 lines. Delete `_spl_stripe_json_get 130` from `LONG` (18 -> 17 listed). **Red control:** fixtures with multi-line inline body and subshell body followed by 100-line function measure 100 (both fail on old walker). `bash-cleancode.tst.sh`, `curl-time-bounded.tst.sh` | sat | claude | complex_coding | 1 |
| 06 `refactor(r9-06-bash-small-checkout-functions)` | small functions | Two test payment functions exceed MAX_LINES | `orc:src/bash/run/spl-checkout-fake-buy.func.sh:34`<br>`orc:src/bash/run/spl-checkout-stripe-test-buy.func.sh:34`<br>`iac:src/bash/tests/bash-cleancode.tst.sh:35,36` | 2 LONG entries (114 and 108 lines) | Split both functions into named steps under 80 lines; preserve stdout JSON, HTTP status, and 0600 file creation. Delete both lines from `LONG` (17 -> 15 listed). `checkout-fake-buy.tst.sh`, `checkout-stripe-test-buy.tst.sh`, `bash-cleancode.tst.sh` | sat | claude (R14) | simple_coding | 2 (after 05: shares `bash-cleancode.tst.sh`) |
| 07 `refactor(r9-07-bash-small-gcp-fetch-secrets)` | small functions | GCP secret fetch action exceeds MAX_LINES | `iac:src/bash/run/gcp-fetch-secrets.func.sh:11`<br>`iac:src/bash/tests/bash-cleancode.tst.sh:23` | 1 LONG entry (107 lines) | Split `do_gcp_fetch_secrets` into named steps under 80 lines; preserve environment exports, error exits, and logs. Delete line from `LONG` (15 -> 14 listed). `gcp-exit-status-checks.tst.sh`, `bash-cleancode.tst.sh` | sat | claude (R14) | simple_coding | 3 (after 06: shares `bash-cleancode.tst.sh`) |
| 08 `ci(r9-08-round-branch-prune-multi)` | nothing ad hoc: a named action | Pruning multiple rounds requires separate manual runs; 25 stale branches on origin | `orc:src/bash/run/git-prune-round-branches.func.sh:28,34`<br>`orc:src/bash/tests/git-prune-round-branches.tst.sh` | 25 branches (15 r7 + 10 r8) | Support comma- or space-separated `ROUND="7,8"` or `ROUNDS="7 8"` in `do_git_prune_round_branches`. The lane runs with `DRY_RUN=1` and quotes the 25 listed branches; round 9 retro lane runs with `DRY_RUN=0` (R8). **Red control:** `ROUND="7,8"` in test fixture identifies both rounds, preserves master and r6. `git-prune-round-branches.tst.sh` | sat | claude | simple_coding | 1 |
| 09 `test(r9-09-spool-harness-settle)` | a test waits for a state, never for a time | Fixed wait before roster announcement caused 2 red sightings under CI load | `orc:features/spawn-agents/tests/test-spool-harness.sh:124` | 2 CI red sightings (runs 38080037175, 38118720855) | In `test-spool-harness.sh`, raise `SPOOL_HARNESS_WAIT_SECS` from 5 to 30: harness polls roster and returns on announcement, so green runs wait no longer. **Red control:** fake sidecar writes `roster.json` after `sleep 6` -> old cap 5 fails `hub: agent announced`, new cap 30 passes; fake sidecar that never writes roster -> prints `not yet announced` and fails (`SPOOL_HARNESS_STRICT=1`, exit 69). Run 20/20 locally | sat | claude | tests | 1 |
| 10 `refactor(r9-10-bash-temp-sdk-config-helper)` | don't repeat yourself (DRY) | 26 files repeat identical 4-line throwaway CLOUDSDK_CONFIG trap block | `iac:lib/bash/funcs/gcp-temp-sdk-config.func.sh` (new)<br>`iac:src/bash/tests/gcp-temp-sdk-config.tst.sh` (new)<br>`iac:lib/bash/funcs/gcp-each-env-sa.func.sh:22-26`<br>`iac:lib/bash/funcs/gcp-project-apis.func.sh:25-29`<br>`iac:src/bash/run/spl-kms-check.func.sh:18-22` | 26 copies across IAC | Create `gcp-temp-sdk-config.func.sh` with `spl_gcp_temp_sdk_config` (saves `CLOUDSDK_CONFIG`, creates `_spl_sdk_dir`, exports) and `spl_gcp_temp_sdk_config_restore` (removes dir, restores/unsets). Caller holds one-line trap: `local _spl_sdk_saved _spl_sdk_dir; spl_gcp_temp_sdk_config \|\| return 1; trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN`. Convert 3 caller files. **Red control:** private dir exists inside caller, is removed after return, caller value comes back; trap inside helper fails. `gcp-actions-isolated-config.tst.sh`, `gcp-temp-sdk-config.tst.sh` | sat | claude (R14) | simple_coding | 1 |

<a id="ws-doc-693e8c89-5fa6-4cc2-8682-902e3707931b"></a>
### 3.1 Disjoint files (R1)

- No path is in two actions of the same batch.
- **Shared files, serialised:**
  - `go-coverage-floor.txt`: 01 (Batch 1), then 02 (Batch 2).
  - `cleancode.test.mjs`: 03 (Batch 1), then 04 (Batch 2).
  - `bash-cleancode.tst.sh`: 05 (Batch 1), then 06 (Batch 2), then 07 (Batch 3).

<a id="ws-doc-d37bfc03-dff1-4488-bce0-6c475556eef5"></a>
## 4. Per action: what the lane does

- **01 `test(r9-01-go-coverage-spool-cli-fs)`:** Write `api:cmd/spool/cli_fs_test.go` driving pure CLI subcommands `archive`, `move`, `react`, `edit`, `delete` against an `httptest.Server` stub hub (the pattern of `doc_test.go` `newDocsHub`), no Postgres, no real network. Measure `cmd/spool` coverage with `go test -cover ./cmd/spool/` (current 61.1 %); raise `cmd/spool` line in `csi-spl-api/src/bash/tests/go-coverage-floor.txt` to the measured value (target >= 63.0 %; the four files hold +2.75 points at most). **Red control:** deleting `cli_fs_test.go` causes `run-all-tests.sh` to fail the coverage floor.
- **02 `test(r9-02-go-coverage-spool-cli-inspect)`:** Write `api:cmd/spool/cli_inspect_test.go` driving pure CLI subcommands `topics`, `flow`, `lane`, `box_beat` against an `httptest.Server` stub hub. Measure `cmd/spool` coverage; raise `cmd/spool` floor in `go-coverage-floor.txt` to the new value (target >= 66.0 %). **Red control:** deleting `cli_inspect_test.go` fails the coverage floor.
- **03 `refactor(r9-03-wui-small-stores-topic-viewer)`:** In `csi-spl-wui/src/stores/topic.ts` (line 37, 117 lines) and `viewer.ts` (line 11, 173 lines), extract internal helper functions into named module-level step functions under 80 lines. Keep exported store composable interface and Vue reactivity byte-for-byte compatible. Delete both entries from `LONG` map in `csi-spl-wui/tests/unit/cleancode.test.mjs` (10 -> 8 listed). Run `topic-kind.test.mjs`, `search.test.mjs`, `list-order.test.mjs`, and `npm run typecheck`.
- **04 `refactor(r9-04-wui-small-store-session)`:** In `csi-spl-wui/src/stores/session.ts` (line 65, 167 lines), extract internal handlers into named functions under 80 lines. Delete its entry from `LONG` map in `cleancode.test.mjs` (8 -> 7 listed) and lower `createSpoolClient` ceiling from 565 to 542. Run `page-session-gates.test.mjs`, `signed-out-socket.test.mjs`, and `npm run typecheck`.
- **05 `refactor(r9-05-bash-cleancode-walker)`:** In `measure()` of `csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` (lines 51-54), ensure a column-1 function header closes the function still open (length = header line - start), and `^\)[[:space:]]*\}` closes a function like `^\}` does. Split `do_spl_provision_stripe_endpoints` (118 lines, lines 71-188) into named steps under 80 lines in the same commit. Delete `_spl_stripe_json_get 130` from `LONG` (line 37, 18 -> 17 listed). Add two new CONTROL fixtures in `bash-cleancode.tst.sh`: multi-line body closed inline (`' "$1"; }`) followed by 100-line function measures 100; `f() { (` ... `) }` body followed by 100-line function measures 100. Run `bash-cleancode.tst.sh` and `curl-time-bounded.tst.sh`.
- **06 `refactor(r9-06-bash-small-checkout-functions)`:** In `spl-checkout-fake-buy.func.sh` (line 34, 114 lines) and `spl-checkout-stripe-test-buy.func.sh` (line 34, 108 lines), extract parameter validation and response handling into named step functions under 80 lines. Retain exact JSON stdout formats, file permissions (0600), and exit codes. Delete both lines from `LONG` in `bash-cleancode.tst.sh` (lines 35, 36; 17 -> 15 listed). Run `checkout-fake-buy.tst.sh` and `checkout-stripe-test-buy.tst.sh`.
- **07 `refactor(r9-07-bash-small-gcp-fetch-secrets)`:** In `csi-spl-iac/src/bash/run/gcp-fetch-secrets.func.sh` (line 11, 107 lines), decompose `do_gcp_fetch_secrets` into named steps under 80 lines (`_gcp_fetch_secrets_auth`, `_gcp_fetch_secrets_export`). Retain exact secret extraction, transformation logic, and exit status. Delete its line from `LONG` in `bash-cleancode.tst.sh` (line 23; 15 -> 14 listed). Run `gcp-exit-status-checks.tst.sh` and `bash-cleancode.tst.sh`.
- **08 `ci(r9-08-round-branch-prune-multi)`:** In `csi-spl-orc/src/bash/run/git-prune-round-branches.func.sh`, parse `ROUND` or `ROUNDS` as a list of round numbers (e.g. `ROUND="7,8"` or `ROUNDS="7 8"`). Iterate across each round number for branch matching and atomic remote deletion. Update `git-prune-round-branches.tst.sh` to test multi-round pruning and invalid formats. The lane runs `ROUND="7,8" ./run -a do_git_prune_round_branches` (DRY_RUN=1) and quotes the 25 listed branches; the round 9 retro lane runs it with `DRY_RUN=0` (R8), as `ROUND="7,8,9"`.
- **09 `test(r9-09-spool-harness-settle)`:** In `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-harness.sh:124`, raise the test's `SPOOL_HARNESS_WAIT_SECS` from 5 to 30: the harness polls the roster and returns at the first announcement, so a green run waits no longer. **Red control:** the fake sidecar writes `roster.json` after `sleep 6` -> old cap 5 fails `hub: agent announced`, new cap 30 passes; fake sidecar that never writes roster -> harness prints `not yet announced` and assertion fails (`SPOOL_HARNESS_STRICT=1`, exit 69). Run 20/20 locally.
- **10 `refactor(r9-10-bash-temp-sdk-config-helper)`:** Create `iac:lib/bash/funcs/gcp-temp-sdk-config.func.sh` with `spl_gcp_temp_sdk_config` (saves `CLOUDSDK_CONFIG` into caller's `_spl_sdk_saved`, makes `_spl_sdk_dir`, exports it) and `spl_gcp_temp_sdk_config_restore` (removes the dir, restores or unsets). The RETURN trap stays in caller: `local _spl_sdk_saved _spl_sdk_dir; spl_gcp_temp_sdk_config || return 1; trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN`. Convert 3 caller files (`gcp-each-env-sa.func.sh`, `gcp-project-apis.func.sh`, `spl-kms-check.func.sh`). **Red control:** `gcp-temp-sdk-config.tst.sh` proves private dir exists inside caller, is removed after return, and caller's value comes back (set and unset); trap inside helper fails. Run `gcp-actions-isolated-config.tst.sh` and `gcp-temp-sdk-config.tst.sh`.

<a id="ws-doc-dcfa5ee0-f908-4ff4-9a01-62ec5a5ccc9e"></a>
## 5. Spawn, done, status (R1-R16)

- **R1, Disjoint files per batch.** As in round 8: no path is in two actions of the same batch. Shared files are strictly serialised across batches.
- **R2, Rebase onto latest master.** Before every push, fetch and rebase onto `origin/master`.
- **R3, Before the wave.** The orchestrator runs `lane-map.sh --check <action paths> --agent <id>` per action. Never spawn on top of an owned path.
- **R4, Spawning across boxes.** `sat` spawns 05, 06, 07, 08, 09, 10; `PC` spawns 01, 02, 03, 04. Spawner reads the new pane 2 minutes after spawn.
- **Batch order.** Batch 1 = 01, 03, 05, 08, 09, 10. Batch 2 = 02 (after 01), 04 (after 03), 06 (after 05). Batch 3 = 07 (after 06).
- **R5, Done = served.** WUI changes (03, 04): verified via `do_check_deploy_lag` on dev and prd. Go tests (01, 02): test-only. Bash/CI: on `origin/master` and verified in box checkout with red control proof.
- **R6, No hand-kept status.** Read trunk via `git fetch origin master && git log origin/master --grep='r9-' --format='%h %cI %s'`.
- **R7, Peer review across vendors.** Review lines cross-vendor (agy reviews claude; mistral reviews agy/grok). Review lines carry evidence (`ran:`, `read:`). Review branches stay on origin until retro C7 verification.
- **R8, Retro and seat order.** Retro lane writes `refactor-round-9-retro.md`, verifies C7 diff=0, prunes round branches, then editor closes seats.
- **R9, Gate lanes.** Rows 01, 05, 08 run tests under `PRE_PUSH_TIER=full` before first push.
- **R10, Placement & progress checks.** 30-minute progress check on every live row lane; 1-hour placement check.
- **R11, CI verdict per row.** Individual test jobs must pass; master workflow 10 run must show green or independent failures.
- **R12, R13, R15 carried.**
- **R14, Vendor mix.** `simple_coding` refactor rows stay on Claude until Mistral proves reliable on refactor rows. Mistral retains panel review seat.
- **R16 (new, batch placement SLA):** Dependent Batch 2 and Batch 3 rows must be spawned within 30 minutes of the prerequisite row landing on trunk.

<a id="ws-doc-324a3465-f749-4627-9926-6794d59a2017"></a>
## 6. Process practices, measured (no lane)

| owner practice | measured state | verdict |
|---|---|---|
| peer code review with a checklist before merge | round 8: 10 of 10 review lines cross-vendor, C7 diff=0 for all 10 rows (retro 4.1) | **held:** R7.4, R7.6 |
| work is placed, not forgotten | round 8: batch 2 rows waited 11-12 h unplaced (retro 2, 5) | **tightened:** R16 30-min batch spawn SLA |
| a gate measures what it claims | awk parser misses functions after inline python braces and subshell headers (section 2 row 4) | **new:** action 05 |
| comprehensive tests, high coverage | pure CLI subcommands run at 0.0 % coverage (section 2 row 1) | **new:** actions 01, 02 |
| tests wait for state, never time | fixed test timeout in test-spool-harness caused 2 CI red sightings (section 2 row 8) | **new:** action 09 |
| nothing ad hoc | 25 stale review/wip branches left on origin (section 2 row 7) | **new:** action 08 |

<a id="ws-doc-05667bbe-4ee2-46b1-a7e1-eaf3faf125b4"></a>
## 7. Disagreements

Seat reviews on `afbd48aaa`:
- agy (a-497): 10 agree (the planner's proposal).
- mistral (m-501, `39a662c30`): signed with 2 objections.
  - D1 (mistral, row 03): Claimed incorrect line counts and no LONG entries using `wc -l` on the whole file. **Settled: objection incorrect.** `cleancode.test.mjs:40-41` lists the setup bodies at 117 and 173 lines; whole files are 153 and 183 lines (`wc -l`). Plan row stands.
  - D2 (mistral, row 05): Claimed `_spl_stripe_json_get` is 13 lines not 130. **Settled: incorporated.** The plan noted 130 was the awk walker's false measurement and the body ~11 lines; folded into D4's broader walker fix.
- claude (c-500, `db56c80ea`): not signed on `afbd48aaa` pending 5 operational objections; folds 1-5 signed in v1.0.
  - D3 (claude, rows 01, 02): Drive CLI subcommands against `httptest.Server` stub hub (`newDocsHub` pattern); realistic coverage targets >= 63.0 % (row 01) and >= 66.0 % (row 02). **Settled: folded.**
  - D4 (claude, row 05): Walker defect is in `measure()` of `bash-cleancode.tst.sh` (matches 8 files); `do_spl_provision_stripe_endpoints` is 118 lines; slug is `refactor(r9-05-bash-cleancode-walker)`. **Settled: folded.**
  - D5 (claude, row 08): Row lane runs `DRY_RUN=1` only; `DRY_RUN=0` reserved for retro lane (R8); agent kind is `simple_coding`. **Settled: folded.**
  - D6 (claude, row 09): Harness already polls roster; test timeout `SPOOL_HARNESS_WAIT_SECS` raised from 5 to 30. **Settled: folded.**
  - D7 (claude, row 10): Helper must not set RETURN trap inside itself; caller holds one-line trap using pair of helpers `spl_gcp_temp_sdk_config` / `spl_gcp_temp_sdk_config_restore`. **Settled: folded.**
  - D8 (claude, row 06/07 line numbers & vendor column): Line numbers updated and vendor column added (all 10 rows claude; agy reviews all 10 under R7). **Settled: folded.**

<a id="ws-doc-0fbefa98-c581-4add-8d5a-0d4c9bcfc95c"></a>
## 8. Measured and left out

| what | why it is out | measured by |
|---|---|---|
| `cmd/spool/hub.go` server wiring (`cmdServe`, `openStore`, `serveUntilDone`, `wirePayments`, ...) | needs live Postgres and full hub runtime; rows 01 and 02 take pure CLI subcommands | `go tool cover -func` on `e05383148` |
| `internal/blob` 66.2 % (19 functions at 0 %) | requires fake-gcs emulator | `go test -cover ./internal/blob/` |
| Large Pinia setup stores (`channel.ts` 576, `notification.ts` 430, `flow.ts` 317) | large live feature stores; rows 03 and 04 take smaller stores `topic.ts` (117), `viewer.ts` (173), `session.ts` (167) | `cleancode.test.mjs:34-48` |
| `do_spl_cloud_cnf` 96, `do_tf_init` 95, GCP destructive LONG entries (`do_gcp_import_to_cloudsql` 175) | key execution paths and destructive operations | `bash-cleancode.tst.sh` |
| `spawn_main` 185 | spawn core engine, live fleet files | `bash-cleancode.tst.sh` |
| Flakes under 3 sightings (`test-agent-hook.sh` 1, `test-tmux-close-window-vibe.sh` 1) | below 3rd-sighting threshold (R11.3) | `do_report_ci_gate` |
| shfmt and prettier | no repo-wide config or tooling configured | round 8 plan section 8 |

<a id="ws-doc-88f314e2-f107-47f3-b3d9-2cb7cf13ea22"></a>
## 9. Counts

| | Go | TS/Vue | bash | CI / gate | total |
|---|---|---|---|---|---|
| code actions | 0 | 2 (03, 04) | 4 (05, 06, 07, 10) | 0 | 6 |
| test actions | 2 (01, 02) | 0 | 1 (09) | 0 | 3 |
| gate / tooling action | 0 | 0 | 0 | 1 (08) | 1 |
| per box | `sat`: 05, 06, 07, 08, 09, 10 | | | `PC`: 01, 02, 03, 04 | 10 |
| vendor | claude: 10 (01, 02, 05, 08, 09 mix; 03, 04, 06, 07, 10 R14) | | | reviewer: agy (all 10 rows, R7) | 10 |
| agent kind | complex_coding: 05 | tests: 01, 02, 09 | simple_coding: 03, 04, 06, 07, 08, 10 | | 10 |
| batches | Batch 1: 01, 03, 05, 08, 09, 10 | Batch 2: 02, 04, 06 | Batch 3: 07 | | 10 |
| rules | R1-R15 carried and updated; R16 new | | | | 16 |

<a id="ws-doc-b34f253b-d028-452f-a08c-69a62d19614e"></a>
## 10. Consensus

Signed plan sha: **`9296e7b99`** (v1.0; all 3 vendor seats re-checked and signed).

| seat | signed | how |
|---|---|---|
| agy (planner and editor a-497@PC) | `9296e7b99` | proposal `refactor-round-9/seat-agy.md`, signed at `a45d82597` |
| claude (c-500@PC) | `9296e7b99` | `refactor-round-9/seat-claude.md`: re-checked objections 1-5 folded, signed at `6fd5ba611` |
| mistral (m-501@PC) | `9296e7b99` | `refactor-round-9/seat-mistral.md`: re-checked, objections settled/withdrawn, signed at `6deade0ef` |
