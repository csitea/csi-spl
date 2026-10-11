# 130: Flow: what is happening

Status: **proposed**

Amends and supersedes parts of 062.

## 0. The owner's ask

prd t1 #spool-hub-devel, topic da98036e-f62b-4482-a354-c71585be933d, HUM-10:
> "We should reconsider the flow view or the flow functionality... what it should be presenting is the things which are happening in the system, both from the point of view of persons and also from the agent's point of view. That is, what actually is happening? What is important is that a person should not receive anything in the flow from messages in which he is not involved... I would like to be able to quickly jump from the flow to the actual discussion or issue which triggered that flow. All of the releases, all of the 'something is ready', and all of the 'something is blocked' should go to the flow."

> "Kind of a place where there is a condensed answer to the question 'What is happening?' and then you are able to actually jump from there to the actual topics or channel discussions"

## 1. Today's Flow, measured

- **Spec 062** (`csi-spl-doc/specs/062-flow-per-user-counts/spec.md`): flow events per member, kinds mention / poke / dm / reply. Mine / All switch (Q1), Mine default; plain channel lines not in Mine (Q2); agents get no Flow events (Q5). Store: `internal/store/flow*.go`, rdb 0104 + 0137; hub `internal/hub/flow.go`; WUI `FlowList.vue`, `stores/flow.ts`, `utils/flow-*.mjs`.
- **Releases**: `do_release_note_link` mints `v<X.Y.Z>` tags and `/releases/<sha>` pages (wf 20 / 30).
- **Blockers**: A message kind `blocker`. c-821 (dispatch-e48433ef) is building blocker -> issue.
- **Issues**: Spec 039.
- **What is missing**: All breaks "not involved"; `release`, `ready`, `blocked` are not Flow kinds; agents get nothing; issues are not linked.

## 2. The condensed "what is happening" view

The Flow pane becomes a condensed answer to "What is happening?".

1. **One line per event**: Each event is a single line, grouped or collapsed so it reads as a high-level summary.
2. **Direct links**: Each line links directly to the exact message, topic, channel discussion, or issue behind it.

## 3. Relevance and "All"

A person or agent sees only events from discussions they are **part of**.
- **Part of** is defined as: posted in the thread, tagged (`@mention`), addressed (`to`), assigned to the issue, or explicitly watching.
- **Never** from a channel they merely belong to.
- **"All" switch**: Removed entirely. The Flow is strictly what is relevant to the viewer. (See Owner Questions).

## 4. New kinds: release, ready, blocked

Three new event kinds are added.

| kind | when it is emitted | emitted by | link goes to |
|---|---|---|---|
| `release` | A version goes live on dev or prd. | CI (`do_release_note_link` / harness) | The release note page (`/releases/<sha>`). |
| `ready` | A result message is accepted and its work is live. | Hub (upon `ACCEPTED` status update) / Spool | The result message / topic. |
| `blocked` | A `blocker` message naming the viewer, or in their discussion. | Hub / Spool | The issue (ties to c-821's blocker -> issue) or the topic. |

These work for every agent down the chain.

## 5. Agents: they get the same Flow

Reverses 062 Q5. Agents are first-class actors and get the exact same Flow as humans.
- **How they read it**: Via the desk pane, the spool (`spool recv` / `spool tail`), or MCP tools (`spool_flow`).
- **Cost**: The event is written to `flow_events` for the agent's `member_id` exactly as for a human. Since agents only get events they are "involved in", the fan-out is contained.

## 6. Data and performance

Under FORCE RLS on `db-f1-micro` (max_connections 25):

- **Fan-out**: Writing an event (e.g., a release or blocker) fans out one row per involved member to `flow_events`. For `release`, if everyone gets it (see Owner Questions), that is one row per tenant member. On a micro DB, this write must be batched asynchronously or riding the existing message insert to avoid starving the 25 connections.
- **Indexes**: `flow_events_member_at` on `(tenant_id, member_id, at DESC)` handles the read for humans and agents.
- **Badge**: The badge remains one index-only scan anti-joined with `read_marks`. For agents, they consume via MCP or spool, relying on the same index.

## 7. Migration and back-compat

- `flow_events` kind CHECK is widened to include `release`, `ready`, `blocked`.
- The Mine / All switch is removed from the WUI.
- Agents are backfilled for existing active threads they participate in.

## 8. Functional requirements

| FR | requirement |
|---|---|
| FR-001 | The WUI Flow pane shows grouped/collapsed lines, linking directly to the message, topic, or issue. |
| FR-002 | Relevance strictly enforced: viewer must be part of the discussion (posted, tagged, addressed, assigned, watching). |
| FR-003 | The WUI "All" switch is removed. |
| FR-004 | New kind `release`: emitted by CI deploy, links to release note. |
| FR-005 | New kind `ready`: emitted when a result is accepted. |
| FR-006 | New kind `blocked`: emitted on blocker messages naming the viewer or in their thread, links to issue. |
| FR-007 | Agents receive Flow events, readable via spool and MCP. |
| FR-008 | Fan-out writes for `flow_events` are batched to respect the 25-connection limit under FORCE RLS. |

## 9. Code lanes

| lane | scope |
|---|---|
| **L1 hub/store** | Widen `flow_events` kind CHECK. Hub logic to emit `ready` and `blocked` events on message insert/update. Agent ID inclusion in `flow_events` write. |
| **L2 WUI** | Remove Mine / All switch. Group/collapse UI for flow entries. Link rendering for `release`, `ready`, `blocked` (including issue links via c-821). |
| **L3 emitters** | CI harness update to emit `release` events (via a new hub API or spool message). |
| **L4 tests+proof** | e2e tests for new kinds. Live proof: an agent gets a blocker, human gets a release event. Performance test ensuring batch fan-out keeps connection pool healthy. |

## 10. Owner questions

| Q | question | proposal | decided |
|---|---|---|---|
| **Q1** | A release nobody involved you in: does everyone get the event, or only the people it ships for? | **Everyone.** A release is a system-wide "what is happening" event that concerns all members. | (pending) |
| **Q2** | The "All" switch: remove it entirely, or keep it behind the switch? | **Remove it.** Strict relevance keeps the view clean and matches the core "what is happening" intent. | (pending) |
