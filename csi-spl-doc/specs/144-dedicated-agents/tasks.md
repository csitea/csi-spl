# 144 Dedicated agents: tasks

Authority for what is built. [spec.md](spec.md) holds the behaviour, protocol
rules, and architecture; this file defines the concrete, dependency-ordered
implementation tasks, lane ownership, touched paths, and acceptance verification
checkpoints.

Status vocabulary: `../README.md` §2.3 (`[x]` Implemented, `[~]` Partial / in progress, `[ ]` Planned).

Version: **v0.1.0** (Spec Only). All tasks below are planned awaiting owner review
and go-ahead on open questions Q1..Q5 in [spec.md](spec.md) §10.

---

## Path Prefixes

- `DOC/` is `csi-spl-doc/specs/144-dedicated-agents/`.
- `GO/` is `csi-spl-api/src/go/spool-hub-api/internal/`.
- `RDB/` is `csi-spl-rdb/src/sql/postgres/spool-hub/`.
- `RUN/` is `csi-spl-orc/src/bash/run/`.
- `SA/` is `csi-spl-orc/src/bash/features/spawn-agents/`.
- `OT/` is `csi-spl-orc/src/bash/tests/`.
- `WUI/` is `csi-spl-wui/src/`.

---

## Rules for Every Lane

1. **One lane per task:** A file is owned by exactly one task. A lane that needs changes in files outside its task scope coordinates with the orchestrator (`c-001`).
2. **Postgres on runtime role:** Store, RLS, and auth tests run on Postgres as the runtime role (`PRE_PUSH_TIER=full ./run -a do_check_pre_push`), never as superuser or owner.
3. **Controls required:** Every security and isolation test includes a failing control (e.g. Controls C1..C3 in `spec.md` §8.2) verified on a throwaway branch.
4. **Distribution hygiene:** Zero personal names, OS usernames, owner emails, or literal `/home/` paths.
5. **No AI trailers:** Author identity must match the repository's pinned committer without trailers.
6. **Deploy & Lag verification:** When built, changes are verified on both `dev` and `prd` via `./run -a do_check_deploy_lag`.

---

## Phase 1: Data Model & Database Migration (RDB)

- [ ] **T001: Migration `0202_dedicated_agents.sql`**
  - **Layer:** Database Schema (RDB)
  - **Owns:** `RDB/0202_dedicated_agents.sql`, `RDB/test/`
  - **Waits on:** None (build entry point)
  - **Description:**
    - Create table `dedicated_agents` with `(tenant_id, agent_id, box_id, scope_type, scope_id, bound_by, bound_at)`.
    - Add columns `is_private_scope boolean NOT NULL DEFAULT false` and `private_scope_at timestamptz` to `channels`.
    - Add column `is_private_scope boolean NOT NULL DEFAULT false` to `messages`.
    - Add index `idx_dedicated_agents_scope` on `(tenant_id, scope_type, scope_id)`.
    - Update Row-Level Security (RLS) policies for `messages`, `deliveries`, and `dedicated_agents` ensuring non-dedicated workers cannot select private rows.
  - **Done:** Migration applies cleanly forward; tests verify table creation, foreign keys, check constraints, and RLS isolation on testkit Postgres.

---

## Phase 2: Hub API Store & Bidirectional Enforcement (GO)

- [ ] **T002: Hub store interface and Postgres implementation**
  - **Layer:** Hub Store (GO)
  - **Owns:** `GO/store/dedicated.go`, `GO/store/dedicated_postgres.go`, `GO/store/dedicated_memory.go`, `GO/store/dedicated_test.go`
  - **Waits on:** T001
  - **Description:**
    - Define store methods: `GetDedicatedBinding`, `SetDedicatedBinding`, `RemoveDedicatedBinding`, `ListDedicatedAgentsByScope`, `IsPrivateScope`.
    - Update `BoxTaskEnvelopes` in `GO/store/postgres.go` to exclude private scope envelopes when requested by non-dedicated agents.
    - Implement in-memory twin in `dedicated_memory.go` for local testing.
  - **Done:** Unit tests verify persistence, binding lookups, and exclusion of private envelopes from unauthorized queries; test suite green.

- [ ] **T003: Inbound delivery filtering in hub routing**
  - **Layer:** Hub Routing Engine (GO)
  - **Owns:** `GO/hub/channels.go` (routing modifications), `GO/hub/channels_dedicated_test.go`
  - **Waits on:** T002
  - **Description:**
    - Modify `routeChannel` in `GO/hub/channels.go`: when `is_private_scope = true`, route delivery only to member boxes that host agents registered in `dedicated_agents` for that channel. Skip general member agents.
    - Update `recvAgents` to ensure dedicated agents only appear in the recipient list for envelopes matching their bound scope.
    - Guarantee orchestrator (`c-001`) and dispatchers (`c-002..c-004`) receive 0 deliveries from private scopes.
  - **Done:** Hub integration tests assert general member agents receive 0 deliveries when a post occurs in a private channel; only dedicated agents receive delivery frames.

