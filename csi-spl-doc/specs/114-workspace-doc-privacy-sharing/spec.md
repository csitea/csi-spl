# Spec 114: Workspace documents are private; sharing is a deliberate grant

Version **v0.2** (2026-10-09), the review panel folded in by c-719 (claude)
on v0.1 (seat 1, c-711, b65209947). Every finding of the four seats is
applied or rejected, each with one line why, in section 7. The
recommendation stays model (a); the panel's write-side findings are now part
of the grant file and of the proof (P8-P14, controls C3-C11), re-run green:
**55 PASS, 11 of 11 controls caught** (section 3.4).

v0.1 replaced the draft at c2a713420 completely (its SQL did not parse).
Every SQL statement this spec relies on lives in [bench/](bench/) and ran in
a throwaway `postgres:16-alpine`; the spec quotes it, never retypes it. Build
tasks: [tasks.md](tasks.md).

Builds on [spec 113](../113-workspace-docs-qto/spec.md) v1.0 (the document
tables, live as rdb `0157_workspace_docs.sql`). It does not change 113's
files.

## 0. Owner asks (verbatim, HUM-10, t1 topic d85e7d3c-d584-4114-9bb6-7496de8ee8e0)

| msg | text |
|---|---|
| 9a7166b0 | "We must ensure that each workspace/tenant has its own QTO documents, so use some kind of naming convention for the table names or something. They should not be intermixed. They can be shared, yes, but they should not be intermixed by default. The workspace QTO docs should be private to each workspace." |
| 33a5564d | "I really don't know what the technical solution is for how to achieve that. For now, we don't have separate databases for the different workspaces, but that might come into question, or separate schemas at least. I don't know yet. Actually, collect a panel of agents to discuss how to implement that requirement to be able to have completely private QTO documents in the workspaces, but with the capability to share them." |

What they ask for:

- **Private by default.** A workspace's documents are invisible to every
  other workspace until someone acts.
- **Shareable on purpose.** One explicit act shares one document; nothing
  shares by default.
