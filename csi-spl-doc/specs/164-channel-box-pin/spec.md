# 164 Channel Box Pin: Pin a Channel to Chosen Boxes (Default: Any Box of the Fleet)

Version: v1.0 (2026-10-29).  
Status: **Draft** (Placement slug `c003-channel-box-pin-spec`, Issue SPL-4171, Epic SPL-2398).  
Class: feature.  
Kind: specs_and_docs.  

Source: owner HUM-10, prd t1 topic `021d4921-a6b9-427b-bf86-4eb0b945c82d` (msgs `f9234b11`, `6b6d092c`).  
Authority: this file for the behaviour and specification. Each build row in section 8 gets its own issue when scheduled.  

Paths used below:
- `wui/` = `csi-spl-wui/src/`
- `api/` = `csi-spl-api/src/go/spool-hub-api/`
- `hub/` = `api/internal/hub/`
- `store/` = `api/internal/store/`
- `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`
- `orc/` = `csi-spl-orc/src/bash/`

Every `file:line` citation was read and verified on origin/master commit `b4ad49dc6` (2026-10-29).

---

## 1. The Owner's Request (Verbatim)

From owner HUM-10, prd t1 topic `021d4921-a6b9-427b-bf86-4eb0b945c82d`:

- **msg f9234b11**: *"it should be possible to "fix" a channel to only certain boxes ..."*
- **msg 6b6d092c**: *"by default any channel should run on any box from the cluster , but one should be able to fix only certain boxes for a channel"*

---

## 2. Today: What Exists on Master

### 2.1 Workspace Box Pinning vs Channel Box Pinning
- **Box pinning is per workspace only**: In PostgreSQL (`rdb/0001_hub_core.sql:28-35`), the `pins` table keys on `(tenant_id, box_id)` with a signed 32-byte Ed25519 public key. The hub verifies this pin before allowing any dispatch (`hub/dispatch.go:161-163`: `if _, err := s.o.Store.GetPin(ctx, c.tenant, box); err != nil { return "", nil, "unpinned_box", http.StatusNotFound, ... }`).
- **No channel-level box binding exists**: Running `git grep -iE 'allowed_boxes|channel_boxes'` across origin/master returns zero hits. Today, once a box is pinned to a workspace, all channels of that workspace treat all pinned boxes identically.

### 2.2 How a Channel Post Routes Today
- **Channel membership**: Defined in `rdb/0002_channels.sql:15-23` (`channel_subscriptions` table with PK `(tenant_id, channel_id, agent_id, box_id)`).
- **Fan-out to desks**: In `hub/channels.go:264-305` (`routeChannel`), when a message arrives in a channel:
  ```go
  members, err := s.o.Store.ChannelMembers(ctx, tenant, channel)
  // ...
  for box, agents := range members {
      if box == WUIBox || (!fromBrowser && box == env.ToBox) {
          continue
      }
      // enqueues delivery for EVERY box with members in that channel
      if err := s.o.Store.Enqueue(ctx, tenant, m.MsgID, box, now, now.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err != nil { ... }
      if target := s.boxSession(tenant, box); target != nil {
          s.push(ctx, target, m.MsgID, canon)
      }
  }
  ```
  Spec 058 row H7 (`csi-spl-doc/specs/058-multi-machine-fleet/spec.md:42`) notes: *"one delivery per member box... Handled once therefore comes from WHO is seated where... not from the hub."*
- **Posting check**: In `hub/channels.go:219-231` (`agentInChannel`), an agent may post to a channel if it is present in `members[box]`. Non-members receive a 404 `unknown_channel` (the read-door rule).
- **Receiving check**: In `hub/channels.go:315-339` (`recvAgents`), a receiving box filters the channel members it hosts from `members[x.box]`.