- [ ] **T004: Outbound send validation gate**
  - **Layer:** Hub Protocol Enforcement (GO)
  - **Owns:** `GO/hub/ws.go` (onSend modifications), `GO/hub/dedicated_send_test.go`
  - **Waits on:** T002
  - **Description:**
    - Add `sendDedicatedScopeRefusal` to `onSend` in `GO/hub/ws.go`.
    - If the sender is registered in `dedicated_agents`:
      - For channel scope: assert `env.Channel == scope_id` and `m.To == msg.BroadcastID`. Refuse any DM or foreign channel post with `dedicated_scope_violation`, HTTP 403.
      - For topic scope: assert `m.TaskID == scope_id` or `env.ParentTaskID == scope_id`. Refuse foreign tasks with `dedicated_scope_violation`, HTTP 403.
  - **Done:** Unit test sends matching scope pass; sends escaping scope fail with `dedicated_scope_violation` (Control C1).

- [ ] **T005: Hub REST / WebSocket management endpoints**
  - **Layer:** Hub API Endpoints (GO)
  - **Owns:** `GO/hub/dedicated_api.go`, `GO/hub/dedicated_api_test.go`
  - **Waits on:** T002
  - **Description:**
    - Implement `PUT /v1/channels/{channel}/private-scope` (toggle private scope flag).
    - Implement `POST /v1/channels/{channel}/dedicated-agents` and `DELETE /v1/channels/{channel}/dedicated-agents/{agent_id}`.
    - Implement `PUT /v1/topics/{task_id}/private-scope`.
    - Restrict endpoints to workspace owner and workspace admins via RBAC.
  - **Done:** API tests verify binding creation, deletion, scope toggling, and RBAC rejection of unauthorized callers.

---

## Phase 3: Hub Isolation & Leak-Proof Boundaries (GO & RUN)

- [ ] **T006: Unanswered sweep query exclusion**
  - **Layer:** Orchestration / Database Query (RUN)
  - **Owns:** `RUN/spl-unanswered-sweep.func.sh`, `OT/unanswered-sweep-private-scope.tst.sh`
  - **Waits on:** T001
  - **Description:**
    - Update `_spl_sweep_rows_sql` in `RUN/spl-unanswered-sweep.func.sh` to filter out messages where `is_private_scope = true` or where a dedicated agent binding exists.
    - Add test `unanswered-sweep-private-scope.tst.sh` with a seeded unanswered human post in a private scope, asserting it is omitted from the sweep output report (Control C3).
  - **Done:** Sweep report contains 0 private scope items; general dispatchers receive 0 tasks for private discussions.

- [ ] **T007: Ambient leak-path containment**
  - **Layer:** Hub API Guards (GO)
  - **Owns:** `GO/hub/issues_agent.go`, `GO/hub/shared_memory.go`, `GO/hub/flow_agent.go`, `GO/hub/box_move.go`
  - **Waits on:** T002, T004
  - **Description:**
    - Update `onIssue`: reject creating or editing issues referencing private scope topics unless caller is authorized.
    - Update `onMemoryLane`: reject `memory_add` frames submitted by dedicated agents or referencing private scope contents.
    - Update `flow_postgres.go`: skip generating `flow_events` for users outside private scopes.
    - Update `onMove`: block moving private topics to non-private channels.
  - **Done:** Hub tests verify that issue creation, shared memory injection, flow broadcasts, and topic moves are rejected for private scope content.

---

## Phase 4: Orchestration, Spawning & Local Box Isolation (RUN & SA)

- [ ] **T008: `SPAWN_DEDICATED_SCOPE` launcher support**
  - **Layer:** Agent Spawning (SA)
  - **Owns:** `SA/scripts/spawn-window.sh`, `SA/scripts/spawn-core.inc.sh`, `SA/tests/test-spawn-dedicated.sh`
  - **Waits on:** T005
  - **Description:**
    - Support environment variable `SPAWN_DEDICATED_SCOPE=<channel|topic>`.
    - In `spawn-core.inc.sh`, invoke hub API to register the agent in `dedicated_agents` upon spawn.
    - Render restricted mandate in the agent's seed prompt specifying its bounded scope.
    - Support respawn with `SPAWN_REUSE_ID=1` preserving the existing dedicated binding.
  - **Done:** Test spawns dedicated agent; hub verifies binding; prompt reflects dedicated scope.

