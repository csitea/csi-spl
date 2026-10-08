# 108 workspace-owned boxes: opinion of reviewer claude-a

**Reviewer**: claude-a (lane c-543) · **Author**: the agy lane, owns `spec.md`
· **Topic**: 5901e226-01b9-4d6f-a13e-f714897c3ffd · **Written**: 2026-10-08
· **Tree read**: `origin/master` @ `c5b2ab89`

Written BEFORE the author's draft, as the brief asks. Section 6 compares the
two once the draft lands. Docs only: nothing here is built.

The owner's ask, in short: a workspace admin adds one or more boxes, each with
one or more agents, to their own workspace, and no other workspace sees the
data on those boxes or the messages in the hub database.

## 1. Verdict in one paragraph

The hub database half is mostly built already: every `tenant_id` table is under
ENABLE + FORCE row level security and a test fails when one is not. The weak
parts are elsewhere: (a) the BOX half, where today one box runs several
workspaces' desks under one OS user and one shared spool group, so there is no
isolation at all on the box; (b) the relay bucket, which is one bucket with one
service account that can read, list and delete every object; (c) the operator
scope, which is a session setting the hub login can set for itself; (d) enrolment
still needs a root key, because the join tokens of spec 073 are only Planned.
My position: **one box belongs to exactly one workspace, for its whole life**.
Everything below follows from that rule.

## 2. What is measured today (the attack surface)

| # | Fact | Check |
|---|---|---|
| M1 | Every tenant table has ENABLE + FORCE row level security, two policies: `tenant_scope` (`tenant_id = app.tenant_id`) and `operator_scope` (`app.rls_scope = 'operator'`) | `csi-spl-rdb/src/sql/postgres/spool-hub/0014_tenant_rls.sql:38-44`; newer tables repeat it, e.g. `0147_box_beats.sql:38-43` |
| M2 | A test fails when a `tenant_id` table lacks ENABLE or FORCE | `internal/store/rls_failclosed_test.go:18,66` |
| M3 | The operator scope is the GUC `app.rls_scope = 'operator'`, set with `set_config(..., true)`. Any statement the hub login runs may set it | `internal/store/rls.go:18-19` |
| M4 | An AST test lists every `asOperator` caller; a new one fails the build. It scans the store package only | `internal/store/operator_scope_test.go:20-56,69-127` |
| M5 | `boxes` and `pins` are keyed `(tenant_id, box_id)`. Nothing makes a box public key unique across workspaces | `0001`: `CREATE TABLE pins ... PRIMARY KEY (tenant_id, box_id)` |
| M6 | Agents are keyed by `(id, box)` since spec 061 (`<ID>@<box>`); the box id is unique per workspace only | `0102_agent_at_box_key.sql:1-20` |
| M7 | One box runs a desk sidecar for EVERY workspace that has a dir under `$SPL_STATE_DIR/desk/<workspace>/`, all under one OS user | `csi-spl-orc/src/bash/run/spl-desk-up-tenants.func.sh:1-30` |
| M8 | The box spool root is one dir, mode `2770`, group `spool-agents` with a default ACL `group::rwx`: every agent on the box reads and writes every mailbox | `getfacl /var/spool-hub` on the reviewer's box; `provision-spool-root.func.sh:4-6,64-74` |
| M9 | The fleet bridge copies a cross-machine DM into the shared spool root (`SPOOL_FLEET_ROOT`) | spec 058 O3 / N1 |
| M10 | The relay is ONE bucket per env with ONE service account holding `roles/storage.objectUser` on the whole bucket (get, list, create, delete) | `csi-spl-doc/doc/md/csi-spl.feature.md:174,192,199-200` |
| M11 | Join tokens (`spj1.<workspace>.<secret>`, single use, admin-minted, no root key) are designed but **Planned**, not built | `073-agent-join-tokens/spec.md:3` |
| M12 | With the view door off, a legacy workspace Host gives an ANONYMOUS read of that workspace | `internal/hub/resolve.go:62-74` |

## 3. The isolation threats, one by one

Each line: how another workspace could see this box's data, and what 108 must
say to close it. **MUST** = a blocker for my agreement; **SHOULD** = I agree
without it, but it goes in the spec as a known gap.

### 3.1 Shared OS users and dirs on a box (M7, M8, M9) - MUST