### 2.3 How Lanes Are Placed Today
- **Queue and placement**: In `orc/run/spl-spawn-place.func.sh:153-187` (`do_spl_spawn_place`), asks queued in the hub are inspected every minute by the orchestrator lease holder.
- **Box selection**: Today, box targeting is controlled either by:
  1. Hand-pinned slug prefixes (`HAND-PINNED SLUG`, `spl-spawn-place.func.sh:58-62`): e.g. `hand-<box>-<slug>` or `<box>hand-<slug>` which sets `SPAWN_BOX=<box>`.
  2. Automatic load balancing (`spl_spawn_place_agy_box_hold`, `:860-913` and `spawn-window.sh:273-305`), which invokes `do_spl_box_pick` to find the box with the lowest load and available quotas.
- There is no automated bridge between a channel's topic and the box chosen for spawned lanes working on that topic.

### 2.4 The 3-Minute Answer Rule and Sweeps Today
- **The 3-minute SLA**: Defined in `SPEC-spool-fleet-roles.md § 3` (`csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md:198`): *"Every human post is answered within 3 minutes."*
- **Taking a post**: An orchestrator dispatcher takes an unanswered human post via `do_spl_take` (`orc/run/spl-take.func.sh:37-79`), which posts an explicit take line ("Taken by <id>@<box>: <plan>.") into the topic.
- **Auto-take**: `do_spl_take_auto` (`orc/run/spl-take-auto.func.sh:43-63`) posts the take line on inbound posts. It inspects sole seats via `cr_sole_seat` (`orc/src/bash/features/spawn-agents/lib/channel-rules.inc.sh:71-80`), which reads column 6 of `<spool root>/channel-rules.tsv`. This map is local, uncommitted, and machine-specific.
- **The backstop**: If no seat takes a post within 2 minutes, the orchestrator lease holder acts as the 3-minute backstop and assumes ownership.
- **Unanswered sweep**: In `orc/run/spl-unanswered-sweep.func.sh:16-37` and `orc/src/bash/scripts/unanswered-sweep-classify.py`, posts older than take grace without agent replies are surfaced as open/overdue.

### 2.5 Real Production Use Cases (Anonymized)
Three real production cases exist today where channels must only be answered on specific machines, maintained entirely by informal seat briefs and operator habit:
1. **Workspace A, channel `#app-alpha`**: Specialized automation seat `c-423` on `box-x`. Must never execute on `box-y` or `box-z` because underlying tooling, runtime state, and environment hooks reside only on `box-x`.
2. **Workspace B, channel `#project-beta`**: Private member project. Contains proprietary secrets, credentials, and data that must remain strictly confined to the owner's dedicated hardware node (`box-y`), per explicit workspace isolation policy.
3. **Workspace C, channel `#service-gamma`**: Customer code repositories cloned and maintained strictly on a single node (`box-x`). Repositories and tokens must never be cloned to or cached on other cluster machines.

---

## 3. The Data Model

### 3.1 Relational Schema: `channel_box_pins` Table
To support forward-only schema evolution and strict multi-tenancy, a new relational table `channel_box_pins` is introduced in forward-only migration `rdb/0240_channel_box_pins.sql`:

```sql
-- 0240_channel_box_pins.sql — channel-level box pins (spec 164, SPL-4171)
-- Pins a channel to chosen boxes in the tenant. Empty/no rows = any box (cluster default).

CREATE TABLE channel_box_pins (
    tenant_id   text        NOT NULL,
    channel_id  text        NOT NULL,
    box_id      text        NOT NULL,
    pinned_at   timestamptz NOT NULL DEFAULT now(),
    pinned_by   text        NOT NULL, -- HUM-* or operator SA email
    PRIMARY KEY (tenant_id, channel_id, box_id),
    FOREIGN KEY (tenant_id, channel_id) REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, box_id) REFERENCES pins (tenant_id, box_id) ON DELETE CASCADE
);

CREATE INDEX idx_channel_box_pins_tenant_channel ON channel_box_pins (tenant_id, channel_id);
CREATE INDEX idx_channel_box_pins_tenant_box ON channel_box_pins (tenant_id, box_id);

-- Enforce Row-Level Security (RLS) consistent with all tenant tables
ALTER TABLE channel_box_pins ENABLE ROW LEVEL SECURITY;
CREATE POLICY channel_box_pins_tenant_isolation ON channel_box_pins
    FOR ALL
    USING (tenant_id = NULLIF(current_setting('app.current_tenant', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.current_tenant', true), ''));
```

