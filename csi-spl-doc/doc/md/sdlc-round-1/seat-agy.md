# SDLC Round 1 - agy seat proposal (a-240@sat)

Measured on `origin/master` (2026-10-16).

Proposal for Software Life-cycle (SDLC) Round 1: automating the software delivery path end to end (idea -> ask -> lane -> review -> land -> deploy -> verify -> close) while maximizing stability and performance.

The editor (this seat) synthesizes empirical measurements across git, hub asks, spool messaging, and CI history into `../sdlc-round-1-plan.md`.
The expert panel seats (Claude seat `c-247@sat`, Takeover seat `c-251@sat`) review empirical measurements on current trunk, give verdicts per row, and sign v1.4.

## 1. The 6 actions (after panel consensus & verification)

| # | slug | sites | number now | target | kind | batch | lane | box |
|---|---|---|---|---|---|---|---|---|
| 01 | `refactor(sdlc-01-placer-slug-normalize-handoff)` | `orc:src/bash/run/spl-spawn-place.func.sh:235-262` | 10 hand prefix rows; 12 hand-offs burned 10-min slots | Strip prefix, pass `SPAWN_BOX=<box>`, unblock hand-off without burning slot | complex_coding | 1 | Lane 1 | sat |
| 07 | `refactor(sdlc-07-topic-status-card)` | `orc:src/bash/features/spawn-agents/scripts/topic-status-card.sh (new)`<br>`orc:src/bash/run/spl-asks-tick.func.sh:417` | 32 owner status asks across 28 topics | Live edited-in-place topic card (P1); 0 new message spam | complex_coding | 1 | Lane 2 | PC |
| 09 | `refactor(sdlc-09-verify-lane-served-auto)` | `orc:src/bash/run/check-lane-served.func.sh (new)` | 18 owner posts/week on live/served | < 30s for docs (`served=n/a`); automated deploy verify for code | complex_coding | 1 | Lane 3 | sat |
| 11 | `refactor(sdlc-11-issue-close-cadence)` | `cnf/box-crons/box-crons.manifest:28` | 59m max lag on hourly closer (`37 * * * *`) | Cadence `*/5 * * * *` on sweeping box (P2); cuts lag to 5m | simple_coding | 1 | Lane 4 | PC |
| 06 | `refactor(sdlc-06-spawn-place-dynamic-gap)` | `orc:src/bash/run/spl-spawn-place.func.sh:198-208` | 1,467 clock holds; 4.3h median queue wait | Dynamic placement gap following lane heartbeat (P3); 3m floor | complex_coding | 2 | Lane 1 | sat |
| 12 | `refactor(sdlc-12-no-go-asks-owner-topics)` | `orc:src/bash/features/spawn-agents/scripts/spool-send.sh` | 66 owner go/yes/ok nudges across 47 topics | Send-side guard refusing unneeded go-asks in owner topics (P1) | complex_coding | 2 | Lane 2 | PC |

## 2. Parallel Lanes & Batches

- **Batch 1 (4 parallel lanes: 2 sat + 2 PC):**
  - Lane 1 (sat): Row 01 (`refactor(sdlc-01-placer-slug-normalize-handoff)`)
  - Lane 2 (PC): Row 07 (`refactor(sdlc-07-topic-status-card)`)
  - Lane 3 (sat): Row 09 (`refactor(sdlc-09-verify-lane-served-auto)`)
  - Lane 4 (PC): Row 11 (`refactor(sdlc-11-issue-close-cadence)`)
- **Batch 2 (2 parallel lanes: 1 sat + 1 PC, after Batch 1 lands):**
  - Lane 1 (sat): Row 06 (`refactor(sdlc-06-spawn-place-dynamic-gap)`)
  - Lane 2 (PC): Row 12 (`refactor(sdlc-12-no-go-asks-owner-topics)`)

## 3. Status

agreed & v1.4 drafted by editor (a-240@sat); standing by for panel signatures (`c-247@sat`, `c-251@sat`).