- **The mechanism is open.** The owner asks to not intermix them by default
  ("use some kind of naming convention... separate databases... or separate
  schemas"), but also asks for a panel to discuss the technical solution.
  Section 3 compares physical separation (schemas, databases) against logical
  separation (shared tables + RLS) with numbers.

## 1. Goals and terms

- **"They should not be intermixed"** (msg 9a7166b0) is a goal of its own,
  next to privacy: a workspace's own document list and search show only its
  own documents. A document shared with it appears in a separate, labelled
  list (section 4.4), never in the own list. Today's store would mix them the
  day the share policies land (P10, control C10): tasks.md T002a fixes that
  first.
- **Workspace = tenant** (rdb 0126's naming; spec 113 section 2.2): every
  document row carries `tenant_id`, the workspace id.
- **"Completely private"** (section 3.1 makes it testable): a session scoped
  to workspace X cannot read, write, lock or reference a document row of
  workspace Y unless a live grant names X and X has accepted it. The DB
  enforces it, not only the hub, and a test with a control proves it.
- **Share** = one grant: one document, one receiving workspace, `read` or
  `edit`, accepted by the receiver, revocable by the owner.
- Out of scope: per-member access inside one workspace (every member of a
  workspace sees its documents, as today), public links, copying a document
  between workspaces.

## 2. The measurement

### 2.1 What ran

[bench/isolation-bench.sh](bench/isolation-bench.sh) starts ONE throwaway
`postgres:16-alpine` (16.15) with `max_connections=25`, as on Cloud SQL
db-f1-micro, and runs everything as a **non-superuser role that owns the
tables**, so FORCE RLS binds it as it binds the hub's owner login. No cloud
env is touched.

```text
BENCH_N="6 100" BENCH_REPS=5 bash csi-spl-doc/specs/114-workspace-doc-privacy-sharing/bench/isolation-bench.sh
```

Raw output of the v0.2 run: [bench/raw-2026-10-09-v02.txt](bench/raw-2026-10-09-v02.txt)
(`uptime` before and after it: load average 14.26 at 20:55:55Z, 12.73 at
20:58:20Z; 16 CPUs). The v0.1 run (load 4.90) stays as
[bench/raw-2026-10-09.txt](bench/raw-2026-10-09.txt), and c-715 re-ran v0.1
at load 7.61; every ranking below reproduced in all three runs, and the
relation, byte and connection counts match exactly. n = 5 per timed migration
and query (median). As in spec 113 section 2.1, differences under 2 ms are
not ranked on this box; only the 10-100x gaps carry the decision.

**Wall times include the client.** Every timed step is a `docker exec ..
psql` process start: a no-op `SELECT 1` costs 95 ms wall here (M5, raw line
70; c-715 measured 57-124 ms). So the M1-M3 wall times are mostly client
start-up for small steps; M5 times the same ALTER fan-out inside Postgres.

| id | measures | per model |
|---|---|---|
| P1-P14 | the model (a) privacy + sharing proof, 55 checks ([share-proof.sql](bench/share-proof.sql)) | (a) |
| C1-C11 | eleven controls that break it on purpose ([share-control.sql](bench/share-control.sql)) | (a) |
| M1-M3 | create the 0157 tables for n workspaces; one ALTER fanned out to all of them (wall); relations, bytes; connections | (a), (b), (c) |
| M4 | read cost of the share policies at 100 workspaces x 1 doc x 1,111 items (111,100 rows) | (a) |
| M5 | the client cost alone (`exec_noop_ms`), and the ALTER fan-out timed server-side (`clock_timestamp`, a COMMIT per statement as a migration run does) | (a), (b) |

### 2.2 Live facts (read 2026-10-09, operator scope, read-only)

Command, per env:

```text
cd csi-spl-orc && ENV=<env> SQL="select (select count(*) from tenants) as tenants, (select count(*) from workspace_doc) as docs, current_setting('max_connections') as max_conn, current_setting('superuser_reserved_connections') as su_res, pg_size_pretty(pg_database_size(current_database())) as db_size, (select count(*) from pg_stat_activity) as backends, (select count(*) from pg_database where not datistemplate) as dbs" ./run -a do_spl_db_query
```

| env | tenants | docs | max_connections | reserved | DB size | backends | databases |
|---|---|---|---|---|---|---|---|
| dev | 25 | 0 | 25 | 3 | 108 MB | 14 | 3 |
| prd | 13 | 4 | 25 | 3 | 194 MB | 17 | 3 |

- prd: 12 of the 13 tenant ids are not test-shaped (`tenant_id !~
  '^(e2e|test|probe)'`). The brief counts 6 workspaces; which of the 12 are
  in use was not measured. This spec sizes for **6 and 100**.
- Tier: `db-f1-micro` (`csi-spl-cnf/csi-spl/all.env.yaml` line 179). Of the
  25 connections, 3 are superuser-reserved and 2 held by `cloudsqladmin`, so
  20 are usable; the hub pool is 8 per instance, min 2
  (`SPOOL_HUB_DB_MAX_CONNS`, `SPOOL_HUB_DB_MIN_CONNS`, same file, comment at
  line 361).
- Cloud SQL limits (Google's docs, fetched 2026-10-09):
  `docs.cloud.google.com/sql/docs/postgres/quotas`: "You can have up to 1000
  instances per project" (new network architecture); no per-instance limit
  on databases or schemas is stated. `.../postgres/flags`, default
  `max_connections` by memory: tiny (~0.5 GB) 25, small (~1.7 GB) 50, 3.75 to
  < 6 GB 100, 6 to < 7.5 GB 200, 7.5 to < 15 GB 400.
- Cost: list-price estimate, not an invoice (the env SAs cannot read
  billing): Cloud SQL db-f1-micro + 10 GB SSD + backups ~$10-11 / env / month
  of ~$60-65 total, marginal tenant ~$0; Secret Manager $0.06 per active
  secret / month
  ([spec 047 deployability-analysis.md section 4.2](../047-spool-deployability/deployability-analysis.md)).

## 3. Isolation models

### 3.1 What "completely private" means, as a test

A model is private when all of these hold, each as an automated check with
a control that turns it red:

1. **Read**: a session of workspace X reads 0 rows of workspace Y's
   documents, items and revision log.
2. **Write**: X's UPDATE / DELETE of Y's rows hits 0 rows; X's INSERT tagged
   with Y is refused.
3. **Reference**: X cannot create a row that points at Y's document. FK
   checks bypass RLS (spec 113 seat 5#2, measured), so this is its own check.
4. **Fail closed**: no scope set = 0 rows.
5. **One bypass**: the operator scope, used only by allow-listed callers
   (`TestOperatorScopeCallers`).
6. **Control**: the same checks run against a deliberately weakened model
   and must fail.

### 3.2 The models side by side

| | (a) shared tables + `tenant_id` + FORCE RLS (today) | (b) a Postgres schema per workspace | (c) a database per workspace | (d) = (a) + a per-workspace encryption key |
|---|---|---|---|---|
| **The boundary** | row policy `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')`, ENABLE + FORCE (0157) | `ws_<n>.workspace_doc` etc.; a role per workspace with USAGE on its schema only, or a qualified name in every query | a connection string per workspace | (a), plus document text encrypted with the workspace's key |
| **Private, proven by** | P1-P14 + C1-C11 (section 3.4): **measured green**, 55 PASS, all 11 controls caught | per-workspace role + `SET ROLE` per request; a cross-schema SELECT must be refused (42501). Not built in this bench | a different DSN; cross-database SQL does not exist in Postgres without `dblink` / `postgres_fdw` | (a)'s proof, plus: a dump read without the key shows no text |
| **Create, n = 6** (wall; raw v02 lines 71-75) | 280 ms once | 710 ms | 2,838 ms | as (a) |
| **Create, n = 100** (raw v02 lines 76-80) | 196 ms once (independent of n) | 5,511 ms | 40,669 ms | as (a) |
| **One ALTER, all workspaces, n = 100** | 111 ms wall (one psql call; ~95 ms of it is docker exec + psql start, M5); server-side **4.1 ms** (raw v02 line 78; c-715: 18.9 ms at a far higher box load) | 345 ms wall, **245.9 ms** server-side (200 statements; c-715: 259.5 ms) | 11,508 ms wall = 100 psql starts (~100 ms each); the per-database cost is a connection + a migrate run | as (a) |
| **Catalogue, n = 100** | 16 relations | 1,000 relations | 100 databases, 797 MB empty (7.97 MB each) | as (a) |
| **Connections, n = 100** | the pool of 8 | the pool of 8 | 22 of 100 one-connection-per-database sessions got in, 78 refused (`max_connections` 25 minus 3 reserved); on Cloud SQL 20 are usable | the pool of 8 |
| **Migrations** | `Migrate` applies each file once and records it in `spool_schema_migrations` (`internal/store/migrate.go`; line 58 is the table's CREATE) | every file once PER schema, a new workspace replays them all; `/version` `schema_head` per schema. 0157's trigger functions name tables without a schema (`grep -c 'FROM workspace_doc' 0157_workspace_docs.sql` -> 7), so each copy must pin `SET search_path` or it resolves the CALLER's schema (**measured**: both 0157 trigger functions created in `ws_1` carry no `proconfig`, M2 `ws_1_fns_without_search_path=2`) | every file once PER database; a half-done fan-out leaves workspaces on different heads | as (a); a key rotation re-encrypts every body |
| **Backups** | one export (`do_spl_db_backup`, wf 45) holds all; restoring ONE workspace = `do_spl_db_restore` into a scratch database (target `database:<name>`, exists), then an operator-scope copy of that workspace's rows (**no such action yet**, tasks T005); grants whose `to_tenant` is missing in the target fail the FK | one export holds all; one workspace = `pg_restore -n ws_<n>` | Cloud SQL export is per `--database` (`spl-db-backup.func.sh` line 100): 100 exports + 100 verifies a day | as (a); a stolen export shows no document text |
| **Operator workspace** | `app.rls_scope = 'operator'`, one query | a generated `UNION ALL` over n schemas | n connections, more than the pool at 100 | as (a), plus the operator needs every key to read text |
| **Search across a workspace's docs + its shares** | one query; under FORCE RLS no GIN index serves `@@` (rdb `0135` search_sig exists for that reason) | n schemas = n queries or a generated union | n connections; at 100 not possible in one request | SQL search, grid sort/filter on `body` and 0157's `length(body)` CHECK stop working on ciphertext |
| **Sharing one document** (section 4) | a grant row the policies consult: **measured** | schema GRANTs are per TABLE, so one document needs RLS inside the schema (= (a)'s mechanism again) or a copy into the receiver's schema (a fork: edits diverge, a revoke cannot recall it) | the hub reads the owner's database for the receiver after checking a grant in a central database: enforced by the hub, not the DB; or a copy | as (a); the hub decrypts with the OWNER's key for the receiver |
| **Cost at 6** | $0 extra | $0 extra | $0 extra on one instance | +$0.36 / env / month (6 secrets) |
| **Cost at 100** | $0 extra; one instance, 16 relations | $0 extra; 1,000 relations | one instance: 797 MB of the 10 GB disk, but pools of min 2 x 100 = 200 connections need `max_connections` >= 200, a 6-7.5 GB tier (flags table); or 100 instances x ~$10 = ~$1,000 / env / month (047 estimate, under the 1,000-instance quota) | +$6 / env / month (100 secrets) |

Create rows: (a) includes share-grant.sql, (b) and (c) do not; (c) also
includes 100 `CREATE DATABASE` calls. Wall times include ~95 ms of docker
exec + psql start per call (M5).

### 3.3 Reading of the table

- (b) and (c) **do not remove the need for RLS** once a single document can
  be shared: schema and database boundaries are all-or-nothing. They add a
  second mechanism next to it.
- (b) costs one to two orders of magnitude more server-side migration time
  at 100 (245.9 vs 4.1 ms here at load ~14; c-715 read 259.5 vs 18.9 ms,
  ~14x, at a far higher load; 345 vs 111 ms wall incl. client start). The
  (a) side is a few ms and swings with box load; the (b) side grows with n
  and (a) does not. It also has 62x the relations, and moves the boundary
  from a DB-enforced row policy to "every query names the right schema or
  role", which a typo breaks silently unless the per-workspace role is used,
  and then every request pays a `SET ROLE`.
- (c) fails on today's tier outright at 100 workspaces (78 of 100 refused,
  measured) and needs 100 migrate runs instead of 1.
- (d) is the only model that protects against a reader of a **backup or an
  operator psql session**. It costs search and sort over document text. It
  is an add-on to (a), not an alternative: keep it as a later option.

### 3.4 The model (a) proof, measured

[share-proof.sql](bench/share-proof.sql) on top of 0157 and
[share-grant.sql](bench/share-grant.sql), as the owning non-superuser role
(raw v02 lines 3-57: 55 PASS; controls lines 58-68; `SUMMARY pass=55
controls_caught=11 of 11`, line 69):

| check | what it shows | control |
|---|---|---|
| P1 | private by default: b sees 0 of a's docs and items, 1 of its own | C1 |
| P2 | b cannot grant itself a's doc: refused 23503 (FK carries the owner tenant) and 42501 (RLS) | C1 |
| P3 | after a's read grant (accepted), b sees A1 (1 doc, 2 items) and the grant row; still 0 of A2; c sees nothing; a cannot share with itself (23514) | C1 |
| P4 | read is read: b's UPDATE and DELETE hit 0 rows; b cannot re-share (42501) or revoke a grant it received (23514) | C1 |
| P5 | revoke: stamps `revoked_at` once; a second revoke or an in-place access change is refused (23514); b sees 0 items after, and still sees the revoked grant (audit) | C2 |
| P6 | edit grant: b adds an item to A1 under the doc lock, the 0157 tree trigger and the hub's own bump; rows keep tenant a; b cannot tag a row with b (23503), delete the doc (0 rows), or write into unshared A2 (42501) | C1 |
| P7 | no scope = 0 docs, 0 grants; operator sees all 3 docs and 2 grants | C7 |
| P8 | the header's columns: a receiver cannot forge `created_by`, jump `rev` or re-tag `tenant_id` (23514); a title change with a +1 bump lands; the owner cannot rewrite `created_at` either | C3 |
| P9 | the rev log: a receiver's entry under an owner actor is refused (42501); a pre-filled next or far rev slot is refused at commit (23514); the owner's next bump still lands | C4, C5 |
| P10 | the own list (the hub's `wsDocHeadSQL` WITH an explicit tenant filter) shows only b's own doc while a grant is live; the shared list shows the shared one | C10 |
| P11 | consent: a pending grant shows b the grant row and 0 docs, 0 items; only the receiver can accept (owner refused 23514), once | C6 |
| P12 | the policy set of the four tables equals the pinned set; the RESTRICTIVE fence keeps a later `USING (true)` policy at 0 rows for no scope | C7, C8 |
| P13 | history bound: a receiver sees 0 rev entries written before its grant, and the 3 written since | C9 |
| P14 | revoke closes the write side at the next statement: b's bump and item update hit 0 rows, b's item and rev-log inserts are refused (42501) | C11 |

| control | what it breaks | result (raw v02) |
|---|---|---|
| C1 | `NO FORCE ROW LEVEL SECURITY` on items | c reads 4 of a's items: **caught** |
| C2 | `share_read` without `revoked_at IS NULL` | b reads 3 revoked items: **caught** |
| C3 | drop the column trigger | b forged `created_by` and `rev` of A1: **caught** |
| C4 | drop the reached trigger | b pre-filled rev 1000000 of A1: **caught** |
| C5 | rev-log `share_edit` without the actor term | b wrote a rev entry as `owner-admin@a`: **caught** |
| C6 | `share_read` without `accepted_at` | b reads 3 items of a pending grant: **caught** |
| C7 | drop the fence, add a `USING (true)` policy | no scope reads 5 items: **caught** |
| C8 | add a `USING (true)` policy, fence kept | the pin differs: **caught** |
| C9 | rev-log `share_read` without the `granted_at` bound | b reads 1 pre-share rev entry: **caught** |
| C10 | today's store list query, no tenant filter | b's own list shows 2 docs, owns 1: **caught** |
| C11 | item `share_edit` without `revoked_at` | b added an item after the revoke: **caught** |

M4 (raw v02 lines 81-86), 100 workspaces x 1,111 items, w1 holding 5
accepted read grants: reading one document's items is a Bitmap Heap Scan with
and without the share policies (own 1.08 ms with vs 0.95 ms without, a
shared one 1.12 ms); listing the visible documents 0.24 vs 0.17 ms. Both gaps
are under the 2 ms noise floor, and the plan does not change at this size:
the grant lookup is an `ARRAY(..)` sub-select, computed once per statement.
The rev-log `share_read` is an `EXISTS` per row (it needs the grant's
`granted_at`); the rev log is read per document, not listed, and was not
timed.

## 4. Sharing, never the default

### 4.1 The grant

One table, [share-grant.sql](bench/share-grant.sql) (bench input, not a
migration):

- `workspace_doc_share (id, tenant_id, doc_id, to_tenant, access,
  granted_by, granted_at, accepted_by, accepted_at, revoked_by,
  revoked_at)`. `tenant_id` is the OWNING workspace and is named `tenant_id`
  on purpose: the RLS catalogue gate finds tenant tables by that column name
  (`internal/store/rls_test.go` line 80), so a `from_tenant` column would
  slip past it.
- FK `(tenant_id, doc_id)` -> `workspace_doc (tenant_id, id)`: a grant can
  only name the owner's own document (P2).
- `access` is `read` or `edit`. CHECK `to_tenant <> tenant_id`. At most one
  live grant per (doc, receiver) (partial UNIQUE).
- **Never default**: no trigger, no hub default, no workspace setting
  creates a row. Only an explicit grant call by the owning workspace inserts
  one; the RLS `WITH CHECK` refuses any other workspace (P2, P4).
- **Consent**: `accepted_at`, `accepted_by` (a pair, both or neither). The
  RECEIVING workspace accepts a grant; it is the receiver's only write on the
  row (policy `share_accept` FOR UPDATE on `to_tenant` = its scope, and the
  revoke-only trigger allows the receiver that one stamp, once). Every share
  policy requires `accepted_at IS NOT NULL`, so a pending grant opens nothing
  (P11). The receiver's pending list shows the owning workspace, `read` or
  `edit`, who granted and when; the title shows after accepting, because
  reading it would need a policy on the owner's header before consent.
- **No workspace-existence oracle**: the FK on `to_tenant` answers 23503 for
  a workspace id that does not exist. The grant call maps that, and a
  receiver that refuses shares, to one and the same answer, so the call
  cannot probe which workspace ids exist (tasks T003).

### 4.2 What the policies add

0157's `tenant_scope` and `operator_scope` stay exactly as they are. One
RESTRICTIVE policy per document table fences every permissive one, verbatim
from the bench file:

```sql
CREATE POLICY scope_fence ON workspace_doc_item AS RESTRICTIVE
    USING (current_setting('app.rls_scope', true) = 'operator'
           OR NULLIF(current_setting('app.tenant_id', true), '') IS NOT NULL);
```

A store test pins the exact `(tablename, policyname, permissive, cmd)` set of
the four tables from `pg_policies` (the bench's `bench_policy_pinned()`,
P12); a new policy fails it until the test is changed in the same commit.

The migration ADDS permissive policies (OR-ed with the existing ones), verbatim
from the bench file:

```sql
CREATE POLICY share_read ON workspace_doc_item FOR SELECT
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.accepted_at IS NOT NULL AND s.revoked_at IS NULL)));
```

- `share_read` (SELECT) on `workspace_doc`, `workspace_doc_item`; on
  `workspace_doc_rev_log` only entries with `created_at >= s.granted_at` of
  the live grant, so a share does not disclose who worked on the document
  before it was shared (P13).
- `share_edit` for `edit` grants: UPDATE on `workspace_doc` (the rev bump
  and the `FOR UPDATE` lock every op and the 0157 tree trigger take), limited
  by a BEFORE UPDATE trigger `workspace_doc_share_edit_cols`: `id`,
  `tenant_id`, `created_by`, `created_at` never change for anyone, and a
  receiver (a scope other than the row's tenant) moves `rev` by exactly +1,
  so `title` and `updated_at` are all else it can touch (refused 23514). RLS
  cannot restrict columns, so the trigger is the boundary (P8). The hub's
  only UPDATE of `workspace_doc` is that +1 bump
  (`internal/store/workspace_docs.go` line 192), so the trigger costs the
  hub nothing.
- `share_edit`: all commands on `workspace_doc_item`. No DELETE of the
  document itself (P6).
- `share_edit`: INSERT on `workspace_doc_rev_log` only for a rev the
  document has reached and only under the receiver's own actor: the policy's
  WITH CHECK requires `actor` to end in `'@' || <its scope>`, and a
  DEFERRABLE INITIALLY DEFERRED constraint trigger `workspace_doc_rev_log_reached`
  refuses (23514) any entry whose `rev` exceeds `workspace_doc.rev` at
  commit. With the +1 rule nobody can pre-fill a future slot and freeze the
  owner's next bump (P9). (A plain policy term `rev = (SELECT d.rev ...)`
  does not work: inside the hub's bump CTE the INSERT's check sees the
  pre-UPDATE snapshot.)
- On `workspace_doc_share`: the owner reads and writes its grants; the
  receiver reads the ones naming it and may accept them; operator scope as
  0157.

### 4.3 Revocation

- `UPDATE .. SET revoked_at, revoked_by` once; a trigger refuses any other
  change and a second revoke (P5). Changing `read` to `edit` = revoke + a new
  grant, so history is never rewritten.
- Effect: the next statement, read side (P5) and write side (P14). Policies
  read the live grant per statement, so no cache to flush in the DB.
- The hub pushes a "doc gone" event to the receiver's open views, and a
  revoke bumps the receiver's doc-list change stamp so no 304 answers for a
  revoked doc. Open views and edit sessions close with the notice "This
  document is no longer shared with you." Edits a receiver made (including
  item deletes) stay; the rev log names them, and Q3 decides whether `edit`
  may delete items at all.
- What the receiver already read or exported is not recalled (no model can).

### 4.4 What the receiving side sees

- A **"Shared with this workspace"** list: the document's title, the owning
  workspace's display name, `read` or `edit`, and when it was granted. This
  list is separate from the receiver's own documents and labelled as shared;
  the receiver's own document list shows only documents it owns, never shared
  ones (P10).
- Pending grants: a separate "Waiting for you to accept" list (section 4.1),
  with accept for the receiving workspace's admins.
- `read`: the outline and grid views read-only. `edit`: the same edits as
  the owner, except delete the document and share it on.
- The receiver's search includes documents shared with it, each labelled
  with the owning workspace, in a separate section of the results.
- After a revoke the document disappears from the "Shared with this
  workspace" list and open views close with the notice above (4.3); the
  revoked grant stays visible to both sides as history (P5).

### 4.5 Audit trail

- The grant table is the share audit: who granted, when, what access; who
  accepted, when; who revoked, when. The runtime login gets SELECT, INSERT,
  UPDATE on it, no DELETE: `runtime-grants.sql` gains `REVOKE DELETE ON
  workspace_doc_share FROM :"runtime_role";`, because its default privileges
  grant DELETE on every new table (`spool-hub-roles/runtime-grants.sql` line
  34; the rev log precedent is line 32). The cascade from a doc or tenant
  delete runs as the table owner, so it still works.
- Edits by the receiver land in `workspace_doc_rev_log` (spec 113 D-Q1) with
  `actor` = `<member>@<workspace>`, so the owner sees who changed what. The
  actor's `@<workspace>` suffix is enforced by the policy (P9), not trusted
  from the hub.
- Reads by the receiver are not logged (no per-read write on an f1-micro).
  An optional read log was proposed (m-717 #3) and is not part of this spec
  (section 7.1).

## 5. Recommendation

**Model (a): keep shared tables + `tenant_id` + FORCE RLS, and add one grant
table with permissive share policies, a RESTRICTIVE fence, and the write-side
triggers.** Why, in three lines:

1. It is the only model where the DB itself proves both privacy and a
   per-document share: 55 checks and 11 controls green (section 3.4).
2. (b) and (c) still need RLS for a single shared document; (b) costs one to
   two orders of magnitude more server-side migration time at 100
   workspaces, (c) needs 100 migrate runs instead of 1 and fails on today's
   tier (78 of 100 connections refused).
3. Zero added cost at 6 or 100 workspaces, one migration path, one backup;
   (d) encryption stays an add-on if backups must become unreadable.

No panel finding changes the model: all of them were write-side or hub-side
gaps inside (a), and each is now a check with a control.

What changes in spec 113's live tables (0157):

- **No column, constraint, index or existing policy changes.** Two triggers
  are added: `workspace_doc_share_edit_cols` (BEFORE UPDATE on
  `workspace_doc`) and the constraint trigger `workspace_doc_rev_log_reached`
  (on `workspace_doc_rev_log`).
- A new, additive migration (next free number today: 0159; name it once
  taken): creates `workspace_doc_share` (+ its revoke/accept trigger, 4
  permissive policies and its fence) and **adds 6 share policies and 3
  restrictive fences** to the three 0157 tables (`share_read` x 3,
  `share_edit` x 3, `scope_fence` x 3), plus the two triggers above.
  `runtime-grants.sql` gains the `REVOKE DELETE` (4.5).
- **Hub change ships with or before the migration's first grant**: every 113
  read that relied on RLS alone (`wsDocHeadSQL`, `DocSearch`, `docHeads`)
  gains `AND d.tenant_id = $tenant` (own list), and shared docs are read
  through a separate call (section 4.4); `DocHead` and `DocHit` gain the
  owning `tenant_id` for the label. A store test seeds one accepted grant to
  the session's tenant and asserts the own list is unchanged (P10). The
  migration can land first (DDL first, dev and prd): it opens nothing while
  no grant row exists, and no grant row may exist in dev or prd until that
  hub change is live (tasks T002a, T003).
- Gates the build must keep green: `TestRLSCoversEveryTenantTable` and
  `TestRLSPoliciesFailClosed` pick the new table up (column `tenant_id`, the
  `NULLIF` form); `TestCrossTenantEveryTable` counts `tenant_id <> $1` rows
  per table and stays 0 only while its seed holds no grant to the session's
  tenant, so P1-P14 + C1-C11 become their own Go test on testkit Postgres.

No code, migration or GCP change is part of this v0.2.

## 6. Rules

- Every new document-adjacent table carries `tenant_id` (the owner), the
  0157 policy pair and a `scope_fence`, or the catalogue gate fails.
- Every 113 query names `tenant_id` explicitly for the own-workspace view;
  RLS is the backstop, not the filter.
- The policy set of the document tables is pinned by a test; a new policy
  changes the pin in the same commit.
- No hub path shares by default: a grant is created only by the grant call,
  and opens nothing until the receiver accepts it.
- The store never reads a shared document under the OWNER's tenant scope;
  the receiver's own scope + the share policies decide.
- A revoke is an UPDATE of `revoked_at`, never a DELETE.

## 7. Review seats

Seat 1 wrote v0.1. c-002 seated the panel on v0.1 (b65209947); c-719 folded
it into this v0.2.

| seat | agent | verdict | changes & answers |
|---|---|---|---|
| 1 | c-711 (claude) | author | v0.1 |
| 2 | a-716 (agy) | agree with changes | 3 findings, all applied (7.1) |
| 3 | c-714 (claude, security) | agree with changes | 7 findings, all applied; Q5 folded into Q2 (7.1); P8-P14 + C3-C11 built from its attack.sql and fix.sql |
| 4 | c-715 (claude, buildability + ops) | agree with changes | 6 findings, all applied, its ratio re-measured (7.1) |
| 5 | m-717 (mistral) | agree with changes | 3 findings: 1 and 2 applied, 3 rejected (7.1) |
| - | (grok) | not reviewed | weekly limit |
| fold | c-719 (claude) | v0.2 | this text; bench re-run 55 PASS, 11 of 11 controls |

### 7.1 Every finding and what v0.2 did with it

| finding | done | why |
|---|---|---|
| a-716 #1 "not intermixed" missing | applied: section 0 bullet 3 (its text) and section 1 bullet 1 | the owner's words are a goal of their own, and the live store breaks it (P10) |
| a-716 #2 Q2 carries a shell command | applied: Q2 in plain words | an owner question carries no commands |
| a-716 #3 Q3 cites proof ids | applied: Q3 in plain words | proof ids mean nothing to the owner |
| c-714 #1 edit receiver forges the header | applied: column trigger, P8, C3 | RLS cannot limit columns; reproduced (C3) |
| c-714 #2 rev log forged and poisoned | applied: actor term + reached trigger, P9, C4, C5 | reproduced; its fix.sql shape kept, made immediate in the proof so the refusal is caught |
| c-714 #3 store list has no tenant filter | applied: section 5 hub bullet, section 6 rule, P10, C10, tasks T002a | the list mixes on the day the policies land (C10: 2 docs, owns 1) |
| c-714 #4 shares land without consent; id oracle | applied: `accepted_*`, `share_accept`, P11, C6; oracle mapped in the grant call (4.1, T003). Its Q5 is folded into Q2 | consent is in the DB; the oracle is an API answer, not SQL. The dispatcher asked for 4 questions, and Q2 now names the accepting step |
| c-714 #5 permissive only | applied: 4 RESTRICTIVE fences + the pin, P12, C7, C8 | one forgotten permissive policy would otherwise widen reads silently |
| c-714 #6 revoke incomplete | applied: 4.3 text (doc gone, change stamp), write side P14, C11 | the DB part is provable; the stamp and the event are hub work (T003) |
| c-714 #7 pre-share history | applied: `granted_at` bound, P13, C9 | member identities before the share are not the receiver's |
| c-715 #1 ratios measure docker exec | applied, re-measured: M5 in the bench, section 3.2 ALTER row and 3.3 | c-001 noted c-715's run was at load ~800; this run (load ~14) gives 4.1 vs 245.9 ms, so the text says "one to two orders of magnitude", not 5x or 14x |
| c-715 #2 Create compares unequal work | applied: note under the 3.2 table | (a) includes share-grant.sql, (c) includes CREATE DATABASE |
| c-715 #3 search_path trap | applied: measured in the bench (M2 `ws_1_fns_without_search_path=2`) | now reproducible by anyone |
| c-715 #4 store reads scope by RLS alone | applied with c-714 #3 (same finding) | the two seats found it independently |
| c-715 #5 DELETE via default privileges | applied: explicit `REVOKE DELETE` (4.5), tasks T002 | line 34 grants DELETE on every new table |
| c-715 #6 no tenant-filtered restore | applied: Backups cell, tasks T005 | `do_spl_db_restore` restores the whole dump to a scratch database; the per-workspace copy is the missing step |
| c-715 nit: migrate.go line 58 | applied: Migrations cell | line 58 is the table's CREATE |
| m-717 #1 own vs shared list wording | applied: 4.4 bullet 1 | clearer, and it states the goal from section 1 |
| m-717 #2 receiver notice on revoke | applied: 4.3 and 4.4 | the receiver must learn why the document closed |
| m-717 #3 optional read log | rejected | a read log turns every read into a write on the f1-micro (25 connections), nobody asked for read audit, and it is additive later without touching this design |

## 8. Owner questions

**Q1. How should workspace documents be kept apart?**
- (a) One set of tables, each row tagged with its workspace and locked to
  it by the database, plus a sharing table (**recommended**).
- (b) A separate schema per workspace; sharing still needs the row locks
  inside it.
- (c) A separate database per workspace (needs a larger database server or
  one server each).
- (d) (a) now, plus a per-workspace encryption key later, if backups and
  operators must not be able to read document text.

**Q2. Who can a document be shared with?**
- (a) Another workspace as a whole; it shows there only after an admin of
  that workspace accepts it (**recommended**: no unsolicited documents).
- (b) As (a), but it shows at once, without accepting.
- (c) Also one named person in another workspace.

**Q3. What may someone with edit access do?**
- (a) Change text and structure, never delete the document or share it on
  (**recommended**).
- (b) Read only in the first build, editing later.
- (c) Also share it on to a third workspace.

**Q4. Who in the owning workspace may share and stop sharing?**
- (a) Workspace admins only (**recommended**).
- (b) Any member who can edit the document.