### 3.2 Relational Table vs Array Column Comparison
- **Relational Table (`channel_box_pins`)**:
  - *Pros*: Foreign key integrity (`REFERENCES pins(tenant_id, box_id) ON DELETE CASCADE`). If a machine is de-pinned or decommissioned from a workspace, channel pin rows are automatically cleaned up without dangling box references. Standard PostgreSQL RLS tenant isolation (`TestRLSCoversEveryTenantTable`). Audit timestamps and author tracking per pinned box.
  - *Cons*: Requires a join or secondary query when fetching channel metadata.
- **Array Column (`channels.box_pins text[]`)**:
  - *Pros*: Single row read when retrieving channel details.
  - *Cons*: Cannot enforce foreign key constraints against `pins`. A decommissioned box remains in the array unless manually cleaned up by application code. Violates normalized relational standards of the hub database.
- **Decision**: The relational table `channel_box_pins` is adopted as the primary canonical model.

### 3.3 Default Semantics: Empty Set = Cluster Default
- If `channel_box_pins` contains zero rows for `(tenant_id, channel_id)`:
  - The channel is **unpinned**.
  - Any box that has an active pin in `pins (tenant_id, box_id)` is eligible to host agents, receive posts, and execute lanes for that channel.
  - This preserves the owner's rule 100%: *"by default any channel should run on any box from the cluster"*.
- If `channel_box_pins` contains one or more rows for `(tenant_id, channel_id)`:
  - The channel is **pinned**.
  - Only the explicit subset of boxes listed in `channel_box_pins` is permitted to receive messages, post messages, or run lanes for topics in that channel.

### 3.4 Store Interface (Go)
Added to `api/internal/store/store.go`:

```go
type ChannelBoxPinsStore interface {
    GetChannelBoxPins(ctx context.Context, tenant, channel string) ([]string, error)
    SetChannelBoxPins(ctx context.Context, tenant, channel string, boxes []string, pinnedBy string) error
    ListWorkspaceChannelBoxPins(ctx context.Context, tenant string) (map[string][]string, error)
}
```

Implemented in `store/channel_box_pins_postgres.go` and `store/channel_box_pins_memory.go`. Tested via `store/channel_box_pins_test.go`.

---

## 4. Administration and APIs

### 4.1 RBAC and Authorization
- Managing channel box pins requires workspace administration privileges (`rbac.TenantSettings` or channel creator for private channels).
- Validations on modification:
  1. `channel_id` must exist in the workspace and not be deleted/archived.
  2. Every box ID in the supplied list must already be pinned to the workspace in `pins` (`store.GetPin(ctx, tenant, box)`). If an unknown or unpinned box is supplied, the API refuses with `400 Bad Request` (token `unknown_box: box X is not pinned in this workspace`).
  3. Default public channels (`#lobby`, `#alerts`, `#feedback`): see Owner Questions (Section 9, Q1). By default, pinning public lobby is rejected to prevent workspace-wide communication failure.

### 4.2 REST API Routes
1. **`GET /v1/channels/{channel}/box-pins`**:
   - Returns: `{"channel": "<channel>", "box_pins": ["box-x", "box-y"], "is_pinned": true}`.
   - For an unpinned channel: `{"channel": "<channel>", "box_pins": [], "is_pinned": false}`.
2. **`PUT /v1/channels/{channel}/box-pins`**:
   - Body: `{"box_pins": ["box-x"]}` (empty array `[]` clears the pin, returning the channel to cluster default).
   - Returns: `{"channel": "<channel>", "box_pins": ["box-x"], "is_pinned": true}`.
