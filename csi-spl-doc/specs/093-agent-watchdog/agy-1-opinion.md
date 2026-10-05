# 093 Agent watchdog: opinion of panelist agy-1

**Reviewer**: agy-1 (AntiGravity panelist 1, lane `a-323`)  
**Topic**: t1 `340f3be9-bd64-4419-8267-cb1b8083d8ea` (HUM-10)  
**Spec lane / author**: c-318 (`csi-spl-doc/specs/093-agent-watchdog/spec.md`, commit `880524250`, v0.1 draft)  
**Target File**: `csi-spl-doc/specs/093-agent-watchdog/agy-1-opinion.md`  

---

## 1. Codebase Verification of the Incident & Cited Subsystems

Panelist agy-1 verified the claims of Section 1 and Section 9 against the active codebase:

1. **The Stall Rule Blindspot (`spl_lease_stall`)**:
   - Inspected `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` (lines 450–475).
   - `LEASE_STALL_RE_DEFAULT` includes `please run /login`, `usage limit reached`, and `oauth token expired`.
   - However, `spl_lease_stall` requires either a frozen spinner (`spin`) or an un-spun banner with an epoch reset time (`until="$(spl_lease_limit_until "$foot")"`). A login prompt presents neither a spinner nor a reset timestamp. Consequently, line 464 executes `return 0` with an empty string, reporting the dead agent as fully "able". The claim in Section 1 is confirmed.
2. **The Stuck Rule Blindspot (`spl_fleet_stuck` / `spl_lease_activity`)**:
   - Inspected `spl_fleet_stuck` (lines 1010–1025) and `spl_lease_activity` (lines 1028–1045).
   - Activity is calculated as the mtime of the newest transcript write. Because incoming pokes trigger prompt writes and subsequent API error lines (`isApiErrorMessage: true`) into the session transcript, every ping renewed the activity timestamp. Activity was conflated with progress, allowing an incapacitated agent to renew its lease for 6 hours.
3. **Subsystem Dependencies**:
   - Verified existence and API compatibility of `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` (rotation handoff, seed, spawn, retire) and `csi-spl-orc/src/bash/run/spl-peer-restart.func.sh`.
   - Verified alignment with `csi-spl-doc/specs/068-peer-seats/spec.md` (claim columns, `FOR UPDATE SKIP LOCKED`, fence) and `csi-spl-doc/specs/060-role-rotation/spec.md`.

---

## 2. Verdicts on the Three Core Questions

### Q1: Decentralization (Heartbeat Loop Service + Agent Intelligence, No SPoF)
- **Verdict**: **AGREE with Section 3 (The Four Layers)**, with an operational safety requirement on Layer 3 execution timeouts.
- **Rationale**:
  - The architecture successfully dissolves the fragile singleton orchestrator/dispatcher model into four decoupled layers:
    1. *Hub (Postgres)*: Central transactional state and concurrency arbiter.
    2. *Poll loops (Per-seat shell service)*: Staggered 5s loop offering free jobs and renewing locks conditional on model progress.
    3. *Watchdog (Per-box shell daemon)*: 30s local inspection daemon evaluating deterministic situation scripts (S1–S8).
    4. *Agents (Intelligence)*: Cognitive layer handling job evaluation, tool execution, topic context, and post-takeover root-cause analysis.
  - Eliminating dedicated orchestration roles prevents single-node lockups from stalling fleet throughput.
  - **Operational Requirement for Layer 3**:
    In `do_spl_watchdog`, situation scripts execute against all local agents. A stalled situation script (e.g. an unresponsive `/proc` access, hung `tmux capture-pane`, or slow regex scan) must never block the 30s watchdog tick for remaining seats. Every situation script invocation must be bounded by a strict execution timeout (e.g., `timeout 5s`).

### Q2: Which Agent Takes Which Job
- **Verdict**: **AGREE with Section 4.4 (Routing Rules)**; **CONCRETE REFINEMENT of Section 4.3 (Poller Selection Priority)**.
- **Rationale**:
  - Section 4.4 correctly establishes topic stickiness for thread continuity, routes lane reports to their spawner, delegates takeover investigations to alternative harnesses (preventing credential/provider blind spots), and reserves seats for dispatch while offloading heavy tasks to newly spawned lanes.
  - **Refinement to Section 4.3**:
    Section 4.3 proposes offering a new job to the "first able poller with room" among seats polling every 5s. However, under Section 5.3, any seat holding fewer than 3 jobs whose model is actively executing a lengthy tool turn is marked `fresh` and `ready`. If an offer is placed into the inbox of an agent 5 seconds into a 40-second tool turn, that agent will not accept until its turn completes. If it fails to respond within the 45s `offer_until` window, the job is delayed by 45s before the next seat is even offered the task.
  - **Concrete Modification**:
    The poll loop query for candidate seats must prioritize:
    1. `state = 'idle'` over `state IN ('working', 'in-tool')`.
    2. Least loaded seats: `cardinality(held) ASC`.
    3. Staggered time order.
    Routing offers to truly idle seats first ensures immediate tool-call acceptance (within 1–2s), satisfying the owner's "fastest response" principle without resorting to context-polluting token broadcasts.

