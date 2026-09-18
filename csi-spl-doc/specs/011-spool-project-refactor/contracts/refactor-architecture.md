# Contract: Spool Refactor Architecture & Interfaces (011)

**Feature**: `specs/011-spool-project-refactor` · **Milestone**: M1–M3 Consolidation · **Created**: 2026-09-18
**Authority**: `../spec.md` · **Binding Narrative**: `../../../doc/md/SPEC-spool-project-refactor.md`

---

## 1. Go Backend Architecture (`csi-spl-api`)

### 1.1 Target Package Hierarchy

```
csi-spl-api/src/go/spool-hub-api/
├── cmd/
│   └── spool/
│       ├── main.go               # Minimal CLI entry point (context, signal handling)
│       └── commands/             # Isolated subcommand definitions
│           ├── command.go        # Interface Command { Name(), Flags(), Run() }
│           ├── serve.go          # Cloud Run hub daemon
│           ├── send.go           # CLI message dispatch
│           ├── recv.go           # CLI mailbox receiver
│           ├── tail.go           # CLI thread follower
│           ├── sync.go           # Offline sync runner
│           ├── flush.go          # Outbox flush runner
│           ├── pin.go            # Pinning management
│           ├── keygen.go         # Box key generation
│           ├── mcp.go            # Model Context Protocol stdio server
│           └── migrate.go        # Postgres schema migration runner
└── internal/
    ├── domain/                   # Pure domain models (no transport or DB tags)
    │   ├── message.go            # Message entity, Kind, Validation
    │   ├── envelope.go           # Hub envelope, cryptographic signature
    │   ├── channel.go            # Channel entity, permissions
    │   └── tenant.go             # Tenant entity, quota, status
    ├── service/                  # Application business logic
    │   ├── dispatcher.go         # Cross-box message routing & delivery tracking
    │   ├── thread.go             # Thread grouping & chronological assembly
    │   └── pin_service.go        # Pin verification & tenant root rules
    ├── transport/                # External protocol adapters
    │   ├── ws/                   # WebSocket server & client session handlers
    │   ├── http/                 # REST handlers (/v1/view/*, /v1/files/*)
    │   ├── mcp/                  # MCP tool definitions & JSON-RPC mapping
    │   └── middleware/           # Tenant resolution, AuthSession, Logging, Recovery
    ├── store/                    # Persistence adapters
    │   ├── store.go              # Storage interfaces (MessageStore, TenantStore)
    │   ├── postgres/             # PostgreSQL implementation & migrations
    │   └── memory/               # In-memory test store
    ├── blob/                     # Cloud blob storage adapter (GCS client)
    ├── sign/                     # Ed25519 cryptographic primitives
    └── config/                   # Environment configuration loader
```

### 1.2 CLI Command Interface

```go
package commands

import "context"

type Command interface {
    Name() string
    Description() string
    RegisterFlags(fs *flag.FlagSet)
    Run(ctx context.Context, args []string) error
}
```

---

## 2. Frontend Architecture & Client Adapter (`csi-spl-wui`)

### 2.1 Polymorphic Client Interface

```typescript
// utils/client/interface.ts
export interface SpoolClient {
  listChannels(): Promise<Array<{ channel_id: string; name: string; created_by: string }>>
  createChannel(params: { name: string }): Promise<{ channel_id: string; name: string }>
  listMessages(filter: { channel?: string; peer?: string; limit?: number }): Promise<SpoolMessage[]>
  getThread(taskId: string): Promise<ThreadView>
  sendMessage(params: { channel?: string; peer?: string; text: string; parentTaskId?: string }): Promise<SpoolMessage>
  roster(): Promise<RosterData>
  session(): Promise<SessionState>
  healthz(): Promise<{ status: string }>
}
```

- **`HttpSpoolClient`**: Dispatches requests via `fetch` to `/v1/view/*` and maintains WebSocket subscription on `/v1/ws`. Throws standard error envelopes (`ErrorResponse`) on failures.
- **`MockSpoolClient`**: Operates against an immutable copy of `mock-data.mjs`, simulating async network latency (5–20ms) and mutating an in-memory session.

### 2.2 3-Pane Component Topology

```
+-------------------------------------------------------------------------------+
|                             SpoolShell.vue                                    |
+----------------------+-------------------------------+------------------------+
| Pane 1: Left (260px) | Pane 2: Middle (flex: 1)      | Pane 3: Right (380px)  |
| ChannelSidebar.vue   | MessageFeed.vue               | ThreadPane.vue         |
|                      |                               | (collapsible drawer)   |
| - Tenant header & dot| - TopOmnibox.vue (pinned top) | - Pinned Root Card     |
| - Global views       | - Reverse Prepend Stream:     | - Verbosity Selector   |
| - Channels (#lobby)  |   - MessageCard.vue           | - Prepended Replies    |
| - People & Bots      |   - FileAttachment.vue        | - Thread Composer      |
| - User profile footer| - Downward scroll pagination  |                        |
+----------------------+-------------------------------+------------------------+
```

### 2.3 Store Hierarchy & State Responsibilities

| Store | File | State Responsibility |
|---|---|---|
| `useWorkspaceStore` | `stores/workspace.ts` | Active channel slug (defaults to `lobby`), selected DM peer, Pane 3 drawer toggle state (`isThreadOpen`, `activeTaskId`). |
| `useFeedStore` | `stores/feed.ts` | Reverse-ordered message list for the active viewport, pagination cursors, optimistic send queue, Omnibox text draft. |
| `useThreadStore` | `stores/thread.ts` | Active thread root message, thread replies array (prepended), verbosity level (`minimal`, `normal`, `verbose`). |
| `useRosterStore` | `stores/roster.ts` | Active agents and humans in tenant, online/busy/offline presence, robot avatar styling parameters. |
| `useSessionStore` | `stores/session.ts` | Authenticated identity (`HUM-*`), provider status, CSRF tokens, sign-out action. |

---

## 3. Data Streaming & Reverse Prepend Contract

1. **Ordering Invariant**:
   - In both the main feed (Pane 2) and thread drill-down (Pane 3), messages are rendered with the **newest message at the top** and the oldest message at the bottom.
2. **Real-Time Event Ingestion**:
   - When a new message arrives via WebSocket or local user send:
     - It is **prepended** at index 0 of the store's message array: `messages.unshift(newMessage)`.
     - The DOM applies a CSS entrance animation (`keyframes slideDownFadeIn`).
     - Scroll position remains pinned to top unless user has explicitly scrolled down.
3. **Downward Historical Paging**:
   - Scrolling down triggers an intersection observer when reaching the bottom buffer (older messages).
   - The client fetches the next chunk: `listMessages({ channel, before: oldestTimestamp, limit: 50 })`.
   - Incoming chunk items are appended to the end of the array: `messages.push(...olderChunk)`.

---

## 4. Configuration Schema Contract (`csi-spl-cnf`)

Every environment configuration file (`<env>.env.yaml`) must conform to the JSON Schema `csi-spl-cnf/schema/env-schema.json`.

Required top-level blocks:
- `env.gcp`: `project_id`, `region`, `zone`
- `env.dns`: `domain`, `base_domain`, `managed_zone`
- `env.hub`: `service_name`, `min_instances`, `max_instances`, `memory`, `cpu`
- `env.postgres`: `instance_name`, `tier`, `database_name`
- `env.auth`: `providers`, `session_cookie_name`, `cookie_domain`

Execution invariant: `./run` aborts immediately with exit code 1 if configuration validation fails.

---

<!-- version: 1.0.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:33:00Z -->