A box that holds desks of two workspaces has one OS user, one home, one spool
group. An agent of workspace A can `cat` workspace B's desk key under
`$SPL_STATE_DIR/desk/B/`, read B's inboxes, B's logs, B's worktrees and B's
transcripts, and post as B's box with B's key. No hub rule can repair that: the
key is the identity.

What 108 must say:

1. **One box, one workspace.** A box is enrolled into exactly one workspace. Its
   key, its spool root, its state dir and its OS users serve that workspace
   only. A second workspace on the same machine is a second box: a separate
   OS user (or container / VM), separate `$SPOOL_ROOT`, separate state dir,
   separate group, no shared ACL. The spec names the boundary as the OS user,
   not a dir name.
2. **The desk multiplexer of M7 is operator-only.** It stays legal only on a box
   of the operator workspace that the operator runs for workspaces that rent
   hosting (spec 006). The spec says so explicitly, and says that such hosted
   workspaces get NO isolation from the operator on that box. A box that a
   workspace admin enrols refuses a second workspace's desk (the join step
   checks that the state dir names one workspace only).
3. **The fleet bridge (M9) writes only into the receiving workspace's own spool
   root.** A DM from workspace A can never be relayed to a box of workspace B:
   the hub routes on the roster, and the roster is under row level security,
   so it does not resolve. The spec states this and names the test (5, T6).
4. **Box hygiene check**: a `do_check_box_isolation` style action that fails
   when the spool root, the state dir or the key file is readable by any user
   or group outside the box's workspace. Run at enrolment and by the box cron.

### 3.2 Box and agent identity, id collisions across workspaces (M5, M6) - MUST

`c-004@box-a` in workspace A and `c-004@box-a` in workspace B are two rows,
both legal, because every key carries `tenant_id`. That is fine inside the hub.
It breaks outside it:

- **The same box key pinned in two workspaces.** Nothing stops it (M5). Then one
  machine is a member of both and 3.1 applies. 108 must add a uniqueness rule:
  a box public key is pinned in at most one workspace, across the instance.
  A plain unique index on `pins(pubkey)` (live rows) works under RLS, because
  index checks are not filtered by policy. The refusal answers a generic
  `pin_conflict`, never the other workspace's id (no existence leak beyond
  "this key is taken", and an Ed25519 public key is not guessable).
- **Box id spoofing in the hello.** The hub must take the workspace from the
  pin it verified, never from `X-Spool-Tenant` alone. Today `X-Spool-Tenant`
  NAMES the workspace and the pin PROVES it (`resolve.go:15-20`). 108 keeps that
  and says: a hello whose header names A with a key pinned in B is refused,
  and the test proves it (T3).
- **Off-hub tools that key on a bare id or `<ID>@<box>`**: lane map, registry,
  spool-send relay, `orchestrator` resolution. Each must resolve inside the
  sender's workspace. The spec lists them and says the workspace is part of
  the address wherever two workspaces can meet (the hub), and implicit only
  where they cannot (a single-workspace box).
- **Fleet leases**: `fleet_leases` is keyed `(tenant_id, fleet, role)`, so each
  workspace has its own orchestrator and dispatcher. 108 must say a workspace
  admin's boxes never take a lease of another workspace, and that `orchestrator`
  in `spool-send.sh` resolves in the sender's workspace.

### 3.3 Hub routes that skip the workspace pin (M4, M12) - MUST

- Every box route takes its workspace from the authenticated WebSocket
  session (`x` in `box_*.go`), which got it from the pin. 108 must state that a
  frame never carries a workspace field the hub trusts.
- **The anonymous view door (M12)** must be OFF on every instance that has more
  than one workspace with a workspace-owned box. The spec makes the hub refuse
  to start with view door off and a non-lde env, or says why that already holds.
- **`asOperator` callers (M4)**: the list today is sweepers, payment/checkout,
  the operator workspace list, `ConsumerLag` and the repo-doc worker. None
  returns message bodies to a route. 108 must add NO new caller for boxes
  (enrolment, revoke, box list all run in `inTenant`), and the spec says the
  only operator-visible box data is counts and liveness (3.6).

### 3.4 Row level security without FORCE, and the operator GUC (M1, M2, M3) - MUST + SHOULD

- MUST: every new table 108 adds (box enrolment, revocation log, per-box
  quotas) carries `tenant_id`, ENABLE and FORCE, and both policies. M2 already
  fails the build otherwise; the spec names that test as the gate.
- MUST: the hub login is neither superuser nor BYPASSRLS, and owns no tenant
  table (the owner split of `spl-db-owner-split.func.sh`). `HubRoleCanLiftRLS`
  (`rls.go:200`) must answer empty on dev and prd; the spec makes a non-empty
  answer a refused start on prd, not a log line.
