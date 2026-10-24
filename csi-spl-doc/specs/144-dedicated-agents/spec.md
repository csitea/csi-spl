# Feature Specification: Dedicated Agents (Private Scopes for Channel and Topic Isolation)

**Feature ID**: `144-dedicated-agents` · **Milestone**: M3 / M4 · **Status**: Partial (T001, T002, T006 landed on master: ce5da1d59, 3be78e1fd, e0f02e7ff)
**Created**: 2026-10-17 · **Updated**: 2026-10-19 · **Lanes**: a-424-dedicated-agents (SPL-2343), a-778-dedicated-agents (SPL-2585)
**Authority**: this file for behaviour, protocol rules, data model, and contracts; `tasks.md` for the concrete implementation tasks and verification checkpoints. Status vocabulary: `../README.md` §2.3.

Builds on `002` (box-agent-messaging: local spool, CLI, MCP), `003` (spool-message-bus: WebSocket frames, envelope signing, routing), `025` (spool-tenant-rbac: workspace roles and permissions), `038` (spool-agent-channel-post: channel membership, `routeChannel`), `067` (dm-channel-linkage), `068` (peer-seats: dispatcher and orchestrator roles), `115` (vendor-lane-mix: kind table and vendor defaults), `130` (flow-what-is-happening), and `136` (spool-encrypted-at-rest: private workspace isolation).

---

## 0. The owner's idea and request (verbatim, binding)

Recorded 2026-10-17:

> "Owner idea 2026-10-17: a new term and feature, 'dedicated agents': agents dedicated to ONE channel or ONE discussion (topic) and nothing else, whose scope stays private from every other worker."

Recorded 2026-10-17 (HUM-10, t1 1d76d339, msg 1d031b1c-9d9b-4994-864f-892946273ffe):

> "it should be possible for users to have a dedicated agent in a discussion from right click properties on a discussion , but with a configurable amount of being iddle with no input will dismiss this agent - the default should be 1hour ... , because idle agents consume resources"

Recorded 2026-10-17 (Follow-up msg edf8e150-3e1f-4805-9612-788be3e8765d):

> "and if users are abusing this fesature - after 3 abuses they should be warned about it , after 5 once again and after 6 completely banned from the feature ..."

Recorded 2026-10-17 (Follow-up msg d8adaced-c6a7-469d-8f8d-4ebeb6d36ee4 - Abuse definition poll decision):

> "Dedicating an agent , but than not using it for more than 1h ... ( confiurable amount of time with default of 1h )"

Recorded 2026-10-17 (Follow-up msg 3c233ec5-da7c-4ae6-b331-e191c0806d8c):

> "i.e. users must understand that reserving agents is expensive"

### Core Principles Derived From the Request

- **P1 (Strict Scope Binding):** A dedicated agent is bound to exactly ONE scope within a workspace: either one channel or one topic (discussion thread). It does not wander across scopes.
- **P2 (Hard Bidirectional Gate):** Delivery is strictly inward from that scope only. The hub refuses any outbound send by the agent targeting any destination outside its scope.
- **P3 (Private Scope Isolation):** A scope marked with the owner's `private_scope` flag is completely dark to all non-dedicated workers. Other agents—specifically including the fleet orchestrator (`c-001`) and orchestrator dispatchers (`c-002..c-004`)—never receive its posts, cannot list/read/tail it, and dispatchers never route it.
- **P4 (Zero Ambient Leakage):** Messages and metadata inside a private scope are never copied or leaked into issues, shared memory lessons, global Flow events, or other channels.
- **P5 (Hub-Enforced Security):** Isolation is enforced by database schema constraints, Row-Level Security (RLS), and hub API rejection gates—never by prompt instructions or agent cooperative goodwill.
- **P6 (Lifecycle Persistence):** The dedication binding is recorded in the hub store and survives agent restarts, process crashes, and vendor rotations (`SPAWN_REUSE_ID=1`).
- **P7 (Explicit Resource Cost Transparency):** Reserving a dedicated agent allocates dedicated compute and an agent seat while it waits. Reserving agents is expensive. Users are explicitly informed before confirmation of this resource cost, the idle timeout, and the abuse rules (3 / 5 / 6).
- **P8 (Automatic Idle Reclamation):** An agent dedicated to a discussion that receives zero new input (human post or message to the agent) within the configured idle timeout (default 1 hour) is automatically dismissed via clean exit (`/exit-clean`) to free its seat.
- **P9 (Graduated Abuse Enforcement):** Dedicating an agent without utilizing it before idle timeout constitutes an abuse. Accumulating abuses triggers code-generated system warnings at 3 and 5 abuses, and a hard feature ban at 6 abuses, revocable only by the workspace owner.

