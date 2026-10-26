# Refactor round 7 - claude seat proposal (c-776, sat)

> Generated from qto doc `2075ff16-4edd-4b14-bc86-77bd15937a77`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

A proposal, not the plan. The editor (this seat) merges the three seats into `../refactor-round-7-plan.md`. The agy and mistral seats write `seat-agy.md` and `seat-mistral.md` beside this file, measured on `origin/master`, give a verdict per row (agree / agree with changes / disagree, with the command behind any change), then sign. **Both seats stay up after signing: under the plan's R7.1 you are this round's cross-vendor reviewers until every row is on trunk.**

Every count was measured on ONE trunk sha, **`b161a015b`**, n=1 per count unless stated otherwise. The command for each is in the plan, section 2. Round 6 is closed and held: `refactor-round-6-retro.md` section 1 (10 of 10 actions).

<a id="ws-doc-559e38a8-2548-4f4a-8aec-55eb5e6fb484"></a>
## 1. The 10 actions

| # | slug | source | sites | n | kind | box | batch |
|---|---|---|---|---|---|---|---|
| 01 | `test(r7-01-wui-fetch-signal-scan)` | r6 retro 6.4 | scan every `await fetch(` under `wui:src/`; fix the 5 with no signal | 5 | simple_coding | PC | 1 |
| 02 | `ci(r7-02-gate-first-red)` | r6 retro 6.3 | `do_report_ci_gate` counts the first red per run, not the fail-fast stops | 24 runs | complex_coding | sat | 1 |
| 03 | `test(r7-03-strip-resize-settle)` | r6 retro 6.6 | `spool-strip-resize-proof.sh` polls for the paint instead of fixed sleeps | 7 of 20 jobs | tests | sat | 1 |
| 04 | `test(r7-04-go-coverage-hubclient)` | r6 retro 6.8 | `internal/hubclient` 51.9 % | 55 at 0 % | tests | PC | 1 |
| 05 | `refactor(r7-05-bash-cron-checkout-helper)` | r6 retro 6.8 | helper + 4 of the 9 "self-updating checkout" copies | 4 of 9 | simple_coding | sat | 1 |
| 06 | `refactor(r7-06-bash-cron-checkout-rest)` | r6 retro 6.8 | the other 5 copies | 5 of 9 | simple_coding | sat | 2 (after 05) |
| 07 | `refactor(r7-07-bash-small-functions-iac)` | r6 retro 6.8 | `do_check_weekly_full_scan` 128, `do_gcp_backup_env` 82 | 2 | secret | sat | 1 |
| 08 | `refactor(r7-08-bash-small-functions-orc)` | small functions | `spl_dispatch_setup_steps` 86, `do_spl_responder_run` 105 | 2 | secret | sat | 2 (after 07) |
| 09 | `refactor(r7-09-wui-small-functions)` | small functions | `useLive` 113, `live-ws handle` 117, `useMentionPicker` 130 | 3 | simple_coding | PC | 1 |
| 10 | `test(r7-10-go-coverage-spool-cli)` | r6 retro 6.8 | `cmd/spool` client commands, 26.8 % | 73 at 0 % | tests | PC | 2 (after 04) |

<a id="ws-doc-102684de-e68c-4cb6-8e56-d178074fefc2"></a>
## 2. Rules proposed (from the r6 retro, section 6)

- **R7 rewritten** (retro 6.1): the agy and mistral seats stay up until every row is on trunk; each row brief names its cross-vendor reviewer; a gone seat is re-placed within the hour and the row waits; the same-vendor fallback is withdrawn. Review lines name `<id>@<box> <vendor>`.
- **R10** (retro 6.2): the orchestrator checks placement every hour until every row has a lane; a batch-2 row is placed by whoever first sees its dependency land.
- **R11** (retro 6.3): measured first. A `cancelled` wf 10 run is a superseded pending run by design; the 19 runs that finished in round 6 were all red. A row's CI verdict is the first completed run whose head contains it, and its first red must not be one of the row's jobs. Trunk-red watch in the hourly check. No change to wf 10 concurrency without a measurement.
- **R12** (retro 6.5): a count sent to the owner quotes its command.
- **R13** (retro 6.7): an id live on two boxes is written `<id>@<box>`.

<a id="ws-doc-113bc04a-c1fb-406e-8cef-c658847d9eca"></a>
## 3. Left out

The plan's section 8, each with the command that measured it.
