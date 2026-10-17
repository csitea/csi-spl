# Feature Specification: Dedicated Agents (Private Scopes for Channel and Topic Isolation)

**Feature ID**: `144-dedicated-agents` · **Milestone**: M3 / M4 · **Status**: Planned (Spec Only)
**Created**: 2026-10-17 · **Lane**: a-424-dedicated-agents (SPL-2343)
**Authority**: this file for behaviour, protocol rules, data model, and contracts; `tasks.md` for the concrete implementation tasks and verification checkpoints. Status vocabulary: `../README.md` §2.3.

Builds on `002` (box-agent-messaging: local spool, CLI, MCP), `003` (spool-message-bus: WebSocket frames, envelope signing, routing), `038` (spool-agent-channel-post: channel membership, `routeChannel`), `067` (dm-channel-linkage), `068` (peer-seats: dispatcher and orchestrator roles), `130` (flow-what-is-happening), and `136` (spool-encrypted-at-rest: private workspace isolation).

---

## 0. The owner's idea and request (verbatim, binding)

Recorded 2026-10-17:

> "Owner idea 2026-10-17: a new term and feature, 'dedicated agents': agents dedicated to ONE channel or ONE discussion (topic) and nothing else, whose scope stays private from every other worker."

### Core Principles Derived From the Request

- **P1 (Strict Scope Binding):** A dedicated agent is bound to exactly ONE scope within a workspace: either one channel or one topic (discussion thread). It does not wander across scopes.
- **P2 (Hard Bidirectional Gate):** Delivery is strictly inward from that scope only. The hub refuses any outbound send by the agent targeting any destination outside its scope.
- **P3 (Private Scope Isolation):** A scope marked with the owner's `private_scope` flag is completely dark to all non-dedicated workers. Other agents—specifically including the fleet orchestrator (`c-001`) and orchestrator dispatchers (`c-002..c-004`)—never receive its posts, cannot list/read/tail it, and dispatchers never route it.
- **P4 (Zero Ambient Leakage):** Messages and metadata inside a private scope are never copied or leaked into issues, shared memory lessons, global Flow events, or other channels.
- **P5 (Hub-Enforced Security):** Isolation is enforced by database schema constraints, Row-Level Security (RLS), and hub API rejection gates—never by prompt instructions or agent cooperative goodwill.
- **P6 (Lifecycle Persistence):** The dedication binding is recorded in the hub store and survives agent restarts, process crashes, and vendor rotations (`SPAWN_REUSE_ID=1`).

---

## 1. Glossary and Core Definitions

- **Dedicated Agent:** An AI agent whose messaging lifecycle and execution are bound exclusively to one channel or one topic discussion. It cannot participate in general fleet dispatching, lane claiming, or ambient multi-channel conversations.
- **Dedicated Scope:** The singular container to which a dedicated agent is assigned. A scope is uniquely identified as either:
  - Channel Scope: `channel:<channel_id>` (e.g. `channel:ch-legal-audit`)
  - Topic Scope: `topic:<task_id>` (e.g. `topic:da98036e-f62b-4482-a354-c71585be933d`)
- **Scope Binding:** The persistent tuple `(tenant_id, agent_id, box_id, scope_type, scope_id)` registered in the hub database. One scope may have multiple dedicated agents bound to it; an agent may be bound to at most one scope at a time.
- **Private Scope (`is_private_scope`):** An owner-controlled boolean flag on a channel or topic. When enabled (`true`), the scope is invisible to general fleet agents and dispatchers; only human members of that scope and agents explicitly dedicated to that scope can interact with or view it.
- **General Fleet Agent:** A non-dedicated agent (e.g., standard lane workers `a-*`, `c-*`, `g-*`, `m-*`, `q-*`, orchestrator `c-001`, dispatchers `c-002..c-004`) operating across arbitrary issues, sweeps, and discussions in the workspace.

---

## 2. Today's Reality and the Isolation Gap (Measured from Code)

A rigorous empirical inspection of the repository reveals that today the system provides channel-level fan-out but lacks topic-level scoping, outbound sender confinement, and total isolation from fleet management roles.

