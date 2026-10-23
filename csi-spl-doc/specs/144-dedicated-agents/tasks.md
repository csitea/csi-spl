# 144 Dedicated agents: tasks

Authority for what is built. [spec.md](spec.md) holds the behaviour, protocol
rules, and architecture; this file defines the concrete, dependency-ordered
implementation tasks, lane ownership, touched paths, and acceptance verification
checkpoints.

Status vocabulary: `../README.md` §2.3 (`[x]` Implemented, `[~]` Partial / in progress, `[ ]` Planned).

Version: **v0.2.0**. All tasks below are planned awaiting owner review
and go-ahead on open questions Q1..Q5 in [spec.md](spec.md) §14.

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
3. **Controls required:** Every security and isolation test includes a failing control (e.g. Controls C1..C6 in `spec.md` §12.2) verified on a throwaway branch.
4. **Distribution hygiene:** Zero personal names, OS usernames, owner emails, or literal `/home/` paths.
5. **No AI trailers:** Author identity must match the repository's pinned committer without trailers.
6. **Deploy & Lag verification:** When built, changes are verified on both `dev` and `prd` via `./run -a do_check_deploy_lag`.

---

## Phase 1: Data Model & Database Migration (RDB)

- [x] **T001: Migration `0215_dedicated_agents.sql`** (planned as 0202, taken by then)
  - **Built:** rdb `0215_dedicated_agents.sql` (SPL-3074): the table, the flags, `spool_agent_scope_ok` (an opaque function: inline EXISTS failed TestHiddenUnreadBufferBudget; the SQL tab plan check takes its call, store `planCallAllowed`) and the RESTRICTIVE `agent_scope` policies keyed on the transaction-local `app.agent_id` + `app.agent_box` (unset = no agent session, unchanged). Test `csi-spl-rdb/src/bash/tests/dedicated-agents-rls.tst.sh`, as the runtime login; red control `DEDICATED_RLS_CONTROL=1` (0215 without its policies) prints FAIL. `seedTenantAll` seeds the table for the cross-tenant census.
  - **Layer:** Database Schema (RDB)
  - **Owns:** `RDB/0215_dedicated_agents.sql`, `csi-spl-rdb/src/bash/tests/dedicated-agents-rls.tst.sh`
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

## Phase 7: Discussion Properties, Idle Dismissal & Abuse Protection (Owner msgs 1d031b1c, edf8e150, d8adaced, 3c233ec5)

- [ ] **T016: Discussion Properties UI: Dedicated Agent management & cost confirmation**
  - **Layer:** Web User Interface (WUI)
  - **Owns:** `WUI/components/DiscussionPropertiesDialog.vue`, `WUI/components/TopicContextMenu.vue`, `WUI/components/DiscussionPropertiesSheet.vue`
  - **Waits on:** T012, T018
  - **Description:**
    - Implement topic right-click context menu (desktop) and kebab / long-press bottom sheet (mobile) opening "Discussion Properties" (§8.1, FR-004).
    - Provide "Dedicated Agent" management: vendor dropdown defaulting to `agent_split_by_kind` main vendor (§8.2, FR-006).
    - Display mandatory cost transparency confirmation dialog (§8.4, FR-008): warns that reserving agents is expensive, shows idle timeout, outlines 3/5/6 abuse rules, and shows current abuse count.
    - Implement live dedicated agent card showing real-time status, uptime, countdown to idle dismissal, and interactions (§8.5, FR-005).
    - Provide "Dismiss Dedicated Agent" button for clean manual termination (§8.6, FR-005).
    - Gate UI actions by workspace role per Spec 025; disable for banned users with explanatory badge (§8.3, FR-007, FR-015).
  - **Done:** Unit and component tests verify menu trigger, vendor default selection, confirmation notice display, and RBAC button state; i18n parity green.

- [ ] **T017: Hub Schema & Store for Discussion Idle Config & Abuse Tracking**
  - **Layer:** Database Schema & Hub Store (RDB / GO)
  - **Owns:** `RDB/0203_dedicated_idle_and_abuses.sql`, `GO/store/dedicated_idle.go`, `GO/store/dedicated_abuse.go`, `GO/store/dedicated_abuse_test.go`
  - **Waits on:** T001, T002
  - **Description:**
    - Migration `0203_dedicated_idle_and_abuses.sql`: add `idle_timeout_seconds` (default 3600), `last_activity_at`, and `dedicated_interaction_count` to messages; create `dedicated_agent_abuses` table with `(tenant_id, human_id, abuse_count, is_banned, banned_at, banned_by, unbanned_at, unbanned_by, last_abuse_at)` (§3.4, FR-009, FR-013).
    - Implement store methods: `GetDiscussionIdleConfig`, `SetDiscussionIdleConfig`, `TouchTopicActivity`, `RecordDedicatedInteraction`, `IncrementUserAbuse`, `GetUserAbuseStatus`, `ResetUserAbuse` (§9.1, §10.2).
    - Enforce check constraints on idle timeout (300 s to 86400 s; 0 allowed for admin "never") and non-negative abuse counter.
  - **Done:** Migration applies cleanly; unit tests verify atomic counter increments, activity timestamp updates, and store queries.