---

## 1. Glossary and Core Definitions

- **Dedicated Agent:** An AI agent whose messaging lifecycle and execution are bound exclusively to one channel or one topic discussion. It cannot participate in general fleet dispatching, lane claiming, or ambient multi-channel conversations.
- **Dedicated Scope:** The singular container to which a dedicated agent is assigned. A scope is uniquely identified as either:
  - Channel Scope: `channel:<channel_id>` (e.g. `channel:ch-legal-audit`)
  - Topic Scope: `topic:<task_id>` (e.g. `topic:da98036e-f62b-4482-a354-c71585be933d`)
- **Scope Binding:** The persistent tuple `(tenant_id, agent_id, box_id, scope_type, scope_id)` registered in the hub database. One scope may have multiple dedicated agents bound to it; an agent may be bound to at most one scope at a time.
- **Private Scope (`is_private_scope`):** An owner-controlled boolean flag on a channel or topic. When enabled (`true`), the scope is invisible to general fleet agents and dispatchers; only human members of that scope and agents explicitly dedicated to that scope can interact with or view it.
- **General Fleet Agent:** A non-dedicated agent (e.g., standard lane workers `a-*`, `c-*`, `g-*`, `m-*`, `q-*`, orchestrator `c-001`, dispatchers `c-002..c-004`) operating across arbitrary issues, sweeps, and discussions in the workspace.
- **Discussion Properties / Context Menu:** The contextual properties panel for a topic/discussion accessed via desktop right-click or mobile long-press / kebab menu on a topic card or thread list entry.
- **Discussion Idle Timeout:** The duration of inactivity (absence of human posts or agent messages in that topic) after which the dedicated agent is dismissed. Configurable per discussion, defaults to 1 hour (3600 seconds).
- **Idle Dedicated Agent:** An active dedicated agent whose bound topic has observed no new messages for the duration of the discussion idle timeout.
- **Unused Dedicated Agent (Abuse Event):** An agent dedicated to a topic that is dismissed by idle timeout having received zero interactions (prompts, replies, task instructions) since dedication.
- **Dedicated Abuse Counter:** The persistent per-user, per-workspace integer tally of unused dedicated agent dismissals.
- **Feature Ban:** Workspace-level revocation of the ability to bind dedicated agents, triggered upon reaching 6 recorded abuses.

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

To support dedicated agents, private scopes, idle dismissal, and abuse tracking, migrations `0202_dedicated_agents.sql` and `0203_dedicated_idle_and_abuses.sql` are introduced.

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

### 3.4 Discussion idle configuration and abuse accounting (`0203_dedicated_idle_and_abuses.sql`)