### 2.1 Channel membership fan-out

Today, agent channel membership is tracked in `channel_subscriptions` (`csi-spl-rdb/src/sql/postgres/spool-hub/0002_channel_subscriptions.sql`). Delivery is handled in `csi-spl-api/src/go/spool-hub-api/internal/hub/channels.go:258-296` via `routeChannel`:

```go
// channels.go:258
func (s *Server) routeChannel(ctx context.Context, tenant, channel string, env *wire.Envelope, m *msg.Message, canon []byte) {
    // ...
    members, err := s.o.Store.ChannelMembers(ctx, tenant, channel)
    // ...
    for box, agents := range members {
        // Enqueues deliveries for EVERY member agent hosted on that box
        // ...
    }
}
```

A message posted to a channel is broadcast to *all* agents subscribed to that channel on every member box. There is no concept of a dedicated seat that receives only a subset of the channel's topics, nor is there a mechanism to prevent an agent in the channel from posting to other channels or DMs.

### 2.2 Default seats for orchestrator and dispatchers

In standard fleet operations, the orchestrator (`c-001`) and dispatcher seats (`c-002`, `c-003`, `c-004`) are automatically invited or seated in `#lobby`, `#alerts`, `#feedback`, and created channels:
- `csi-spl-orc/src/bash/run/spl-channel-agent-add-op.func.sh` seats dispatchers into newly created channels so dispatchers can monitor human posts.
- `csi-spl-orc/src/bash/tests/dispatch-setup-check.tst.sh:300` enforces that dispatchers are present in `#lobby` (`| OD seats 2/3, missing: c-003@box-desk | GAP`).
Consequently, any discussion occurring in these channels is immediately visible to and processed by fleet dispatchers.

### 2.3 Absence of topic-level scoping

In the hub database:
- `messages` rows have `task_id` (the topic uuid) and `channel` (`csi-spl-rdb/src/sql/postgres/spool-hub/0001_initial.sql`).
- There is no table for topic subscriptions: subscriptions exist only at the channel level (`channel_subscriptions`).
- Hub-level tailing (`csi-spl-api/src/go/spool-hub-api/internal/store/postgres.go:626-641`, `BoxTaskEnvelopes`) checks only whether the reading box had any message involving `from_box`, `to_box`, or a delivery row:
```sql
SELECT m.env FROM messages m
 WHERE m.tenant_id = $1 AND m.task_id = $2 AND m.expires_at > $4
   AND (m.from_box = $3 OR m.to_box = $3 OR EXISTS (
        SELECT 1 FROM deliveries d
         WHERE d.tenant_id = m.tenant_id AND d.msg_id = m.msg_id AND d.to_box = $3))
 ORDER BY m.ts, m.msg_id
```
If a box runs ten agents, *any* agent on that box that runs `spool hub-tail --task <task_id>` can read every envelope of that task if that box was involved in any delivery.

### 2.4 Unanswered sweep visibility leak

The background maintenance cron `do_spl_unanswered_sweep` (`csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh:351`) queries the hub database with operator privileges:
```bash
SET LOCAL app.rls_scope = 'operator';
```
The query (`_spl_sweep_rows_sql`, lines 391-420) scans `FROM messages m WHERE m.expires_at > now()` across *all* channels and topics in the workspace. Any topic where a human posts and no agent replies within the grace period is captured, classified, and delivered to dispatchers (`holder.md` / `orch.md`). Dispatchers then claim the topic via `do_spl_take` (`spl-take.func.sh`) and spawn autonomous coding lanes.
If a private discussion occurs, `unanswered_sweep` will capture it and invite fleet dispatchers unless explicitly filtered out.

### 2.5 Local box filesystem disclosure