- [ ] **T018: Hub API Endpoints for Topic Dedicated Agents, Idle Config & Abuse Administration**
  - **Layer:** Hub API Endpoints (GO)
  - **Owns:** `GO/hub/dedicated_topic_api.go`, `GO/hub/dedicated_abuse_api.go`, `GO/hub/dedicated_topic_api_test.go`
  - **Waits on:** T005, T017
  - **Description:**
    - Implement `GET /v1/topics/{task_id}/dedicated-agent` (inspect live state) and `DELETE /v1/topics/{task_id}/dedicated-agent` (dismiss agent) (§8.5, §8.6, FR-005).
    - Implement `POST /v1/topics/{task_id}/dedicated-agent` (bind agent to topic): verify user ban status; if `is_banned = true`, refuse with HTTP 403 `dedicated_feature_banned` (Control C4, §10.4, FR-015).
    - Implement `PUT /v1/topics/{task_id}/idle-timeout` (configure discussion timeout) (§9.1, FR-009).
    - Implement `GET /v1/members/{user_id}/dedicated-abuse` and `POST /v1/members/{user_id}/reset-dedicated-abuse` (unban user and reset abuse counter, restricted to workspace owner and admin) (§10.4, FR-015).
  - **Done:** API integration tests verify topic dedicated agent binding, rejection of banned users (Control C4), and administrator ban reset.

- [ ] **T019: Inactivity Monitor and Automatic Idle Dismissal Daemon**
  - **Layer:** Orchestration / Daemon (GO / RUN / SA)
  - **Owns:** `GO/hub/dedicated_idle_monitor.go`, `RUN/spl-dedicated-idle-sweep.func.sh`, `SA/scripts/dismiss-dedicated-agent.sh`, `OT/dedicated-idle-dismiss.tst.sh`
  - **Waits on:** T008, T017
  - **Description:**
    - Build inactivity monitor scanning dedicated topic bindings where `now() - last_activity_at > idle_timeout_seconds` (§9.3, FR-010, FR-011).
    - Check agent execution status: if an active tool call or turn is running, defer dismissal with a 5-minute grace period (§9.4, FR-012).
    - For confirmed idle agent: dispatch `/exit-clean` to agent process; release seat on host box; remove binding from `dedicated_agents` (§9.3, FR-010).
    - Post non-AI system message in topic announcing dismissal for idleness ("idle agents consume resources") and how to re-add (§9.3, FR-010).
    - If `dedicated_interaction_count == 0`, trigger abuse event against reserving user (Control C5, §10.1, FR-013). If interactions > 0, do not count abuse (Control C6).
    - Handle edge case: messages arriving during shutdown are buffered in topic, and user is alerted to re-add (§9.4, FR-012).
  - **Done:** Test verifies automatic dismissal after silence, seat reclamation, system message posting, tool call grace, and correct abuse accounting.

- [ ] **T020: Abuse Warning Notifications & Ban Enforcement Engine**
  - **Layer:** Hub Protocol & Notifications (GO)
  - **Owns:** `GO/hub/dedicated_abuse_guard.go`, `GO/hub/dedicated_abuse_guard_test.go`
  - **Waits on:** T017, T018
  - **Description:**
    - Hook abuse counter increment:
      - At 3 abuses: dispatch Warning 1 system notification to user and topic quoting "reserving agents is expensive" (§10.3, FR-014).
      - At 5 abuses: dispatch Final Warning 2 system notification to user (§10.3, FR-014).
      - At 6 abuses: set `is_banned = true`, dispatch ban notification, and block further dedicated agent reservations (§10.3, FR-014, FR-015).
    - Ensure all warnings are deterministic system lines generated by code without AI.
  - **Done:** Unit tests verify notification dispatch at 3 and 5 abuses, and automatic feature ban at 6 abuses.

- [ ] **T021: Admin User Management: Ban Inspection & Lifting UI**
  - **Layer:** Web User Interface (WUI)
  - **Owns:** `WUI/components/TenantUsersDialog.vue`, `WUI/components/UserDedicatedAbuseBadge.vue`
  - **Waits on:** T016, T018
  - **Description:**
    - In Tenant Users / Settings management dialog, display dedicated agent abuse tally and ban status badge per user (§10.4, FR-015).
    - For workspace owner (`biz_owner`) and admin: provide action button "Reset Abuses & Unban" calling `POST /v1/members/{user_id}/reset-dedicated-abuse` (§10.4, FR-015).
  - **Done:** UI tests verify badge rendering and successful execution of unban action restoring user privileges.

- [ ] **T022: E2E Verification of Discussion Properties, Idle Dismissal, and Abuse Escalation**
  - **Layer:** System Integration (OT)
  - **Owns:** `OT/dedicated-idle-dismiss-abuse-e2e.tst.sh`
  - **Waits on:** T015, T016, T019, T020, T021
  - **Description:**
    - Comprehensive end-to-end integration test:
      1. User opens topic Discussion Properties via right-click; selects vendor (defaulting to lane-mix); confirms cost warning modal.
      2. Dedicated agent starts. Zero messages sent. Advance clock past 1-hour idle timeout.
      3. Daemon dismisses agent cleanly (`/exit-clean`); seat released; system notice posted in topic; abuse count increments to 1.
      4. Repeat unused reservations until 3 abuses -> verify Warning 1 notification received.
      5. Repeat until 5 abuses -> verify Warning 2 notification received.
      6. 6th unused dismissal -> verify user banned (`is_banned = true`); subsequent reservation attempt fails with 403 `dedicated_feature_banned` (Control C4).
      7. Workspace owner clicks "Reset Abuses & Unban" -> user unbanned, abuses reset to 0, dedication allowed again.
      8. Reserve agent and post 1 user interaction; advance clock past idle timeout -> verify agent dismissed but abuse count stays 0 (Control C6).
      9. In-flight tool call suppresses dismissal until tool completion (Control C5 / §9.4).
  - **Done:** Full scenario passes on testkit; Controls C4, C5, C6 verified green.

---

<!-- version: 0.2.0 · updated: 2026-10-19 · last-edit: 2026-10-19T17:00:00Z -->
