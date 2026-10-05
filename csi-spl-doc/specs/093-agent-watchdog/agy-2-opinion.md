# 093 Opinion: AntiGravity Panelist 2 (agy-2)

Status: **Independent Opinion**, 2026-10-05  
Panelist: **agy-2** (AntiGravity Panelist 2, agent `a-324`)  
Topic: t1 `340f3be9-bd64-4419-8267-cb1b8083d8ea` (HUM-10)  
Target Spec: `csi-spl-doc/specs/093-agent-watchdog/spec.md` at commit `880524250` (draft v0.1 by claude-1 / c-318)

---

## 1. Verification of Draft Claims Against Real Code

The v0.1 draft's diagnosis of the 2026-10-05 incident and its architectural citations were audited directly against the live implementation:

1. **`spl_lease_stall` blindness (`csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` lines 450–475):**  
   Confirmed. In lines 462–466, when an error banner matches `LEASE_STALL_RE` (which contains `please run /login`) but no moving spinner is detected (`-z "$spin"`), the code invokes `until="$(spl_lease_limit_until "$foot")"`. For a login screen, there is no reset timestamp, leaving `until` empty. Consequently, the function prints nothing and returns 0, which `spl_lease_agent_able` interprets as "able".
2. **`spl_fleet_stuck` / `spl_lease_activity` reset (`csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` lines 1010–1041):**  
   Confirmed. `spl_lease_activity` determines last activity by taking the newest mtime among `~/.claude/projects/*/*.jsonl`. When a poke arrives, Claude CLI writes both the user prompt and the immediate `Login expired` error reply into the JSONL transcript. This bumps `act` to `now`, resetting the idle timer and ensuring `oldest` unread inbox files are never older than `act`. Thus, the 600 s threshold is never triggered despite the agent being completely dead.
3. **Session Takeover Reusability (`csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh` & `spl-peer-restart.func.sh`):**  
   Confirmed. `spl_peer_restart_spawn`, `spl_rotate_handoff`, and `peer/restart.lock` provide production-tested primitives for teardown, state capture, and in-place respawn under identical agent identity, validating Section 8's design.

---

## 2. Answers to the Core Questions

### Q1. Decentralization: Simple Heartbeat Loop + Agent Intelligence (No Single Point of Failure)

**Verdict: AGREE with Section 3 and Section 6.**

- **Elimination of Single Point of Failure:** Removing the singleton orchestrator/dispatcher lease holder role and moving to four autonomous layers completely eliminates the vulnerability exposed on 2026-10-05.
- **Clear Separation of Concerns:**
  - *Layer 1 (Hub Postgres):* Authoritative lock and state transitions via row-level locks (`FOR UPDATE SKIP LOCKED`).
  - *Layer 2 (Seat Poll Loop):* Autonomous 5 s shell loop per seat offering free jobs and renewing 120 s TTL locks solely when the local heartbeat is fresh.
  - *Layer 3 (Watchdog):* Autonomous 30 s box-local daemon evaluating situation scripts S1–S8 and handling session recovery.
  - *Layer 4 (Agents):* Model intelligence dedicated to triage, execution, spawning lanes, and investigating takeovers.
- **Decoupled Job Movement:** Crucially, job reassignment does NOT depend on Layer 3 watchdog health. If a seat freezes, Layer 2 lock renewal ceases, and the job automatically reverts to `FREE` at `locked_until` (T5, 120 s), allowing any peer seat on any box to claim it.

---

### Q2. Which Agent Takes Which Job

**Verdict: AGREE with Section 4.3 and Section 4.4.**

- **Fastest Response Without Broadcast Storms:** Naive broadcast to all agents wastes context tokens and produces stampedes. Staggered 5 s polling across seats (averaging ~1.25 s latency) gives the first able poller a 45 s offer window (`offer_until`), achieving the owner's goal of fast claiming while maintaining order.
- **Topic Stickiness:** Routing follow-up messages in an owned topic to the existing owner seat preserves conversational memory and reasoning context, preventing disjointed thrashing across seats.
- **Harness Diversity in Failure Investigation:** Routing takeover blocker jobs (`wd-<id>-<rid>`) to an able seat of a *different* harness prevents shared blind spots (such as fleet-wide auth provider outages) from paralyzing investigation.
- **Lane Offloading:** Heavy implementation work remains delegated to ephemeral task lanes, keeping general seats responsive.

---

### Q3. An Unambiguous Claim Protocol (Who Claims, How, Race Resolution, Expiry)

**Verdict: AGREE with Section 4.1 and Section 4.2, with CONCRETE REPLACEMENTS for Section 5.3 and Section 7.3.**

- **Two-Phase Claim Architecture:** Splitting claim into code-driven `OFFERED` (T1) and agent-driven `OWNED` (T2 via tool call `spool claim --accept <msg>`) solves the fundamental flaw of 068, ensuring no dead model can own a job.
- **Race Resolution:** Postgres atomic row lock (`FOR UPDATE SKIP LOCKED`) ensures zero race conditions during polling. Transition T2 enforces `responsible = me AND responsible_gen = gen AND offer_until >= now()`.
- **Fencing on Late Resumption:** Generation fencing (`responsible_gen`) enforced at every outward action (`do_spl_peer_fence`) stops zombie agents from performing duplicate external operations after a 120 s timeout.

---

## 3. Concrete Replacements and Amendments