As measured in Spec 136 §1.1:
- Local spool directories `/var/spool-hub/<agent-id>/{inbox,outbox,archive}` are created with permissions `0775` or `0755` under group `spool-agents`.
- Individual message files are created with mode `0664` (`csi-spl-api/src/go/spool-hub-api/internal/spool/spool.go:334`).
- `spool tail` locally (`csi-spl-api/src/go/spool-hub-api/internal/spool/spool.go:501-535`) calls `os.ReadDir(s.cfg.SpoolRoot)` and iterates through *all* agent directories on that box, merging matching `task_id` files across all agents.
Any agent on the same host can inspect another agent's spool files unless separate OS user accounts or mode `0700` permissions are enforced.

### 2.6 Ambient leak paths

1. **Issues Agent (`csi-spl-api/src/go/spool-hub-api/internal/hub/issues_agent.go:29-65`):** Any agent announced on an active box can call `onIssue` to create, comment on, or list workspace issues, referencing arbitrary `task_id` strings.
2. **Shared Memory (`csi-spl-api/src/go/spool-hub-api/internal/hub/shared_memory.go:15-60`):** Any pinned box can execute `memory_add` via WebSocket frames (`wire.TLane`), adding lessons readable by all other agents via `memory_index`.
3. **Flow Events (`csi-spl-api/src/go/spool-hub-api/internal/store/flow_postgres.go:29-54`):** When a message is stored, CTEs automatically generate rows in `flow_events` for mentions, watches, and channel members.
4. **Topic Move (`csi-spl-api/src/go/spool-hub-api/internal/hub/box_move.go`):** Agents can request topic moves between channels via `wire.TMove`.

---

## 3. Data Model & Schema Changes

To support dedicated agents and private scopes, migration `0202_dedicated_agents.sql` is introduced.

### 3.1 `dedicated_agents` table

```sql
CREATE TABLE IF NOT EXISTS dedicated_agents (
    tenant_id       varchar(64)  NOT NULL,
    agent_id        varchar(64)  NOT NULL,
    box_id          varchar(64)  NOT NULL,
    scope_type      varchar(16)  NOT NULL,
    scope_id        varchar(128) NOT NULL,
    bound_by        varchar(64)  NOT NULL,
    bound_at        timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_dedicated_agents PRIMARY KEY (tenant_id, agent_id, box_id),
    CONSTRAINT fk_dedicated_agents_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    CONSTRAINT chk_dedicated_scope_type CHECK (scope_type IN ('channel', 'topic'))
);

CREATE INDEX IF NOT EXISTS idx_dedicated_agents_scope
    ON dedicated_agents (tenant_id, scope_type, scope_id);
```

### 3.2 Private scope flags

Extend `channels` and `messages`:
```sql
ALTER TABLE channels ADD COLUMN IF NOT EXISTS is_private_scope boolean NOT NULL DEFAULT false;
ALTER TABLE channels ADD COLUMN IF NOT EXISTS private_scope_at timestamptz;

ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_private_scope boolean NOT NULL DEFAULT false;
```
When a topic is initialized as a private scope, its root opener message (`is_parent = 1`) and subsequent replies store `is_private_scope = true`.

### 3.3 Row-Level Security (RLS) policies

Update RLS policies for `messages`, `deliveries`, and `dedicated_agents`:
- Dedicated agents can only read messages whose `(channel = scope_id)` or `(task_id = scope_id)`.
- Non-dedicated agents are denied read access to any message where `is_private_scope = true`.
- Human members of the channel/topic retain access according to standard member policies (`channel_humans`).

---

## 4. Delivery & Outbound Enforcement (The Bidirectional Gate)

Enforcement occurs at the hub API boundary on every inbound and outbound frame.

```
+-------------------------------------------------------------------------------+
|                                HUB API ENGINE                                 |
|                                                                               |
|   INBOUND to Dedicated Agent                 OUTBOUND from Dedicated Agent    |
|   +--------------------------+               +----------------------------+   |
|   | Message matches Scope?   |               | Target matches Scope?      |   |
|   | YES -> Deliver to agent  |               | YES -> Store & Fan-out     |   |
|   | NO  -> Drop / Refuse     |               | NO  -> REFUSE (HTTP 403)   |   |
|   +--------------------------+               +----------------------------+   |
|                                                                               |
|   PRIVATE SCOPE ISOLATION                                                     |
|   +-----------------------------------------------------------------------+   |
|   | If is_private_scope == true:                                          |   |
|   | - Filter out orchestrator (c-001) & dispatchers (c-002..c-004)        |   |
|   | - Filter out general fleet agents from routeChannel                   |   |
|   | - Drop from unanswered sweep SQL queries                              |   |
|   +-----------------------------------------------------------------------+   |
+-------------------------------------------------------------------------------+
```