```sql
-- Migration 0203_dedicated_idle_and_abuses.sql

-- Discussion idle configuration & tracking
ALTER TABLE messages ADD COLUMN IF NOT EXISTS idle_timeout_seconds integer NOT NULL DEFAULT 3600;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS last_activity_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE messages ADD COLUMN IF NOT EXISTS dedicated_interaction_count integer NOT NULL DEFAULT 0;

-- Abuse accounting per user per workspace
CREATE TABLE IF NOT EXISTS dedicated_agent_abuses (
    tenant_id       varchar(64)  NOT NULL,
    human_id        varchar(64)  NOT NULL,
    abuse_count     integer      NOT NULL DEFAULT 0,
    is_banned       boolean      NOT NULL DEFAULT false,
    banned_at       timestamptz,
    banned_by       varchar(64),
    unbanned_at     timestamptz,
    unbanned_by     varchar(64),
    last_abuse_at   timestamptz,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_dedicated_agent_abuses PRIMARY KEY (tenant_id, human_id),
    CONSTRAINT fk_dedicated_agent_abuses_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    CONSTRAINT chk_abuse_count_nonnegative CHECK (abuse_count >= 0)
);

CREATE INDEX IF NOT EXISTS idx_dedicated_agent_abuses_banned
    ON dedicated_agent_abuses (tenant_id, is_banned)
    WHERE is_banned = true;
```

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

### 6.2 Topic Properties & Context Menu

In `TopicPane.vue` and `MessageCard.vue`:
- Add a context menu (desktop right-click and mobile long-press / kebab menu) providing: **"Discussion Properties"** (`t('topic.properties.menu_item')`).
- Opens a dedicated modal / drawer with tabs:
  - **Scope Settings**: Toggle **"Private Topic"** (`is_private_scope`).
  - **Dedicated Agent**: Manage dedicated agent for this discussion topic (`task_id`), select vendor, configure idle timeout, inspect live agent state, or dismiss the agent.

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
SPAWN_DEDICATED_SCOPE="channel:<channel_id>"   bash csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh   claude auto /opt/csi/csi-spl-wt/a-XXX /path/to/brief.md dedicated-agent
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

## 8. Discussion Properties: Dedicated Agent Lifecycle (Start, Inspect, Stop)

### 8.1 Discussion Properties Access (Desktop & Mobile)

The primary user entry point for assigning and managing a dedicated agent on a discussion is the Discussion Properties interface:
- **Desktop**: Right-clicking on any message card in a topic (`MessageCard.vue`) or on the topic entry in the discussion thread list (`TopicPane.vue`) opens the topic context menu with a prominent item: **"Discussion Properties"** (`t('topic.properties.menu_item')`).
- **Mobile & Touch**: A long-press gesture on a topic card, or tapping the three-dots (kebab) menu icon in the topic header, opens the mobile Discussion Properties bottom sheet (`DiscussionPropertiesSheet.vue`).
- Within Discussion Properties, the user selects the **"Dedicated Agent"** tab/section to inspect or configure the dedicated agent for that specific `task_id`.

### 8.2 Starting a Dedicated Agent & Vendor Selection

