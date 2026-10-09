# Spec 114: Workspace documents are private; sharing is a deliberate grant

Version **v0.1** (2026-10-09), seat 1 (c-711, claude). This v0.1 replaces
the draft at c2a713420 completely: none of its text or SQL is kept (its SQL
did not parse: mangled quotes and double-quoted string literals). Every SQL
statement this spec relies on lives in [bench/](bench/) and ran in a
throwaway `postgres:16-alpine`; the spec quotes it, never retypes it. Build
tasks: [tasks.md](tasks.md) (skeleton until the panel agrees).

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
- **The mechanism is open.** A table naming convention, a schema or a
  database per workspace are all named as possibilities. Section 3 compares
  them with numbers.

## 1. Goals and terms

- **Workspace = tenant** (rdb 0126's naming; spec 113 section 2.2): every
  document row carries `tenant_id`, the workspace id.
- **"Completely private"** (section 3.1 makes it testable): a session scoped
  to workspace X cannot read, write, lock or reference a document row of
  workspace Y unless a live grant names X. The DB enforces it, not only the
  hub, and a test with a control proves it.
- **Share** = one grant: one document, one receiving workspace, `read` or
  `edit`, revocable.
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

Raw output: [bench/raw-2026-10-09.txt](bench/raw-2026-10-09.txt). Box: 16
CPUs, load 4.90 at start (M0 line), n = 5 per timed migration and query
(median). As in spec 113 section 2.1, differences under 2 ms are not ranked
on this box (the same `own` query without share policies read 1.09 ms in
an earlier run of this script and 0.42 ms in the recorded one);
only the 10-100x gaps carry the decision.

| id | measures | per model |
|---|---|---|
| P1-P7 | the model (a) privacy + sharing proof, 29 checks ([share-proof.sql](bench/share-proof.sql)) | (a) |
| C1, C2 | two controls that break it on purpose ([share-control.sql](bench/share-control.sql)) | (a) |
| M1-M3 | create the 0157 tables for n workspaces; one ALTER fanned out to all of them; relations, bytes; connections | (a), (b), (c) |
| M4 | read cost of the share policies at 100 workspaces x 1 doc x 1,111 items (111,100 rows) | (a) |

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
| **Private, proven by** | P1-P7 + C1, C2 (section 3.4): **measured green**, 29 PASS, both controls caught | per-workspace role + `SET ROLE` per request; a cross-schema SELECT must be refused (42501). Not built in this bench | a different DSN; cross-database SQL does not exist in Postgres without `dblink` / `postgres_fdw` | (a)'s proof, plus: a dump read without the key shows no text |
| **Create, n = 6** (M1-M3, raw lines 33-40) | 302 ms once | 717 ms | 2,936 ms | as (a) |
| **Create, n = 100** | 334 ms once (independent of n) | 10,178 ms | 44,071 ms | as (a) |
| **One ALTER, all workspaces, n = 100** | 121 ms (one statement) | 605 ms (100 statements) | 11,101 ms (100 connections, 100 migrate runs) | as (a) |
| **Catalogue, n = 100** | 16 relations | 1,000 relations | 100 databases, 797 MB empty (7.97 MB each) | as (a) |
| **Connections, n = 100** | the pool of 8 | the pool of 8 | 22 of 100 one-connection-per-database sessions got in, 78 refused (`max_connections` 25 minus 3 reserved); on Cloud SQL 20 are usable | the pool of 8 |
| **Migrations** | `Migrate` applies each file once and records it in `spool_schema_migrations` (`internal/store/migrate.go` line 58) | every file once PER schema, a new workspace replays them all; `/version` `schema_head` per schema. 0157's trigger functions name tables without a schema (`grep -c 'FROM workspace_doc' 0157_workspace_docs.sql` -> 7), so each copy must pin `SET search_path` or it resolves the CALLER's schema (Postgres name resolution; not measured here) | every file once PER database; a half-done fan-out leaves workspaces on different heads | as (a); a key rotation re-encrypts every body |
| **Backups** | one export (`do_spl_db_backup`, wf 45) holds all; restoring ONE workspace = a filtered restore by `tenant_id` | one export holds all; one workspace = `pg_restore -n ws_<n>` | Cloud SQL export is per `--database` (`spl-db-backup.func.sh` line 101): 100 exports + 100 verifies a day | as (a); a stolen export shows no document text |
| **Operator workspace** | `app.rls_scope = 'operator'`, one query | a generated `UNION ALL` over n schemas | n connections, more than the pool at 100 | as (a), plus the operator needs every key to read text |
| **Search across a workspace's docs + its shares** | one query; under FORCE RLS no GIN index serves `@@` (rdb `0135` search_sig exists for that reason) | n schemas = n queries or a generated union | n connections; at 100 not possible in one request | SQL search, grid sort/filter on `body` and 0157's `length(body)` CHECK stop working on ciphertext |
| **Sharing one document** (section 4) | a grant row the policies consult: **measured** | schema GRANTs are per TABLE, so one document needs RLS inside the schema (= (a)'s mechanism again) or a copy into the receiver's schema (a fork: edits diverge, a revoke cannot recall it) | the hub reads the owner's database for the receiver after checking a grant in a central database: enforced by the hub, not the DB; or a copy | as (a); the hub decrypts with the OWNER's key for the receiver |
| **Cost at 6** | $0 extra | $0 extra | $0 extra on one instance | +$0.36 / env / month (6 secrets) |
| **Cost at 100** | $0 extra; one instance, 16 relations | $0 extra; 1,000 relations | one instance: 797 MB of the 10 GB disk, but pools of min 2 x 100 = 200 connections need `max_connections` >= 200, a 6-7.5 GB tier (flags table); or 100 instances x ~$10 = ~$1,000 / env / month (047 estimate, under the 1,000-instance quota) | +$6 / env / month (100 secrets) |

### 3.3 Reading of the table

- (b) and (c) **do not remove the need for RLS** once a single document can
  be shared: schema and database boundaries are all-or-nothing. They add a
  second mechanism next to it.
- (b) costs 5x the migration time at 100 (605 vs 121 ms) and 62x the
  relations, and moves the boundary from a DB-enforced row policy to "every
  query names the right schema or role", which a typo breaks silently unless
  the per-workspace role is used, and then every request pays a `SET ROLE`.
- (c) fails on today's tier outright at 100 workspaces (78 of 100 refused,
  measured) and multiplies migrations by n (92x, 11,101 vs 121 ms).
- (d) is the only model that protects against a reader of a **backup or an
  operator psql session**. It costs search and sort over document text. It
  is an add-on to (a), not an alternative: keep it as a later option.

### 3.4 The model (a) proof, measured

[share-proof.sql](bench/share-proof.sql) on top of 0157 and
[share-grant.sql](bench/share-grant.sql), as the owning non-superuser role
(raw lines 2-32):

| check | what it shows |
|---|---|
| P1 | private by default: b sees 0 of a's docs and items, 1 of its own |
| P2 | b cannot grant itself a's doc: refused 23503 (FK carries the owner tenant) and 42501 (RLS) |
| P3 | after a's read grant, b sees A1 (1 doc, 2 items) and the grant row; still 0 of A2; c sees nothing; a cannot share with itself (23514) |
| P4 | read is read: b's UPDATE and DELETE hit 0 rows; b cannot re-share (42501) or revoke a grant it received (0 rows) |
| P5 | revoke: stamps `revoked_at` once; a second revoke or an in-place access change is refused (23514); b sees 0 items after, and still sees the revoked grant (audit) |
| P6 | edit grant: b adds an item to A1 under the doc lock and the 0157 tree trigger, rows keep tenant a; b cannot tag a row with b (23503), delete the doc (0 rows), or write into unshared A2 (42501) |
| P7 | no scope = 0 docs, 0 grants; operator sees all 3 docs and 2 grants |
| C1 | `NO FORCE ROW LEVEL SECURITY` on items: workspace c reads 4 of a's items. **CONTROL caught** |
| C2 | `share_read` without `revoked_at IS NULL`: b reads 3 items of a revoked share. **CONTROL caught** |

M4 (raw lines 41-46), 100 workspaces x 1,111 items, w1 holding 5 read
grants: reading one document's items is a Bitmap Heap Scan with and without
the share policies (own 1.03 ms with vs 0.42 ms without, a shared one
0.94 ms); listing the visible documents 0.24 vs 0.20 ms. Both gaps are
under the 2 ms noise floor, and the plan does not change at this size: the grant lookup is an `ARRAY(..)` sub-select, computed once
per statement.

## 4. Sharing, never the default

### 4.1 The grant

One table, [share-grant.sql](bench/share-grant.sql) (bench input, not a
migration):

- `workspace_doc_share (id, tenant_id, doc_id, to_tenant, access,
  granted_by, granted_at, revoked_by, revoked_at)`. `tenant_id` is the
  OWNING workspace and is named `tenant_id` on purpose: the RLS catalogue
  gate finds tenant tables by that column name
  (`internal/store/rls_test.go` line 80), so a `from_tenant` column would
  slip past it.
- FK `(tenant_id, doc_id)` -> `workspace_doc (tenant_id, id)`: a grant can
  only name the owner's own document (P2).
- `access` is `read` or `edit`. CHECK `to_tenant <> tenant_id`. At most one
  live grant per (doc, receiver) (partial UNIQUE).
- **Never default**: no trigger, no hub default, no workspace setting
  creates a row. Only an explicit grant call by the owning workspace inserts
  one; the RLS `WITH CHECK` refuses any other workspace (P2, P4).

### 4.2 What the policies add

0157's `tenant_scope` and `operator_scope` stay exactly as they are. The
migration ADDS permissive policies (OR-ed with the existing ones), verbatim
from the bench file:

```sql
CREATE POLICY share_read ON workspace_doc_item FOR SELECT
    USING (doc_id = ANY (ARRAY(
        SELECT s.doc_id FROM workspace_doc_share s
         WHERE s.to_tenant = NULLIF(current_setting('app.tenant_id', true), '')
           AND s.revoked_at IS NULL)));
```

- `share_read` (SELECT) on `workspace_doc`, `workspace_doc_item`,
  `workspace_doc_rev_log`.
- `share_edit` for `edit` grants: UPDATE on `workspace_doc` (the rev bump
  and the `FOR UPDATE` lock every op and the 0157 tree trigger take), all
  commands on `workspace_doc_item`, INSERT on `workspace_doc_rev_log`. No
  DELETE of the document itself (P6).
- On `workspace_doc_share`: the owner reads and writes its grants; the
  receiver only reads the ones naming it; operator scope as 0157.

### 4.3 Revocation

- `UPDATE .. SET revoked_at, revoked_by` once; a trigger refuses any other
  change and a second revoke (P5). Changing `read` to `edit` = revoke + a new
  grant, so history is never rewritten.
- Effect: the next statement. Policies read the live grant per statement, so
  no cache to flush in the DB. The hub must also push a "doc gone" event to
  the receiver's open views (WebSocket), else an open page shows stale text
  until reload.
- What the receiver already read or exported is not recalled (no model can).

### 4.4 What the receiving side sees

- A **"Shared with this workspace"** list: the document's title, the owning
  workspace's display name, `read` or `edit`, granted at. Never mixed into
  its own document list.
- `read`: the outline and grid views read-only. `edit`: the same edits as
  the owner, except delete the document and share it on.
- The receiver's search includes documents shared with it, each labelled
  with the owning workspace.
- After a revoke the document disappears; the revoked grant stays visible to
  both sides as history (P5).

### 4.5 Audit trail

- The grant table is the share audit: who granted, when, what access; who
  revoked, when. The runtime login gets SELECT, INSERT, UPDATE on it, no
  DELETE (`spool-hub-roles/runtime-grants.sql` at build time); the row
  deletes only with its document or its workspace (cascade).
- Edits by the receiver land in `workspace_doc_rev_log` (spec 113 D-Q1) with
  `actor` = `<member>@<workspace>`, so the owner sees who changed what.
- Reads by the receiver are not logged (no per-read write on an
  f1-micro).

## 5. Recommendation

**Model (a): keep shared tables + `tenant_id` + FORCE RLS, and add one grant
table with permissive share policies.** Why, in three lines:

1. It is the only model where the DB itself proves both privacy and a
   per-document share: 29 checks and 2 controls green (section 3.4).
2. (b) and (c) still need RLS for a single shared document, and cost 5x /
   92x per migration at 100 workspaces; (c) fails on today's tier (78 of 100
   connections refused).