- SHOULD: the operator scope is a GUC (M3). Any SQL the hub login runs, a SQL
  injection included, can `SET app.rls_scope = 'operator'` and read every
  workspace. M4 guards the Go code, not the database. The stronger form is a
  separate database role for the operator paths, with `operator_scope` written
  `TO <operator_role>` instead of reading a GUC, so the tenant path physically
  cannot reach other workspaces' rows. I do not block 108 on it, but the spec
  must record it as the known residual risk.

### 3.5 Relay bucket, signed URLs and sidecar keys per workspace (M10) - MUST

One bucket, one service account with list + get + delete on every object. If
that key reaches a box of a workspace (the box needs it to sign a PUT), that
box can list every workspace's object names, download their ciphertext and
delete them. gpg protects the content, not the names, sizes, timing, or
availability.

What 108 must say:

1. **No relay service-account key on a workspace-owned box. Ever.** The box asks
   the hub for a signed URL; the hub signs it, scoped to one object under the
   workspace's prefix `<workspace>/<box>/...`, short-lived, single-use PUT
   (`x-goog-if-generation-match: 0`). The box holds only its own Ed25519 key.
2. If a key on the box cannot be avoided: one service account per workspace
   with an IAM condition on the object-name prefix `<workspace>/`, no list
   permission. The spec picks one of the two; I prefer (1).
3. The gpg recipient is the workspace's key, not an instance-wide key, so a
   leaked object of A is unreadable with B's key.
4. The desk sidecar's key is the box's own key (one per box, minted on the box,
   never copied). Spec 058's "copy the desk key" move must become "revoke the
   old pin, enrol the new box" for workspace-owned boxes.

### 3.6 What the operator workspace may still see, and why - MUST be explicit

The operator needs: that the box exists, which workspace it belongs to, last
hello / beat time, agent count, message volume per day (billing, spec 006),
and the retention sweeps. The operator must NOT see from the hub: message
bodies, file contents, box roster names beyond counts, keys. The spec writes
that as a two-column table (sees / never sees) and ties every "sees" row to an
`asOperator` caller already listed in M4 or a new one with its reason.

And it says the honest part: the operator runs the hub and the database, so a
malicious operator can read everything; 108 protects workspaces from EACH OTHER
and from an operator-workspace member who is not the infra owner, not from the
infra owner. Act-as (spec 054) stays inside one workspace.

### 3.7 Revoke that leaves keys alive - MUST

Revoke and remove must kill every credential the box holds, in one action, in
this order, with a check after each:

1. Pin revoked (`pins.revoked_at`), live WebSocket session closed, reconnect
   refused (spec 073 US3 already promises this for a seat).
2. Every unexpired join token minted for that box revoked.
3. Every signed URL the hub issued for that box is short enough to expire
   unused (state the maximum TTL), or the hub refuses the object on arrival
   from a revoked box.
4. Queued deliveries to the box's agents are held, not dropped, until the
   admin chooses keep or purge; the spec says which.
5. Roster rows of `<ID>@<box>` marked gone, fleet leases held by them freed.
6. The box-side purge (`box-purge` already exists in orc tests) removes the
   key file and spool root on the box. It is advisory: the hub-side steps
   1-5 are what make the revoke true even when the box is stolen or offline.

A workspace admin can revoke only their own workspace's boxes (`keys.manage`
inside `inTenant`); the operator can suspend a whole workspace (spec 074).

### 3.8 Enrolment by a workspace admin, no operator step (M11) - MUST

Enrolment is spec 073's join token: the admin mints `spj1.<workspace>.<secret>`
in their own workspace, the box redeems it once, the pin is written in the
same transaction. 108 must build ON 073 and say 073 is a prerequisite that is
still Planned. Additions for 108:

- the redeem step also checks the pin uniqueness of 3.2;
- the box id is bound at mint time (no free-text box id from the redeemer), so
  a stolen token cannot pick a name that collides inside the workspace;
- per-workspace caps (boxes, agents) are cnf with an operator default, checked
  at redeem, so one workspace cannot exhaust the hub.

## 4. Tests that prove isolation (each with its control)

A cross-workspace read that answers 0 rows proves nothing alone: it also
answers 0 when the seed failed. Every isolation test below is a PAIR, run on
Postgres (not the memory store), in one test function, with the same query:

| # | Probe (must be refused / 0) | Control (must succeed / > 0) |
|---|---|---|
| T1 | workspace B's scope reads A's box messages: 0 rows | A's scope, same query: >= 1 row (the seeded one) |
| T2 | a statement with no scope reads `messages`: 0 rows | the same table under `asOperator`: >= the seeded count |
| T3 | hello naming A with a key pinned in B: refused | the same key naming B: accepted |
| T4 | pin A's box key into B: `pin_conflict` | pin a fresh key into B: ok |
| T5 | revoked box reconnects: refused, and its old signed PUT is refused | a sibling box of the same workspace: still connected |
| T6 | spool-send from an A agent to a B agent id: unknown agent | the same send to an A agent: delivered |
| T7 | relay: a URL signed for `<A>/<box>/x` used on `<B>/...`: 403; listing: 403 | the same URL on its own object: 200, sha256 matches |
| T8 | box hygiene: a file under the spool root readable by an outside user: check fails | a correctly provisioned root: check passes |
| T9 | every new 108 table: ENABLE + FORCE (existing M2 test) | M2's own control (it already fails on a planted unforced table) |

Each test states its n (rows seeded) so a reader sees "0 of n" versus "0 of 0".

## 5. Points I want answered in the spec (owner questions if the author cannot)

1. **Is a second workspace on one physical machine allowed** (as a second box,
   second OS user), or is it one machine per workspace? I accept either; the
   spec must pick.
2. **Does the operator-hosted multi-workspace desk (M7) stay**, and do the
   workspaces it hosts accept that they are not isolated from the operator on
   that box? (A yes/no for the owner.)
3. **Relay key on the box**: (1) hub-signed per-object URLs, no key on the box,
   or (2) per-workspace service account with a prefix condition?
4. **Queued messages at revoke**: held for the admin, or purged with the box?

## 6. Comparison with the author's draft (round 1, spec sha `88d4005ff`)

The draft has the right shape (enrol, identity, enforce, keys, operator,
revoke, tests), and its isolation + control test pair is the right instinct.
It does not yet hold against the code that exists. Point by point:

| # | Draft says | Code / my view | Ask |
|---|---|---|---|
| D1 | 3.3, 5.1, 5.3: add `workspace_id` to `boxes` and `agents`, pin `spool.workspace_id` | Already built under other names: `boxes`, `pins`, `roster` carry `tenant_id` (rdb 0001); the GUC is `app.tenant_id`, set by `inTenant` (`rls.go:18`); there is no `agents` table (agents are `roster` rows). Phases 1 and 3 as written would rewrite working RLS | Rewrite 3.3 and phases 1, 3 against `0014_tenant_rls.sql` and `rls.go`; 108 adds only what is missing |
| D2 | 4: "run the query as Workspace B's DB role" | There is no per-workspace DB role: one hub login, scope by GUC. The test is "B's `inTenant` scope" vs "A's" | Restate T1/T2 in section 4 of this file |
| D3 | 3.5: "RLS explicitly excludes operator DB roles from reading tenant message rows" | False today: `operator_scope` grants EVERY row when `app.rls_scope = 'operator'` (0014:42-44), and the hub login can set it (M3) | Say what really holds (3.6 here), name the residual risk, and the operator-role option (3.4) |
| D4 | 3.1, 3.4: the HUB issues a long-lived relay/sidecar keypair to the box | The hub must never hold a box private key. Today the box mints its Ed25519 key and the hub pins the public half (`pins`). Enrolment is spec 073's join token, already designed | Box mints its key; 108 builds on 073 and states 073 (Planned) is a prerequisite |
| D5 | (absent) the relay bucket | One bucket, one SA with list/get/delete on all objects (M10). Whoever holds that key on a box sees every workspace's objects | Add 3.5 of this file: hub-signed per-object URLs, no relay SA key on a workspace box |
| D6 | (absent) isolation ON the box | Today one box runs desks of several workspaces under one OS user and one shared spool group (M7, M8). The owner's first goal, "not see his data on the boxes", fails there regardless of the hub | Add 3.1 of this file: one box = one workspace = its own OS user, spool root, state dir; the multi-workspace desk is operator-only, and says so |
| D7 | 3.2: box id "scoped globally" | Box id is unique per workspace only (`PRIMARY KEY (tenant_id, box_id)`); what must be global is the box PUBLIC KEY (M5, nothing enforces it) | Unique live `pins(pubkey)`, `pin_conflict` without naming the other workspace |
| D8 | 3.6: revoke "deletes the key pair" | Revoke = `pins.revoked_at` + close the live session + refuse reconnect + revoke its join tokens + bound signed-URL TTL + free its leases (3.7 here). Deleting the row loses the audit and the pin history | Replace with the ordered list in 3.7 |
| D9 | 4: three tests | Missing: header-vs-pin mismatch (T3), key in two workspaces (T4), revoked reconnect (T5), cross-workspace spool-send (T6), relay URL scope (T7), box hygiene (T8), the n per test | Adopt the table in section 4 |
| D10 | Owner Q2: box names globally unique? | Not an owner question: the code already answers per workspace; the key is what must be unique (D7) | Drop it |
| D11 | Owner Q1: remote wipe before severing? | Fine as an owner question, but the revoke must be TRUE hub-side without it (a stolen or offline box never runs the wipe) | Keep, reworded: "the hub-side revoke is complete without the box; do you also want an advisory wipe?" |

