# Feature Specification: Per-Workspace Agent Caps by Kind

**Feature ID**: `147-workspace-agent-caps` · **Milestone**: M3 / M4 · **Status**: Planned (Spec Only)
**Created**: 2026-10-19 · **Epic**: SPL-2400 · **Issue**: SPL-2586 · **Lane**: a-799-c002-spec-workspace-agent-caps
**Authority**: this file for system behaviour, database schema, protocol rules, API contracts, and enforcement semantics. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).

Builds on, and does not repeat:
- [002 box-agent-messaging](../002-box-agent-messaging/spec.md) (local spool, box CLI, MCP server)
- [003 spool-message-bus](../003-spool-message-bus/spec.md) (WebSocket frames, envelope signing, routing)
- [009 spool-m4](../009-spool-m4/spec.md) (tenant bot seat limits `seats_bots`, buy-time stamps)
- [025 spool-tenant-rbac](../025-spool-tenant-rbac/spec.md) (roles, permissions, workspace admin vs operator)
- [061 agent-id-rename](../061-agent-id-rename/spec.md) (agent id grammar `^[acgmq]-[0-9]{3}$` and vendor prefix mapping)
- [074 operator-workspace](../074-operator-workspace/spec.md) (operator workspace console, `operator.workspaces` authority)
- [108 workspace-owned-boxes](../108-workspace-owned-boxes/spec.md) (dedicated workspace boxes and OS isolation)
- [115 vendor-split-by-task-kind](../115-vendor-split-by-task-kind/spec.md) (vendor kinds `claude`, `grok`, `mistral`, `agy`, `qwen`)
- [127 workspace-vendor-keys](../127-workspace-vendor-keys/spec.md) (workspace admin settings for vendor keys)
- [144 dedicated-agents](../144-dedicated-agents/spec.md) (topic and channel scoped agent bindings)

---

## 0. The Owner's Request and Business Need (Verbatim, Binding)

Recorded 2026-10-19:
- Owner HUM-10, t1 topic `4ce4c8db-e298-4d06-8325-37c761c2aa23`, msg `9c96ca9e`:
  > "given the following biz needs https://csitea.spool-hub.ai/channel/csitea-sells?topic=02d271a2-1721-461e-8067-14390f097a45 the spool-hub admin should be able to define a max amount of agents and their kind per workspace"

- Business requirement from discussion (csitea topic `02d271a2-1721-461e-8067-14390f097a45`, msg `dc010e3c`):
  > "the new workspace <CUSTOMER-WORKSPACE> gets not more than 1 claude and 1 grok instance and 2 agy and 1 mistral"

- Dispatcher post:
  > `https://spool-hub.ai/m/93aa0ccd-7eec-4dc4-87a8-8ada9d23f557`

### Core Principles Derived From the Request

1. **P1 (Cap Definition Tuple):** A cap is the persistent tuple `(workspace_id, vendor, max_live)`. The supported vendors correspond to the five fleet agent kinds: `claude`, `grok`, `mistral`, `agy`, `qwen`.
2. **P2 (Strict Spool-Hub Admin Authority):** Per the owner's explicit mandate, defining, updating, or deleting agent caps per workspace is reserved **strictly** to the spool-hub admin (an administrator of the operator workspace holding `operator.workspaces` / `operator_scope`).
3. **P3 (Workspace Admin Read-Only Visibility):** Administrators of individual workspaces may read and inspect their workspace's caps (via API and Workspace Settings), but can never modify them. Any mutation attempt by a workspace admin is refused with HTTP 403 Forbidden.
4. **P4 (Default Uncapped / Zero Regression):** A workspace with no cap configured for a given vendor defaults to unlimited live instances (`max_live = NULL` / absent row). Existing workspaces without explicit caps continue to operate exactly as today, constrained only by tenant-wide `seats_bots` (M4) or box host limits.
5. **P5 (Universal Path Enforcement):** The cap must be enforced across every path that seats, connects, or spawns an agent into a workspace. If admitting an agent would cause the count of live agents of that vendor in that workspace to exceed `max_live`, the operation is refused.
6. **P6 (Informative Rejection Message):** Every refusal explicitly identifies the affected workspace, the agent vendor, the configured cap, and the current live count (e.g. `refused: claude agent cap reached for workspace example-ws: max 1 live, currently 1 live`).
7. **P7 (Dynamic Concurrency Lifecycle):** Caps apply strictly to concurrent *live* instances. When an agent terminates cleanly (`/exit-clean`) or is retired, its live seat is released, immediately restoring capacity for subsequent spawns or desk seating of that vendor.

---

## 1. Glossary and Core Definitions

- **Workspace / Tenant:** The isolated tenant container on a spool-hub instance, identified by `workspace_id` (in database schemas and headers: `tenant_id`, e.g. `t1`, `example-ws`).
- **Spool-Hub Admin (Operator Admin):** A human member holding the `admin` role in the designated operator workspace (Spec 074, `tenants.is_operator = true`). Only this identity holds instance-wide management authority (`operator.workspaces`).
- **Workspace Admin:** A member holding the `admin` role within a regular workspace (Spec 025). Holds `tenant.settings` for their own workspace, but possesses zero operator privileges.
- **Agent Kind / Vendor:** The underlying AI model vendor and runtime kind of an agent. Governed by Spec 061 and Spec 115, the valid vendor set is:
  - `claude` (Anthropic): agent ID prefix `c-` (legacy `CLE-`)
  - `grok` (xAI): agent ID prefix `g-` (legacy `GRK-`)
  - `mistral` (Mistral): agent ID prefix `m-`
  - `agy` (Google): agent ID prefix `a-` (legacy `AGY-`)
  - `qwen` (OpenAI-compatible): agent ID prefix `q-` (legacy `QWN-`)
