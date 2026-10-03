# Antigravity Review: Spec 064 (Fleet Without the PC)

Review of `csi-spl-doc/specs/064-fleet-without-the-pc/spec.md` (c-048, sha `5a63e8d8`).

## 1. Failover, Correctness & Gaps
- **Split-brain & Flapping**: Ranking sat first (`sat,<the PC>`) stops priority flapping. Hub CAS enforces single-holder lease semantics, and local self-demotion after 180s hub unreachability bounds dual-actor risk during netsplits.
- **Mid-Push & Dark Box**: Hard laptop shutdown traps unpushed local commits and freezes active turns. The 20-min push rule bounds data loss, and the 60-min ask lock release frees uncommitted asks, but local git worktree state cannot be recovered remotely.
- **SPOF Risks**: Cloud Run Hub and Cloud SQL are single points of failure for fleet lease CAS, ask tracking, and cross-machine messaging. Concentrating all fleet roles on sat creates a single-VM failure domain.
- **Inventory Misses**: sat root disk is only 30 GB (23 GB free); CI runners, docker layers, and concurrent worktrees will exhaust it rapidly. sat disk must be resized to ≥100 GB. OOM risk also rises if runners and Chrome share 16 vCPUs with 20+ lanes.

## 2. Lanes Evaluation (L1–L9)
- **L1 (Lease ranking action)**: Agree. Essential prerequisite to anchor rank 0 on sat and eliminate flapping.
- **L2 (Holder-gated responder)**: Agree. Guarantees immediate "Seen" acks without duplicate replies.
- **L3 (Runners on sat)**: Agree. Unblocks workflow 10 quality gate when the PC is off; cap initial runners at 2.
- **L4 (PC-only crons to sat)**: Agree. Dev reconcile, weekly scan, and tmp cleanup must run on sat.
- **L5 (Headless Chrome e2e proof)**: Agree. Verifies headless browser dependencies in sat VM environment.
- **L6 (Keys to sat + check action)**: Agree. Necessary for release relays and backups; check action is safe.
- **L7 (Infra stack & lde on sat)**: Agree. Useful for self-contained validation; run on-demand to save memory.
- **L8 (15-min failover drill)**: Agree. Empirical verification of D1–D6 is required before trusting laptop shutdown.
- **L9 (do_spl_box_leave drain)**: Disagree. Laptops close abruptly; relying on manual drains fails. Hard failover resilience is what matters.

## 3. Owner Questions (Q1–Q10)
- **Q1 (sat rank 0 for all roles)**: Yes — Eliminates lease flapping and keeps orchestration continuous.
- **Q2 (box-rsp on sat, holder-gated)**: Yes — Delivers immediate "Seen" feedback without duplicate responses.
- **Q3 (Runner count on sat)**: 2 — Balances CI throughput on `e2-standard-16` without starving lane memory/CPU.
- **Q4 (Keep PC runners active)**: Yes — Provides opportunistic extra capacity whenever the PC is online.
- **Q5 (sat VM size)**: Stay `e2-standard-16` — But expand disk to ≥100 GB; upgrade CPU only if load > 20.
- **Q6 (Copy rel/bkp keys to sat)**: Yes — Enables unattended releases and backups when the PC is asleep.
- **Q7 (Run 15-min cut drill)**: Yes — Essential proof of D1–D6 failover behavior under simulated loss.
- **Q8 (Build L9 drain action)**: No — Abrupt shutdowns make drains unreliable; 20-min pushes are sufficient.
- **Q9 (PC still takes lanes)**: Yes — Good for local overflow, provided lanes push every 20 minutes.
- **Q10 (Move other project crons)**: Yes — Background watchdogs and credential backups should not stop with the PC.