3. **`PATCH /v1/tenant/channels/{channel}`**:
   - Extended to accept `box_pins`:
     ```json
     {
       "no_fallback": false,
       "box_pins": ["box-x"]
     }
     ```
4. **`GET /v1/tenant/channels`**:
   - Augmented to include `box_pins: string[]` in each returned channel setting item.
5. **`POST /v1/operator/channels/{channel}/box-pins`**:
   - Operator service account twin for CLI and automation scripts.

### 4.3 Web UI (WUI) Integration
- **`ChannelPropertiesDialog.vue` (Settings Tab)**:
  - Located under `tab === 'settings'` (`wui/components/ChannelPropertiesDialog.vue:298-320`).
  - Displays a "Designated Fleet Boxes" selector:
    - Default toggle: *"Any box in cluster (default)"*.
    - Specific boxes: Checkbox group of all pinned workspace boxes (`box-x`, `box-y`, `box-z`) fetched via `api.listPins()`.
    - Disabled for non-admins (`!canEdit`).
- **`tenant-settings/channels.vue`**:
  - Adds a "Boxes" column to `tenant-channels-table` (`wui/pages/tenant-settings/channels.vue:13-20`).
  - Renders `t('tenant_settings.boxes_any')` when empty, or comma-separated pill badges `box-x`, `box-y` when pinned.

---

## 5. Enforcement Mechanics

### 5.1 (a) Channel Post Routing and Fan-out
In `hub/channels.go:264-305` (`routeChannel`), live fan-out enforces box pinning before delivery creation:
```go
pinnedBoxes, err := s.o.Store.GetChannelBoxPins(ctx, tenant, channel)
if err != nil {
    s.o.Log.Error().Err(err).Str("channel", channel).Msg("channel box pins lookup")
    return
}
for box, agents := range members {
    if len(pinnedBoxes) > 0 && !contains(pinnedBoxes, box) {
        continue // Skip delivery to any box not in the channel's allowed list
    }
    // ... proceed with lock check, enqueue, and push
}
```
In `recvAgents` (`hub/channels.go:315-339`), when a box requests queued messages, it returns empty targets if the message belongs to a channel pinned to other boxes.

### 5.2 (b) Lane Placement and Spawn-Window Isolation
1. **Ask Enrichment**:
   - When an ask is queued (`do_spl_spawn_enqueue`), the ask row stores `channel` (derived from topic parent task ID or explicit brief `Channel: <workspace> #<channel>` header).
2. **Placer Validation (`do_spl_spawn_place`)**:
   - In `orc/run/spl-spawn-place.func.sh:860-913`, before launching or handing off a lane:
   - If the ask's channel has box pins `[box-x]`:
     - The candidate box list passed to `do_spl_box_pick` is restricted strictly to `[box-x]`.
     - The placer sets `SPAWN_BOX=box-x`.
     - If `box-x` is at capacity, in quota reset, or offline: the ask **HOLDS** in the queue.
     - `.place.wait` records: `waiting: channel #channel-name is pinned to box-x (box-x is full / offline)`.
     - The ask is never diverted to another machine.
3. **Launcher Enforcement (`spawn-window.sh`)**:
   - `spawn-window.sh` verifies that `SPAWN_BOX` matches the channel's allowed boxes. Any mismatch aborts with exit code 8.

### 5.3 (c) Read and Post Isolation Across Boxes
1. **Posting Prohibition**:
   - In `hub/channels.go:219-231` (`agentInChannel`):
     ```go
     pinnedBoxes, _ := s.o.Store.GetChannelBoxPins(ctx, tenant, channel)
     if len(pinnedBoxes) > 0 && !contains(pinnedBoxes, box) {
         return false, nil // Rejected: agent's box is not allowed in this channel
     }
     ```
   - If an agent on an unpinned box executes `spool send --channel <ch>`, the hub returns `404 unknown_channel` (preserving the read door principle: unauthorized clients cannot confirm channel existence).