- **Agent Cap (`max_live`):** A non-negative integer specifying the maximum number of concurrent live agent instances of a specific vendor allowed within a workspace.
- **Live Agent:** An agent instance actively seated or operating in a workspace that occupies compute, memory, or hub routing resources. Specifically, an agent whose ID is announced in the active `roster` of an online box for that workspace, or holds an active dedicated agent reservation (`dedicated_agents`), or has an unexpired active spawn claim.
- **Uncapped:** The absence of a cap record for `(workspace, vendor)`, granting unconstrained instance counts up to tenant-wide bot seat limits.

---

## 2. Today, Measured: Every Path that Seats or Spawns an Agent into a Workspace

An exhaustive empirical code audit of trunk (`master`) reveals six distinct architectural paths through which an agent enters a workspace. Each path must be instrumented with cap enforcement.

### 2.1 Desk Seating (`do_spl_desk_up` and Callers)

The desk mechanism connects an agent running in a terminal pane on a host machine to a workspace (tenant) at the hub:

- **Primary Seating Action (`do_spl_desk_up`):** `csi-spl-orc/src/bash/run/spl-desk-up.func.sh:62-128`.
  - Line 64: `spl_box_ws_guard` validates workspace enrollment.
  - Line 97-99: Creates local spool tree `$SPL_STATE_DIR/desk/$tenant/$box/spool/$agent/{inbox,outbox,archive}`.
  - Line 102: `spl_desk_pin` pins the box public key to the workspace (`POST /v1/pins` or `POST /v1/join-tokens/claim`).
  - Line 106: `spl_desk_sidecar` starts `spool hub-run`, which initiates WebSocket connection and roster sync to Cloud Run hub.
  - Line 109: `spl_desk_wait_roster` waits up to `DESK_WAIT_SECS` for the hub roster to announce `DESK_AGENT` under `DESK_BOX`.
- **All-Seats Desk Reconciliation (`do_spl_desk_up_all`):** `csi-spl-orc/src/bash/run/spl-desk-up.func.sh:317-360`. Iterates over all role seats on this box and calls `do_spl_desk_up`.
- **Multi-Tenant Desk Reconciliation (`do_spl_desk_up_tenants`):** `csi-spl-orc/src/bash/run/spl-desk-up.func.sh:372-405`. Reconciles desks across workspaces discovered under `$SPL_STATE_DIR/desk/`.
- **Multi-Box Desk Reconciliation (`do_spl_desk_up_boxes`):** `csi-spl-orc/src/bash/run/spl-desk-up.func.sh:416-452`. Reconciles remote box desks listed in `lease.conf`.
- **Periodic Desk Cron:** `csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh:36-40`. Automatically invokes `do_spl_desk_up_all`, `do_spl_desk_up_tenants`, and `do_spl_desk_up_boxes`.
- **Interactive Agent Seating:** `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-agent.sh:268`. Calls `do_spl_desk_up` to seat an interactive agent in a target workspace.
- **MCP Agent Seating:** `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mcp.sh:114`. Calls `do_spl_desk_up` with `DESK_POKE=0` to seat an MCP service agent into a workspace.
- **Dedicated Box Workspace Binding:** `csi-spl-orc/src/bash/run/spl-box-workspace-setup.func.sh:28-85`. Sets up a host box dedicated to exactly one workspace (`SPL_WS_BASE`), restricting all desk seating on that machine to that tenant.

### 2.2 Hub Database Tables & Protocol Ingestion (`seats` / Desk Tables)

The hub represents agent presence, seating, and tenancy through database tables and WebSocket frame handlers:

- **Database Roster Table:** `csi-spl-rdb/src/sql/postgres/spool-hub/0001_initial.sql:40-48`. `roster (tenant_id, box_id, agent_id, announced_at)` maintains the active agent set announced by each box.
- **Database Agent Seats Table:** `csi-spl-rdb/src/sql/postgres/spool-hub/0107_agent_seats.sql:25-32`. `agent_seats (tenant_id, box_id, agent_id, seated_at)` tracks when an agent entered that box's roster.
- **Database Tenant Bot Seat Limits:** `csi-spl-rdb/src/sql/postgres/spool-hub/0012_m4_seats_buy_stamp.sql:25-26`. `tenants.seats_bots` holds the aggregate paid bot seat cap across all vendors.
- **Database Box Join Tokens:** `csi-spl-rdb/src/sql/postgres/spool-hub/0119_agent_join_tokens.sql:6-24`. `box_join_tokens` seats box keys without requiring the tenant root private key.
- **Database Roster Replacement (`SetRoster`):** `csi-spl-api/src/go/spool-hub-api/internal/store/postgres.go:335-370`.
  - Line 337: Calls `s.botSeatGate(ctx, tx, tenant, box, agents)`.
  - Line 348-353: Inserts new holders into `agent_seats`.
  - Line 354: Deletes old roster rows for `(tenant_id, box_id)`.
  - Line 356: Inserts new agents into `roster`.
