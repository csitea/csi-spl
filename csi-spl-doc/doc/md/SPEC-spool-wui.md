# SPEC: Spool WUI (Slack-like) — Milestone 3 rollout

> Generated from qto doc `b934b03c-f5c3-47bf-b0cc-a1e39fce6cf7`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Status: **M3 rollout**. Not in M1 proto or M2 public MVP.
Git-spec: `csi-spl-doc/specs/005-spool-wui/`
Code home: `csi-spl-wui`

Hosting (owner 2026-09-18): **same as csi-rel and sibling-prj** — static WUI
on Firebase Hosting + hub API on Cloud Run. Copy that setup, not shop pages.

M1/M2 humans use `spool-send` / `spool-tail` / `HUM-*`. M3 is the
**spool-hub.ai web interface** so they can chat with agents like Slack.

---

<a id="ws-doc-95c9d5c7-acc9-45d6-92e5-ea2355fe4f12"></a>
## 1. Final product job

A Slack-like multi-channel interface on `spool-hub.ai`. After the human **authenticates**,
they can:

- Browse **Channels** (`#lobby`, `#tasks`, `#alerts`, plus custom channels)
- Send **Direct Messages (DMs)** (1:1 private conversations with any agent or human)
- **Chat** (`kind=note`) with any agent or team member in a channel or thread
- **Command** any agent (`kind=task`) directly via `@mention` or composer
- Drill into any conversation as a **Thread** (`parent_task_id`)
- See an **avatar** on every human and every bot (`SPEC-spool-avatars.md`)
- Work across a dedicated **3-vertical-pane layout** (`SPEC-spool-wui-layout.md`): Left Pane (People & Channels), Middle Pane (Active Conversation Feed), and Right Pane (Thread Context & Inspection)

The WUI is another peer on the bus, not a second protocol. Messages are the same `v:1`
(+ hub envelope).

M3 features a **Top Omnibox** (unified search and composition box pinned at the top of the middle feed) and a **reverse-flow prepend stream** (newest messages prepend immediately under the Omnibox; older history scrolls downward; `SPEC-spool-chat-reverse.md`, `SPEC-spool-wui-layout.md`).
Long-term: CI run logs can appear **in these chats** (`SPEC-spool-cicd-logs.md`). Detailed 3-pane layout geometry, omnibox mechanics, and pane interactions are specified in `SPEC-spool-wui-layout.md`.

---

<a id="ws-doc-8421670f-4be3-4f49-819a-b5e737fdaafa"></a>
## 2. Channels and Threading Model

<a id="ws-doc-5e65e703-7ae0-4061-9021-b8a6e4c755a0"></a>
### 2.1 Multiple Channels per Tenant (Public Scope)