2. **Reading Prohibition**:
   - Requests from a box to `/v1/topics/{task}` or `/v1/channels/{channel}/messages` verify that the caller's box is among `pinnedBoxes`. Unpinned boxes receive 404.
3. **Trade-Off Analysis: Why Strict Isolation is Wise vs Nuanced Exceptions**:
   - *Why Strict Isolation is Wise*:
     - **Data containment**: Sensitive proprietary code, database credentials, and production configs stay strictly on the approved machine.
     - **No accidental leak via broad tools**: An agent exploring the filesystem or running shell tests cannot access customer files on nodes where they are not supposed to be cloned.
   - *Nuanced Considerations*:
     - **Fleet Orchestrator Metadata**: The fleet orchestrator (`c-001`) may reside on a machine different from the pinned box (e.g. `c-001@sat` vs `box-x`). If `c-001` were completely blind to topic metadata, it could not monitor whether topics are progressing.
     - *Resolution*: The orchestrator inspects issue records (`issues` table) and topic metadata (`is_parent`, message counts, timestamps) without reading sensitive message bodies from unpinned channels.
     - **Mentions of unpinned agents**: If a human @mentions an agent that resides on an unpinned box inside a pinned channel, the dispatch check refuses the delivery with `400 channel_box_mismatch` ("Agent is on box Y which is not allowed in this channel"), preventing accidental cross-box information leaks.

### 5.4 (d) Behavior When Every Listed Box Is Offline
What happens if `#project-beta` is pinned to `box-y` and `box-y` is powered off or disconnected?
1. **Message Preservation**:
   - The human's message is stored permanently in `messages`.
   - `routeChannel` enqueues delivery rows into `deliveries` for `box-y` in state `queued`.
2. **WUI Real-Time Transparency**:
   - In the WUI channel view, a warning banner appears below the channel header:
     > ⚠️ *This channel is pinned to box `<box-y>`, which is currently offline. Messages will be processed once `<box-y>` reconnects.*
   - Message bubble status shows `Waiting for box-y` rather than a generic sending spinner.
3. **Reconnection Drain**:
   - As soon as `box-y` connects to `/v1/ws` (`register`), the hub's queue relay drains all queued deliveries in FIFO order.

---

## 6. The 3-Minute Answer Rule and Offline Backstops

### 6.1 SLA Backstop vs Data Isolation Boundary
Under standard fleet operation (`SPEC-spool-fleet-roles.md § 3`), any human post unanswered after 2 minutes is seized by the fleet orchestrator lease holder (`c-001`) as the 3-minute backstop.

**The Conflict**:
If channel `#app-alpha` is pinned to `box-x`, and `box-x` is down:
If `c-001` (sitting on `box-sat`) seized the topic, attempted to answer it, or spawned a lane on `box-sat`:
- It would fail because the repository and tools only exist on `box-x`.
- If it forced a lane, it would violate customer confidentiality and security boundaries.

### 6.2 The Pinned Channel Backstop Rule
1. **No Autonomous Unpinned Take**:
   - `do_spl_take_auto` (`orc/run/spl-take-auto.func.sh:74-88`) checks `channelBoxPins`. If the channel is pinned to boxes that do not include `SPOOL_BOX_ID`, `spl_take_auto_skip` returns `skip channel pinned to other boxes ([box-x])`.
2. **Automated Holding Notice**:
   - If all pinned boxes remain offline for 120 seconds after a human post, the hub system agent (or the fleet backstop acting via the hub API with a system note) posts an automated holding message in the topic:
     > *"Channel #<channel> is configured to run exclusively on box `<box-x>`. `<box-x>` is currently offline. Your request has been queued and will be handled as soon as `<box-x>` reconnects."*
   - This satisfies the human expectation that the system acknowledges their post within 3 minutes, while explicitly preventing unlawful execution on unpinned machines.
