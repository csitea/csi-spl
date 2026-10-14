# Refactor round 9 - agy seat proposal (a-497, PC)

A proposal, not the plan. The editor (this seat) merges the three seats into `../refactor-round-9-plan.md`. The claude and mistral seats write `seat-claude.md` and `seat-mistral.md` beside this file, measured on `origin/master`, give a verdict per row (agree / agree with changes / disagree, with the command behind any change), then sign. **Both seats stay up after signing: under the plan's R7.1 you are this round's cross-vendor reviewers until every row is on trunk. A seat commits its seat file and nothing else (R7.6).**

Every count was measured on ONE trunk sha, **`e05383148`** (`origin/master`, 2026-10-14T08:09:42Z), n=1 per count unless stated otherwise. The command for each is in the plan, section 2. Round 8 is closed and held: `refactor-round-8-retro.md` section 1 (10 of 10 actions).

## 1. The 10 actions

| # | slug | source | sites | n | kind | box | batch |
|---|---|---|---|---|---|---|---|
| 01 | `test(r9-01-go-coverage-spool-cli-fs)` | r8 retro 6.2 | pure filesystem CLI subcommands in `cmd/spool` (`archive.go`, `move.go`, `react.go`, `edit.go`) | 4 files at 0.0 %; spool cov 61.1 % | tests | PC | 1 |
| 02 | `test(r9-02-go-coverage-spool-cli-inspect)` | r8 retro 6.2 | pure CLI inspection subcommands in `cmd/spool` (`topics.go`, `flow.go`, `lane.go`, `box_beat.go`) | 4 files at 0.0 % | tests | PC | 2 (after 01) |
| 03 | `refactor(r9-03-wui-small-stores-topic-viewer)` | r8 retro 6.3, cleancode | `topic.ts` (117 lines) and `viewer.ts` (173 lines) under 80 lines | 2 LONG entries | simple_coding | PC | 1 |
| 04 | `refactor(r9-04-wui-small-store-session)` | r8 retro 6.4, cleancode | `session.ts` (167 lines) under 80 lines; lower `createSpoolClient` ceiling to 542 | 1 LONG entry + 1 ceiling lower | simple_coding | PC | 2 (after 03) |
| 05 | `test(r9-05-bash-stripe-measure-fix)` | r8 retro 6.6, clean-code gate | `spl-provision-stripe-endpoints.func.sh:69` brace defect; `do_spl_provision_stripe_endpoints` split | 1 fake LONG (130) + 1 unmeasured (119) | complex_coding | sat | 1 |
| 06 | `refactor(r9-06-bash-small-checkout-functions)` | r8 retro 6.5, clean-code | `spl-checkout-fake-buy.func.sh` (114) and `spl-checkout-stripe-test-buy.func.sh` (108) | 2 LONG entries | simple_coding | sat | 2 (after 05) |
| 07 | `refactor(r9-07-bash-small-gcp-fetch-secrets)` | clean-code | `gcp-fetch-secrets.func.sh` (107 lines) under 80 lines | 1 LONG entry | simple_coding | sat | 3 (after 06) |
| 08 | `ci(r9-08-round-branch-prune-multi)` | r8 retro 6.7 | `do_git_prune_round_branches` multi-round support (`ROUND="7,8"`); prune 25 stale origin branches | 15 r7 + 10 r8 branches | tests | sat | 1 |
| 09 | `test(r9-09-spool-harness-settle)` | r8 retro 3.2 flake watch | `test-spool-harness.sh` bounded poll for sidecar announcement (2 CI red sightings) | 2 sightings | tests | sat | 1 |
| 10 | `refactor(r9-10-bash-temp-sdk-config-helper)` | r8 retro 6.1 DRY | extract `spl_gcp_temp_sdk_config` helper and convert 3 caller files | 26 files repeat 4-line trap block | simple_coding | sat | 1 |

## 2. Rules carried and updated (from r8 retro section 6)

- **R1-R6, R9, R12, R13, R15 carried.**
- **R7 (peer review):** 10 of 10 rows cross-vendor (agy reviews claude rows; mistral reviews agy/grok rows). Review line evidence (`ran:`, `read:`) required.
- **R8 (retro & seat order):** retro reads review lines and runs C7, action 08 prunes branches, then planner closes review seats.
- **R10 (placement & progress check):** 30-minute progress check; hourly placement check.
- **R14 (vendor mix):** `simple_coding` refactor rows stay on Claude until Mistral proves reliable on refactor rows (retro 4.2). Mistral retains panel review seat.
- **R16 (new, batch placement):** Batch 2 and Batch 3 rows placed within 30 minutes of prerequisite row landing on trunk, avoiding Round 8's 11-12 hour idle queue delay.

## 3. Left out

The plan's section 8, each with the command that measured it.