### Q3: Unambiguous Claim Protocol (Offer, Accept, Races, Expiry)
- **Verdict**: **AGREE with Section 4.1 & 4.2 (Two-Phase Claim Protocol & Egress Fence)**.
- **Rationale**:
  - The two-phase protocol (T1 Offer by poll loop, T2 Accept by agent tool call) definitively solves the claim problem:
    - *Offer (T1)*: Code sets `responsible = seat`, `offer_until = now() + 45s`, increments `responsible_gen`. Atomicity is guaranteed by `FOR UPDATE SKIP LOCKED`.
    - *Accept (T2)*: Only a functioning model can issue the tool call `spool claim --accept <msg>`. Atomically verifies `responsible = me AND responsible_gen = gen AND offer_until >= now()`, setting `accepted_at` and `locked_until = now() + 120s`.
    - *Offer Expiry (T3)*: If the agent does not accept within 45s, `offer_until` lapses; the next poller moves it back to `FREE` and records the lapsed seat in `offered_to`.
    - *Lock Expiry (T5)*: If an agent ceases to emit progress heartbeats, its poll loop ceases renewing `locked_until`. At 120s, the lock lapses and any other seat re-offers the job.
    - *Egress Fence*: Late or zombie agents are blocked by the egress check (`responsible = me AND responsible_gen = gen`) on every outbound call, returning HTTP 409 and preventing split-brain or duplicate responses.
  - **Refinement on `offered_to` Array**:
    If transient network latency causes all active seats to let an offer lapse, `offered_to` must reset once `cardinality(offered_to) >= active_seat_count` to allow retries rather than immediately burning through `CLAIM_MAX` (4) into dead-letter.

---

## 3. Concrete Replacement of Section 7.3: AntiGravity (AGY) Integration

Section 7.3 of the draft characterizes AGY as:
> *"agy shows hooks.json, PreToolUse, PostToolUse, SessionStart but not additionalContext... heartbeat hooks only (no injection), unless its stdin stream (--input-format stream-json) proves a way in"*

This is inaccurate. Antigravity CLI provides native, first-class context injection and lifecycle gating via `hooks.json`:

1. **In-Turn Context Injection (`PreInvocation`)**:
   AGY supports `PreInvocation` hooks that accept execution context on stdin and return structured steps on stdout:
   ```json
   {
     "injectSteps": [
       {
         "ephemeralMessage": "[SPOOL INBOX] Offered job <msg_id> (gen <gen>). Accept with: run_command CommandLine='spool claim --accept <msg_id>'"
       }
     ]
   }
   ```
   This delivers inbox offers directly into the model's reasoning stream at the start of each turn.
2. **Deterministic Progress Accounting**:
   AGY emits `PreToolUse` and `PostToolUse` events with tool names, argument maps, and execution timestamps. Every tool invocation directly updates `progress_ts`, `state: in-tool / working`, and appends tool signatures for loop detection (S5).
3. **Completion Gating (`Stop`)**:
   AGY's `Stop` hook allows blocking termination if unhandled offers remain:
   ```json
   {
     "decision": "continue",
     "reason": "You have unaccepted offered jobs in your inbox; run 'spool claim --accept <msg_id>' or release them before stopping."
   }
   ```
4. **Conclusion**:
   AGY is a full Tier-1 harness supporting both progress heartbeat emissions and programmatic context injection. Section 7.3 must place AGY alongside Claude Code in Tier 1.

---

## 4. Property Scores (Draft vs agy-1 Refined)

| Property | Draft | agy-1 Refined | Justification |
|---|---|---|---|
| **robust** | 4 | 5 | Draft strictly ties liveness to model-produced work (fixing the 2026-10-05 trap); agy-1 elevates this by integrating native AGY `PreInvocation`/`Stop` hook contracts and adding watchdog subprocess timeouts. |
| **failover-proof** | 5 | 5 | Eradicates singleton orchestrator/dispatcher bottlenecks; any able seat on any host recovers orphaned jobs via 120s lock expiration with zero leader-election coordination. |
| **fast** | 4 | 5 | Draft achieves ~5s offers but risks 45s stalls on busy seats; agy-1's load-aware sorting (`idle` before `working`) guarantees sub-2s offer pickup without token-wasting broadcasts. |
| **scalable** | 4 | 5 | Hub load is strictly bounded at 0.2 QPS/seat via 5s staggered polling; local box watchdogs operate in O(agents) via zero-model file/pane inspection, scaling horizontally across N hosts. |
| **uninterruptible** | 4 | 4 | `PARKED` state protects long operations (builds, CI) from false watchdog evictions; slot takeovers preserve worktrees and handoffs; multi-host independence protects against box-level power loss. |

---

<!-- version: 0.1.0 · updated: 2026-10-05 · panelist: agy-1 -->