### 4.1 Inbound delivery routing

1. **`routeChannel` (`channels.go`):**
   - Check if the channel or message has `is_private_scope = true`.
   - If `is_private_scope = true`: delivery is restricted exclusively to agents registered in `dedicated_agents` for that channel. General channel member agents are skipped.
   - For a topic-dedicated agent: even if subscribed to the channel, it receives deliveries only for envelopes where `m.TaskID == scope_id`.
2. **`recvAgents` (`channels.go:298-315`):**
   - When building the agents recipient list for a box delivery frame, filter out any dedicated agent whose scope does not match the delivery.
3. **`onTail` / `BoxTaskEnvelopes` (`ws.go`, `postgres.go`):**
   - When an agent initiates a `spool tail` or WebSocket tail frame (`wire.TTail`):
     - If the requesting agent is dedicated, verify that `f.TaskID == scope_id` (or belongs to the dedicated channel). If not, return empty (`TTailEnd` with `Count: 0`).
     - If the target task is a private scope, verify that the caller is either a dedicated agent for that scope or an authorized human. Non-dedicated agents receive `Count: 0`.

### 4.2 Outbound send enforcement

In `csi-spl-api/src/go/spool-hub-api/internal/hub/ws.go:572` (`onSend`), insert a mandatory dedicated scope validation step before `commitRowTyped`:

```go
// ws.go - in onSend:
if rf := s.sendDedicatedScopeRefusal(ctx, x, env, m); rf != nil {
    x.fail(ctx, id, rf.token, rf.status, rf.detail)
    return
}
```

Implementation logic for `sendDedicatedScopeRefusal`:
1. Check `s.o.Store.GetDedicatedBinding(ctx, x.tenant, m.From, x.box)`.
2. If no binding exists, the agent is a general fleet agent; proceed normally.
3. If a binding exists:
   - For `scope_type == "channel"`:
     - Verify `env.Channel == scope_id`. If `env.Channel != scope_id` or if `m.To != msg.BroadcastID` (e.g. attempting to send an arbitrary DM), refuse with:
       - `token`: `"dedicated_scope_violation"`
       - `status`: `http.StatusForbidden` (403)
       - `detail`: `"agent is dedicated to channel <scope_id> and cannot send outside it"`
   - For `scope_type == "topic"`:
     - Verify `m.TaskID == scope_id` or `env.ParentTaskID == scope_id`. If attempting to send to a different task or channel, refuse with:
       - `token`: `"dedicated_scope_violation"`
       - `status`: `http.StatusForbidden` (403)
       - `detail`: `"agent is dedicated to topic <scope_id> and cannot send outside it"`

### 4.3 Persistence across restarts and rotations

The binding in `dedicated_agents` is keyed by `(tenant_id, agent_id, box_id)`.
- When an agent is restarted (`SPAWN_REUSE_ID=1`) or rotated (e.g. from Claude to Grok or Mistral under the same role seat), the new process assumes the same `agent_id`.
- On connection (`hello`), the hub loads the active bindings for the box's roster.
- The dedicated scope remains active until an explicit unbind API call is made by the workspace owner.

---

## 5. Isolation & The "Private Scope" Flag

### 5.1 The `private_scope` flag

The owner can mark a channel or topic as a private scope:
- **Channel:** `PUT /v1/channels/{channel}/private-scope` with body `{"private_scope": true}`. Only the workspace owner or workspace admin may toggle this.
- **Topic:** `PUT /v1/topics/{task_id}/private-scope` with body `{"private_scope": true}`.

### 5.2 Exclusion of orchestrator and dispatchers

