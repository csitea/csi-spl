# Spec 108: Workspace-Owned Boxes

## 1. The Problem
We must establish the mechanisms by which the admin of every workspace might be able to add 1 or more boxes with one or more agents to their own workspace so that the other workspaces will NOT be able to see neither their data on the boxes, nor their messages in the hub DB.

## 2. Threat Model
A second workspace's admin, agent, or box could try to:
- Read or write messages in the hub DB belonging to the first workspace.
- Access spool directories, keys, or logs of a box belonging to the first workspace.
- Impersonate a box or agent of the first workspace.
- Register an agent or box under the first workspace's identity.

## 3. Design

### 3.1. Box Enrolment by Workspace Admin
A workspace admin generates a "Box Join Token" from the WUI (Workspace Settings -> Fleet). This token embeds the workspace ID. The admin runs the box start script, passing this token. The hub validates the token, creates the box record in the DB pinned to that workspace, and issues a long-lived relay/sidecar keypair bound to that specific box and workspace. There is no operator intervention.

### 3.2. Box and Agent Identity
Agents on a box follow the grammar `<ID>@<box>` (e.g., `c-004@box-alpha`, defined in Spec 061). The box identifier (`box-alpha`) is scoped globally but strictly tied to its workspace in the hub DB. All spool messages from/to `<ID>@<box>` carry the box's workspace ID.

### 3.3. Hub Enforcement on Read and Write
The hub DB enforces isolation using Postgres Row-Level Security (RLS) with `FORCE`. Every authenticated hub session (via the WUI, relay, or sidecar) maps to exactly one pinned workspace ID. The RLS policies ensure that any `SELECT`, `INSERT`, `UPDATE`, or `DELETE` on the `messages`, `boxes`, and `agents` tables automatically append a `WHERE workspace_id = current_setting('spool.workspace_id')` condition, preventing any cross-workspace leakage.

### 3.4. Keys per Workspace
Each box receives a unique relay/sidecar key pair upon enrolment. These keys authenticate the box to the hub API. The hub looks up the key, identifies the box and its owning workspace, and sets the Postgres session variable (`spool.workspace_id`) before processing any query.

### 3.5. Operator Workspace Visibility
The operator workspace (Spec 074) manages global infrastructure. It sees anonymized fleet health (e.g., box counts, connection status) but does NOT see message payloads, file names, or user data. RLS explicitly excludes operator DB roles from reading tenant message rows.

### 3.6. Revoke / Remove Path
A workspace admin can revoke a box from the WUI. The hub deletes the box's key pair, instantly severing its relay and API access. All pending inbox/outbox messages for that box in the hub DB remain in the workspace but are undeliverable. The box itself remains isolated; the admin must physically wipe it to clear local spool directories.

## 4. Tests
- **Isolation Test**: Create Workspace A and Workspace B. Send a message in A. Run a query as Workspace B's DB role; assert it returns 0 rows.
- **Control Test**: Run the same query as Workspace A's DB role; assert it returns the message row.
- **Enrolment Test**: Enrol a box with Workspace A's token. Assert the API sets `workspace_id = A`. Attempt to fetch messages using the token but overriding the workspace ID to B; assert failure.

## 5. Phased Task List (Sketch)
1. **Schema & RLS**: Add `workspace_id` to `boxes` and `agents` tables. Update RLS policies.
2. **Tokens & Keys**: Implement "Box Join Token" generation in WUI/API. Update the relay/sidecar key issuing to bind keys to `workspace_id`.
3. **Session Pinning**: Update hub API middlewares to set `current_setting('spool.workspace_id')` based on the authenticated box/user.
4. **WUI Admin Views**: Add Fleet management to Workspace Settings (Enrol / Revoke box).
5. **Tests**: Implement the Isolation, Control, and Enrolment tests.

## 6. Consensus
(Pending reviews from one grok, two claude)

## 7. Owner Questions
1. When a box is revoked, should the hub automatically issue a remote-wipe command to the box before severing its connection, or is manual physical wipe expected?
2. Are box names (e.g., `box-alpha`) required to be globally unique across all workspaces, or only unique within a single workspace?