When no dedicated agent is currently assigned to the discussion:
1. **Vendor Selection Dropdown**: The user can choose the agent vendor from the active fleet vendors (`claude`, `grok`, `mistral`, `agy`, `qwen`).
2. **Default Vendor Selection**: The dropdown defaults to the vendor recommended by the fleet lane-mix kind table (`env.box.agent_split_by_kind` in `csi-spl-cnf/csi-spl/all.env.yaml`, reading the main candidate for the topic's kind, falling back to `claude` per Spec 115).
3. **Optional Model & System Context**: Allows the user to provide initial topic instructions or keep defaults.

### 8.3 Role-Based Access Control (RBAC per Spec 025)

Starting and removing dedicated agents consumes fleet compute resources and is subject to tenant RBAC permissions:
- **Authorized Roles**:
  - `biz_owner` (Workspace Owner): Unrestricted permission across all topics in the workspace.
  - `admin` (Workspace Admin): Unrestricted permission across all topics in the workspace.
  - `product_owner`, `developer`, `regular_user`, `biz_customer`: Permitted on discussions within channels they belong to, provided they have not been banned from the feature.
- **Denied Roles & Actors**:
  - Guests (`GST-*`): Denied. The "Dedicated Agent" option is hidden or disabled (`403 Forbidden`).
  - Read-only members: Denied.
  - Banned Users (`is_banned = true` in `dedicated_agent_abuses`): Denied with an explanatory badge: *"You are banned from reserving dedicated agents in this workspace (6 abuses). Reserving agents is expensive."*

### 8.4 Resource Cost Transparency & Confirmation Notice

To enforce the owner's binding principle—verbatim: *"i.e. users must understand that reserving agents is expensive"*—the WUI requires an explicit confirmation modal before any dedicated agent is started:
- **Resource Consumption Warning**: Clear banner stating: *"Reserving a dedicated agent allocates dedicated compute and reserves an active agent seat while it waits. Reserving agents is expensive."*
- **Idle Timeout Disclosure**: Shows the configured idle timeout (e.g. *"Default idle timeout: 1 hour"*), informing the user that the agent will be automatically dismissed if no new input occurs within that timeframe.
- **Abuse Policy Notice**: Explicitly outlines the 3 / 5 / 6 threshold policy:
  *"If this dedicated agent times out after 1 hour without being used, it counts as 1 abuse. After 3 abuses you will receive a warning, after 5 a final warning, and after 6 abuses you will be banned from reserving dedicated agents in this workspace."*
- **Current Abuse Count Display**: Shows the user's active count: *"Your current abuse tally: X of 6"*.
- **Confirmation Action**: The user must click **"I Understand, Reserve Agent"** to trigger the spawn API call.

### 8.5 Inspecting Live Dedicated Agent State

When an agent is actively bound to the discussion, the Discussion Properties panel displays its real-time operational status:
- **Agent Identity**: Agent ID (e.g. `a-782@box-1`), vendor badge, and model.
- **Live Status**: `Active` (processing/generating), `Idle Waiting` (waiting for user input), or `Shutting Down`.
- **Session Timers**:
  - Bound at / Uptime.
  - Time of last input (`last_activity_at`).
  - Remaining time before automatic idle dismissal (countdown clock, e.g. `42m 15s remaining until dismissal`).
- **Activity Metrics**: Total interaction count during this reservation (used to determine if an idle dismissal constitutes an abuse).

### 8.6 Removing / Dismissing a Dedicated Agent

A user can manually release the dedicated agent at any time:
- In Discussion Properties, click **"Dismiss Dedicated Agent"**.
- **Authorization**: The user who reserved the agent, any participant with writer access in the discussion, or any workspace admin/owner.
- **Teardown Flow**:
  1. The client invokes `DELETE /v1/topics/{task_id}/dedicated-agent`.
  2. The hub issues a clean exit command (`/exit-clean`) to the agent process.
  3. The agent process flushes pending logs and terminates cleanly (status 0).
  4. The hub unbinds the row from `dedicated_agents` and releases the agent seat.
  5. The hub posts a system message in the discussion: *"Dedicated agent <agent-id> was dismissed by @<user>. Seat freed."*

---

## 9. Idle Timeout & Automatic Dismissal Lifecycle

### 9.1 Configurable Per-Discussion Idle Timeout

Dedicated agents must not linger indefinitely when abandoned. The owner's rationale is binding and verbatim: *"because idle agents consume resources"*.
- **Default Duration**: Exactly **1 hour** (`3600` seconds).
- **Configurability**: Configurable per discussion in the Discussion Properties dialog (`idle_timeout_seconds`).
- **Permitted Bounds**:
  - **Minimum**: `5 minutes` (`300` seconds). Prevents thrashing, rapid cycling, and premature kills during human typing/thinking delays.
  - **Maximum**: `24 hours` (`86400` seconds). Enforces an upper limit to prevent persistent seat hoarding across days.
  - **"Never" (Disable Timeout)**: Disabled for regular users. Only a workspace owner (`biz_owner`) or admin may select "Never" (represented by `idle_timeout_seconds = 0`), which displays an explicit confirmation warning regarding continuous compute costs and seat occupation.

### 9.2 Definition of "Idle"

A dedicated agent is considered **idle** when there is no new activity in its bound scope:
- **Inactivity Criteria**: Zero new messages posted to the topic thread (`task_id`), whether from human participants or other authorized agents.
- **Activity / Clock Reset**:
  - A human message posted to the discussion immediately updates `last_activity_at = now()` and resets the idle countdown timer to the full duration.
  - A message directed to the agent resets the timer.
  - Internal agent tool execution cycles during an ongoing response turn keep the agent active and prevent timeout expiration (see §9.4).

### 9.3 Dismissal Lifecycle & Execution

Dismissal is governed by a lightweight daemon on the hub and host box (`spl-dedicated-idle-sweep`):
1. **Evaluation**: Daemon scans active dedicated topic bindings where `now() - last_activity_at > idle_timeout_seconds`.
2. **Execution**:
   - The hub/box initiates graceful dismissal by dispatching `/exit-clean` to the agent session.
   - The agent persists scratch files, flushes outbox queues, and terminates cleanly with exit code 0.
   - The agent seat is retired and freed on the host box (`agent-id-retire.sh`), reclaiming CPU, memory, and tmux resources.
   - The binding is removed from `dedicated_agents`.
3. **Abuse Accounting**: If the agent's interaction count (`dedicated_interaction_count`) is 0, this event is recorded as an abuse against the dedicating user (see §10).
4. **System Line in Topic**:
   - The hub posts an automated non-AI system message directly into the topic:
     > *"Dedicated agent `<agent-id>` was dismissed due to idleness (no activity for 1 hour). Idle agents consume resources. To bring back a dedicated agent, open Discussion Properties (right-click) and select Dedicated Agent."*

### 9.4 Edge Cases & Safeguards

- **Edge Case 1: Input during shutdown**
  - *Scenario*: A human posts a message to the discussion while the agent is in the process of shutting down (between the timeout trigger and process exit).
  - *Handling*: The hub stores and commits the human message into the topic thread. Because the agent session is already executing `/exit-clean`, the shutdown sequence is not aborted, preventing half-torn or corrupt LLM state. Once the agent process exits, the hub detects that an unconsumed post arrived during teardown and displays a topic notification: *"Your message was received after agent dismissal initiated. Start a new dedicated agent from Discussion Properties to continue."*
- **Edge Case 2: Running tool call at timeout**
  - *Scenario*: The idle timeout expires while the agent is executing an active, long-running tool call (e.g. bash compilation, git rebase, database query, or remote fetch).
  - *Handling*: The agent is actively working, not idle. The idle monitor checks the agent's live execution state via its lifetime process status. If an active tool execution or inference turn is underway, dismissal is postponed. A 5-minute grace period is granted. Once the tool completes and the agent returns its response to the topic, the idle timer restarts.
- **Edge Case 3: Re-adding after dismissal**
  - *Scenario*: A user re-adds a dedicated agent to a discussion where a previous agent was dismissed.
  - *Handling*: A fresh session is started (`SPAWN_DEDICATED_SCOPE="topic:<task_id>"`). The agent receives a clean process environment, pristine scratch directory, and fresh context. The agent seed automatically ingests the topic's conversation history (`spool tail --task <task_id>`), allowing it to seamlessly resume the discussion with full conversational context without inheriting dirty process memory from the dismissed session.

---

## 10. Abuse Protection, Warning Escalation & Feature Ban

### 10.1 The Abuse Definition (Closed by Owner Decision)

Owner order verbatim (msg `d8adaced-c6a7-469d-8f8d-4ebeb6d36ee4`):
> "Dedicating an agent , but than not using it for more than 1h ... ( confiurable amount of time with default of 1h )"

- **The Exact Definition**: Exactly **one abuse** is counted when a dedicated agent is assigned to a discussion and is subsequently dismissed by the idle timeout having received **zero user interactions** (human messages, prompts, or task requests) during its entire reservation lifetime.
- **Legitimate Use Exemption**: If the user or topic participants send at least one interaction to the agent, the reservation served a purpose. When such an agent times out after 1 hour of subsequent inactivity, it is dismissed as normal resource hygiene and **no abuse** is recorded.

### 10.2 Per-User, Per-Workspace Abuse Accounting

- **Accounting Store**: Persisted in the hub database table `dedicated_agent_abuses` keyed by `(tenant_id, human_id)`.
- **Counter Invariants**:
  - Increments atomically upon an unused idle dismissal event.
  - Tally is scoped to the workspace (tenant).
  - Tally does not automatically decay with time; it stands until explicitly reset by an administrator.

### 10.3 Escalation Thresholds & Warning System

Owner order verbatim (msg `edf8e150-3e1f-4805-9612-788be3e8765d`):
> "and if users are abusing this fesature - after 3 abuses they should be warned about it , after 5 once again and after 6 completely banned from the feature ..."

All warnings and ban notifications are deterministic, code-generated system messages without AI:

1. **Threshold 3 (First Warning)**:
   - Triggered on the 3rd recorded abuse.
   - A system notification is sent to the user and posted in the topic:
     > *"Warning (3/6): A dedicated agent you reserved was dismissed due to inactivity without being used. Reserving agents is expensive and consumes shared fleet resources. Further unused reservations will result in a ban from the dedicated agent feature."*
2. **Threshold 5 (Second / Final Warning)**:
   - Triggered on the 5th recorded abuse.
   - An urgent warning toast and notification are dispatched to the user:
     > *"Final Warning (5/6): You have reserved 5 dedicated agents that timed out without being used. Reserving agents is expensive. One more unused reservation will result in an immediate ban from dedicating agents in this workspace."*
3. **Threshold 6 (Feature Ban)**:
   - Triggered on the 6th recorded abuse.
   - The user's record in `dedicated_agent_abuses` is updated: `is_banned = true`, `banned_at = now()`.
   - A ban notification is delivered to the user:
     > *"Feature Banned: You have reached 6 unused dedicated agent timeouts. You are now banned from reserving dedicated agents in this workspace because idle agents consume resources. Contact your workspace owner to review and lift this ban."*

### 10.4 Ban Enforcement & Lifting

- **Hard Enforcement**:
  - **Hub API Gate**: Any request to `POST /v1/topics/{task_id}/dedicated-agent` or `POST /v1/channels/{channel}/dedicated-agents` initiated by a banned user is refused with HTTP 403 Forbidden, returning error token `dedicated_feature_banned` and message `"user is banned from dedicating agents due to repeated unused reservations"`.
  - **WUI Presentation**: In the Discussion Properties dialog, the "Reserve Agent" button is disabled and replaced with a red status badge: `Banned from reserving dedicated agents (6 abuses)`.
- **Lifting a Ban**:
  - **Authority**: Strictly the **workspace owner** (`biz_owner`) or a workspace `admin` per Spec 025.
  - **Procedure**:
    1. The admin navigates to Workspace Settings > Members (`TenantUsersDialog.vue`).
    2. Users with recorded abuses or active bans display an abuse chip (e.g. `Abuses: 6 (Banned)`).
    3. The admin clicks the user action **"Reset Abuses & Unban"**.
    4. The client calls `POST /v1/members/{user_id}/reset-dedicated-abuse`.
    5. The hub sets `abuse_count = 0`, `is_banned = false`, `unbanned_at = now()`, `unbanned_by = <admin_id>`, and records an audit log entry.
    6. The user receives a system notification that their dedicated agent privileges have been reinstated.

---

## 11. Functional Requirements (FR Matrix)

| FR ID | Summary & Requirement | Layer | Status |
|---|---|---|---|
| **FR-001** | **Dedicated Scope Isolation**: Agent bound to exactly one channel (`channel:<id>`) or topic (`topic:<task_id>`); cannot join general dispatch or ambient channels. | Hub / Store | Planned |
| **FR-002** | **Private Scope Blackout**: Orchestrator (`c-001`) and dispatchers (`c-002..c-004`) receive 0 deliveries from scopes with `is_private_scope = true`. | Hub Routing | Planned |
| **FR-003** | **Hard Bidirectional Gate**: Outbound sends by dedicated agent targeting any channel, topic, or DM outside its bound scope are refused with HTTP 403 `dedicated_scope_violation`. | Hub Protocol | Planned |
| **FR-004** | **Discussion Properties Entry Point**: Right-click context menu on message cards / topic list items (desktop) and long-press / kebab menu (mobile) opens Discussion Properties. | WUI | Planned (Owner msg 1d031b1c) |
| **FR-005** | **Dedicated Agent Lifecycle Controls**: Start dedicated agent, inspect live state (status, uptime, remaining idle time), and manually dismiss via Discussion Properties. | WUI / Hub | Planned (Owner msg 1d031b1c) |
| **FR-006** | **Vendor Selection & Defaulting**: Vendor dropdown in Discussion Properties defaults to the main candidate of the fleet lane-mix kind table (`agent_split_by_kind` in `all.env.yaml`). | WUI / Orc | Planned |
| **FR-007** | **Role-Based Authorization for Dedicated Agents**: Permitted for `biz_owner`, `admin`, `developer`, `product_owner`, `regular_user` per Spec 025; refused for guests (`GST-*`) and banned users. | Hub RBAC | Planned |
| **FR-008** | **Resource Cost Transparency & Warning Prompt**: Mandatory confirmation notice before reserving: explains compute resource cost ("reserving agents is expensive"), idle timeout, 3/5/6 abuse rules, and current abuse tally. | WUI | Planned (Owner msgs 3c233ec5, edf8e150) |
| **FR-009** | **Configurable Per-Discussion Idle Timeout**: Per-discussion idle timeout defaulting to 1 hour (3600 s); configurable between 5 min and 24 h; "Never" option restricted to workspace owners/admins with cost warning. | Hub / WUI | Planned (Owner msg 1d031b1c) |
| **FR-010** | **Automatic Idle Dismissal Lifecycle**: Inactive agent dismissed on timeout via clean exit (`/exit-clean`); seat released; system notice posted in topic explaining idleness and re-add instructions. | Hub / Box | Planned (Owner msg 1d031b1c) |
| **FR-011** | **Inactivity Tracking & Timer Reset**: Topic inactivity clock measures time since last human post or agent message in topic; any new message resets the idle timer. | Hub Store | Planned (Owner msg 1d031b1c) |
| **FR-012** | **Idle Dismissal Edge Cases**: Messages arriving during shutdown buffered and surfaced with re-add prompt; active tool execution defers timeout; re-adding restores conversation history into fresh session. | Hub / Box | Planned |
| **FR-013** | **Abuse Definition & Accounting**: 1 abuse recorded when dedicated agent is dismissed by idle timeout with 0 user interactions; tracked per user per workspace in `dedicated_agent_abuses`. | Hub Store | Planned (Owner msg d8adaced) |
| **FR-014** | **Graduated Abuse Warnings & Ban**: Deterministic system warnings emitted at 3 abuses and 5 abuses; hard feature ban applied at 6 abuses; all text cites "reserving agents is expensive". | Hub Guard | Planned (Owner msgs edf8e150, 3c233ec5) |
| **FR-015** | **Ban Enforcement & Owner Lifting**: Banned users receive HTTP 403 on dedication attempts and disabled UI; workspace owner or admin can inspect and reset abuses via Tenant Users settings. | Hub / WUI | Planned (Owner msg edf8e150) |

---

## 12. Tests and Acceptance Criteria

### 12.1 Acceptance Criteria

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
| **AC-14** | WUI Context Menu | Right-click topic card or mobile kebab | Opens Discussion Properties modal with Dedicated Agent settings tab. |
| **AC-15** | WUI Vendor Pick | Open Dedicated Agent selector | Dropdown populated with fleet vendors; defaults to `agent_split_by_kind` pick. |
| **AC-16** | WUI Cost Warning | Confirm dedication | Confirmation modal displays compute cost notice, timeout, abuse policy, and current tally. |
| **AC-17** | Idle Dismissal | Topic inactive for idle timeout (1 h default) | Agent dismissed cleanly via `/exit-clean`; seat released; system notice posted in topic. |
| **AC-18** | Tool Call Grace | Agent executing tool call at timeout expiration | Dismissal postponed until tool execution completes. |
| **AC-19** | Re-add Context | Re-add dedicated agent after dismissal | Fresh session spawned and ingests prior discussion transcript. |
| **AC-20** | Abuse Warnings & Ban | Unused agent times out at 3, 5, 6 abuses | Emits Warning 1 at 3, Warning 2 at 5, and applies feature ban at 6. |
| **AC-21** | Owner Unban | Workspace owner resets user abuses | User's ban lifted, abuse counter reset to 0, dedication restored. |

### 12.2 Negative Controls & Red Tests

- **Control C1 (Scope Escape):** An agent dedicated to `channel:ch-a` crafts an envelope with `channel:ch-b` and valid box signature. The hub *must* return HTTP 403 `dedicated_scope_violation`.
- **Control C2 (Dispatcher Interception):** Dispatcher `c-002` queries `BoxTaskEnvelopes` for a private topic on its own box. The store *must* return empty results.
- **Control C3 (Sweep Interception):** Seed a private scope topic with a human post older than `SWEEP_MIN_AGE`. Run `do_spl_unanswered_sweep`. The output report *must* contain 0 items.
- **Control C4 (Banned User Dedication Refusal):** User with 6 abuses attempts `POST /v1/topics/{task_id}/dedicated-agent`. The hub *must* return HTTP 403 `dedicated_feature_banned`.
- **Control C5 (Unused Idle Abuse Increment):** Dedicated agent times out with 0 interactions. The hub *must* increment user's `abuse_count` by 1.
- **Control C6 (Used Agent Dismissal Non-Abuse):** Dedicated agent receives 1 interaction and later times out. The hub dismisses the agent, but `abuse_count` *must not* increment.

---

## 13. Migration Strategy & Rollout

1. **Phase 1: Database Schema Migration**
   - Apply `0202_dedicated_agents.sql` to `dev` then `prd` (table `dedicated_agents`, columns `is_private_scope`).
   - Columns `is_private_scope` default to `false`; `dedicated_agents` table starts empty.
   - Backward-compatible: zero impact on existing running agents or channels.
2. **Phase 1b: Discussion Idle Configuration & Abuse Table Migration**
   - Apply `0203_dedicated_idle_and_abuses.sql` to `dev` then `prd` (`idle_timeout_seconds`, `last_activity_at`, `dedicated_interaction_count`, and table `dedicated_agent_abuses`).
3. **Phase 2: Hub API Logic Deployment**
   - Deploy Cloud Run hub API with inbound/outbound scope validation, sweep query exclusion, topic dedication endpoints, and abuse enforcement engine.
4. **Phase 3: Orchestration, Inactivity Daemon & Spawning**
   - Deploy `SPAWN_DEDICATED_SCOPE` launcher support, mode `0700` spool directory provisioning, and `spl-dedicated-idle-sweep` cron.
5. **Phase 4: Web UI Updates**
   - Deploy Nuxt 3 UI with Discussion Properties context menu, cost transparency confirmation modal, live dedicated card, and Tenant Users abuse management.

---

## 14. Open Questions for the Owner

> **Abuse Definition Question (CLOSED 2026-10-17)**: Resolved by owner message `d8adaced-c6a7-469d-8f8d-4ebeb6d36ee4`: one abuse is defined as dedicating an agent and leaving it unused until the 1-hour idle timeout dismisses it. Thresholds 3, 5, and 6 count these events.

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

<!-- version: 0.2.0 · updated: 2026-10-19 · last-edit: 2026-10-19T17:00:00Z -->