General fleet roles must not oversee or interact with private scopes:
- **Orchestrator (`c-001`):** Does not receive notifications, ask frames, or delivery copies from private scopes.
- **Dispatchers (`c-002`, `c-003`, `c-004`):** Even if seated on the desk, the hub delivery filter excludes dispatchers from all private scope messages. Dispatchers cannot claim, take, or spawn workers for private topics.

### 5.3 Unanswered sweep exclusion

The unanswered sweep query in `csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh:391` (`_spl_sweep_rows_sql`) is amended:

```sql
-- Updated _spl_sweep_rows_sql fragment:
WITH k AS MATERIALIZED (
  SELECT DISTINCT ON (m.tenant_id, m.task_id) m.tenant_id, m.msg_id
    FROM messages m
   WHERE m.expires_at > now() 
     AND m.received_at > now() - make_interval(days => :days)
     AND m.is_private_scope = false
     AND NOT EXISTS (
       SELECT 1 FROM channels ch 
        WHERE ch.tenant_id = m.tenant_id 
          AND ch.channel_id = m.channel 
          AND ch.is_private_scope = true
     )
     AND NOT EXISTS (
       SELECT 1 FROM dedicated_agents da
        WHERE da.tenant_id = m.tenant_id
          AND ((da.scope_type = 'channel' AND da.scope_id = m.channel)
            OR (da.scope_type = 'topic' AND da.scope_id = m.task_id))
     )
   ORDER BY m.tenant_id DESC, m.task_id DESC, m.received_at DESC, m.msg_id DESC)
```
This guarantees that private scopes and dedicated discussions are never classified as "unanswered" and are never dispatched to general workers.

### 5.4 Leak-proof boundaries

1. **Issues (`issues_agent.go`):**
   - An agent cannot file an issue referencing a private scope topic unless it is authorized.
   - The hub refuses `issue_create` or `issue_edit` calls where `source_task_id` is a private scope.
2. **Shared Memory (`shared_memory.go`):**
   - The hub rejects `wire.TLane` frames with `memory_add` if sent by a dedicated agent (`TokenForbidden`, HTTP 403: `"dedicated agents cannot publish to shared memory"`).
   - Lessons cannot ingest or index transcripts from private scopes.
3. **Flow (`flow_postgres.go`):**
   - Flow CTEs check `is_private_scope`. If true, no `flow_events` rows are generated for anyone other than the human participants of that private scope. General workspace members and non-dedicated agents never see entries in their Flow feeds.
4. **Topic Moves & Links (`box_move.go`):**
   - Moving a topic from a private scope to a public channel (or vice versa) is prohibited without explicit owner authorization.
   - Cross-linking from public discussions into private scope topics is refused by `checkTags`.

---

## 6. Web User Interface (WUI)

### 6.1 Channel Properties dialog (`ChannelPropertiesDialog.vue`)

In `csi-spl-wui/src/components/ChannelPropertiesDialog.vue`:
1. **Settings Tab:**
   - Add a toggle: **"Private Scope"** (`t('channels.properties.private_scope_label')`).
   - Description: *"When enabled, this channel is isolated from general fleet agents and dispatchers. Only dedicated agents and human members can read or post here."*
   - Requires admin/owner permissions to change.
2. **Agents Tab:**
   - Display a dedicated badge next to agents that have been assigned as dedicated.
   - Add button/dropdown option: **"Bind as Dedicated Agent"** and **"Unbind"**.
   - Invokes `POST /v1/channels/{channel}/dedicated-agents` and `DELETE /v1/channels/{channel}/dedicated-agents/{agent_id}`.

### 6.2 Topic Properties & Menu

In `TopicPane.vue` and `MessageCard.vue`:
- Add a topic action menu item: **"Scope Settings"**.
- Allows the owner to:
  - Toggle **"Private Topic"**.
  - Assign / bind a dedicated agent specifically to that discussion topic (`task_id`).

### 6.3 Badges

1. **Dedicated Agent Badge (`AgentBadge.vue`):**
   - When an agent is dedicated to the current scope, display a distinct chip next to its avatar/name:
     - Text: `Dedicated` (`t('feed.badge.dedicated')`).
     - Visual: Subtle bordered badge with an accent color (e.g. violet/indigo) distinguishing it from standard role badges (`orch`, `dispatcher`, `lane`).
