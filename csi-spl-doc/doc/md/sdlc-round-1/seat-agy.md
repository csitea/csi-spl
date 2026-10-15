# SDLC Round 1 - agy seat proposal (a-240@sat)

Measured on `d0950b1e3` (`origin/master`, 2026-10-16 01:16 local time / 2026-10-15 22:16Z).

Proposal for Software Life-cycle (SDLC) Round 1: automating the software delivery path end to end (idea -> ask -> lane -> review -> land -> deploy -> verify -> close) while maximizing stability and performance.

The editor (this seat) synthesizes empirical measurements across git, hub asks, spool messaging, and CI history into `../sdlc-round-1-plan.md`.
The expert panel seats (claude, grok, mistral takeover) review empirical measurements on current trunk, give verdicts per row, and sign v1.2.

## 1. The 8 actions (after panel consensus & verification)

| # | slug | sites | n (measured on `d0950b1e3`) | target | kind | batch | lane | box |
|---|---|---|---|---|---|---|---|---|
| 01 | `refactor(sdlc-01-placer-slug-normalize)` | `orc:src/bash/run/spl-spawn-place.func.sh` | 12 blocked rows | 0 blocked rows; auto-normalize brief slug | complex_coding | 1 | Lane 1 | sat |
| 03 | `refactor(sdlc-03-box-pick-quota-failover)` | `orc:src/bash/run/spl-box-pick.func.sh` | 9 manual reroutes | 0 manual reroutes; quota failover (rebases on ab32184e) | complex_coding | 1 | Lane 2 | PC |
| 07 | `refactor(sdlc-07-topic-status-card)` | `orc:src/bash/features/spawn-agents/scripts/topic-status-card.sh (new)` | 32 owner status asks | 0 owner status asks; live edited-in-place card (P1) | complex_coding | 1 | Lane 3 | PC |
| 09 | `refactor(sdlc-09-verify-lane-served-auto)` | `orc:src/bash/run/check-lane-served.func.sh (new)` | 8.8m wait/lane | < 30s; automated multi-env landed+served check | complex_coding | 1 | Lane 4 | sat |
| 04 | `refactor(sdlc-04-placer-handoff-unblock)` | `orc:src/bash/run/spl-spawn-place.func.sh` | 12 hand-offs burned slots | 0 wasted slots; unblock queue on hand-off (P2) | complex_coding | 2 | Lane 1 | sat |
| 11 | `refactor(sdlc-11-issue-close-landing-hook)` | `orc:src/bash/run/spl-issue-close-landed.func.sh` | 59m max lag | 0m lag; trigger issue closer on commit land | simple_coding | 2 | Lane 2 | PC |
| 12 | `refactor(sdlc-12-push-master-inbox-notify)` | `orc:src/bash/run/spl-push-master.func.sh` | 15 polling calls | 0 polling calls; push completion inbox notification | complex_coding | 2 | Lane 3 | sat |
| 06 | `refactor(sdlc-06-spawn-place-dynamic-gap)` | `orc:src/bash/run/spl-spawn-place.func.sh` | 1,418 timer holds | Dynamic placement gap following lane heartbeat (P3) | complex_coding | 3 | Lane 1 | PC |

## 2. 4 Parallel Lanes (2 PC + 2 sat, owner a29ba4db)

- Lane 1 (sat - Placer): Row 01 -> Row 04
- Lane 2 (PC - Box Selection & Heartbeat Gap): Row 03 -> Row 06 (Batch 3)
- Lane 3 (PC - Topic Cards & Issue Closer): Row 07 -> Row 11
- Lane 4 (sat - Verification & Push Pipeline): Row 09 -> Row 12
- Starts with: Batch 1 (Rows 01, 03, 07, 09) running in 4 parallel lanes (2 sat + 2 PC).

## 3. Status

agreed & v1.2 drafted by editor (a-240@sat); standing by for panel signatures.