- **Existing Aggregate Bot Seat Gate (`botSeatGate`):** `csi-spl-api/src/go/spool-hub-api/internal/store/seats_postgres.go:27-54`. Checks `tenants.seats_bots` against non-human roster rows; returns `store.ErrSeatQuota` if aggregate bot cap is exceeded.
- **Hub WebSocket Connection Hello (`seatSession`):** `csi-spl-api/src/go/spool-hub-api/internal/hub/ws.go:319-345`.
  - Line 333: Calls `s.seatRoster(ctx, tenant, f.BoxID, f.Agents, now)`.
  - Line 339: Calls `s.o.Store.SetSubscriptions`.
- **Hub WebSocket Hello Roster Seating (`seatRoster`):** `csi-spl-api/src/go/spool-hub-api/internal/hub/ws.go:517-539`. On `ErrSeatQuota`, drops new additions and keeps existing agents.
- **Hub WebSocket Roster Announcement (`onAnnounce`):** `csi-spl-api/src/go/spool-hub-api/internal/hub/ws.go:475-511`.
  - Line 485: Calls `s.o.Store.SetRoster`. If `ErrSeatQuota`, fails frame with HTTP 402 `TokenQuota` (`billing.TokenQuota`).
  - Line 505: Broadcasts updated roster to connected sessions (`s.broadcastRoster`).

### 2.3 Autonomous Spawning Paths

When the fleet or a dispatcher launches an autonomous worker lane:

- **Window Spawning Script (`spawn-window.sh`):** `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh`.
  - Lines 59-84: `PLACEMENT` algorithm selects target box based on lowest busy count and available memory (ranks candidate boxes across local box, `PC`, and satellite).
  - Lines 85-97: `LOAD TARGET` (`do_spl_box_pick`) queries hub load target (`rdb 0118`).
  - Lines 413-419: Propagates `LANE_TENANT`, `LANE_ENV`, `LANE_DESK_BOX`, and vendor configuration to the child launcher.
  - Line 423: Executes `tmux new-window -d` invoking the vendor launcher.
- **Core Spawn Lifecycle (`spawn-core.inc.sh`):** `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh:350-450`. Initializes agent worktree, renders seed prompt (`prompt.txt`), registers workdir in `$SPOOL_ROOT/workdirs.tsv`, and creates spool queues.
- **Vendor Launchers:**
  - `spawn-claude.sh:1-40` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-claude.sh`)
  - `spawn-grok.sh:1-55` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-grok.sh`)
  - `spawn-mistral.sh:1-120` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-mistral.sh`)
  - `spawn-agy.sh:1-60` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-agy.sh`)
  - `spawn-qwen.sh:1-65` (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-qwen.sh`)
- **Remote Spawn Relaying (`spawn-remote.sh`):** `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-remote.sh:120-180`. Relays spawn request across machines (e.g. from local box to `PC` or satellite).
- **Dispatcher Lane Claiming (`do_spl_take`):** `csi-spl-orc/src/bash/run/spl-take.func.sh:35-80`. Dispatcher claims topic, queries lane mix (`spl-lane-mix.func.sh`), resolves vendor, files issue, and calls `spawn-window.sh`.
- **Channel Agent Addition (`do_spl_channel_agent_add_op`):** `csi-spl-orc/src/bash/run/spl-channel-agent-add-op.func.sh:30-80`. Adds agent to channel via `POST /v1/channels/{channel}/members/agents`.
- **Hub Channel Subscription Addition:** `csi-spl-api/src/go/spool-hub-api/internal/hub/channels.go:210-250`. Adds agent to `channel_subscriptions`.

### 2.4 Dedicated Agents (Spec 144)

- **Dedicated Agent Table:** `csi-spl-doc/specs/144-dedicated-agents/spec.md:144-159`. `dedicated_agents (tenant_id, agent_id, box_id, scope_type, scope_id)`.
- **Launcher Dedicated Flag:** `spec.md:390-401`. `SPAWN_DEDICATED_SCOPE="topic:<task_id>"` or `"channel:<channel_id>"`.
- **Dedicated Hub Binding Route:** `spec.md:406-418`. `POST /v1/dedicated-agents/bind` registers dedicated agent.
- **Dedicated Agent Teardown:** `spec.md:486-495`. `DELETE /v1/topics/{task_id}/dedicated-agent` dismisses dedicated agent and releases seat.

### 2.5 Workspace Vendor Keys (Spec 127)

- **Workspace Key Administration:** `csi-spl-doc/specs/127-workspace-vendor-keys/spec.md:50-55`. Workspace admin sets API keys per vendor kind in Workspace Settings.
- **Agent Split Configuration:** `spec.md:71`. `PATCH /v1/agent-split` updates `tenant_agent_split_kind` under `rbac.TenantSettings`.
- **Per-Kind Seat Authentication:** `spec.md:92-100`. Launchers authenticate using workspace-specific keys for `claude`, `grok`, `agy`, `mistral`, `qwen`.

### 2.6 Tenant RBAC (Spec 025) & Operator Console (Spec 074)

- **Role Definitions:** `csi-spl-doc/specs/025-spool-tenant-rbac/spec.md:38-53`. `admin` vs `biz_owner` vs member roles within a tenant.
- **Operator Authority:** `csi-spl-doc/specs/074-operator-workspace/spec.md:35-37`. Only the admin of the operator workspace (`operator.workspaces`) manages instance-wide resources.
- **Operator Actor Authentication:** `csi-spl-api/src/go/spool-hub-api/internal/hub/operator_workspaces.go:83-113`. `operatorActor` enforces that caller belongs to `operatorTenant` and holds role `rbac.Admin`.

---

## 3. Data Model & Database Migration Sketch

To persist per-workspace agent caps by vendor, migration `0209_workspace_agent_caps.sql` is introduced.

### 3.1 Migration Sketch: `0209_workspace_agent_caps.sql`

```sql
-- 0209_workspace_agent_caps.sql — Per-workspace agent caps by kind/vendor
-- Spec 147 (SPL-2586, owner orders HUM-10 msg 9c96ca9e)
--
-- Defines max live concurrent agents per vendor for each workspace.
-- Uncapped vendors have no row (or max_live IS NULL).
-- Set and edited ONLY by spool-hub admin (operator_scope); readable by workspace.

CREATE TABLE IF NOT EXISTS tenant_agent_caps (
    tenant_id       varchar(64)  NOT NULL,
    vendor          varchar(16)  NOT NULL,
    max_live        integer      NOT NULL,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),
    updated_by      varchar(64)  NOT NULL,
    CONSTRAINT pk_tenant_agent_caps PRIMARY KEY (tenant_id, vendor),
    CONSTRAINT fk_tenant_agent_caps_tenant FOREIGN KEY (tenant_id)
        REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    CONSTRAINT chk_tenant_agent_caps_vendor
        CHECK (vendor IN ('claude', 'grok', 'mistral', 'agy', 'qwen')),
    CONSTRAINT chk_tenant_agent_caps_max_live
        CHECK (max_live >= 0)
);