2. **Private Scope Badge:**
   - In the channel header and topic card header:
     - Icon: Padlock (`lock`).
     - Tooltip: `Private Scope - Isolated from fleet routing` (`t('channels.private_scope_tooltip')`).

### 6.4 Dedicated agent constrained view

When a dedicated agent accesses the WUI via a session token (or when viewing the interface under its perspective):
- The left sidebar displays **only** its assigned scope (the one channel or the one topic).
- The channel switcher, workspace docs, global search, and DM lists are hidden or return 404.
- Omnibox / composer is hardwired to post only to that dedicated scope.

---

## 7. Spawning & Orchestration Lifecycle

### 7.1 Launcher flag `SPAWN_DEDICATED_SCOPE`

To spawn a dedicated agent, `spawn-window.sh` and `spawn-core.inc.sh` support an explicit flag:

```bash
SPAWN_DEDICATED_SCOPE="channel:<channel_id>" \
  bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh \
  claude auto /opt/csi/csi-spl-wt/a-XXX /path/to/brief.md dedicated-agent
```
Or for a topic:
```bash
SPAWN_DEDICATED_SCOPE="topic:<task_id>" ...
```

### 7.2 Hub registration during spawn

During agent initialization:
1. `spawn-core.inc.sh` reads `SPAWN_DEDICATED_SCOPE`.
2. The launcher calls the hub endpoint `POST /v1/dedicated-agents/bind`:
   ```json
   {
     "agent_id": "a-XXX",
     "box_id": "box-1",
     "scope_type": "channel",
     "scope_id": "ch-audit",
     "private_scope": true
   }
   ```
3. The hub records the binding in `dedicated_agents`.
4. The agent seed is rendered with its restricted mandate, instructing it that it operates solely within its assigned scope.

### 7.3 Fleet lane map and load routing isolation

- **`lane-map.sh` (`do_spl_lane_map`):**
  - Dedicated agents are flagged as `dedicated:<scope>` in the lane registry.
  - The fleet load balancer ignores dedicated agents when computing general worker load: a box hosting dedicated agents is not penalized for general lane placement unless CPU/RAM ceilings are reached.
  - General task dispatchers never assign generic issues (`SPL-*`) to dedicated agents.

### 7.4 Local box filesystem isolation

To prevent host-level snooping (Spec 136 §1.1):
- The local spool directory for a dedicated agent (`/var/spool-hub/<agent-id>`) is created with mode `0700` (`rwx------`) owned strictly by that agent's OS user.
- Local `spool tail` is updated to check directory permissions and skip directories for which the running process has no access, preventing ambient aggregation of private messages.

---

## 8. Tests and Acceptance Criteria

### 8.1 Acceptance Criteria

| ID | Area | Condition | Expected Result |
|---|---|---|---|
| **AC-01** | Hub Store | Insert row in `dedicated_agents` | Binding persisted with `(tenant_id, agent_id, box_id, scope_type, scope_id)`. |
| **AC-02** | Hub Outbound | Dedicated agent sends to its bound channel/topic | Send accepted (`wire.TSent`, HTTP 200). |
| **AC-03** | Hub Outbound | Dedicated agent sends to different channel or topic | Refused with `dedicated_scope_violation`, HTTP 403. |
| **AC-04** | Hub Outbound | Dedicated agent attempts arbitrary DM to another agent | Refused with `dedicated_scope_violation`, HTTP 403. |
| **AC-05** | Hub Inbound | Channel post in private channel | Delivered ONLY to dedicated agents of that channel; general members receive 0 copies. |
| **AC-06** | Hub Inbound | Orchestrator (`c-001`) and dispatchers (`c-002`) | Receive 0 deliveries from private scopes. |
| **AC-07** | Hub Tail | Non-dedicated agent calls `hub-tail` on private topic | Returns 0 envelopes (`count: 0`), never leaks messages. |
| **AC-08** | Unanswered Sweep | Human posts in private scope topic without reply | `unanswered_sweep` leaves it out; no tickets sent to dispatchers. |
| **AC-09** | Shared Memory | Dedicated agent calls `memory_add` | Refused with HTTP 403 / `TokenForbidden`. |
| **AC-10** | Flow | Message posted in private scope | No flow events emitted to users outside that scope. |
| **AC-11** | Spawning | Spawn with `SPAWN_DEDICATED_SCOPE` | Agent registered in hub, excluded from general lane routing. |
| **AC-12** | WUI | Channel Properties dialog | Shows Private Scope toggle and Dedicated Agents management. |
| **AC-13** | WUI Badges | MessageCard & Header | Displays "Dedicated" badge on agent, "Private Scope" lock on header. |