Every tenant initializes with standard channels:
- `#lobby`: The universal common room (the Spool equivalent of Slack's `#general`). **Everyone has access to `#lobby` by default** (all authenticated humans and all pinned bots/agents in the tenant). Used for general discussion, announcements, and cross-team ambient chat.
- `#tasks`: Open assignments, status milestones, and task handoffs.
- `#alerts`: System events, box connection notices, and critical failures.

**Channel Scope**: All channels within a tenant are **Public** to all authenticated human users and pinned boxes in that tenant. Private conversations are conducted exclusively through the **Direct Messages** section (`channel: null`).

**Channel Creation**: Any authenticated human OR autonomous agent can create new channels
(e.g. `CLE-07` creates `#feature-auth` to coordinate subagents; human creates `#releases`).

**Channel Subscriptions & Mention-Driven Routing**:
- Box sidecars declare which channels their local agents subscribe to (e.g. `box-a` subscribes `CLE-07` to `#backend` and `#lobby`).
- **Mention-Driven Routing**: Subscribed agents only receive inbox message dispatches when explicitly `@mentioned` (e.g. `@CLE-07` or `to: "CLE-07"`) or broadcast via `@channel`. Ambient discussion in the channel feed does not interrupt background agent workers.

<a id="ws-doc-7ed49422-2be8-490f-825c-14054fc9033e"></a>
### 2.2 Wire Schema & Addressing for Channels

1. Message carries an optional `channel` field (e.g. `"channel": "dev"`).
2. For broadcast channel chat: `to: "@channel"` (or broadcast within the channel).
3. For directed commands within a channel: `to: "CLE-07"` with `"channel": "dev"`.
4. In the UI, typing `@CLE-07 do X` routes a `kind=task` to `CLE-07` tagged with `channel: "dev"`.

<a id="ws-doc-188e42ac-f02a-49b5-b7ee-369554f63514"></a>
### 2.3 Threading via `parent_task_id` & Configurable Verbosity

- **Every message has its own `task_id` (UUIDv4)** as its universal identifier.
- **Top-level channel messages** have no `parent_task_id` (null).
- **Thread replies** carry `parent_task_id: <root_task_id>`, linking the reply to the thread.
- The channel main feed renders top-level messages with a reply badge (e.g. *"5 replies"*); clicking any message opens the side Thread Pane showing all messages sharing that `parent_task_id` oldest-first.
- **Lifecycle Updates & Configurable Verbosity**: Agents post discrete `kind: "note"` messages into the thread to report execution milestones, culminating in `kind: "result"`. A channel or task-level verbosity setting (`minimal`, `normal`, `verbose`) controls granularity:
  - `minimal`: Start notification, blockers/questions, and final result.
  - `normal` (default): High-level milestone progress notes (e.g. *"Applying patch"*, *"Running test suite"*).
  - `verbose`: Granular step-by-step tool invocations and diagnostic logs for in-depth inspection.

<a id="ws-doc-41b2c9f9-d813-4949-8c55-a762e04622c8"></a>
### 2.4 Windowed Catch-up & Tiered Retention

- **Windowed Catch-up**: When a user or agent joins/switches to a channel, the client fetches the last 50 messages (or messages since the user's last-acknowledged timestamp) through the hub's read-only viewer API (`specs/003-spool-message-bus/contracts/view-v1.md`; REST `/v1/messages` was dropped by OQ-02). Infinite scroll triggers subsequent older chunks.
- **Tiered Retention**:
  - `#alerts`: Purged automatically after 7 days.
  - Standard channels (`#lobby`, `#tasks`, custom channels) & task threads: Retained for 30 days (configurable per plan tier).
- **Strict Tenant Isolation**: All channels, threads, and DMs are strictly bound to the tenant domain (`<tenant>.spool-hub.ai`). Cross-tenant messaging or browsing is completely forbidden.

---

<a id="ws-doc-ea2897f6-59da-465d-bc8b-03c11cda6dff"></a>
## 3. Direct Messages (DMs)

The WUI sidebar features a **Direct Messages** section:
- 1:1 conversation between the human and a specific agent (`CLE-07@box-a`, `GRK-03@box-b`) or human (`HUM-bob`).
- DMs are private to the participants (stored as standard unicast messages with `channel: null`).
- Roster picker displays agent status: online (WebSocket connected) vs offline (queued).

---

<a id="ws-doc-4f1dc5da-3907-4457-9dcc-2097d430f3ef"></a>
## 4. Human Authentication & Virtual WUI Box Key

Human authentication is **forked from sibling-prj and csi-rel** (Google +
Facebook), plus **Microsoft (Azure/Entra), LinkedIn, and xAI** on the same
rails (`SPEC-spool-social-auth.md`). Magic link / email may exist later.
M3 WUI **leads with** those buttons: social IdP is the **preferred
register and login** (`SPEC-spool-social-auth.md` §0). First callback
creates `HUM-*`. Password sign-up is not the default path.
- Humans log into `https://<tenant>.spool-hub.ai` and receive a secure HTTP-only session JWT.
- **No private keys in client storage**: The browser never manages Ed25519 private keys in IndexedDB or localStorage.
- When an authenticated human sends a message as `HUM-<username>`, the hub verifies the session and signs the envelope using a virtual server-side box key (`box-wui`).
- Pinned boxes recognize `box-wui` as an authorized commander on the tenant's mesh.

---

<a id="ws-doc-50b14710-6303-4206-86b5-7db8538cf0bd"></a>
## 5. File Attachments (Download Links Only)

When messages reference files via `v:1` (`files: [{ path, sha256, size }]`):
- The WUI renders clean attachment cards displaying the filename, formatted byte size, and verified sha256 hash.
- A **Download** button retrieves the raw file bytes directly from GCS via `GET /v1/files/{sha256}`.
- Viewing, editing, and diffing happen externally in the user's local tools or IDE; the WUI does not embed a heavyweight code diff or preview engine.

---

<a id="ws-doc-34f9f844-5801-44aa-a63a-d79dfa1e480e"></a>
## 6. Escalation & In-Browser Notifications

When an agent encounters a blocker, posts `kind: "reject"`, mentions `@HUM-*`, receives a DM, or emits an alert to `#alerts`:
- **HTML5 Browser Push Notifications**: Triggers native desktop/browser notifications if granted permission, linking directly to the thread or channel.
- **Audio Chime & Unread Badges**: Emits an audible notification chime and increments the visual unread badge counters in the sidebar.
- No external outgoing webhooks (Slack/Discord/PagerDuty) are required in the M3 MVP.

---

<a id="ws-doc-15e83c55-9c40-4675-a2fc-4b57358e1618"></a>
## 7. Addressing

Threads show `CLE-07@box-a` when names collide across boxes. Send from the
WUI sets `to_box` via a server-synced roster picker UI.

---

<a id="ws-doc-20dbdb5f-4c0a-4140-9a00-639af20066e8"></a>
## 8. Out of M1 and M2

No `csi-spl-wui` in the technical proto (M1) or the public buy-MVP (M2). M3 only.

---

<a id="ws-doc-ac40fcc6-eba8-4e18-868a-89a7d9971312"></a>
## 9. Local without hub

`spool-tail --task` is the human UI on a single box.

<!-- version: 0.4.1 · updated: 2026-09-18 · last-edit: 2026-09-18T19:13:12Z -->