-- Index for rapid tenant lookup during WebSocket connect and announce
CREATE INDEX IF NOT EXISTS idx_tenant_agent_caps_lookup
    ON tenant_agent_caps (tenant_id);

-- Row-Level Security: fail-closed NULLIF pattern
ALTER TABLE tenant_agent_caps ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_agent_caps FORCE ROW LEVEL SECURITY;

-- Workspace members and workspace admins can READ their own workspace's caps
CREATE POLICY tenant_scope ON tenant_agent_caps
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));

-- Only the operator scope (spool-hub admin) can INSERT, UPDATE, DELETE, or SELECT across all tenants
CREATE POLICY operator_scope ON tenant_agent_caps
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

### 3.2 Audit Trail Integration

All mutations of `tenant_agent_caps` record an entry in `operator_audit` (`store.OperatorAudit`, `csi-spl-rdb/src/sql/postgres/spool-hub/0115_operator_audit.sql`):
- `action`: `"set_agent_caps"` or `"delete_agent_cap"`
- `tenant_id`: the target workspace (e.g. `example-ws`)
- `actor_hum`: the human ID of the operator admin
- `detail`: `{"vendor": "claude", "max_live": 1, "previous": null}`

---

## 4. Definition of "Live" Agent Count & Enforcement Semantics

### 4.1 Definitive Count Calculation

An agent is counted as **live** for vendor $V$ in workspace $W$ if and only if it satisfies one of the following empirical criteria:

1. **Active Box Roster Presence:** The agent ID appears in `roster` for workspace $W$ where the hosting box has sent a heartbeat (`last_hello_at`) within the last 60 seconds (or has an open WebSocket connection on the hub).
2. **Dedicated Scope Reservation:** The agent ID is registered in `dedicated_agents` (Spec 144) for workspace $W$ and has not yet been dismissed by idle timeout or manual unbind.
3. **Active Spawn Reservation:** The agent ID has an unexpired lease in `$SPOOL_ROOT/agent-claims.tsv` during the initial bootstrap interval (up to 45 seconds) before its first WebSocket hello reaches the hub.

Mathematically, the live query inside the hub store transaction executes:

```sql
SELECT count(DISTINCT r.agent_id)
  FROM roster r
  JOIN boxes b ON b.tenant_id = r.tenant_id AND b.box_id = r.box_id
 WHERE r.tenant_id = $1
   AND b.last_hello_at > now() - interval '60 seconds'
   AND (
     (r.agent_id LIKE 'c-%' AND $2 = 'claude') OR
     (r.agent_id LIKE 'g-%' AND $2 = 'grok') OR
     (r.agent_id LIKE 'a-%' AND $2 = 'agy') OR
     (r.agent_id LIKE 'm-%' AND $2 = 'mistral') OR
     (r.agent_id LIKE 'q-%' AND $2 = 'qwen') OR
     (r.agent_id LIKE 'CLE-%' AND $2 = 'claude') OR
     (r.agent_id LIKE 'GRK-%' AND $2 = 'grok') OR
     (r.agent_id LIKE 'AGY-%' AND $2 = 'agy') OR
     (r.agent_id LIKE 'QWN-%' AND $2 = 'qwen')
   );
```

### 4.2 Distinguishing Live vs Inactive States