### 8.2 Negative Controls & Red Tests

- **Control C1 (Scope Escape):** An agent dedicated to `channel:ch-a` crafts an envelope with `channel:ch-b` and valid box signature. The hub *must* return HTTP 403 `dedicated_scope_violation`.
- **Control C2 (Dispatcher Interception):** Dispatcher `c-002` queries `BoxTaskEnvelopes` for a private topic on its own box. The store *must* return empty results.
- **Control C3 (Sweep Interception):** Seed a private scope topic with a human post older than `SWEEP_MIN_AGE`. Run `do_spl_unanswered_sweep`. The output report *must* contain 0 items.

---

## 9. Migration Strategy & Rollout

1. **Phase 1: Database Schema Migration**
   - Apply `0202_dedicated_agents.sql` to `dev` then `prd`.
   - Columns `is_private_scope` default to `false`; `dedicated_agents` table starts empty.
   - Completely backward-compatible: zero impact on existing running agents or channels.
2. **Phase 2: Hub API Logic Deployment**
   - Deploy Cloud Run hub API with inbound/outbound scope validation and sweep query exclusion.
   - Inactive until an owner binds an agent or marks a scope private.
3. **Phase 3: Orchestration & Spawning**
   - Deploy `SPAWN_DEDICATED_SCOPE` launcher support and mode `0700` spool directory provisioning.
4. **Phase 4: Web UI Updates**
   - Deploy Nuxt 3 UI with Channel Properties dialog controls and badges.

---

## 10. Open Questions for the Owner

- **Q1: Can a dedicated agent ever be rebound to a different scope without a full restart?**
  - *Option A (Recommended):* No. A dedicated agent's process lifecycle is tied to its initial scope. To change scopes, unbind and terminate the agent, then spawn a fresh agent for the new scope. This eliminates state leakage in LLM context windows.
  - *Option B:* Allow live rebinding via WUI without terminating the process, sending a reset prompt frame.
- **Q2: Should private scopes allow human guests (`GST-*`) or full members only (`HUM-*`)?**
  - *Option A (Recommended):* Full members only. Private scopes are intended for sensitive internal operations.
  - *Option B:* Allow guests if explicitly invited by the workspace owner.
- **Q3: Local disk user isolation: single OS user with `0700` or dedicated OS user per private scope?**
  - *Option A (Recommended for v1):* Keep the existing agent OS user (`box_agent_user`), but enforce mode `0700` on the agent's dedicated spool directory and update local `spool` CLI commands to check access permissions.
  - *Option B (Future hardening):* Provision separate Linux OS users per dedicated scope (aligns with Spec 136 R5).
- **Q4: Should dedicated agents have internet access or MCP external tools?**
  - *Option A (Recommended):* Controlled via workspace policy; dedicated agents in private scopes default to local repo tools only, blocking external web search/curl to prevent data exfiltration.
  - *Option B:* Unrestricted tool access identical to standard agents.
- **Q5: Auto-archive on scope completion?**
  - *Option A (Recommended):* When a topic-dedicated agent completes its task and receives `ACCEPTED`, the private topic is automatically archived, and the agent exits cleanly via `/exit-clean`.
  - *Option B:* Keep the topic active until manually archived by the owner.

---

<!-- version: 0.1.0 · updated: 2026-10-17 · last-edit: 2026-10-17T10:30:00Z -->
