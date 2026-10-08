# 108 review: claude-b opinion

Reviewer `claude-b` (c-544). Draft read: `spec.md` at `88d4005ff`. Code read on
origin/master `c5b2ab89` and later. Doc only.

## 1. Verdict, round 1

**Not ready to build.** The goal and the two isolation goals are right. But the
draft describes a hub that does not exist: a `workspace_id` column, a
`spool.workspace_id` setting, one DB role per workspace, and a box key pair the
hub holds. It re-specifies what is already built (RLS with FORCE) and misses
the real gaps, which are on the box and in the relay bucket, not in Postgres.

The rule I want in the spec: **one box serves one workspace.** It is the
smallest change that delivers isolation goal 1. Today one box serves several.

## 2. What is already true (cite it, do not re-design it)

| fact | check |
|---|---|
| Every table with `tenant_id` has `ENABLE` + `FORCE ROW LEVEL SECURITY`, policy `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')` | spec 017 FR-SEC-013/014; rdb `0014_tenant_rls.sql`, `0021_rls_fail_closed.sql`; `grep -c 'FORCE ROW LEVEL' csi-spl-rdb/src/sql/postgres/spool-hub/0096_fleet_lanes.sql` -> 1 |
| CI fails a `tenant_id` table that lacks FORCE or has a fail-open policy; the table list comes from the catalogue | `TestRLSPoliciesFailClosed` (017 FR-SEC-014c) |
| The pin is transaction-local (`set_config(..., true)`), so a pooled connection cannot carry it into the next request; an empty workspace is `ErrNoTenant` | `internal/store/rls.go` `inTenant` |
| The hub's runtime login cannot lift RLS (not the owner, no BYPASSRLS) | 017 FR-SEC-014e, `TestRLSHubRoleCannotLiftRLS` |
| A cross-workspace suite with positive controls already exists | `grep -c 'control' csi-spl-api/src/go/spool-hub-api/internal/store/crosstenant_test.go` -> 4; e.g. line 459 "control: B's own message" |
| A box is seated per (workspace, box id) by a pinned PUBLIC key; the hub never holds the private key | `0001_hub_core.sql` pins PK; `internal/hub/rest.go` `handlePin` (line 424), `handleRevoke` (line 489) |
| A box names its workspace with `X-Spool-Tenant`, proven by its pin | `internal/hub/resolve.go:15-26` |
| Seating a box without the root key is spec 073 (join tokens): rdb `0119` landed; hub routes, CLI and WUI are not built | `073-agent-join-tokens/tasks.md`: T002 `[x]`, T003..T009 `[ ]`; `grep -c 'join' csi-spl-api/src/go/spool-hub-api/internal/hub/server.go` -> 0 |

## 3. Blocking findings

### 3.1 Wrong names and a wrong model (draft 3.3, 3.4, 4, 5)