| State | Definition | Counts as Live? | Rationale |
|---|---|---|---|
| **Active Running** | Process running, WebSocket connected, announced in `roster`. | **YES** | Consumes concurrent vendor seat and compute resources. |
| **Idle Waiting** | Pane open, waiting for prompt/message, announced in `roster`. | **YES** | Reserved capacity; immediately available to answer. |
| **Dedicated Reserved** | Bound to channel/topic via Spec 144, waiting in scope. | **YES** | Exclusively reserved seat. |
| **Clean Exited (`/exit-clean`)** | Process ended, retired by `agent-id-retire.sh`, dropped from next roster. | **NO** | Seat released; capacity restored for another instance. |
| **Stale Box Disconnect** | Box offline (`last_hello_at > 60s`), no active socket. | **NO** | Dead box does not consume live capacity. |
| **Unseated Pane** | Local process running in pane but not seated via `do_spl_desk_up`. | **NO** | Not enrolled in workspace; cannot receive workspace DMs or posts. |

---

## 5. Universal Enforcement Mechanics Across Every Path

Enforcement is layered across both the Cloud Run hub boundary and host-side orchestration tools.

```
                              SPAWN & SEATING ATTEMPTS
                                        │
             ┌──────────────────────────┴──────────────────────────┐
             ▼                                                     ▼
     HOST / ORC LEVEL                                      HUB API LEVEL
  (spawn-window, do_spl_desk_up)                        (SetRoster, THello, TAnnounce)
             │                                                     │
             ▼                                                     ▼
   Pre-flight Cap Query                                 Database Transaction
 (do_spl_workspace_agent_caps)                             (vendorCapGate)
             │                                                     │
    Live >= max_live?                                     Live >= max_live?
   ┌─────────┴─────────┐                                 ┌─────────┴─────────┐
   ▼                   ▼                                 ▼                   ▼
  YES                 NO                                YES                 NO
Refuse: exit 14     Proceed: spawn                    Refuse: 409         Commit roster
Print Cap Error     tmux window                       vendor_cap_exceeded & broadcast
```

### 5.1 Hub WebSocket Boundary (`SetRoster` & `vendorCapGate`)

In `csi-spl-api/src/go/spool-hub-api/internal/store/postgres.go:335` (`SetRoster`), insert `vendorCapGate` directly alongside `botSeatGate`:

```go
func (s *Postgres) SetRoster(ctx context.Context, tenant, box string, agents []string, now time.Time) error {
    return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
        if err := s.botSeatGate(ctx, tx, tenant, box, agents); err != nil {
            return err
        }
        if err := s.vendorCapGate(ctx, tx, tenant, box, agents); err != nil {
            return err
        }
        // ... proceed with roster replacement ...
    })
}
```

Implementation logic for `vendorCapGate`:
1. Query `tenant_agent_caps` for `tenant`: map `vendor -> max_live`. If empty, return `nil` (default uncapped).
2. Fetch current roster for `tenant`, partitioned by box.
3. Compute the prospective agent set: $(Roster_{tenant} \setminus Roster_{box}) \cup Agents_{new}$.
4. Count prospective agents per vendor using `agentid.Kind(agent_id)`.
5. For each vendor $V$, if $Count(V) > max\_live(V)$, return `store.ErrVendorCapExceeded{Vendor: V, Cap: max_live, Live: Count(V)}`.
6. **In `onAnnounce` (`ws.go:485`):** If `errors.As(err, &capErr)`, fail frame with:
   - `token`: `"vendor_cap_exceeded"`
   - `status`: `http.StatusConflict` (409)
   - `detail`: `fmt.Sprintf("%s agent cap reached for workspace %s: max %d live, requested %d", capErr.Vendor, tenant, capErr.Cap, capErr.Live)`
7. **In `seatRoster` (`ws.go:517`):** When handling `wire.THello`, trim incoming agents that would violate the vendor cap, seat only the allowed subset (favoring agents previously announced by this box), and log a warning.

### 5.2 Host Desk Seating Action (`do_spl_desk_up`)

In `csi-spl-orc/src/bash/run/spl-desk-up.func.sh:94`:
- Before creating state directory or starting sidecar, query active caps for `$TENANT_ID`.
- Resolve vendor kind using `spl_kind_of_agent_id "$agent"`.
- If a cap exists for that vendor and live count is already $\ge max\_live$:
  - Log fatal error:
    `FATAL agent $agent ($vendor) exceeds workspace $tenant cap of $max_live (currently $live live); seating refused`
  - Return exit code 1 without starting sidecar or pinning key.

### 5.3 Spawn Window Gate (`spawn-window.sh`)

In `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh`:
- Before `tmux new-window -d` (line 423), check if `LANE_TENANT` is specified.
- If specified, query live count of `$KIND` in `LANE_TENANT` via `spool hub-caps --tenant "$LANE_TENANT" --check "$KIND"`.
- If cap reached:
  - Print to stderr:
    `spawn-window: REFUSED: $KIND agent cap reached for workspace $LANE_TENANT (cap: $max_live, live: $live)`
  - Release any claimed agent ID (`sw_release_claim`).
  - Exit with designated code `14` (`VENDOR_CAP_EXCEEDED`).

### 5.4 Dispatcher Lane Mix & Fallback (`do_spl_take`)

In `csi-spl-orc/src/bash/run/spl-take.func.sh`:
- When taking an unassigned topic for workspace `$TENANT_ID`, inspect candidate vendors from `spl-lane-mix.func.sh`.
- If the primary vendor is at its workspace cap, immediately skip to the designated backup vendor (Spec 115 §4), logging:
  `INFO primary vendor $main capped out for workspace $tenant ($live/$cap); failing over to backup vendor $backup`.
