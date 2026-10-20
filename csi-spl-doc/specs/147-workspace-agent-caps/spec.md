# Feature Specification: Per-Workspace Agent Caps by Kind

**Feature ID**: `147-workspace-agent-caps` · **Milestone**: M3 / M4 · **Status**: Planned (Spec Only) · **Version**: 1.1.0
**Created**: 2026-10-19 · **Updated**: 2026-10-19 · **Epic**: SPL-2400 · **Issue**: SPL-2586 · **Lane**: a-799-c002-spec-workspace-agent-caps
**Authority**: this file for system behaviour, database schema, protocol rules, API contracts, and enforcement semantics. Status vocabulary: `../README.md` §2.3. Docs only: this spec builds nothing (`../README.md` §2.4).
**Reviews**: [review-claude.md](review-claude.md) (c-864, R7 seat, signed off on master in commit 0a97ae54d).

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
4. **P4 (Default Uncapped / Zero Regression):** A workspace with no cap configured for a given vendor defaults to unlimited live instances (absent row). Existing workspaces without explicit caps continue to operate exactly as today, constrained only by tenant-wide `seats_bots` (M4) or box host limits. Setting `max_live = 0` explicitly forbids that vendor (zero live allowed).
5. **P5 (Universal Path Enforcement):** The cap must be enforced across every path that seats or connects an agent into a workspace. The hub's `SetRoster` method is the sole authority; host-side seating tools perform courtesy pre-checks. If admitting an agent would cause the count of live agents of that vendor in that workspace to exceed `max_live`, the operation is refused.
6. **P6 (Informative Rejection Message):** Every refusal explicitly identifies the affected workspace, the agent vendor, the configured cap, and the current live count (e.g. `refused: claude agent cap reached for workspace example-ws: max 1 live, currently 1 live`).
7. **P7 (Dynamic Concurrency Lifecycle & Explicit Release):** Caps apply strictly to concurrent *live* instances. When an agent terminates cleanly (`/exit-clean`) or is retired, its live seat must be released promptly via explicit desk unseating / retire unannouncement (`do_spl_desk_down` removing the agent's desk spool directory), rather than relying on the background `dropDead` timeout (up to 60 minutes on customer desks where `DESK_RETIRE=0`), restoring capacity for subsequent seating of that vendor.

---

## 1. Glossary and Core Definitions

- **Workspace / Tenant:** The isolated tenant container on a spool-hub instance, identified by `workspace_id` (in database schemas and headers: `tenant_id`, e.g. `t1`, `example-ws`).
- **Spool-Hub Admin (Operator Admin):** A human member holding the `admin` role in the designated operator workspace (Spec 074, `tenants.is_operator = true`). Only this identity holds instance-wide management authority (`operator.workspaces`).
- **Workspace Admin:** A member holding the `admin` role within a regular workspace (Spec 025). Holds `tenant.settings` for their own workspace, but possesses zero operator privileges.
- **Agent Kind / Vendor:** The underlying AI model vendor and runtime kind of an agent. Governed by Spec 061 and Spec 115, the valid vendor set is resolved canonically by Go `agentid.Kind(agent_id)`:
  - `claude` (Anthropic): agent ID prefix `c-` (legacy `CLE-`)
  - `grok` (xAI): agent ID prefix `g-` (legacy `GRK-`)
  - `mistral` (Mistral): agent ID prefix `m-`
  - `agy` (Google): agent ID prefix `a-` (legacy `AGY-`)
  - `qwen` (OpenAI-compatible): agent ID prefix `q-` (legacy `QWN-`)
- **Agent Cap (`max_live`):** A non-negative integer specifying the maximum number of concurrent live agent instances of a specific vendor allowed within a workspace. Uncapped vendors have no row in `tenant_agent_caps`; a row with `max_live = 0` blocks all instances of that vendor.
- **Live Agent:** An agent instance actively seated in a workspace that occupies compute, memory, or hub routing resources. Formally defined as an active `(box_id, agent_id)` pair announced in the hub's `roster` for that workspace from a box within its presence TTL. (Dedicated agent reservations under Spec 144 will be incorporated when Spec 144 lands as a named follow-up).
- **Pair Counting `(box_id, agent_id)`:** Because the roster primary key is `(tenant_id, box_id, agent_id)` (`0001_hub_core.sql:47`) and role seats `c-001..c-003` exist once per box (`agentid.IsRoleSeat`, `agentid.go:121`), live agents must be counted by `(box_id, agent_id)` pairs, not `DISTINCT agent_id`. Role seats or fleet agents seated into a customer workspace count against that workspace's cap for their vendor.
- **Uncapped:** The absence of a cap record for `(workspace, vendor)`, granting unconstrained instance counts up to tenant-wide bot seat limits.

---

## 2. Today, Measured: Every Path that Seats or Spawns an Agent into a Workspace

An empirical code audit of trunk (`master` @ `683348fd9`) establishes the seating and announcement paths into a workspace.

### 2.1 The Architectural Authority: Hub Store `SetRoster`

The Cloud Run hub is the **single authority** for roster state and seating. A box cannot force an agent onto a roster without calling `SetRoster`:
- `grep -rn "INTO roster\|UPDATE roster" csi-spl-api csi-spl-rdb --include=*.go --include=*.sql | grep -v _test` -> exactly 2 sites:
  1. `csi-spl-api/src/go/spool-hub-api/internal/store/postgres.go:356`: the insert in `SetRoster`.
  2. `csi-spl-api/src/go/spool-hub-api/internal/store/agent_run.go:95`: `UPDATE roster ... SET running`, updating runtime status for existing rows without creating new seats.
- `grep -rn "SetRoster(" csi-spl-api/src/go --include=*.go | grep -v _test | grep -v internal/store/` -> exactly 3 callers, all in `csi-spl-api/src/go/spool-hub-api/internal/hub/ws.go`:
  1. Line 485: `onAnnounce` (handling `wire.TAnnounce` frames from connected boxes).
  2. Line 518: `seatRoster` initial call on `wire.THello`.
  3. Line 538: `seatRoster` retry loop on `wire.THello`.
- Because every roster mutation is funnelled into `SetRoster`, placing the vendor cap enforcement inside `SetRoster` guarantees that no box or rogue script can bypass workspace agent caps.

### 2.2 Host Desk Seating Paths (`do_spl_desk_up` and Callers)

On host boxes, desk actions seat agents into a target workspace by provisioning local spool directories and starting the `spool hub-run` sidecar:
- **Primary Seating Action (`do_spl_desk_up`):** `csi-spl-orc/src/bash/run/spl-desk-up.func.sh:62-128`.
  - Line 64: `spl_box_ws_guard` validates workspace enrollment.
  - Lines 97-99: Creates local spool tree `$SPL_STATE_DIR/desk/$tenant/$box/spool/$agent/{inbox,outbox,archive}`.
  - Line 102: Pins box key via `spl_desk_pin`.
  - Line 106: Starts `spool hub-run` sidecar via `spl_desk_sidecar`.
  - Line 109: Waits for hub roster announcement via `spl_desk_wait_roster`.
- **All-Seats Desk Reconciliation (`do_spl_desk_up_all`):** `csi-spl-orc/src/bash/run/spl-desk-up-all.func.sh:80`. Iterates over role seats and seats each active desk.
- **Multi-Tenant Desk Reconciliation (`do_spl_desk_up_tenants`):** `csi-spl-orc/src/bash/run/spl-desk-up-tenants.func.sh:27`. Scans workspace directories under `$SPL_STATE_DIR/desk/` and invokes `do_spl_desk_up`. Runs with `DESK_RETIRE=0` (customer desks keep their dirs across routine ticks).
- **Multi-Box Desk Reconciliation (`do_spl_desk_up_boxes`):** `csi-spl-orc/src/bash/run/spl-desk-up-boxes.func.sh:32`. Reconciles desks on remote boxes from `lease.conf`.
- **Periodic Desk Cron:** `csi-spl-orc/src/bash/scripts/desk-reconcile-cron.sh:374`. Calls `do_spl_desk_up_all`.
- **MCP Agent Seating:** `csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-mcp.sh:114`. Calls `do_spl_desk_up` with `DESK_POKE=0` to seat MCP service agents.
- **Dedicated Box Workspace Binding:** `csi-spl-orc/src/bash/run/spl-box-workspace-setup.func.sh:28-85`. Binds a host machine exclusively to one workspace (`SPL_WS_BASE`).
- **Courtesy Nature of Host Checks:** A box announces every directory present in its desk spool (`hubclient/agent_drop.go:40`, `rosterAgents` -> `scanAgents`). Therefore, host-side pre-checks in `do_spl_desk_up` are a user-friendly courtesy to fail fast before starting processes, but the hub gate is the actual security and quota enforcement point.
- **Channel Membership (`spl-channel-agent-add-op.func.sh`):** Note that channel membership operations are *not* seating paths: line 30 verifies that an agent is already on the tenant roster (exiting with FATAL `not_a_member` if not), so channel operations never introduce new live agent instances.

### 2.3 Concurrency & Lock Serialization

Two boxes announcing at the same time cannot race past the last seat because `SetRoster` executes within a database transaction managed by `s.inTenant`:
- In `internal/store/seats_postgres.go:29`, `botSeatGate` acquires:
  ```sql
  SELECT seats_bots FROM tenants WHERE tenant_id = $1 FOR NO KEY UPDATE
  ```
- Calling `vendorCapGate` directly *after* `botSeatGate` in `SetRoster` ensures that all prospective roster modifications for that workspace are strictly serialized by that row lock on `tenants`.
- This serialization guarantees that concurrent announcements from multiple boxes cannot double-allocate the remaining quota for any vendor.

### 2.4 Autonomous Spawning and Fleet Coordination

- **Window Spawning Script (`spawn-window.sh`):** `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-window.sh`. Spawns fleet worker panes on coordination boxes. Uses claim directories `$SPOOL_ROOT/<id>/` (`sw_release_claim` at line 389).
- **Fleet Tenant Isolation:** `LANE_TENANT` (`spl-lane-map.func.sh:84`, default `${LEASE_TENANT:-}`) defines the coordination tenant that holds the fleet lane map. Fleet workers do not spawn directly into customer workspaces; agents enter customer workspaces via desk seating (`do_spl_desk_up`).
- **Dispatcher Operations:** `do_spl_take` (`csi-spl-orc/src/bash/run/spl-take.func.sh:35-80`) claims topics for fleet processing. Vendor selection logic resides in `do_spl_lane_mix` (`spl-lane-mix.func.sh`) and box allocation in `do_spl_box_pick` (`spl-box-pick.func.sh`).

### 2.5 Hub Schema & Tables Context
- **Roster Table:** `csi-spl-rdb/src/sql/postgres/spool-hub/0001_hub_core.sql:47`. `roster (tenant_id, box_id, agent_id, announced_at)` (agent ID grammar check updated in `0155_mistral_kind.sql:26-27`).
- **Agent Seats Table:** `csi-spl-rdb/src/sql/postgres/spool-hub/0107_agent_seats.sql:25-32`. Tracks initial seating timestamps.
- **Tenant Bot Limits:** `csi-spl-rdb/src/sql/postgres/spool-hub/0012_m4_seats_buy_stamp.sql:25-26`. `tenants.seats_bots` (tenant-wide aggregate).
- **Agent Join Tokens:** `csi-spl-rdb/src/sql/postgres/spool-hub/0119_agent_join_tokens.sql:29`. Creates `agent_join_tokens`.
- **Operator Audit Log:** `csi-spl-rdb/src/sql/postgres/spool-hub/0115_operator_workspaces.sql:37`. Records operator mutations in `operator_audit`.

---

## 3. Data Model & Database Migration Sketch

To persist per-workspace agent caps by vendor, a new migration `<next>_workspace_agent_caps.sql` is introduced. (Migration `0209` is allocated to `0209_human_rail_order_reporting.sql`; the concrete sequence number `<next>` is assigned by Lane A at commit/rebase time).

### 3.1 Migration Sketch: `<next>_workspace_agent_caps.sql`

```sql
-- <next>_workspace_agent_caps.sql — Per-workspace agent caps by kind/vendor
-- Spec 147 (SPL-2586, owner orders HUM-10 msg 9c96ca9e)
--
-- Defines max live concurrent agents per vendor for each workspace.
-- Uncapped vendors have no row; max_live = 0 forbids that vendor.
-- Set and edited ONLY by spool-hub admin (operator_scope); readable by workspace.
--
-- DEPLOY ORDER: before hub image deployment supporting vendorCapGate.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS tenant_agent_caps (
    tenant_id       text         NOT NULL,
    vendor          text         NOT NULL,
    max_live        integer      NOT NULL,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),
    updated_by      text         NOT NULL,
    CONSTRAINT pk_tenant_agent_caps PRIMARY KEY (tenant_id, vendor),
    CONSTRAINT fk_tenant_agent_caps_tenant FOREIGN KEY (tenant_id)
        REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    CONSTRAINT chk_tenant_agent_caps_vendor
        CHECK (vendor IN ('claude', 'grok', 'mistral', 'agy', 'qwen')),
    CONSTRAINT chk_tenant_agent_caps_max_live
        CHECK (max_live >= 0)
);

-- Note: No separate index on tenant_id is needed because tenant_id is already
-- the leading column of the primary key (tenant_id, vendor).

-- Row-Level Security: fail-closed NULLIF pattern
ALTER TABLE tenant_agent_caps ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_agent_caps FORCE ROW LEVEL SECURITY;

-- Workspace members and workspace admins can READ their own workspace's caps
CREATE POLICY tenant_scope ON tenant_agent_caps
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));

-- Only the operator scope (spool-hub admin) can INSERT, UPDATE, DELETE, or SELECT across all tenants.
-- This strict FOR ALL policy on operator_scope ensures tenant members can never write caps.
CREATE POLICY operator_scope ON tenant_agent_caps
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
```

### 3.2 Audit Trail Integration

All mutations of `tenant_agent_caps` record an entry in `operator_audit` (`store.OperatorAudit`, `csi-spl-rdb/src/sql/postgres/spool-hub/0115_operator_workspaces.sql:37`):
- `action`: `"set_agent_caps"` or `"delete_agent_cap"`
- `tenant_id`: target workspace (e.g. `example-ws`)
- `actor_hum`: human ID of operator admin
- `detail`: `{"vendor": "claude", "max_live": 1, "previous": null}`

---

## 4. Definition of "Live" Agent Count & Enforcement Semantics

### 4.1 Definitive Count Calculation

An agent is counted as **live** for vendor $V$ in workspace $W$ based on the hub's authoritative database state:
- Count the number of `(box_id, agent_id)` pairs in `roster` for workspace $W$ whose box is currently active within the hub's presence TTL (`presenceTTL()` = 2 x `presenceEvery`, `hub/presence.go:36`, default 30s).
- The mapping from `agent_id` to vendor kind is performed using Go `agentid.Kind(agent_id)` (`agentid.go:102`), which canonicalizes all modern and legacy prefixes and strips box suffixes.
- Formula inside the hub transaction:
  $$Live(W, V) = \sum_{(box, agent) \in Roster(W)} \mathbf{1}_{\{agentid.Kind(agent) = V \land BoxActive(box)\}}$$

### 4.2 Distinguishing Live vs Inactive States

| State | Definition | Counts as Live? | Rationale |
|---|---|---|---|
| **Active Running** | Process running, WebSocket connected, announced in `roster`. | **YES** | Consumes concurrent vendor seat and compute resources. |
| **Idle Waiting** | Pane open, waiting for prompt/message, announced in `roster`. | **YES** | Reserved capacity; immediately available to answer. |
| **Clean Exited / Retired** | Desk unseated (`do_spl_desk_down`), desk spool directory removed. | **NO** | Promptly omitted from box announcement; seat released. |
| **Stale Box Disconnect** | Box offline beyond presence TTL (`presenceTTL()`). | **NO** | Dead box does not consume live capacity. |
| **Unseated Pane** | Local process running in pane but not seated via `do_spl_desk_up`. | **NO** | Not enrolled in workspace; cannot receive workspace DMs or posts. |

---

## 5. Universal Enforcement Mechanics Across Every Path

Enforcement is layered between the Cloud Run hub boundary (authoritative) and host-side orchestration tools (courtesy).

```
                              SEATING ATTEMPT (do_spl_desk_up)
                                            │
                                            ▼
                                   Host Courtesy Pre-check
                                  (GET /v1/tenant/agent-caps)
                                            │
                                  Live >= max_live?
                                 ┌──────────┴──────────┐
                                 ▼                     ▼
                                YES                   NO
                          Refuse: exit 1         Proceed: start sidecar
                          Print Cap Error        and announce desk
                                                       │
                                                       ▼
                                            Cloud Run Hub Boundary
                                           (SetRoster in ws.go)
                                                       │
                                              Acquire tenants lock
                                            (FOR NO KEY UPDATE in tx)
                                                       │
                                                 vendorCapGate
                                                       │
                                              Live >= max_live?
                                             ┌─────────┴─────────┐
                                             ▼                   ▼
                                            YES                 NO
                                       Refuse: 409          Commit roster
                                    vendor_cap_exceeded    & broadcast
```

### 5.1 Hub WebSocket Boundary (`SetRoster` & `vendorCapGate`)

In both `internal/store/postgres.go` (line 335) and `internal/store/memory.go` (line 272) inside `SetRoster`, execute `vendorCapGate` directly following `botSeatGate`:

```go
func (s *Postgres) SetRoster(ctx context.Context, tenant, box string, agents []string, now time.Time) error {
    return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
        // botSeatGate locks tenants row: FOR NO KEY UPDATE
        if err := s.botSeatGate(ctx, tx, tenant, box, agents); err != nil {
            return err
        }
        // vendorCapGate executes within the same serialized lock
        if err := s.vendorCapGate(ctx, tx, tenant, box, agents); err != nil {
            return err
        }
        // ... proceed with roster update ...
    })
}
```

Implementation logic for `vendorCapGate`:
1. Query `tenant_agent_caps` for `tenant`: map `vendor -> max_live`. If empty, return `nil` (default uncapped).
2. Fetch current active roster `(box_id, agent_id)` pairs for `tenant`.
3. Compute the prospective agent set: replace existing agents for `box` with the incoming `agents` list.
4. Count prospective agents per vendor using `agentid.Kind(agent_id)`.
5. For each vendor $V$, if configured cap $max\_live(V)$ exists and $Count(V) > max\_live(V)$, return `store.ErrVendorCapExceeded{Vendor: V, Cap: max_live, Live: Count(V)}`.
6. **In `onAnnounce` (`ws.go:485`):** If `errors.As(err, &capErr)`, fail the announcement frame with HTTP 409 Conflict (`billing.TokenQuota` / `"vendor_cap_exceeded"`), naming the vendor, cap, and requested count.
7. **In `seatRoster` (`ws.go:517`):** When handling `wire.THello`, trim incoming agents that would violate the vendor cap, seat only the allowed subset (retaining previously seated agents on that box), and pass only the trimmed admitted agent list to `SetSubscriptions` (`ws.go:339`).

### 5.2 Host Desk Seating Action (`do_spl_desk_up`)

In `csi-spl-orc/src/bash/run/spl-desk-up.func.sh`:
- Courtesy pre-flight check: query active caps via `GET /v1/tenant/agent-caps` using desk credentials.
- Resolve vendor kind using `spl_kind_of_agent_id "$agent"`.
- If a cap exists for that vendor and live count is already $\ge max\_live$:
  - Log fatal error:
    `FATAL agent $agent ($vendor) exceeds workspace $tenant cap of $max_live (currently $live live); seating refused`
  - Exit 1 before creating directories or starting sidecar.
- **Explicit Seat Release on Exit:** When an agent exits cleanly or is retired, `do_spl_desk_down` or `agent-id-retire.sh` explicitly removes the agent's spool directory under `$SPL_STATE_DIR/desk/$tenant/$box/spool/$agent/`. On the next announcement tick, the box immediately reports the updated roster without the agent, releasing the seat within seconds rather than waiting for `agent_drop_after_minutes` (up to 60 minutes).

---

## 6. API Routes & Protocol Contracts

### 6.1 Spool-Hub Admin Management Routes (Operator Workspace Only)

Requires valid operator admin session (`tenants.is_operator = true`, role `admin`, `operator.workspaces` permission). Registered in `internal/hub/operator.go:272` under `routeOperatorWorkspaces`.

#### `GET /v1/operator/workspaces/{id}/agent-caps`
Returns all configured agent caps for the workspace.

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
Configures or updates agent caps for the workspace. Passing a vendor with value `null` removes that vendor's cap.

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
Returns updated caps object and appends audit row to `operator_audit`.

**Error Responses:**
- `400 Bad Request`: `{"error": "bad_vendor", "detail": "vendor 'deepseek' is not supported"}`
- `400 Bad Request`: `{"error": "bad_cap", "detail": "max_live must be a non-negative integer"}`
- `403 Forbidden`: `{"error": "operator.workspaces", "detail": "only an admin of the operator workspace manages agent caps"}`
- `404 Not Found`: `{"error": "not_found", "detail": "workspace 'example-ws' does not exist"}`

#### `DELETE /v1/operator/workspaces/{id}/agent-caps/{vendor}`
Removes the cap for a specific vendor, reverting to uncapped. Returns `204 No Content`.

#### `OPTIONS /v1/operator/workspaces/{id}/agent-caps`
CORS preflight support, returning `204 No Content` with standard CORS headers.

---

### 6.2 Workspace Inspection Route (Read-Only)

#### `GET /v1/tenant/agent-caps`
Accessible to all authenticated members of the active workspace. Non-GET requests return HTTP `405 Method Not Allowed`.

**Request:**
```http
GET /v1/tenant/agent-caps HTTP/1.1
Host: api.<BASE_DOMAIN>
X-Spool-Tenant: example-ws
Cookie: session=<workspace_member_session>
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

---

## 7. Web User Interface (WUI) Integration

### 7.1 Spool-Hub Admin Console (`OperatorPane.vue`)

In `csi-spl-wui/src/components/OperatorPane.vue` and `csi-spl-wui/src/stores/operator-pane.ts`:
1. When an operator admin opens the workspace edit drawer, an **"Agent Caps by Vendor"** section is displayed.
2. Numerical inputs for `claude`, `grok`, `agy`, `mistral`, `qwen`.
3. An empty input or clear action sets `null` (`∞ Unlimited`). Setting `0` blocks that vendor.
4. "Save Caps" dispatches `PUT /v1/operator/workspaces/{id}/agent-caps`.

### 7.2 Workspace Settings (`agents.vue`)

In `csi-spl-wui/src/pages/tenant-settings/agents.vue`:
1. Renders a read-only table: **"Workspace Agent Capacity"**.
2. Displays Vendor, Cap, Live count, and status badges (`Available`, `At Limit`, `Unlimited`).
3. Informational notice: *"Agent limits are configured by the spool-hub administrator to govern compute allocation."*
4. All UI strings reside in `csi-spl-wui/i18n/locales/*.json` across all 19 supported locales, verified under agy language review.

---

## 8. Acceptance Case: The `example-ws` Scenario

Mirrors the owner requirement from msg `dc010e3c` and verifies full enforcement.

### Setup
- Workspace `example-ws` provisioned.
- Spool-hub admin sets caps via `PUT /v1/operator/workspaces/example-ws/agent-caps`:
  `{"caps": {"claude": 1, "grok": 1, "agy": 2, "mistral": 1}}`
- Vendor `qwen` is unlisted (`null`), confirming default uncapped behavior.

### Execution Sequence

1. **First Claude Seat:**
   - Command: `TENANT_ID=example-ws DESK_AGENT=c-004 DRY_RUN=0 ./run -a do_spl_desk_up`
   - Outcome: **PASS** (1/1 Claude live). `c-004` appears on roster.
2. **Second Claude Seat (Violation):**
   - Command: `TENANT_ID=example-ws DESK_AGENT=c-005 DRY_RUN=0 ./run -a do_spl_desk_up`
   - Outcome: **REFUSED** (exit code 1).
   - Error: `FATAL agent c-005 (claude) exceeds workspace example-ws cap of 1 (currently 1 live); seating refused`.
3. **First AGY Seat:**
   - Command: `TENANT_ID=example-ws DESK_AGENT=a-004 DRY_RUN=0 ./run -a do_spl_desk_up` -> **PASS** (1/2 AGY live).
4. **Second AGY Seat:**
   - Command: `TENANT_ID=example-ws DESK_AGENT=a-005 DRY_RUN=0 ./run -a do_spl_desk_up` -> **PASS** (2/2 AGY live).
5. **Third AGY Seat (Violation):**
   - Command: `TENANT_ID=example-ws DESK_AGENT=a-006 DRY_RUN=0 ./run -a do_spl_desk_up` -> **REFUSED** (exceeds cap of 2).
6. **First Grok Seat:**
   - Command: `TENANT_ID=example-ws DESK_AGENT=g-004 DRY_RUN=0 ./run -a do_spl_desk_up` -> **PASS** (1/1 Grok live).
7. **Second Grok Seat (Violation):**
   - Command: `TENANT_ID=example-ws DESK_AGENT=g-005 DRY_RUN=0 ./run -a do_spl_desk_up` -> **REFUSED**.
8. **First Mistral Seat:**
   - Command: `TENANT_ID=example-ws DESK_AGENT=m-004 DRY_RUN=0 ./run -a do_spl_desk_up` -> **PASS** (1/1 Mistral live).
9. **Second Mistral Seat (Violation):**
   - Command: `TENANT_ID=example-ws DESK_AGENT=m-005 DRY_RUN=0 ./run -a do_spl_desk_up` -> **REFUSED**.
10. **Uncapped Qwen Seats:**
    - Seating `q-004` and `q-005` both succeed without hindrance.
11. **Explicit Seat Reclamation:**
    - Agent `c-004` completes task and runs `/exit-clean`.
    - `do_spl_desk_down` removes `c-004` desk spool directory.
    - Box roster announcement promptly drops `c-004`.
    - Claude live count in `example-ws` drops to 0 within seconds.
12. **Subsequent Seating:**
    - Command: `TENANT_ID=example-ws DESK_AGENT=c-005 DRY_RUN=0 ./run -a do_spl_desk_up`
    - Outcome: **PASS** (1/1 Claude live).

---

## 9. Functional Requirements (FR Matrix)

| FR ID | Summary & Requirement | Enforcement Layer | Authority |
|---|---|---|---|
| **FR-001** | **Database Cap Schema**: Persist `tenant_agent_caps (tenant_id, vendor, max_live)` with RLS fail-closed policies. | Database Migration | Built R1 (rdb `0212`, SPL-2675) |
| **FR-002** | **Spool-Hub Admin Management API**: `GET`, `PUT`, `DELETE`, `OPTIONS /v1/operator/workspaces/{id}/agent-caps` guarded by `operator.workspaces`. | Hub API (`operator`) | Planned |
| **FR-003** | **Workspace Admin Read-Only API**: `GET /v1/tenant/agent-caps` returns caps and live counts; non-GET returns HTTP 405. | Hub API (`tenant`) | Planned |
| **FR-004** | **Hub Roster Gate (`vendorCapGate`)**: In `SetRoster`, evaluate prospective vendor counts; reject additions exceeding `max_live` with `409 Conflict`. | Hub Store / Protocol | Built R1 (SPL-2675) |
| **FR-005** | **WebSocket Hello Handling**: In `seatRoster`, trim incoming agents violating vendor caps while retaining previously seated agents. | Hub Protocol (`ws.go`) | Built R1 (SPL-2675) |
| **FR-006** | **Desk Seating Courtesy Check**: `do_spl_desk_up` checks vendor cap before sidecar spawn; exits 1 with fatal message naming cap and live count. | Bash Orchestration | Planned |
| **FR-007** | **Explicit Desk Teardown**: `do_spl_desk_down` removes desk directory on agent exit, achieving prompt seat release. | Bash Orchestration | Planned |
| **FR-008** | **Audit Logging**: Every create, update, or delete of workspace agent caps appends an audit row to `operator_audit`. | Hub Store (`audit`) | Built R1 (SPL-2675) |
| **FR-009** | **Default Uncapped Semantics**: Unlisted vendors or workspaces with no rows in `tenant_agent_caps` permit arbitrary concurrent agents up to bot seat limit. | Hub Store / Bash | Built R1 (SPL-2675) |
| **FR-010** | **Operator Console UI**: `OperatorPane.vue` renders editable inputs for all 5 vendors in workspace management drawer. | Web UI (`operator`) | Planned |
| **FR-011** | **Workspace Settings UI**: `pages/tenant-settings/agents.vue` renders read-only status table showing caps, live counts, and limit badges. | Web UI (`tenant`) | Planned |

---

## 10. Tests and Acceptance Criteria (ACs & Negative Controls)

### 10.1 Acceptance Criteria

- **AC-01 (Store Persistence):** Store correctly inserts, updates, and deletes vendor caps for a tenant; queries return exact `(vendor, max_live)` mapping.
- **AC-02 (Operator Auth Gate):** Request to `PUT /v1/operator/workspaces/{id}/agent-caps` with regular workspace admin token is rejected with HTTP 403 `operator.workspaces`.
- **AC-03 (Store Roster Rejection):** `SetRoster` rejects adding a 2nd `claude` agent to a workspace with `claude: 1`, returning `ErrVendorCapExceeded`.
- **AC-04 (Desk Up Refusal):** `do_spl_desk_up` for `c-005` in `example-ws` (with `c-004` active) exits with code 1 and outputs formatted refusal message.
- **AC-05 (Prompt Live Count Reclamation):** Retiring `c-004` and removing desk directory restores capacity within seconds (< 5s), allowing `c-005` to seat via `do_spl_desk_up`.
- **AC-06 (Uncapped Vendor Independence):** Workspace with `claude: 1` allows multiple `qwen` instances to seat concurrently without interference.
- **AC-07 (Pair Counting Accuracy):** Role seats on multiple boxes (`c-001` on box 1 and `c-001` on PC) seated into the same workspace count as 2 distinct live instances.

### 10.2 Negative Controls & Red Tests

- **Control C1 (Cap Bypass Failure):** Execute `SetRoster` with two Claude agents when `claude: 1`. Disabling `vendorCapGate` allows both to seat; with `vendorCapGate` active, the transaction *must* fail with `ErrVendorCapExceeded`.
- **Control C2 (Privilege Escalation Failure):** Issue `PUT /v1/operator/workspaces/{id}/agent-caps` using a session token from `example-ws` admin. The endpoint *must* return HTTP 403 Forbidden.
- **Control C3 (Default Regression Guard):** Verify seating in an uncapped workspace. The cap check *must* return nil and allow seating without error.
- **Control C4 (Stale Box Presence Control):** When `claude: 1`, an agent on a box whose `last_hello_at` is older than `presenceTTL()` is excluded from the live count, allowing a new agent on an active box to seat. If the presence freshness filter is removed, seating is incorrectly refused.
- **Control C5 (Parallel Announcement Race Control):** Two concurrent `SetRoster` calls for the last vendor seat from two boxes. With `FOR NO KEY UPDATE` row locking on `tenants`, exactly one succeeds and one receives `409 Conflict`. If the gate is evaluated without the row lock, both calls succeed (red condition). Runs on PostgreSQL under `PRE_PUSH_TIER=full`.

---

## 11. Build Rows (Disjoint Files, 2 Lanes, Sequenced, with Red Controls)

The work is partitioned into 6 build rows across 2 designated lanes with complete, disjoint file ownership:

| Row | Lane | Scope & Layer | Disjoint Files Owned | Depends On | Red Control & Verification Checkpoint |
|---|---|---|---|---|---|
| **R1** | Lane A | Database Migration & Hub Store Logic | `csi-spl-rdb/src/sql/postgres/spool-hub/<next>_workspace_agent_caps.sql`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/agent_caps.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/agent_caps_postgres.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/agent_caps_memory.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/postgres.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/memory.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/ws.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/store/agent_caps_test.go` | — | `TestVendorCapGate`: inserting 2nd agent of capped vendor in `SetRoster` succeeds instead of returning `ErrVendorCapExceeded`. |
| **R2** | Lane A | Hub API Routes & Operator Mux | `csi-spl-api/src/go/spool-hub-api/internal/hub/operator_agent_caps.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/tenant_agent_caps.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/operator.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/operator_agent_caps_test.go`<br>`csi-spl-api/src/go/spool-hub-api/internal/hub/tenant_agent_caps_test.go` | R1 | `TestOperatorAgentCapsRBAC`: workspace admin calling `PUT /v1/operator/workspaces/{id}/agent-caps` returns 200 instead of 403 Forbidden. |
| **R3** | Lane A | Spool CLI Caps Command & Desk Seating Check | `csi-spl-api/src/go/spool-hub-api/cmd/spool/caps.go`<br>`csi-spl-orc/src/bash/run/spl-agent-caps.func.sh`<br>`csi-spl-orc/src/bash/run/spl-desk-up.func.sh`<br>`csi-spl-orc/src/bash/tests/desk-agent-caps.tst.sh` | R1, R2 | `desk-agent-caps.tst.sh`: `do_spl_desk_up` seats a 2nd claude in `example-ws` when cap is 1 instead of exiting 1 with refusal. |
| **R4** | Lane B | Desk Teardown & Retire Seat Release | `csi-spl-orc/src/bash/run/spl-desk-down.func.sh`<br>`csi-spl-orc/src/bash/features/spawn-agents/scripts/agent-id-retire.sh`<br>`csi-spl-orc/src/bash/tests/desk-retire-caps.tst.sh` | R3 | `desk-retire-caps.tst.sh`: retiring a desk agent leaves its desk directory in place and keeps seat allocated for > 60 s instead of immediate reclamation. |
| **R5** | Lane B | Web User Interface & Localization | `csi-spl-wui/src/components/OperatorPane.vue`<br>`csi-spl-wui/src/pages/tenant-settings/agents.vue`<br>`csi-spl-wui/src/stores/operator-pane.ts`<br>`csi-spl-wui/src/utils/spool-client-lazy.mjs`<br>`csi-spl-wui/i18n/locales/*.json` (19 locales) | R2 | `pnpm run test:unit`: workspace admin in non-operator workspace sees editable inputs instead of read-only badge/table. |
| **R6** | Lane B | Acceptance Test Suite (`example-ws`) | `csi-spl-api/src/bash/tests/workspace-agent-caps.tst.sh`<br>`csi-spl-orc/src/bash/tests/example-ws-caps.tst.sh`<br>`csi-spl-wui/tests/e2e/tenant-settings.test.mjs` (extend existing) | R1–R5 | `example-ws-caps.tst.sh`: full multi-vendor acceptance sequence allows a 2nd concurrent claude to seat alongside the 1st. |

---

## 12. Review Disposition & Sign-Off

### 12.1 Independent Review Summary (c-864 Claude R7 Seat)

- Review Document: [review-claude.md](review-claude.md) (commit `a984c75f4`)
- Author / Seat: c-864 (independent Claude R7 reviewer)
- Baseline Evaluated: `spec.md` v1.0.0 (`8d439404c` + `af7f6b039`) against `origin/master` @ `683348fd9`
- Initial Review Verdict: **1 agree, 9 agree with changes, 2 disagree**

### 12.2 Disposition Matrix of Review Items

| Section | Reviewer Finding | Resolution in Spec v1.1.0 | Status |
|---|---|---|---|
| **§0 & §1** | P4: `max_live = NULL` contradicts `NOT NULL` column. P7: seat release on exit is not immediate on customer desks (`DESK_RETIRE=0`). | P4 updated: absent row = uncapped; `0` = blocked. P7 updated: explicit desk teardown (`do_spl_desk_down`) releases seat promptly. | **Folded** |
| **§2.1** | Citations: `spl-desk-up-all`, `_tenants`, `_boxes` in own files; `desk-reconcile-cron` line 374; `spool-agent.sh` does not call desk up; `0001_hub_core.sql:47`; `0119_agent_join_tokens.sql:29`; `0115_operator_workspaces.sql:37`; `dedicated_agents` does not exist; `spl-channel-agent-add-op` requires existing roster membership. | All citations corrected. Hub side identified as single authority; host checks classified as courtesy pre-checks. | **Folded** |
| **§2.3** | Concurrency: `botSeatGate` row lock `FOR NO KEY UPDATE` on `tenants` serializes transactions. | Explicitly documented dependency: `vendorCapGate` runs after `botSeatGate` within the serialized transaction. | **Folded** |
| **§3** | Migration `0209` is taken by `0209_human_rail_order_reporting.sql`. House SQL conventions: `text`, `lock_timeout`, drop redundant index on PK leading column. | Renamed to `<next>_workspace_agent_caps.sql`. Applied house SQL conventions and dropped duplicate index. | **Folded** |
| **§4** | Single definition of live count; count `(box_id, agent_id)` pairs to avoid undercounting role seats; use `presenceTTL()` and Go `agentid.Kind`. | Single definition adopted using active roster pairs, presence TTL, and canonical Go `agentid.Kind`. | **Folded** |
| **§5.1 & §5.2** | Name `store/memory.go` alongside `store/postgres.go`; define `ErrVendorCapExceeded`; specify desk cap query route; require explicit desk directory removal on exit. | Both store files named; error defined; query route documented; prompt unseating in `do_spl_desk_down` specified. | **Folded** |
| **§5.3 & §5.4** | Disagree with `LANE_TENANT` gating in `spawn-window.sh` (fleet tenant != customer workspace) and `do_spl_take` (does not pick vendor). | Dropped `LANE_TENANT` spawn gate. Documented that customer workspaces seat agents via desk paths. | **Resolved** |
| **§6** | Add `OPTIONS` route; register in `internal/hub/operator.go:272`; pick HTTP 405 for non-GET tenant routes; allow member read access. | Added `OPTIONS` route; registered in operator mux; specified HTTP 405; allowed member read access. | **Folded** |
| **§7** | Correct path to `csi-spl-wui/src/pages/tenant-settings/agents.vue`; specify 19 locales. | Updated UI path to `agents.vue` and specified all 19 locales. | **Folded** |
| **§8** | Standardize action CLI invocation `TENANT_ID=... ./run -a do_spl_desk_up`; reflect prompt seat reclamation. | Standardized CLI syntax across all 12 steps; documented explicit desk teardown. | **Folded** |
| **§10** | Add Control C4 (stale box presence TTL) and Control C5 (PostgreSQL parallel announcement race serialization). | Added controls C4 and C5 with explicit red conditions. | **Folded** |
| **§11** | Build rows missing `ws.go`, `store/postgres.go`, `store/memory.go`, `operator.go`, `cmd/spool/caps.go`, `agents.vue`; naming convention `*.tst.sh`. | Restructured into 6 disjoint rows covering all 18 impacted files with correct naming conventions. | **Folded** |
| **Missed 1** | Customer desk seat release up to 60 min late without explicit desk directory removal. | Addressed in §0 (P7), §5.2, §8 (step 11), §9 (FR-007), and §11 (R4). | **Folded** |
| **Missed 2** | Role/fleet seats in customer workspace count against cap; pair counting required. | Addressed in §1, §4.1, and §10.1 (AC-07). | **Folded** |

### 12.3 Build Record

- **R1** (Lane A, c-594, SPL-2675): `0212_workspace_agent_caps.sql`; `store.AgentCapStore` (`agent_caps*.go`), `vendorCapGate` in both `SetRoster`s after `botSeatGate`; `ws.go` answers an announce over a cap 409 `vendor_cap_exceeded` and trims a hello to old ∩ new plus each addition the caps still admit. A cap refuses only an ADDITION, so an operator lowering a cap unseats nobody (as `seats_bots`, 009 D-3). Live = a roster pair whose box stamped presence within `store.CapPresenceTTL` (60 s, the deploy's `presenceTTL()`), or the announcing box. Audit rows are written in the same operator transaction as the cap. Tests: `internal/store/agent_caps_test.go` (C1, C3, C4, C5, AC-01, AC-06, AC-07, the RLS write refusal), `internal/hub/agent_caps_ws_test.go`.

### 12.4 Sign-Off

- **Specification Author**: a-799 (Gemini 3.8 Flash High)
- **Status**: v1.1.0 Consensus Signed Off (c-864 on 0a97ae54d). Accepted by dispatch in msg 6a4652bb.

---

<!-- version: 1.1.0 · updated: 2026-10-19 · last-edit: 2026-10-19T17:48:00Z -->