- The column is `tenant_id` and the setting is `app.tenant_id`. There is no
  `workspace_id` column and no `spool.workspace_id`. Draft phase 1 ("add
  `workspace_id` to `boxes` and `agents`") would add a second, unpoliced key
  next to the real one. Drop it: `boxes`, `pins` and `roster` already carry
  `tenant_id` under FORCE.
- There is no `agents` table. Agents are rows of `roster`, keyed
  `(tenant_id, box_id, agent_id)`.
- Draft 4, "run a query as Workspace B's DB role": there is ONE runtime role
  for every workspace; the workspace is the transaction setting. A test with
  a role per workspace proves nothing about the hub. Use the existing
  pattern: the same store call under workspace B gives 0 rows, and under
  workspace A gives the row.

### 3.2 Box-side isolation is missing (isolation goal 1)

Measured on one box (n = 1), with `stat` and `getfacl`:

| path | mode | owner:group |
|---|---|---|
| `/var/spool-hub` | `drwxrws---`, `other::---` | `<box user>:spool-agents` |
| `/var/spool-hub/<ID>/inbox` | `drwxrwsr-x` | `<agent user>:spool-agents` |
| `/var/spool-hub/registry.tsv` | `-rw-rw-rw-` | `<box user>:spool-agents` |

So 017 FR-SEC-001 keeps OTHER users out, but **every member of the group reads
and writes every agent's inbox, outbox and archive, and the registry.** There
is one group per box, not per workspace. Desk state and box keys live under
one OS user per box, `$SPL_STATE_DIR/desk/<tenant>/<box>`
(`csi-spl-orc/src/bash/run/spl-desk-up.func.sh:68`), and one box already runs
desks for several workspaces (071 section 3.1: "prd: 6 (t1 + 5 tenants)").
An agent of workspace B on that box can read workspace A's box private key and
spool files. RLS cannot help: none of this reaches Postgres.

Required in the spec:

1. **One box, one workspace** (owner question 5.1). A workspace-owned box
   seats desks for exactly one workspace. `do_spl_desk_up` refuses a second
   workspace on a box whose box.env names another (a new key, e.g.
   `SPOOL_BOX_WORKSPACE`), and the hub refuses to pin one public key in two
   workspaces.
2. If the owner wants shared boxes instead, then per workspace: its own OS
   user and group, its own spool root (`/var/spool-hub/<workspace>`, mode
   2770, `other::---`), its own state dir, and `registry.tsv` at 0660, not
   0666. Plus a test that runs as workspace B's user and gets EACCES on A's
   inbox, with the control that A's user reads it.
3. Logs: the sidecar, desk-reconcile and lease logs live in that workspace's
   state dir with the same mode. The spec names each one.
4. Root on a box sees everything. The spec must say so: a box is isolated from
   other workspaces only when its owner alone holds root. An operator-run
   fleet box must not host another workspace's agents.

### 3.3 The relay bucket is one bucket per env, with one SA

`csi-spl-doc/doc/md/csi-spl.feature.md` section 5: one bucket `<project>-rel`,
one SA with `roles/storage.objectUser` on the whole bucket (list, get, create
and delete every object). Payloads are gpg-encrypted, but object names, sizes
and timing leak, and a key holder can delete another workspace's in-flight
objects. So:

- **The relay SA key never goes to a workspace-owned box.** Remove the draft's
  "issues a long-lived relay/sidecar keypair".
- The box gets **per-object signed URLs minted by the hub**, after the hub has
  resolved the box's workspace from its pin, under a `<workspace>/` prefix the
  hub chooses (never the client), with a short TTL from cnf.
- Test: a box of B asks the hub for a URL under A's prefix and is refused;
  control: A's box gets one.

### 3.4 Revoke (draft 3.6): the hub has no key pair to delete

The hub never holds the private key. Revoke is `DELETE /v1/pins/{box_id}`
(root-signed) or 073's `DELETE /v1/tenant/agents/pins/{box_id}` (admin; not
built). In one transaction it must mark the pin revoked (`pins_history`),
close live sockets (as `handleRevoke` does), void open join tokens for that
box, and refuse signed-URL and upload-token requests from it. URLs and upload
tokens already minted stay valid until their TTL: the spec says so and caps
those TTLs so the window is short. Test: after revoke, hello and upload are
refused; control: an unrevoked box of the same workspace still works.

### 3.5 Operator visibility (draft 3.5) contradicts the code

Every `tenant_id` table also has an `operator_scope` policy, true when
`app.rls_scope = 'operator'` (`0014_tenant_rls.sql:42`). RLS does NOT exclude
the operator. What bounds it is the named `asOperator` caller list
(`internal/store/operator_scope_test.go`, `TestOperatorScopeCallers`). The
honest rule:

- No `asOperator` caller reachable from a route returns message, delivery,
  file or roster rows. Today's route callers (checkout, webhooks,
  `Memberships`, `ListWorkspaces`, ...) do not.
- Box health for the operator is counts only (boxes, live sockets, last beat);
  a new caller goes into `operatorCallers` with that reason.
- The global sweepers (`Sweep`, `PruneBoxStats`, ...) read every workspace by
  design, with no route. Say so; "anonymised" is not accurate.
- Whoever runs the instance holds the DB owner DSN and the GCP project, and can
  read everything. The spec must say isolation is between workspaces, not from
  the instance operator. A workspace that needs more goes self-hosted (044).

### 3.6 Enrolment: build on 073, not a second token

Draft 3.1 is 073's join token under a new name. Use 073 (`spj1.<tenant>.<secret>`,
single use, TTL capped at 24 h, `agents.join` admin only, bound to one
`box_id`). 108 adds only what 073 lacks: the one-box-one-workspace check at
redeem, and the box-side setup of 3.2 run by the join CLI. 108's build starts
after 073 T003..T005.

## 4. Smaller points

- **Agent-id collisions.** Box ids are per workspace
  (`^[a-z0-9][a-z0-9-]{0,31}$`), so `c-004@sat` can exist in two workspaces.
  Routing is fine (the hub keys on the workspace first), but fleet tools such as
  `lane-map.sh`, and 061's "unique as `<ID>@<box>`", assume one workspace.
  My answer to the draft's owner question 2: **unique per workspace**, and any
  cross-workspace display (operator view, logs) shows the workspace next to
  `<ID>@<box>`. Global uniqueness would leak other workspaces' box names
  through enrolment (an existence oracle).