- Only if all candidate vendors are capped out does the lane enter queued hold (`pick=hold`, exit 10).

---

## 6. API Routes & Protocol Contracts

### 6.1 Spool-Hub Admin Management Routes (Operator Workspace Only)

All routes require a valid user session belonging to the operator workspace (`tenants.is_operator = true`) holding role `admin` (`operator.workspaces` permission).

#### `GET /v1/operator/workspaces/{id}/agent-caps`
Returns all configured agent caps for the designated workspace.

**Request:**
```http
GET /v1/operator/workspaces/example-ws/agent-caps HTTP/1.1
Host: api.<BASE_DOMAIN>
Cookie: session=<operator_admin_session>
```

**Response (200 OK):**
```json
{
  "workspace_id": "example-ws",
  "caps": {
    "claude": 1,
    "grok": 1,
    "agy": 2,
    "mistral": 1
  },
  "updated_at": "2026-10-19T18:00:00Z",
  "updated_by": "HUM-01"
}
```

#### `PUT /v1/operator/workspaces/{id}/agent-caps`
Configures or updates agent caps for the designated workspace. Passing `null` or omitting an existing vendor removes its cap (returns to uncapped).

**Request:**
```http
PUT /v1/operator/workspaces/example-ws/agent-caps HTTP/1.1
Host: api.<BASE_DOMAIN>
Content-Type: application/json
Cookie: session=<operator_admin_session>

{
  "caps": {
    "claude": 1,
    "grok": 1,
    "agy": 2,
    "mistral": 1
  }
}
```

**Response (200 OK):**
Returns the updated caps object and records an audit row in `operator_audit`.

**Error Responses:**
- `400 Bad Request`: `{"error": "bad_vendor", "detail": "vendor 'deepseek' is not supported"}`
- `400 Bad Request`: `{"error": "bad_cap", "detail": "max_live must be a non-negative integer"}`
- `403 Forbidden`: `{"error": "operator.workspaces", "detail": "only an admin of the operator workspace manages agent caps"}`
- `404 Not Found`: `{"error": "not_found", "detail": "workspace 'example-ws' does not exist"}`

#### `DELETE /v1/operator/workspaces/{id}/agent-caps/{vendor}`
Removes the cap for a specific vendor, reverting that vendor to uncapped.

**Response (204 No Content)**.

---

### 6.2 Workspace Admin Inspection Route (Read-Only)

#### `GET /v1/tenant/agent-caps`
Allows administrators of the active workspace to inspect their current caps and live utilization.

**Request:**
```http
GET /v1/tenant/agent-caps HTTP/1.1
Host: api.<BASE_DOMAIN>
X-Spool-Tenant: example-ws
Cookie: session=<workspace_admin_session>
```

**Response (200 OK):**
```json
{
  "workspace_id": "example-ws",
  "caps": {
    "claude": 1,
    "grok": 1,
    "agy": 2,
    "mistral": 1,
    "qwen": null
  },
  "live": {
    "claude": 1,
    "grok": 0,
    "agy": 1,
    "mistral": 0,
    "qwen": 0
  },
  "can_edit": false
}
```

**Security Boundary:**
Any `PUT`, `POST`, `PATCH`, or `DELETE` attempt targeting `/v1/tenant/agent-caps` is refused with `405 Method Not Allowed` or `403 Forbidden` (`"agent caps can only be modified by the spool-hub administrator"`).

---

## 7. Web User Interface (WUI) Integration

### 7.1 Spool-Hub Admin Console (`OperatorPane.vue`)

In `csi-spl-wui/src/components/OperatorPane.vue`:
1. When an operator admin opens the workspace edit drawer for a workspace, a new section is displayed: **"Agent Caps by Vendor"** (`t('operator.agent_caps_section')`).
2. Provides numerical input fields for each fleet vendor:
   - Claude (`claude`)
   - Grok (`grok`)
   - AGY (`agy`)
   - Mistral (`mistral`)
   - Qwen (`qwen`)
3. An empty input or clear button sets `null` (uncapped, displaying `∞ Unlimited`).
4. Clicking **"Save Caps"** dispatches `PUT /v1/operator/workspaces/{id}/agent-caps`.
5. Success toast notifies: *"Agent caps updated for workspace <id>"*.

### 7.2 Workspace Settings Dialog (`TenantSettingsDialog.vue`)

In `csi-spl-wui/src/components/TenantSettingsDialog.vue` (under the **Agents** tab):
1. Renders a read-only table: **"Workspace Agent Capacity"** (`t('tenant_settings.agent_caps_title')`).
2. Columns:
   - **Vendor**: Vendor name and icon.
   - **Cap**: Configured maximum live count (e.g. `1 max`, or `Unlimited`).
   - **Currently Live**: Real-time count of active agents in the workspace.
   - **Status Badge**:
     - Green: `Available` (live < cap)
     - Yellow: `At Limit` (live == cap)
     - Blue: `Unlimited` (uncapped)
3. Subtitle / Explanatory Note:
   > *"Agent limits are configured by the spool-hub administrator to govern compute allocation."*
4. No edit buttons, inputs, or save actions are rendered for workspace admins.

---

## 8. Acceptance Case: The `example-ws` Scenario