3. Zero added cost at 6 or 100 workspaces, one migration path, one backup;
   (d) encryption stays an add-on if backups must become unreadable.

What changes in spec 113's live tables (0157):

- **No column, constraint, index, trigger or existing policy changes.**
- A new, additive migration: creates `workspace_doc_share` (+ its revoke
  trigger and 3 policies) and **adds 6 policies** to the three 0157 tables
  (`share_read` x 3, `share_edit` x 3). DDL first, dev and prd, before the
  hub that writes grants.
- Gates the build must keep green: `TestRLSCoversEveryTenantTable` and
  `TestRLSPoliciesFailClosed` pick the new table up (column `tenant_id`, the
  `NULLIF` form); `TestCrossTenantEveryTable` counts `tenant_id <> $1` rows
  per table and stays 0 only while its seed holds no grant to the session's
  tenant, so P1-P7 + C1/C2 become their own Go test on testkit Postgres.

No code, migration or GCP change is part of this v0.1.

## 6. Rules

- Every new document-adjacent table carries `tenant_id` (the owner) and the
  0157 policy pair, or the catalogue gate fails.
- No hub path shares by default: a grant is created only by the grant call.
- The store never reads a shared document under the OWNER's tenant scope;
  the receiver's own scope + the share policies decide.
- A revoke is an UPDATE of `revoked_at`, never a DELETE.