- **Legacy workspace Host with the view door off.** `resolve.go` `humanTenant`
  lets an anonymous request read the workspace a Host names when the view door
  is `off`. Both envs run `session` (cnf `SPOOL_HUB_VIEW_DOOR`). The spec should
  require the hub to refuse to start with `off` outside lde, so a cnf edit
  cannot open it.
- **Box tables without `tenant_id`.** FORCE only covers tables that carry the
  column. Every box table (box stats, facts, beats: rdb 0117, 0140, 0147) must
  carry `tenant_id` so the catalogue test covers it. One line in the spec: a
  box table without `tenant_id` fails review.
- **Remote wipe (draft owner question 1).** Do not offer it: a revoked box is
  untrusted, so a wipe command is only advisory. Give the box owner a local
  action (e.g. `do_spl_box_leave`) that removes that workspace's spool root,
  state dir and keys, and state that revoke is the security boundary.
- Hub tests extend `crosstenant_test.go` (it already has controls) with the
  box routes: roster, pins list, box stats, signed URL. Every 0-row assertion
  sits next to its control in the same test.

## 5. Owner questions I propose (one blocker, sent by the author)

1. Must a box serve one workspace only (recommended), or may one box serve
   several, with per-workspace OS users and spool roots?
2. Isolation is between workspaces, not from the instance operator, who holds
   the DB owner and the GCP project. Is that the promise, with self-hosting for
   a workspace that needs more?

## 6. Round 2, on spec `bc550d488`

Fixed, and I agree with: 3.1 (names, one runtime role, no schema phase in
3.3), 3.3 (relay SA key never on a box, hub-minted URLs), the hub never
minting a box private key, revoke as pin + sockets + tokens + URL refusal,
no remote wipe, and the 0-row test next to its control.

Still open. Each is one or two sentences in the spec:

| # | draft section | what to change | why (check) |
|---|---|---|---|
| R2.1 | 3.2 "public key globally unique" | exempt `box-wui`: the hub pins its OWN browser key in every workspace | `internal/hub/rest.go:435-443` `wui_key_mismatch`; one key, every workspace, by design |
| R2.2 | 3.2 "box identifier scoped globally" | box id is unique per workspace (`boxes` PK `(tenant_id, box_id)`); displays outside a workspace show the workspace too | `0001_hub_core.sql` |
| R2.3 | 3.5 "One box = one workspace (or ...)" + 7 "None remaining" | pick one or ask the owner. I recommend one box, one workspace; enforced twice: `do_spl_desk_up` refuses a second workspace on the box, and the hub refuses a second workspace's pin for the same key (R2.1 exempt) | an "or" cannot be built or tested |
| R2.4 | 3.5 | say root on a box sees everything, so an operator-run fleet box never hosts another workspace's agents | otherwise 3.5 promises what the OS cannot give |
| R2.5 | 3.6 "which the hub login sets" | only the named `asOperator` callers set it, frozen by `TestOperatorScopeCallers`; a new caller needs a reason line and must not return message, delivery, file or roster rows. Name the one route that takes a workspace from the client, `POST /v1/operator/replay-unsigned` (SA allow-list) | `internal/store/operator_scope_test.go`; `internal/hub/replay_unsigned.go` |
| R2.6 | 3.7 | revoke must also drop the box's upload tokens: today they are deleted only by the expiry sweep, so a revoked box uploads for up to `SPOOL_HUB_UPLOAD_TOKEN_TTL`. Other hub instances see the revoke within the 5 s pin cache; say so | `grep -n 'delete(s.tokens' internal/hub/server.go` -> 1 (line 554, the sweep); `store/hotcache.go:44` `hotCacheTTL = 5 * time.Second` |
| R2.7 | 5 phase 1 and 2 | phase 1 is 073 T003..T006 (depend on it, do not rebuild it); phase 2 is already built (`inTenant`): replace it with "the redeem route runs under `inTenant`" | `073-agent-join-tokens/tasks.md` |
| R2.8 | 4 | add, each with its control: relay URL under another workspace's prefix refused (own prefix minted); after revoke, hello and upload refused (an unrevoked box of the same workspace still works); EACCES for B's user on A's spool root (A's user reads it) | brief: every 0-row test needs a control |

R2.3 and the operator promise (5.2) are owner questions if the author does
not decide them; section 7 should not say "None remaining" while 3.5 has an
"or".

## 7. Status

Round 2 sent to the author on task 5901e226. **Points still open**: R2.1 to
R2.8. No consensus yet.