This acceptance case mirrors the verbatim owner requirement from msg `dc010e3c` and validates the end-to-end enforcement lifecycle.

### Setup
- Workspace `example-ws` is provisioned on the cloud instance.
- Spool-hub admin configures the agent caps via `PUT /v1/operator/workspaces/example-ws/agent-caps`:
  ```json
  {
    "caps": {
      "claude": 1,
      "grok": 1,
      "agy": 2,
      "mistral": 1
    }
  }
  ```
- Vendor `qwen` is left unlisted (`null`), confirming default uncapped behavior.

### Execution Sequence

1. **First Claude Seat:**
   - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=c-004 DRY_RUN=0`
   - Outcome: **PASS** (1/1 Claude live). Agent `c-004` appears in roster.
2. **Second Claude Seat (Violation):**
   - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=c-005 DRY_RUN=0`
   - Outcome: **REFUSED** with exit code 1.
   - Error: `FATAL agent c-005 (claude) exceeds workspace example-ws cap of 1 (currently 1 live); seating refused`.
   - Verification: `c-005` is not added to roster; `c-004` remains unaffected.
3. **First AGY Seat:**
   - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=a-004 DRY_RUN=0`
   - Outcome: **PASS** (1/2 AGY live).
4. **Second AGY Seat:**
   - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=a-005 DRY_RUN=0`
   - Outcome: **PASS** (2/2 AGY live).
5. **Third AGY Seat (Violation):**
   - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=a-006 DRY_RUN=0`
   - Outcome: **REFUSED**. Error names cap of 2 reached.
6. **First Grok Seat:**
   - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=g-004 DRY_RUN=0`
   - Outcome: **PASS** (1/1 Grok live).
7. **Second Grok Seat (Violation):**
   - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=g-005 DRY_RUN=0`
   - Outcome: **REFUSED**.
8. **First Mistral Seat:**
   - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=m-004 DRY_RUN=0`
   - Outcome: **PASS** (1/1 Mistral live).
