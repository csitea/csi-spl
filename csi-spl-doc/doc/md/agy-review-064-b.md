# Antigravity (Gemini) Review: Spec 064 (Fleet Without the PC)

Operational and cost review of [spec 064](../../specs/064-fleet-without-the-pc/spec.md) by an Antigravity agent.

## 1. Operations & Cost Evaluation
- **CI runners on sat:** Cold caches for Go/pnpm will initially slow CI; cap runners at 2 (not 4) to avoid CPU/memory starvation while running 30+ agent lanes.
- **Keys & isolation:** Storing release and backup keys on a cloud VM hosting self-hosted runners creates exposure; ensure runner systemd units run under a dedicated OS user denied read access to `~/.gcp/.csi/`.
- **Browser/e2e lanes:** Headless Chrome on sat requires verified tmpfs/shm sizing and clean process teardown to prevent orphan memory leaks.
- **sat sizing:** Current `e2-standard-16` (shared core scheduler) will throttle under peak agent turns + CI race builds; keep 16 vCPU for initial migration, but prepare scaling to 32 vCPU.
- **The drill (15-min cut):** A 15-minute cut tests lease takeover, but does NOT prove uninterrupted development. It misses hourly role rotations (:05/:15), token quota window resets, daily cron runs, and long-term cache stability. A 4-hour soak test is required.

## 2. Lane Evaluation (L1–L9)
- **L1 (Lease ranking action): Agree.** Establishes sat as rank 0 across roles and ends failover flapping.
- **L2 (Holder-gated responder): Agree.** Prevents duplicate "Seen" replies while guaranteeing responsiveness.
- **L3 (sat runners registration): Agree with condition.** Limit to 2 runners initially to preserve lane headroom.
- **L4 (PC crons to sat): Agree.** Dev desk reconcile, weekly scan, and scratch sweep are vital to prevent disk exhaustion.
- **L5 (Headless Chrome proof): Agree.** Must precede routing any browser tasks to sat.
- **L6 (Keys out-of-band copy): Agree.** Minimal required keys (`-rel`, `bkp`) with chmod 0600 permissions.
- **L7 (Infra stack & dev LDE): Disagree/Defer.** Unnecessary overhead on sat; terraform apply is owner-gated.
- **L8 (Drill execution): Agree.** Run 15-min smoke drill, but schedule extended soak before production cutover.
- **L9 (do_spl_box_leave drain): Disagree.** Unnecessary complexity; the mandatory 20-min push cadence already protects work.

## 3. What is Missing
- **Disk headroom & cleanup:** sat has 23 GB free on root; CI caches and docker images will rapidly fill disk without an automated prune cron.
- **External watchdog:** If sat halts while the PC is off, monitoring must notify externally rather than depending on sat.

## 4. Answers to Owner Questions (Q1–Q10)
- **Q1:** Yes — sat at rank 0 for all roles ends lease ping-pong and keeps coordination active.
- **Q2:** Yes — holder-gating prevents duplicate acknowledgments.
- **Q3:** 2 runners — 4 will saturate CPU alongside 30+ active lanes.
- **Q4:** Yes — provides burst capacity whenever the PC is online.
- **Q5:** Stay `e2-standard-16` for phase 1; scale to 32 vCPUs once CI and browser lanes migrate.
- **Q6:** Yes — copy `-rel` and `bkp` keys with 0600 permissions, isolated from runner processes.
- **Q7:** Yes — 15-min smoke test first, followed by a scheduled 4-hour soak test.
- **Q8:** No — 20-minute push rule is sufficient; keep laptop sleep frictionless.
- **Q9:** Yes — let the PC take local interactive lanes when online.
- **Q10:** Yes — move monitoring watchdog and creds backup; defer non-essential warms.
