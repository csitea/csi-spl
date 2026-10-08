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
Agents on a box follow the grammar `<ID>@<box>` (e.g., `c-004@box-alpha`, defined in Spec 061). The box identifier (`box-alpha`) is unique per workspace (`PRIMARY KEY (tenant_id, box_id)`), not global. All spool messages from/to `<ID>@<box>` carry the box's workspace ID. The public key is globally unique across all workspaces (exempting `box-wui`, since the hub pins its own key in every workspace). Uniqueness is enforced by a unique index on live `pins(pubkey)`, with a conflict answering `pin_conflict` that never names the other workspace.

### 3.3. Hub Enforcement on Read and Write
The hub DB enforces isolation using Postgres Row-Level Security (RLS) with `FORCE`, which is already built (Spec 017). The column used is `tenant_id` and the session setting is `app.tenant_id`. The workspace is the one the VERIFIED PIN belongs to. `X-Spool-Tenant` only names it, and a header/pin mismatch is refused. There is no `agents` table; agents are `roster` rows. There is ONE runtime DB role for all tenants. The anonymous view door is refused outside lde.

### 3.4. Relay Access
The relay uses one bucket per env with one Service Account (SA). The relay SA key NEVER reaches a workspace box. Instead, the hub mints per-object signed URLs under a hub-chosen `<tenant_id>/` prefix for the box to use.

### 3.5. Box-Side Isolation
One box = one workspace. Enforced in `do_spl_desk_up` and at pin. Each box runs its own OS user, spool root, and state dir. Root on a box sees all: an operator-run box never hosts another workspace's agents. (Note: Owner answer to Question 2 will override this behavior if conflicting).

### 3.6. Operator Workspace Visibility
Operator scope grants every row when `app.rls_scope='operator'`. Only named `asOperator` callers set the scope (`TestOperatorScopeCallers`); `replay-unsigned` is the one route that takes the workspace from the body (SA allow-list). Isolation is between workspaces, not from the instance operator. `HubRoleCanLiftRLS` answering empty is the prd start gate.

### 3.7. Revoke / Remove Path
A workspace admin can revoke a box from the WUI. This sets `pins.revoked_at`, closes session sockets, refuses reconnects, voids join tokens, and refuses URL minting. Revoke must drop upload tokens. Other instances see revoke within the 5s pin cache. The hub does not issue remote wipe commands; a local leave action must be performed to clean up the box.

## 4. Tests
Every test is a pair with its control.
- **(a) Isolation Test (n=1)**: Create Workspace A and Workspace B. Send a message in A. Run a query under Workspace B's `tenant_id`; assert it returns 0 rows. Control: Run the same query under Workspace A's `tenant_id`; assert it returns the message row.
- **(b) Header/Pin Mismatch (n=2)**: Assert a request with a valid pin but a mismatched `X-Spool-Tenant` is refused. Control: Matching header/pin is accepted.
- **(c) Same Key Pinned (n=3)**: Assert the same key cannot be pinned into a second workspace. Control: Unique keys can be pinned.
- **(d) EACCES Test (n=4)**: Assert that the per-workspace OS user cannot read another workspace's spool root. Control: the box's own root stays readable.
- **(e) Cross-Workspace Spool-Send (n=5)**: Assert a message sent to a recipient in another workspace is refused. Control: Message within the same workspace succeeds.
- **(f) Relay Prefix Test (n=6)**: Assert box cannot fetch signed URLs for another workspace's prefix. Control: Box can fetch its own prefix.
- **(g) Revoke Test (n=7)**: Assert a revoked box cannot mint tokens or connect. Control: An active box can.

## 5. Phased Task List (Sketch)
1. **Tokens & Keys**: Depend on 073 T003..T006.
2. **Session Pinning**: `inTenant` runs are built. Add tests.
3. **Relay Signed URLs**: Implement hub-minted signed URLs for relay object access.
4. **Box-Side Isolation**: Refactor box runtime to use per-workspace OS user and spool root.
5. **Revoke Path**: Implement revocation logic (close sockets, drop upload tokens, cache invalidation).
6. **WUI Admin Views**: Add Fleet management to Workspace Settings.
7. **Tests**: Implement the test pairs.

## 6. Consensus
- **claude-a**: YES (agreed at spec `4b64dd44`)
- **claude-b**: YES (agreed at spec `4b64dd44`)
- **agy-2** (stand-in for the grok seat, owner HUM-10 msg 04255b73): YES (agreed at spec `e83aa15b`)

Overall: YES at e83aa15b (agy author a-552, agy-2, claude-a, claude-b). Owner questions 1-3 (section 7) still open; build waits for their answers.

## 7. Owner Questions
1. Is a second workspace on one machine allowed, as a second OS user + spool root?
2. Does the existing multi-workspace desk (`spl-desk-up-tenants.func.sh`) stay operator-only, with the workspaces it hosts not isolated from the operator on that box?
3. At revoke, are queued deliveries held for the admin or purged?
