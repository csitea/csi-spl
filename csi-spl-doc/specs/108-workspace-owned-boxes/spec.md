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
Agents on a box follow the grammar `<ID>@<box>` (e.g., `c-004@box-alpha`, defined in Spec 061). The box identifier (`box-alpha`) is unique per workspace (`PRIMARY KEY (tenant_id, box_id)`), not global. All spool messages from/to `<ID>@<box>` carry the box's workspace ID. A machine that hosts several workspaces (section 3.5) enrols once per workspace: each workspace's OS user generates its own key and joins with its own workspace's token, so each pin, and each `box_id` row, belongs to one workspace only. The public key is globally unique across all workspaces (exempting `box-wui`, since the hub pins its own key in every workspace). Uniqueness is enforced by a unique index on live `pins(pubkey)`, with a conflict answering `pin_conflict` that never names the other workspace.

### 3.3. Hub Enforcement on Read and Write
The hub DB enforces isolation using Postgres Row-Level Security (RLS) with `FORCE`, which is already built (Spec 017). The column used is `tenant_id` and the session setting is `app.tenant_id`. The workspace is the one the VERIFIED PIN belongs to. `X-Spool-Tenant` only names it, and a header/pin mismatch is refused. There is no `agents` table; agents are `roster` rows. There is ONE runtime DB role for all tenants. The anonymous view door is refused outside lde.

### 3.4. Relay Access
The relay uses one bucket per env with one Service Account (SA). The relay SA key NEVER reaches a workspace box. Instead, the hub mints per-object signed URLs under a hub-chosen `<tenant_id>/` prefix for the box to use.