9. **Second Mistral Seat (Violation):**
   - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=m-005 DRY_RUN=0`
   - Outcome: **REFUSED**.
10. **Uncapped Qwen Seats:**
    - Seating `q-004` and `q-005` both succeed without hindrance because `qwen` has no cap.
11. **Seat Reclamation:**
    - Agent `c-004` completes task and executes `/exit-clean`.
    - Host retires `c-004`; hub WebSocket announcement drops `c-004` from roster.
    - Claude live count in `example-ws` drops to 0.
12. **Subsequent Seating:**
    - Command: `do_spl_desk_up TENANT_ID=example-ws DESK_AGENT=c-005 DRY_RUN=0`
    - Outcome: **PASS** (1/1 Claude live).

---

## 9. Functional Requirements (FR Matrix)

| FR ID | Summary & Requirement | Enforcement Layer | Authority |
|---|---|---|---|
| **FR-001** | **Database Cap Schema**: Persist `tenant_agent_caps (tenant_id, vendor, max_live)` with foreign key cascade and RLS NULLIF fail-closed policies. | Database Migration | Planned (`0209`) |
| **FR-002** | **Spool-Hub Admin Management API**: `GET`, `PUT`, `DELETE /v1/operator/workspaces/{id}/agent-caps` guarded by `operator.workspaces` permission. | Hub API (`operator`) | Planned |
| **FR-003** | **Workspace Admin Read-Only API**: `GET /v1/tenant/agent-caps` returns configured caps and live counts; write verbs refused with HTTP 403. | Hub API (`tenant`) | Planned |
| **FR-004** | **Hub Roster Gate (`vendorCapGate`)**: In `SetRoster`, evaluate prospective vendor counts; reject additions exceeding `max_live` with `409 Conflict`. | Hub Store / Protocol | Planned |
| **FR-005** | **WebSocket Hello Handling**: In `seatRoster`, trim incoming agents violating vendor caps while retaining previously seated agents. | Hub Protocol (`ws.go`) | Planned |
| **FR-006** | **Desk Seating Check**: `do_spl_desk_up` checks vendor cap before sidecar spawn; exits 1 with fatal message naming cap and live count. | Bash Orchestration | Planned |
| **FR-007** | **Spawn Window Gate**: `spawn-window.sh` checks workspace vendor cap; refuses spawn with exit 14 (`VENDOR_CAP_EXCEEDED`) if capped out. | Bash Orchestration | Planned |
| **FR-008** | **Dispatcher Failover**: `do_spl_take` automatically fails over to backup vendor when primary vendor is at workspace cap. | Bash Orchestration | Planned |
| **FR-009** | **Default Uncapped Semantics**: Unlisted vendors or workspaces with no rows in `tenant_agent_caps` permit arbitrary concurrent agents up to bot seat limit. | Hub Store / Bash | Planned |
| **FR-010** | **Audit Logging**: Every create, update, or delete of workspace agent caps appends an audit row to `operator_audit`. | Hub Store (`audit`) | Planned |
| **FR-011** | **Operator Console UI**: `OperatorPane.vue` renders editable inputs for all 5 vendors in workspace management drawer. | Web UI (`operator`) | Planned |
| **FR-012** | **Workspace Settings UI**: `TenantSettingsDialog.vue` renders read-only status table showing caps, live counts, and limit badges. | Web UI (`tenant`) | Planned |

---

## 10. Tests and Acceptance Criteria (ACs & Negative Controls)

### 10.1 Acceptance Criteria

- **AC-01 (Store Persistence):** Store correctly inserts, updates, and deletes vendor caps for a tenant; queries return exact `(vendor, max_live)` mapping.
- **AC-02 (Operator Auth Gate):** Request to `PUT /v1/operator/workspaces/{id}/agent-caps` with regular workspace admin token is rejected with HTTP 403 `operator.workspaces`.
- **AC-03 (Store Roster Rejection):** `SetRoster` rejects adding a 2nd `claude` agent to a workspace with `claude: 1`, returning `ErrVendorCapExceeded`.
- **AC-04 (Desk Up Refusal):** `do_spl_desk_up` for `c-005` in `example-ws` (with `c-004` active) exits with code 1 and outputs formatted refusal message.
- **AC-05 (Spawn Window Refusal):** `spawn-window.sh` for `claude` in `example-ws` exits with code 14 and leaves tmux windows untouched.
- **AC-06 (Live Count Reclamation):** Retiring `c-004` immediately allows `c-005` to be seated via `do_spl_desk_up`.
- **AC-07 (Uncapped Vendor Independence):** Workspace with `claude: 1` allows multiple `qwen` instances to seat concurrently without interference.

### 10.2 Negative Controls & Red Tests

- **Control C1 (Cap Bypass Failure):** Execute `SetRoster` with two Claude agents when `claude: 1`. Disabling `vendorCapGate` allows both to seat; with `vendorCapGate` active, the transaction *must* fail with `ErrVendorCapExceeded`.
- **Control C2 (Privilege Escalation Failure):** Issue `PUT /v1/operator/workspaces/{id}/agent-caps` using a session token from `example-ws` admin. The endpoint *must* return HTTP 403 Forbidden.
- **Control C3 (Default Regression Guard):** Verify seating in an uncapped workspace. The cap check *must* return nil and allow seating without error.

---

## 11. Build Rows (Disjoint Files, 2 Lanes, Sequenced, with Red Controls)

To implement this specification cleanly across parallel lanes without merge collisions, the work is partitioned into 6 build rows across 2 designated lanes.

| Row | Lane | Scope & Layer | Disjoint Files Owned | Depends On | Red Control & Verification Checkpoint |
|---|---|---|---|---|---|
| **R1** | Lane A | Database Migration & Hub Store Logic | `csi-spl-rdb/src/sql/postgres/spool-hub/0209_workspace_agent_caps.sql`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/agent_caps.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/agent_caps_postgres.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/agent_caps_memory.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/agent_caps_test.go` | — | `TestVendorCapGate`: inserting 2nd agent of capped vendor in `SetRoster` succeeds instead of returning `ErrVendorCapExceeded`. |
| **R2** | Lane A | Hub API Routes & Operator RBAC | `csi-spl-api/src/go/spool-hub-api/internal/hub/operator_agent_caps.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/tenant_agent_caps.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/operator_agent_caps_test.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/tenant_agent_caps_test.go` | R1 | `TestOperatorAgentCapsRBAC`: workspace admin calling `PUT /v1/operator/workspaces/{id}/agent-caps` returns 200 instead of 403 Forbidden. |
| **R3** | Lane A | Desk Seating Action & Shell Integration | `csi-spl-orc/src/bash/run/spl-agent-caps.func.sh`<br>`csi-spl-orc/src/bash/run/spl-desk-up.func.sh`<br>`csi-spl-orc/src/bash/tests/desk-agent-caps.tst.sh` | R1, R2 | `desk-agent-caps.tst.sh`: `do_spl_desk_up` seats a 2nd claude in `example-ws` when cap is 1 instead of exiting 1 with refusal. |
| **R4** | Lane B | Spawn Window Gate & Dispatcher Lane Mix | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh`<br>`csi-spl-orc/src/bash/run/spl-take.func.sh`<br>`csi-spl-orc/src/bash/tests/spawn-vendor-caps.tst.sh` | R3 | `spawn-vendor-caps.tst.sh`: `spawn-window.sh` starts tmux pane for 2nd claude in `example-ws` instead of exiting 14. |
| **R5** | Lane B | Web User Interface & Localization | `csi-spl-wui/src/components/OperatorPane.vue`<br>`csi-spl-wui/src/components/TenantSettingsDialog.vue`<br>`csi-spl-wui/src/utils/spool-client-lazy.mjs`<br>`csi-spl-wui/src/stores/operator-pane.ts`<br>`csi-spl-wui/i18n/locales/en.json` (and all 19 locales) | R2 | `pnpm run test:unit`: workspace admin in non-operator workspace sees editable inputs instead of read-only badge/table. |
| **R6** | Lane B | Acceptance Test Suite (`example-ws`) | `csi-spl-api/src/bash/tests/test-workspace-agent-caps.sh`<br>`csi-spl-orc/src/bash/tests/example-ws-caps.tst.sh`<br>`csi-spl-wui/tests/e2e/workspace-agent-caps.test.mjs` | R1–R5 | `example-ws-caps.tst.sh`: full multi-vendor acceptance sequence allows a 2nd concurrent claude to seat alongside the 1st. |

---

<!-- version: 1.0.0 · updated: 2026-10-19 · last-edit: 2026-10-19T17:00:00Z -->