### Replacement for Section 7.3: Native AntiGravity (AGY) Lifecycle Hook Integration

The draft v0.1 in Section 7.3 asserts that AGY lacks `additionalContext` and must be restricted to "heartbeat hooks only (no injection)". This is incorrect. AntiGravity's customization engine natively supports lifecycle hooks via `hooks.json` (`.agents/hooks.json` or `~/.gemini/config/hooks.json`):

1. **Native Context Injection via `PreInvocation`:**  
   AGY supports `PreInvocation` command hooks that receive session metadata on `stdin` and return `injectSteps` on `stdout`:
   ```json
   {
     "injectSteps": [
       {
         "ephemeralMessage": "SPOOL INBOX: [msg_id: ... from: ... task_id: ...]\nAccept with: spool claim --accept <msg_id>"
       }
     ]
   }
   ```
   This injects inbox offers directly into model context at turn boundary without requiring streaming JSON or terminal stuffing.
2. **Preventing Premature Exit via `Stop` Hook:**  
   AGY supports a `Stop` lifecycle hook returning:
   ```json
   {
     "decision": "continue",
     "reason": "Unaccepted spool offers pending in inbox. Accept or release before stopping."
   }
   ```
   This mirrors Claude's stop-blocking capability to prevent an agent from exiting while jobs remain offered.
3. **Execution Heartbeat via `PreToolUse` and `PostToolUse`:**  
   AGY command hooks run synchronously around tool execution, providing exact timestamps and tool signatures to atomically update `<spool root>/<id>/heartbeat.json`.

**Section 7.3 Harness Parity Table (Replacement):**

| Harness | Injection Hook Mechanism | Stop Intercept Mechanism | Heartbeat Driver |
|---|---|---|---|
| **claude** | `additionalContext` in `UserPromptSubmit` / `PostToolUse` | `Stop` hook returns blocking message | `PreToolUse` / `PostToolUse` hooks |
| **agy** | `PreInvocation` hook returning `injectSteps` (`ephemeralMessage`) | `Stop` hook returning `decision: "continue"` | `PreToolUse` / `PostToolUse` hooks |
| **grok** / **qwen** | S8 fallback / poke + `spool recv` until ping test passes | S8 poll check | Process transcript / hook script |

---

### Amendment to Section 5.3: Multi-Harness Turn Progress Detection

Section 5.3's definition of **fresh** relies partly on Claude's pane spinner timer (`… (12s)`). AntiGravity does not render Claude spinner glyphs.

**Rule Amendment:**
- For AGY seats, long turn activity without intermediate tool calls (deep reasoning / large generation) is considered **fresh** if:
  1. `turn_since` was updated by `PreInvocation` within 120 s; OR
  2. The agent's transcript (`brain/<id>/.system_generated/logs/transcript.jsonl`) has recorded an append or ongoing thinking block within 45 s; OR
  3. The agent process is actively consuming CPU time in `/proc/<pid>/stat`.
This removes Claude CLI formatting coupling from Layer 2's heartbeat freshness check.

---

## 4. Scores

### Scores for Draft v0.1

| Property | Score | Why |
|---|---|---|
| **robust** | 4 | Distinguishing model progress from prompt/error writes solves the core issue; slight fragility from Claude-specific spinner regex. |
| **failover-proof** | 5 | Fully eliminates orchestrator/dispatcher single points of failure via peer polling and 120 s lock expiry. |
| **fast** | 4 | Staggered 5 s polling yields ~1.25 s offer latency; 45 s accept window and 120 s takeover ceiling meet requirements. |
| **scalable** | 4 | O(1) polling per seat at 0.2 Hz; watchdog is box-local and requires zero cross-box chat. |
| **uninterruptible** | 4 | Generation fencing prevents split-brain duplicate actions; handoff preserves session state. |

### Scores with AGY-2 Replacements (Native AGY Hooks + Multi-Harness Turn Detection)

| Property | Score | Why |
|---|---|---|
| **robust** | 5 | Native AGY hook parity and harness-agnostic turn detection remove single-vendor formatting dependencies. |
| **failover-proof** | 5 | Heterogeneous peer mesh (Claude, AGY, Grok) fail over across seats and boxes without single-vendor trap. |
| **fast** | 4 | Preserves deterministic 1.25 s offer discovery and 120 s recovery guarantees. |
| **scalable** | 5 | Native `PreInvocation` and `Stop` hooks avoid polling/terminal-scraping overhead on AGY seats. |
| **uninterruptible** | 5 | Strong hub generation fencing combined with robust multi-harness takeover ensures continuous 24/7 autonomous flow. |

---

## 5. Summary Verdict

1. **Q1 (Decentralization):** AGREE. Four-layer architecture eliminates single point of failure.
2. **Q2 (Job Assignment):** AGREE. First able poller for new topics, topic stickiness for follow-ups, cross-harness takeover investigations.
3. **Q3 (Claim Protocol):** AGREE with two-phase claim and fencing; REPLACE Section 7.3 to incorporate native AGY `PreInvocation` injection and `Stop` hooks; AMEND Section 5.3 for multi-harness turn freshness.
4. **Draft Scores:** Robust: 4, Failover-proof: 5, Fast: 4, Scalable: 4, Uninterruptible: 4.
5. **Replacement Scores:** Robust: 5, Failover-proof: 5, Fast: 4, Scalable: 5, Uninterruptible: 5.
