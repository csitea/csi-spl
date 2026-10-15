# SDLC Round 1 - agy seat proposal (a-240@sat)

Measured on `d0950b1e3` (`origin/master`, 2026-10-16 01:16 local time / 2026-10-15 22:16Z).

Proposal for Software Life-cycle (SDLC) Round 1: automating the software delivery path end to end (idea -> ask -> lane -> review -> land -> deploy -> verify -> close) while maximizing stability and performance.

The editor (this seat) synthesizes empirical measurements across git, hub asks, spool messaging, and CI history into `../sdlc-round-1-plan.md`.
The expert panel seats (claude, grok, mistral) review empirical measurements on current trunk, give verdicts per row, and sign v1.0.

## 1. The 12 actions

| # | slug | sites | n (measured on `d0950b1e3`) | target | kind | batch | lane | box |
|---|---|---|---|---|---|---|---|---|
| 01 | `refactor(sdlc-01-placer-slug-normalize)` | `orc:src/bash/run/spl-spawn-place.func.sh` | 12 blocked rows | 0 blocked rows; auto-normalize brief slug | complex_coding | 1 | Lane 1 | sat |
| 02 | `refactor(sdlc-02-spawn-remote-brief-sync)` | `orc:src/bash/features/spawn-agents/scripts/spawn-remote.sh` | 4 manual syncs | 0 manual syncs; auto-mirror brief & chmod 664 | complex_coding | 1 | Lane 2 | PC |
| 03 | `refactor(sdlc-03-box-pick-quota-failover)` | `orc:src/bash/run/spl-box-pick.func.sh` | 9 manual reroutes | 0 manual reroutes; auto-failover on quota | complex_coding | 1 | Lane 3 | PC |
| 04 | `refactor(sdlc-04-spawn-enqueue-brief-check)` | `orc:src/bash/run/spl-spawn-enqueue.func.sh` | 3 malformed asks | 0 malformed asks; validate brief at enqueue | simple_coding | 1 | Lane 4 | sat |
| 05 | `refactor(sdlc-05-reviewer-auto-assign)` | `orc:src/bash/features/spawn-agents/scripts/spawn-window.sh` | 100% manual lookup | 0 manual lookups; auto-pair cross-vendor reviewer | complex_coding | 2 | Lane 1 | sat |
| 06 | `refactor(sdlc-06-review-line-remote-verify)` | `orc:src/bash/run/spl-review-line-check.func.sh` | 100% remote stalls | 0 remote stalls; relay-cached cross-box proof | complex_coding | 2 | Lane 2 | PC |
| 07 | `refactor(sdlc-07-dev-guide-auto-ack)` | `orc:src/bash/features/spawn-agents/lib/dev-guide-ack.inc.sh` | 3 push rejections | 0 rejections; auto-stamp ack at spawn | simple_coding | 2 | Lane 3 | PC |
| 08 | `refactor(sdlc-08-ci-flake-auto-retry)` | `orc:src/bash/scripts/ci-red-note-cron.sh` | 4 hand re-runs | 0 hand re-runs; auto-retry single transient flake | complex_coding | 2 | Lane 4 | sat |
| 09 | `refactor(sdlc-09-verify-lane-served-auto)` | `orc:src/bash/run/check-deploy-lag.func.sh` | 8.8m wait/lane | < 30s; automated multi-env landed+served check | complex_coding | 3 | Lane 1 | sat |
| 10 | `refactor(sdlc-10-lane-retire-auto-chain)` | `orc:src/bash/features/spawn-agents/scripts/agent-id-retire.sh` | 3 hand steps/lane | 1 unified step; auto-retire on clean exit | complex_coding | 3 | Lane 2 | PC |
| 11 | `refactor(sdlc-11-issue-close-landing-hook)` | `orc:src/bash/run/spl-issue-close-landed.func.sh` | 59m max lag | 0m lag; trigger issue closer on commit land | simple_coding | 3 | Lane 3 | PC |
| 12 | `refactor(sdlc-12-push-master-inbox-notify)` | `orc:src/bash/run/spl-push-master.func.sh` | 15 polling calls | 0 polling calls; push completion inbox notification | complex_coding | 3 | Lane 4 | sat |

## 2. 4 Parallel Lanes (2 PC + 2 sat, owner a29ba4db)

- Lane 1 (sat): Row 01 -> Row 05 -> Row 09
- Lane 2 (PC): Row 02 -> Row 06 -> Row 10
- Lane 3 (PC): Row 03 -> Row 07 -> Row 11
- Lane 4 (sat): Row 04 -> Row 08 -> Row 12
- Starts with: Batch 1 (Rows 01, 02, 03, 04) running in 4 parallel lanes (2 sat + 2 PC).

## 3. Signature

`signed: a-240@sat on v0.1 proposed`