3. **Unanswered Sweep Classification**:
   - In `orc/src/bash/scripts/unanswered-sweep-classify.py`, an unanswered post in a channel whose pinned boxes are offline is classified as:
     `pinned-box-offline` (grace period extended while node is down).
   - It is reported in the sweep report under "Waiting on Pinned Hardware", not as a broken dispatcher SLA.

---

## 7. Migration of Existing Production Cases

The three real cases currently maintained by informal seat briefs are migrated into database records upon rollout:

| Case | Workspace | Channel | Pinned Boxes | Rationale |
|---|---|---|---|---|
| M1 | Workspace A | `#app-alpha` | `["box-x"]` | Dedicated seat `c-423`, specialized build tooling and runtime dependencies present only on `box-x`. |
| M2 | Workspace B | `#project-beta` | `["box-y"]` | Member private workspace, proprietary secrets and data isolated to single hardware node. |
| M3 | Workspace C | `#service-gamma` | `["box-x"]` | Customer source code repository cloned only on `box-x`. |

A deployment script `orc/run/spl-channel-box-pin-migrate.func.sh` runs idempotently to apply these initial pins using `POST /v1/operator/channels/{channel}/box-pins`.

---

## 8. Build Rows

Seven small, test-driven build rows. Disjoint files allow independent scheduling.

| Row | Items | Area | Files (Only These) | Prerequisites | Verification & Red Controls |
|---|---|---|---|---|---|
| **B1** | Schema & Store | rdb, api | `rdb/0240_channel_box_pins.sql`<br>`store/channel_box_pins.go`<br>`store/channel_box_pins_postgres.go`<br>`store/channel_box_pins_memory.go`<br>`store/channel_box_pins_test.go`<br>`store/rls_test.go` | None | **Tests**: `TestChannelBoxPinsStore`, `TestRLSCoversEveryTenantTable`.<br>**Red Control**: A query without `app.current_tenant` reads cross-tenant pins (fails RLS); inserting an unpinned `box_id` succeeds (fails FK). |
| **B2** | Hub REST API & Permissions | api | `hub/channel_box_pins.go`<br>`hub/channel_box_pins_test.go`<br>`hub/server.go`<br>`hub/tenant_settings.go`<br>`hub/openapi.json` | B1 on master | **Tests**: `TestChannelBoxPinsAPI` (GET, PUT, PATCH).<br>**Red Control**: Non-admin user can update pins (returns 200 instead of 403); pinning an unpinned box returns 200 instead of 400 `unknown_box`. |
| **B3** | Route & Post Isolation | api | `hub/channels.go`<br>`hub/channels_test.go`<br>`hub/channel_box_pins_route_test.go` | B2 on master | **Tests**: `TestRouteChannelBoxPinEnforcement`, `TestAgentInChannelBoxPin`.<br>**Red Control**: `routeChannel` enqueues delivery for unpinned box; `agentInChannel` allows send from unpinned box. |
| **B4** | Placer & Launcher Pinning | orc | `orc/run/spl-spawn-place.func.sh`<br>`orc/src/bash/features/spawn-agents/scripts/spawn-window.sh`<br>`orc/tests/spl-spawn-place-box-pin.tst.sh` | B2 served | **Tests**: `spl-spawn-place-box-pin.tst.sh`.<br>**Red Control**: Lane for pinned channel is placed on unpinned box when pinned box is full. |
| **B5** | SLA Backstop & Sweeper | orc | `orc/run/spl-unanswered-sweep.func.sh`<br>`orc/src/bash/scripts/unanswered-sweep-classify.py`<br>`orc/run/spl-take-auto.func.sh`<br>`orc/tests/spl-unanswered-sweep-box-pin.tst.sh` | B3, B4 | **Tests**: `spl-unanswered-sweep-box-pin.tst.sh`.<br>**Red Control**: Auto-take on unpinned box claims topic; sweep marks offline pinned box as overdue dispatcher failure. |
| **B6** | WUI Properties & Settings | wui | `wui/components/ChannelPropertiesDialog.vue`<br>`wui/pages/tenant-settings/channels.vue`<br>`wui/utils/tenant-settings.mjs`<br>`wui/i18n/locales/*.json`<br>`wui/tests/unit/channel-box-pins.test.mjs`<br>`wui/tests/e2e/tenant-channel-box-pins.test.mjs` | B2 served | **Tests**: Unit tests, e2e Chrome tests, i18n parity.<br>**Red Control**: Saving pins in WUI fails to send `box_pins`; untranslated string alert. |
| **B7** | Production Seed Migration | orc | `orc/run/spl-channel-box-pin-migrate.func.sh`<br>`orc/tests/spl-channel-box-pin-migrate.tst.sh` | B2..B6 served | **Tests**: Idempotent application of M1..M3 pins on dev and prd. |