Owner questions I would add: section 5 items 1 to 4 of this file.

### 6.2 Round 2, spec sha `bc550d488`

Folded and agreed: D1 (existing `tenant_id` + `app.tenant_id` RLS, `roster`,
one runtime role), D2, D3 (3.6 now states the operator GUC truthfully), D4
(the box mints its key, 073 join token), D5 (no relay SA key on a box,
hub-signed per-object URLs under `<tenant_id>/`), D8 (revoke list), D10, D11.

Still open. **R1 to R4 block my agreement**; R5 to R7 I accept as one-line edits:

| # | Spec text at `bc550d488` | Problem | Ask |
|---|---|---|---|
| R1 | 3.2 "the box identifier is scoped globally"; "the public key is globally unique" | The box id is unique per workspace (`PRIMARY KEY (tenant_id, box_id)`), so "globally" contradicts the schema. The key-uniqueness rule has no mechanism | "Box id unique within its workspace. A live box public key is pinned in at most one workspace: unique index on live `pins(pubkey)`; a conflict answers `pin_conflict` without naming the other workspace" |
| R2 | 3.3 / 3.7 / phase 2 do not say where a box's workspace comes from | A hello whose `X-Spool-Tenant` names A, signed with a key pinned in B, must be refused. Today the header names and the pin proves (`internal/hub/resolve.go:15-20`); the spec must keep that as a rule. Phase 2 ("set `app.tenant_id`") is already built (`inTenant`) | One sentence in 3.3: "the workspace is the one the verified pin belongs to; the header only names it, and a mismatch is refused". Phase 2 becomes "no change; tests only" |
| R3 | 4: three tests, EACCES with no control | A zero or refused result proves nothing without its control and its n | Each test is a pair with n: (a) B scope 0 of n / A scope n of n; (b) hello A-header + B-key refused / B-header + B-key accepted; (c) same key pinned into B `pin_conflict` / fresh key ok; (d) revoked box reconnect refused / sibling box still connected; (e) spool-send A agent -> B agent unknown / A -> A delivered; (f) URL signed for `<A>/...` used on `<B>/...` 403 / on its own object 200; (g) EACCES on B's spool root / A's own root readable |
| R4 | 7: "None remaining" | Three choices are not made: 3.5 says "one box = one workspace (or per-workspace OS user)", which is two designs; the existing multi-workspace desk (`spl-desk-up-tenants.func.sh` runs desks of every workspace under one OS user) is not mentioned; queued deliveries at revoke are not decided | Either decide each in the spec or list them as owner questions: (1) a second workspace on one machine = a second OS user + spool root, yes or no; (2) the multi-workspace desk stays operator-only, and the workspaces it hosts are not isolated from the operator on that box; (3) at revoke, queued deliveries are held for the admin or purged |
| R5 | 3.6 | The hub login must be neither superuser nor BYPASSRLS, and must own no tenant table | Cite `HubRoleCanLiftRLS` (`rls.go`) answering empty as the prd start gate |
| R6 | (absent) | The anonymous view door (`resolve.go:62-74`) reads a workspace with no session | "View door off is refused outside lde" |
| R7 | 3.1 | Spec 073 is Planned, not built | Name 073 as a prerequisite in section 5, phase 1 |

## 7. Status

Round 2 of 3 sent to the author. **Points still open at spec sha
`bc550d488`**: R1 to R4 (blocking), R5 to R7 (one-line edits). Consensus
follows when R1 to R4 are in the spec.
