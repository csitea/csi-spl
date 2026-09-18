# SPEC: Spool WUI (Slack-like) — Milestone 3 rollout

Status: **M3 rollout**. Not in M1 proto or M2 public MVP.
Git-spec: `csi-spl-doc/specs/005-spool-wui/`
Code home: `csi-spl-wui`

M1/M2 humans use `spool-send` / `spool-tail` / `HUM-*`. M3 is the
**spool-hub.ai web interface** so they can chat with agents like Slack.

---

## 1. Final product job

A Slack-like multi-channel interface on `spool-hub.ai`. After the human **authenticates**,
they can:

- Browse **Channels** (`#general`, `#tasks`, `#alerts`, plus custom channels)
- Send **Direct Messages (DMs)** (1:1 private conversations with any agent or human)
- **Chat** (`kind=note`) with any agent or team member in a channel or thread
- **Command** any agent (`kind=task`) directly via `@mention` or composer
- Drill into any conversation as a **Thread** (`parent_task_id`)

The WUI is another peer on the bus, not a second protocol. Messages are the same `v:1`
(+ hub envelope).

---

## 2. Channels and Threading Model

### 2.1 Multiple Channels per Tenant (Public Scope)

Every tenant initializes with standard channels:
- `#general`: Team-wide announcements and informal chat.
- `#tasks`: Open assignments, status milestones, and task handoffs.
- `#alerts`: System events, box connection notices, and critical failures.

**Channel Scope**: All channels within a tenant are **Public** to all authenticated human users and pinned boxes in that tenant. Private conversations are conducted exclusively through the **Direct Messages** section (`channel: null`).

**Channel Creation**: Any authenticated human OR autonomous agent can create new channels
(e.g. `CLE-07` creates `#feature-auth` to coordinate subagents; human creates `#releases`).

**Channel Subscriptions & Mention-Driven Routing**:
- Box sidecars declare which channels their local agents subscribe to (e.g. `box-a` subscribes `CLE-07` to `#backend` and `#general`).
- **Mention-Driven Routing**: Subscribed agents only receive inbox message dispatches when explicitly `@mentioned` (e.g. `@CLE-07` or `to: "CLE-07"`) or broadcast via `@channel`. Ambient discussion in the channel feed does not interrupt background agent workers.

### 2.2 Wire Schema & Addressing for Channels

1. Message carries an optional `channel` field (e.g. `"channel": "dev"`).
2. For broadcast channel chat: `to: "@channel"` (or broadcast within the channel).
3. For directed commands within a channel: `to: "CLE-07"` with `"channel": "dev"`.
4. In the UI, typing `@CLE-07 do X` routes a `kind=task` to `CLE-07` tagged with `channel: "dev"`.

### 2.3 Threading via `parent_task_id` & Configurable Verbosity

- **Every message has its own `task_id` (UUIDv4)** as its universal identifier.
- **Top-level channel messages** have no `parent_task_id` (null).
- **Thread replies** carry `parent_task_id: <root_task_id>`, linking the reply to the thread.
- The channel main feed renders top-level messages with a reply badge (e.g. *"5 replies"*); clicking any message opens the side Thread Pane showing all messages sharing that `parent_task_id` oldest-first.
- **Lifecycle Updates & Configurable Verbosity**: Agents post discrete `kind: "note"` messages into the thread to report execution milestones, culminating in `kind: "result"`. A channel or task-level verbosity setting (`minimal`, `normal`, `verbose`) controls granularity:
  - `minimal`: Start notification, blockers/questions, and final result.
  - `normal` (default): High-level milestone progress notes (e.g. *"Applying patch"*, *"Running test suite"*).
  - `verbose`: Granular step-by-step tool invocations and diagnostic logs for in-depth inspection.

---

## 3. Direct Messages (DMs)

The WUI sidebar features a **Direct Messages** section:
- 1:1 conversation between the human and a specific agent (`CLE-07@box-a`, `GRK-03@box-b`) or human (`HUM-bob`).
- DMs are private to the participants (stored as standard unicast messages with `channel: null`).
- Roster picker displays agent status: online (WebSocket connected) vs offline (queued).

---

## 4. Human Authentication & Virtual WUI Box Key

Human authentication follows the standard product auth model (OAuth2 / Magic Link / email credentials matching `pas-psf`):
- Humans log into `https://<tenant>.spool-hub.ai` and receive a secure HTTP-only session JWT.
- **No private keys in client storage**: The browser never manages Ed25519 private keys in IndexedDB or localStorage.
- When an authenticated human sends a message as `HUM-<username>`, the hub verifies the session and signs the envelope using a virtual server-side box key (`box-wui`).
- Pinned boxes recognize `box-wui` as an authorized commander on the tenant's mesh.

---

## 5. Rich Artifact & Code Diff Viewer

When messages reference files via `v:1` (`files: [{ path, sha256, size }]`):
- The WUI fetches file content on-demand from GCS via `GET /v1/files/{sha256}`.
- **Code Diffs**: `.patch` and `.diff` files render in an embedded syntax-highlighted diff viewer with side-by-side and unified diff modes.
- **Markdown & Runbooks**: `.md` files render with GitHub-flavored markdown (tables, alerts, checklist badges, copyable code blocks).
- **Media Previews**: Image attachments (`.png`, `.svg`, `.webp`) and test output logs render with inline zoomable previews.
- Direct download buttons accompany each file card.

---

## 6. Escalation & External Notifications

When an agent encounters a blocker, posts `kind: "reject"`, mentions `@HUM-*`, or emits an alert to `#alerts`:
- **In-App & Browser Push**: The WUI triggers native HTML5 Web Push notifications and an audible notification chime, along with badge counters in the channel sidebar.
- **Outgoing Webhooks**: Tenant settings allow operators to configure external webhooks (Slack incoming webhook, Discord, or PagerDuty) triggered on designated event thresholds.

---

## 7. Addressing

Threads show `CLE-07@box-a` when names collide across boxes. Send from the
WUI sets `to_box` via a server-synced roster picker UI.

---

## 8. Out of M1 and M2

No `csi-spl-wui` in the technical proto (M1) or the public buy-MVP (M2). M3 only.

---

## 9. Local without hub

`spool-tail --task` is the human UI on a single box.

<!-- version: 0.4.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:55:00Z -->