---

## 9. Owner Questions

The following architectural decisions require owner determination before build row execution:

### Question 1: Default Public Channels (`#lobby`, `#alerts`, `#feedback`)
Should administrators be allowed to pin default public channels to specific boxes?
- **Option A (Recommended)**: Disallow pinning default public channels (API returns `400 channel_default_unpinnable`). Default channels are workspace-wide; pinning them risks dropping member greetings and system alerts.
- **Option B**: Allow pinning any channel, including `#lobby`, if an admin explicitly configures it.

### Question 2: Offline Pinned Box SLA Notification
When every pinned box is offline and a human posts in the channel:
- **Option A (Recommended)**: After 2 minutes, the hub/system agent posts an automated holding message into the topic explaining that the channel's pinned box is offline and the post is queued. Unpinned agents never take the topic.
- **Option B**: The topic stays completely silent with no messages posted until the pinned box comes back online (only the WUI header shows the offline banner).
- **Option C**: The fleet orchestrator takes the topic to converse with the human, but refuses to run or spawn code tasks.

### Question 3: Existing Agent Subscriptions on Unpinned Boxes
When a channel is updated from unpinned to pinned to `[box-x]`, but agents on `box-y` are currently subscribed:
- **Option A (Recommended)**: Automatically purge agent subscriptions on `box-y` from `channel_subscriptions` with a log notice.
- **Option B**: Keep subscriptions in `channel_subscriptions`, but dynamically suppress delivery in `routeChannel` while the pin is active.

### Question 4: Fallback Responders
If a channel has `no_fallback: false` (fallback responder enabled) and is pinned to `[box-x]`:
- **Option A (Recommended)**: Fallback selection picks only from agents on `box-x`. If no fallback agent is online on `box-x`, fallback is skipped.
- **Option B**: Fallback can pick any workspace responder across all boxes (violates strict data isolation).

---

## 10. Risks and Open Checks

1. **R1: Single Point of Failure for Pinned Channels**:
   If a channel is pinned to a single box (`box-x`) and `box-x` suffers hardware failure, that channel cannot process agent commands until `box-x` recovers or an admin changes the pin.
   *Mitigation*: WUI channel settings clearly display when a pinned box is offline and allow workspace admins to re-pin or unpin the channel.
2. **R2: Dispatcher Capacity on Pinned Nodes**:
   If many channels are pinned to a single node, that node's OD seat and lane cap (40 agent ceiling) may become a bottleneck while other fleet machines remain idle.
   *Mitigation*: The monitoring load dashboard surfaces per-box channel pin concentration (`/tenant-settings/fleet-load`).
3. **R3: Cross-Box Mentions**:
   A user in a pinned channel might @mention an agent that exists only on another box.
   *Mitigation*: Handled by validation in `dispatchCheck` (`hub/dispatch.go`), failing fast with an informative error rather than silently stalling.

---

<!-- version: 1.0.0 · updated: 2026-10-29 · last-edit: 2026-10-29T04:20:00Z -->
