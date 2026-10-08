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
A workspace admin generates a "Box Join Token" from the WUI (Workspace Settings -> Fleet). This token embeds the workspace ID (`tenant_id`). The admin runs the box start script, passing this token. The box generates its own private key and the hub pins the public half. The hub NEVER mints a box private key. Enrolment uses the spec 073 join token mechanism.

### 3.2. Box and Agent Identity
Agents on a box follow the grammar `<ID>@<box>` (e.g., `c-004@box-alpha`, defined in Spec 061). The box identifier (`box-alpha`) is scoped globally but strictly tied to its workspace in the hub DB. All spool messages from/to `<ID>@<box>` carry the box's workspace ID. The public key is globally unique across all workspaces.

### 3.3. Hub Enforcement on Read and Write
The hub DB enforces isolation using Postgres Row-Level Security (RLS) with `FORCE`, which is already built (Spec 017). The column used is `tenant_id` and the session setting is `app.tenant_id`. There is no `agents` table; agents are `roster` rows. There is ONE runtime DB role for all tenants.

### 3.4. Relay Access
The relay uses one bucket per env with one Service Account (SA). The relay SA key NEVER reaches a workspace box. Instead, the hub mints per-object signed URLs under a hub-chosen `<tenant_id>/` prefix for the box to use.

### 3.5. Box-Side Isolation
One box = one workspace (or per-workspace OS user and spool root). Each box runs its own OS user, spool root, and state dir to isolate spool directories, keys, and logs from other workspaces.

### 3.6. Operator Workspace Visibility
Operator scope grants every row when `app.rls_scope='operator'`, which the hub login sets. However, no route caller returns message rows to the operator instance. Isolation is between workspaces, not from the instance operator.

### 3.7. Revoke / Remove Path
A workspace admin can revoke a box from the WUI. This sets `pins.revoked_at`, closes session sockets, refuses reconnects, voids join tokens, and refuses URL minting. Already-minted URLs live up to their TTL (which is capped). The hub does not issue remote wipe commands; a local leave action must be performed to clean up the box.

## 4. Tests
- **Isolation Test**: Create Workspace A and Workspace B. Send a message in A. Run a query under Workspace B's `tenant_id`; assert it returns 0 rows (using the existing `crosstenant_test.go` pattern).
- **Control Test**: Run the same query under Workspace A's `tenant_id`; assert it returns the message row.
- **EACCES Test**: Assert that the per-workspace OS user cannot read another workspace's spool root.

## 5. Phased Task List (Sketch)
1. **Tokens & Keys**: Implement "Box Join Token" generation in WUI/API. Update hub pinning to tie the box's public key to the `tenant_id`.
2. **Session Pinning**: Update hub API middlewares to set `current_setting('app.tenant_id')` based on the authenticated box/user.
3. **Relay Signed URLs**: Implement hub-minted signed URLs for relay object access.
4. **Box-Side Isolation**: Refactor box runtime to use per-workspace OS user and spool root.
5. **Revoke Path**: Implement revocation logic (close sockets, void tokens).
6. **WUI Admin Views**: Add Fleet management to Workspace Settings.
7. **Tests**: Implement the Isolation, Control, and EACCES tests.

## 6. Consensus
(Pending reviews from one grok, two claude)

## 7. Owner Questions
None remaining.
