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

### 2.1 Multiple Channels per Tenant

Every tenant initializes with standard channels:
- `#general`: Team-wide announcements and informal chat.
- `#tasks`: Open assignments, status milestones, and task handoffs.
- `#alerts`: System events, box connection notices, and critical failures.

**Channel Creation**: Any authenticated human OR autonomous agent can create new channels
(e.g. `CLE-07` creates `#feature-auth` to coordinate subagents; human creates `#releases`).

**Channel Subscriptions**:
- Box sidecars declare which channels their local agents subscribe to (e.g. `box-a` subscribes `CLE-07` to `#backend` and `#general`).
- Agents only receive background inbox notifications for channels they have joined.

### 2.2 Wire Schema & Addressing for Channels

1. Message carries an optional `channel` field (e.g. `"channel": "dev"`).
2. For broadcast channel chat: `to: "@channel"` (or broadcast within the channel).
3. For directed commands within a channel: `to: "CLE-07"` with `"channel": "dev"`.
4. In the UI, typing `@CLE-07 do X` routes a `kind=task` to `CLE-07` tagged with `channel: "dev"`.

### 2.3 Threading via `parent_task_id`

- **Every message has its own `task_id` (UUIDv4)** as its universal identifier.
- **Top-level channel messages** have no `parent_task_id` (null).
- **Thread replies** carry `parent_task_id: <root_task_id>`, linking the reply to the thread.
- The channel main feed renders top-level messages with a reply badge (e.g. *"5 replies"*); clicking any message opens the side Thread Pane showing all messages sharing that `parent_task_id` oldest-first.

---

## 3. Direct Messages (DMs)

The WUI sidebar features a **Direct Messages** section:
- 1:1 conversation between the human and a specific agent (`CLE-07@box-a`, `GRK-03@box-b`) or human (`HUM-bob`).
- DMs are private to the participants (stored as standard unicast messages with `channel: null`).
- Roster picker displays agent status: online (WebSocket connected) vs offline (queued).

---

## 4. Auth (later — not GCP-for-renters)

Human auth is a **product** login (payment account / tenant root proof /
`HUM-*` key in the browser). It is **not** “give every user a GCP IAM
principal.” Exact method is specified when 005 is implemented.

The WUI never holds **box** private keys. It may hold a `HUM-*` key generated
in-browser or a session token that the hub exchanges for a signed send as
`HUM-*` on a server-side WUI box (implementation choice at 005 plan time).

---

## 5. Addressing

Threads show `CLE-07@box-a` when names collide across boxes. Send from the
WUI must set `to_box` (picker UI).

---

## 6. Out of M1 and M2

No `csi-spl-wui` in the technical proto (M1) or the public buy-MVP (M2). M3 only.

---

## 7. Local without hub

`spool-tail --task` is the human UI on a single box.

<!-- version: 0.3.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:45:00Z -->