## 7. Review seats

Seat 1 wrote v0.1. c-002 seats the panel (agy, two claude, grok or
mistral) on this version.

| seat | agent | verdict | changes & answers |
|---|---|---|---|
| 1 | c-711 (claude) | author | v0.1 |
| 2 | (agy) | | |
| 3 | (claude) | | |
| 4 | (claude) | | |
| 5 | (grok or mistral) | | |

## 8. Owner questions

**Q1. Which isolation model?**
- (a) Shared tables + `tenant_id` + FORCE RLS, plus the grant table
  (**recommended**, section 5).
- (b) A schema per workspace, RLS kept inside it for sharing.
- (c) A database per workspace (needs a larger tier or an instance each).
- (d) (a) now, plus a per-workspace encryption key later, if backups and
  operator sessions must not read document text.

**Q2. Who can a document be shared with?**
- (a) Another workspace as a whole (**recommended**: works with the scope
  the store sets today, `app.tenant_id`; it sets only that and
  `app.rls_scope`, by `grep -rhoE "set_config\('app\.[a-z_]+'" internal`).
- (b) Also one named member of another workspace: the store must set a new
  `app.human_id` on every tenant transaction and the grant gets a member
  column.

**Q3. What may an `edit` share do?**
- (a) Change text and structure, never delete the document or share it on
  (**recommended**, as proven in P4 and P6).
- (b) `read` only in the first build, `edit` later.
- (c) Also share it on to a third workspace.

**Q4. Who in the owning workspace may grant and revoke?**
- (a) Workspace admins only (**recommended**).
- (b) Any member who can edit the document.