### 3.5. Box-Side Isolation
A box may host several workspaces (owner, spec 122 Q-2 = C: a shared pool). Each workspace on a box runs as its own OS user, with its own spool root and its own state dir; an OS user never serves two workspaces. Enforced in `do_spl_desk_up` (it refuses to start a workspace's desk under an OS user, spool root or state dir already bound to another workspace) and at pin (a pin belongs to exactly one workspace, section 3.2). Isolation between workspaces on one box is OS-user isolation (test 4(d)), not isolation from that box's root: root, and the operator who runs the box, sees every workspace on it. A workspace that needs isolation from the box operator runs its own box.

### 3.6. Operator Workspace Visibility
Operator scope grants every row when `app.rls_scope='operator'`. Only named `asOperator` callers set the scope (`TestOperatorScopeCallers`); `replay-unsigned` is the one route that takes the workspace from the body (SA allow-list). Isolation is between workspaces, not from the instance operator. `HubRoleCanLiftRLS` answering empty is the prd start gate.

### 3.7. Revoke / Remove Path
A workspace admin can revoke a box from the WUI. This sets `pins.revoked_at`, closes session sockets, refuses reconnects, voids join tokens, and refuses URL minting. Revoke must drop upload tokens. Other instances see revoke within the 5s pin cache. The hub does not issue remote wipe commands; a local leave action must be performed to clean up the box.

### 3.8. Feature Switch and Box Modes
Owner HUM-10, t1 65f75266, msg 9bdc5980 (2026-10-10): "this whole feature should be switchable on and off, and the default should be off for now. Because it will be paid by future customers". Follow-up msg 45f51dbd: "allow operating certain workspaces in this restricted one-workspace-per-one-box setting and to have other boxes which handle one or more workspaces setting."

**The switch.** `tenants.box_join_enabled` (rdb 0170), one per workspace, `NOT NULL DEFAULT false`: OFF for every workspace, existing ones included. Only an admin of the operator workspace (spec 074) flips it: `PATCH /v1/operator/workspaces/{id}` `{"box_join_enabled": true|false}` (audited), or the shell action `do_spl_box_join_switch` (per-env SA through the proxy). A workspace's own admin cannot turn it on: no workspace route writes it.

**Two box modes, side by side on one hub.**
- **shared**: today's fleet boxes. One OS user serves several workspaces, each seated by its root-key holder (`do_spl_desk_pin`, `POST /v1/pins`). Unchanged by this section.
- **dedicated**: a box enrolled into one workspace by `do_spl_box_workspace_setup` (section 3.5, the root-owned `<workspace_base>/claim` naming that workspace, its own OS user and spool root).

`spool join` reads the box's mode from the claim (`SPL_WS_BASE`, default `/var/spool-ws`): a claim naming the token's workspace = `dedicated`; no claim = `shared`; a claim naming another workspace is refused on the box, before any hub call. The mode travels as `box_mode` in the join body and inside the payload the box key signs, and the hub records it on the pin (`pins.box_mode`, rdb 0170; NULL on every root-key pin and every pin before 0170, read as shared).

**Where the hub decides: `POST /v1/pins/join` and `POST /v1/tenant/agents/join-tokens`.**

| workspace switch | mint a join token | redeem, `dedicated` box | redeem, `shared` box |
|---|---|---|---|
| OFF (default) | 403 `box_join_disabled` | 403 `box_join_disabled` | 403 `box_join_disabled` |
| ON (restricted) | 201, as before | pinned, `box_mode = dedicated` | 403 `box_mode_shared` |

The refusal answers before the token is looked up and never echoes it. A box already seated keeps working whatever the switch says: the switch stops new joins only, not sessions, sends or relay URLs. Open tokens of a workspace switched OFF stay listed, so an admin can still revoke them, and revoking a seat stays allowed. The join-token list answers `enabled`, and the WUI hides Settings -> Agents' new-token part when it is false.

**Trust.** The mode is the box's own declaration, signed by its box key: the hub cannot inspect the box. It is as strong as the box's root (section 3.5): the claim is root-owned, and a box operator who lies about it is outside this threat model.

**Owner choice, open (default built).** Does a root-key pin (`POST /v1/pins`) into a restricted workspace also have to be dedicated? Built default: no, a root-key pin is the root holder's own act and stays as it is; only the join path checks the mode.

## 4. Tests
Every test is a pair with its control.
- **(a) Isolation Test (n=1)**: Create Workspace A and Workspace B. Send a message in A. Run a query under Workspace B's `tenant_id`; assert it returns 0 rows. Control: Run the same query under Workspace A's `tenant_id`; assert it returns the message row.
- **(b) Header/Pin Mismatch (n=2)**: Assert a request with a valid pin but a mismatched `X-Spool-Tenant` is refused. Control: Matching header/pin is accepted.
- **(c) Same Key Pinned (n=3)**: Assert the same key cannot be pinned into a second workspace. Control: Unique keys can be pinned.
- **(d) EACCES Test (n=4)**: Assert that the per-workspace OS user cannot read another workspace's spool root. Control: the box's own root stays readable.
- **(e) Cross-Workspace Spool-Send (n=5)**: Assert a message sent to a recipient in another workspace is refused. Control: Message within the same workspace succeeds.
- **(f) Relay Prefix Test (n=6)**: Assert box cannot fetch signed URLs for another workspace's prefix. Control: Box can fetch its own prefix.
- **(g) Revoke Test (n=7)**: Assert a revoked box cannot mint tokens or connect. Control: An active box can.
- **(h) Feature Switch (n=8, section 3.8)**: With the switch OFF, mint and redeem answer 403 `box_join_disabled`, a box seated before still connects, and a non-operator admin cannot turn it on. With it ON, a `shared` redeem answers 403 `box_mode_shared`. Control: ON, mint and a `dedicated` redeem pass and the pin records `dedicated`.

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
- **agy-3** (extra agy seat, owner HUM-10 msg 8a50e06e): YES (agreed at spec `e83aa15b`, opinion 3a13a50e)
- **agy-4** (extra agy seat, owner HUM-10 msg 8a50e06e): YES (agreed at spec `e83aa15b`, opinion b10abdf8)

Overall: YES at e83aa15b (agy author a-552, agy-2, agy-3, agy-4, claude-a, claude-b). Owner question 1 (section 7) answered 2026-10-10: yes, a shared pool (spec 122 Q-2 = C, msgs b7ff5f4a / e95a0695, folded in 5ced76397). Questions 2-3 still open; build waits for their answers.

## 7. Owner Questions
1. Is a second workspace on one machine allowed, as a second OS user + spool root? **ANSWERED: yes** (2026-10-10, spec 122 Q-2 = C "a shared pool, one OS user and spool root per workspace on a box", msg b7ff5f4a "c", confirmed msg e95a0695 "Yes"; folded into section 3.5).
2. Does the existing multi-workspace desk (`spl-desk-up-tenants.func.sh`) stay operator-only, with the workspaces it hosts not isolated from the operator on that box?
3. At revoke, are queued deliveries held for the admin or purged?