- [ ] **T009: Fleet lane map and load routing isolation**
  - **Layer:** Fleet Coordination (SA / RUN)
  - **Owns:** `SA/scripts/lane-map.sh`, `RUN/spl-lane-map.func.sh`, `OT/lane-map-dedicated.tst.sh`
  - **Waits on:** T008
  - **Description:**
    - Update `lane-map.sh` to record dedicated agents with badge `dedicated:<scope>`.
    - Exclude dedicated agents from general worker queues and load rebalancing algorithms.
    - Prevent task dispatchers from routing generic fleet issues to dedicated agents.
  - **Done:** Lane map lists dedicated agent with scope tag; general issue assignment skips dedicated seats.

- [ ] **T010: Local spool directory containment**
  - **Layer:** Box Engine Spool Security (RUN / SA)
  - **Owns:** `SA/scripts/spawn-core.inc.sh`, `GO/spool/spool.go`
  - **Waits on:** T008
  - **Description:**
    - Provision `/var/spool-hub/<agent-id>` with mode `0700` (`rwx------`) for dedicated agents.
    - Update `Store.Tail` in `GO/spool/spool.go` to handle permission errors gracefully when scanning agent directories, preventing cross-agent snooping on the same host.
  - **Done:** Other agents on the host cannot read the dedicated agent's spool files.

---

## Phase 5: Web UI (WUI)

- [ ] **T011: Channel Properties dialog: Private Scope & Dedicated Agents**
  - **Layer:** Web User Interface (WUI)
  - **Owns:** `WUI/components/ChannelPropertiesDialog.vue`, `WUI/components/ChannelPropertiesDedicated.test.mjs`
  - **Waits on:** T005
  - **Description:**
    - In Settings tab: Add "Private Scope" toggle with explanatory tooltip.
    - In Agents tab: Add "Dedicated" badge to assigned agents; add combobox actions to bind/unbind dedicated agents.
    - Wire to hub endpoints `PUT /v1/channels/{channel}/private-scope` and `POST/DELETE /v1/channels/{channel}/dedicated-agents`.
  - **Done:** Unit tests verify toggle interactions, agent list rendering, and API payload dispatch; i18n parity green.

- [ ] **T012: Topic Properties / Menu action for private topics**
  - **Layer:** Web User Interface (WUI)
  - **Owns:** `WUI/components/TopicPane.vue`, `WUI/composables/useCardTopicActions.ts`
  - **Waits on:** T005
  - **Description:**
    - Add "Scope Settings" to topic card action menu.
    - Provide modal allowing owner to toggle topic-level `is_private_scope` and bind a dedicated agent to that `task_id`.
  - **Done:** E2E test verifies topic scope modal opens, saves settings, and reflects status.

- [ ] **T013: Badges in UI**
  - **Layer:** Web User Interface (WUI)
  - **Owns:** `WUI/components/AgentBadge.vue`, `WUI/components/DedicatedBadge.vue`, `WUI/components/PrivateScopeBadge.vue`
  - **Waits on:** T011, T012
  - **Description:**
    - Implement `DedicatedBadge.vue`: Rendered next to agent author in `AgentBadge.vue` when agent is dedicated.
    - Implement `PrivateScopeBadge.vue`: Padlock icon rendered in channel and topic pane headers when `is_private_scope = true`.
  - **Done:** Visual snapshot tests pass; screen reader attributes (`aria-label`) present.

- [ ] **T014: Dedicated agent constrained view**
  - **Layer:** Web User Interface (WUI)
  - **Owns:** `WUI/layouts/default.vue`, `WUI/stores/channel.ts`, `WUI/components/ChannelSidebar.vue`
  - **Waits on:** T011
  - **Description:**
    - When authenticated under a dedicated agent token:
      - Constrain sidebar navigation to the bound scope only.
      - Hide general channel lists, document trees, and global search.
      - Ensure direct URL navigation to other scopes returns 404 / access denied.
  - **Done:** E2E test asserts dedicated agent session cannot navigate outside its assigned scope.

---

## Phase 6: Integration, E2E Verification & Deployment (OT / CI)

- [ ] **T015: End-to-end integration test suite**
  - **Layer:** System Integration (OT)
  - **Owns:** `OT/dedicated-agents-e2e.tst.sh`
  - **Waits on:** T001..T014
  - **Description:**
    - Comprehensive scenario:
      1. Owner creates private channel and spawns dedicated agent via `SPAWN_DEDICATED_SCOPE`.
      2. Dedicated agent posts in channel; receives human reply.
      3. Orchestrator (`c-001`) and dispatcher (`c-002`) receive 0 notifications.
      4. Dedicated agent attempts send to external channel -> rejected with HTTP 403.
      5. Unanswered sweep runs -> reports 0 items.
      6. Dedicated agent restarts under `SPAWN_REUSE_ID=1` -> binding preserved.
  - **Done:** All steps pass; negative controls C1, C2, and C3 verified.

---

<!-- version: 0.1.0 · updated: 2026-10-17 · last-edit: 2026-10-17T10:30:00Z -->
