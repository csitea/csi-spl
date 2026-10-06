# 100 search index: reviewer r3 (c-371), rollout risk, ops cost, test plan

Seat r3 of the spec-100 panel (t1 2b25c535). Scope: migration and rollout risk on
dev and prd, ops cost now and at 10x, and the test plan for the recommended
option. Written from master `6f128452` before the author's spec.md landed,
after r1's note (`ebfe1fbc`); the risk and cost rows cover every option the
owner named. **Position: S1 (with r1), proven locally without BYPASSRLS
(section 1.2); option A (side term table) is the fallback if dev Cloud SQL
refuses step 0.** Prd numbers quoted from the owner text carry their provenance
there (t1 6d5bd334 table); numbers measured here are LOCAL and say so.

## 1. What decides the options: which operators Postgres may index under RLS

The root cause (owner text, point 1) is a rule, not a size: under FORCE RLS the
planner uses an index condition only when its operator is LEAKPROOF. So the
first question for any in-Postgres option is which operators are.

`pg_proc.proleakproof`, local pg 16.15 (postgres:16-alpine), n=1 (a catalogue
read; Cloud SQL pg 16 ships the same catalogue for built-ins, I believe,
unchecked on prd: `SELECT proname, proleakproof FROM pg_proc WHERE proname IN ('texteq','text_lt','text_ge','uuid_eq','ts_match_vq','bitand','arrayoverlap')`):

| operator | function | leakproof | usable as index cond under RLS |
|---|---|---|---|
| `text = text` | texteq | **t** | yes |
| `text < / <= / >= / > text` | text_lt ... | **t** | yes (prefix = a range) |
| `uuid = uuid`, `int8 =`, `timestamptz` compares | uuid_eq ... | **t** | yes |
| `tsvector @@ tsquery` | ts_match_vq | f | no (why 0122 dropped the GIN) |
| `bit & bit` | bitand | f | no (why 0135 is a filter, not an index) |
| `anyarray && / @>` | arrayoverlap ... | f | no (a GIN on a lexeme array has the same wall) |

So a side table of plain `(tenant_id text, term text, msg_id uuid)` rows with a
btree is servable under the tenant policy as is; a GIN is servable only by a
role whose policy has no qual (section 1.2).

### 1.1 Option A proof: a side term table (local, plan shape only)

Local pg 16, throwaway container, n=1, synthetic: 3 tenants x 60k messages.
**Not a performance claim** (owner lesson 5). `messages` and
`message_terms(tenant_id, term, msg_id) PRIMARY KEY (tenant_id, term, msg_id)`,
both FORCE RLS with the 0014 policy shape
`tenant_id = NULLIF(current_setting('app.tenant_id', true), '')`, queried as a
`NOBYPASSRLS` role:

| query | plan | buffers |
|---|---|---|
| one rare term | Index Only Scan on message_terms_pkey, `Index Cond: tenant_id AND term` | 4 |
| prefix `rare424*` as `term >= 'rare424' AND term < 'rare425'` | Index Only Scan, both bounds in Index Cond | 4 |
| rare AND common, rare-driven `EXISTS` | Nested Loop of two Index Only Scans | 8 |
| rare AND common as `INTERSECT` | reads the whole common posting list (60k rows) | 810 |
| scope t1, `WHERE tenant_id = 't0'` / scope unset | 0 rows / 0 rows | - |

### 1.2 Option S1 proof: GIN read through a SECURITY DEFINER function, no BYPASSRLS

r1 (c-369) left S1's precondition open: BYPASSRLS is unlikely to be grantable on
Cloud SQL. It is not needed. Same container, same data, n=1:

- `CREATE ROLE spool_search_reader NOLOGIN NOBYPASSRLS`, `GRANT SELECT ON messages`,
  and a policy **for that role only**:
  `CREATE POLICY search_reader ON messages FOR SELECT TO spool_search_reader USING (true)`.
- `spool_search_candidates(q tsquery) RETURNS SETOF uuid`, `SECURITY DEFINER`,
  `SET search_path = pg_catalog, public`, owned by `spool_search_reader`, body
  `WHERE tenant_id = NULLIF(current_setting('app.tenant_id', true), '') AND search_tsv @@ q`;
  no tenant argument; `EXECUTE` revoked from PUBLIC, granted to the runtime role.

| check | result |
|---|---|
| plan inside the function (as the reader role) | Bitmap Index Scan on the GIN, `Index Cond: search_tsv @@ q`, 5 buffers |
| runtime role, own tenant's rare word | 1 id |
| runtime role, ANOTHER tenant's rare word through the function | 0 |
| runtime role, same word direct on `messages` (policy) | 0 |
| function with no tenant in scope | 0 |
| outer query `m.msg_id IN (SELECT spool_search_candidates(...))` | Nested Loop, Index Only Scan on the PK, 10 buffers |
| size, same data | GIN **15 MB** vs side table + PK **73 MB** |

Two things the proof also shows:

- In that plan `tenant_id` is a **Filter**, not an Index Cond: one GIN over every
  tenant. A common word then makes a tenant pay for every other tenant's
  matches, which is r1's 10x-B case. Build the GIN as
  `USING gin (tenant_id, search_tsv)` with `btree_gin` (I believe, unchecked,
  that Cloud SQL pg 16 offers `btree_gin`: `SELECT * FROM pg_available_extensions WHERE name = 'btree_gin'` on dev).
- The definer function only names ids; the hub's outer statement still reads
  `messages` under the tenant policy, so a bug in the function's tenant pin
  returns ids that the outer join drops (defence in depth). The residual leak is
  an existence oracle through a direct call of the function, which T5 covers.

## 2. Options: rollout risk and ops cost

Cost basis: the estate is ~$60 / env / month, 80% hub CPU (owner text);
Cloud SQL `db-f1-micro`, disk 10 GB (`grep -n disk_size_gb csi-spl-cnf/csi-spl/all.env.yaml` -> 181: `10`),
max_connections 25, hub pool 8. Vendor list prices are what I believe,
unchecked; the deltas matter, not the cents. "10x" per r1: 10x-A one tenant
posts 10x, 10x-B ten tenants of t1's size (retention is 30 days, so it is a
rate, not an age).

| option | migration / rollout risk | ops cost now | at 10x | r3 verdict |
|---|---|---|---|---|
| **S1. GIN `(tenant_id, search_tsv)` + one definer function via a role-scoped policy** | low-medium: one index build (locks writes for its build time, section 4), one role, one policy, one function; the privileged surface is that function | disk ~0: 12 MB on prd when 0122 dropped it; insert +34% median in 0122's local scratch (544 -> 730 ms per 20k, n=3) | GIN grows with lexeme rows, ~1/5 of A's size; a rare word stays a few buffers cold in both 10x cases (with the tenant column leading) | **recommend** |
| A. side term table, btree, own RLS policy | low: additive, no privileged code; but a second copy of the content and its own delete path (section 4) | disk: dev t1 1,018,536 lexeme rows (n=1, dev 2.0.5 / 0c9203ca / 0137, c-001) at ~110 B -> ~110 MB, i.e. 1.4x `messages` itself; prd pending | 10x-A ~1.5 GB of a 10 GB disk and far past 128 MB shared_buffers (point lookups survive that; disk and backups grow) | **fallback** if Cloud SQL refuses S1's role-scoped policy |
| C. pgvector / semantic | high: extension, an embedding call per insert and per query, a new secret, data leaves the estate; `<=>` needs S1's bypass anyway | embedding API + a ~3..6 KB vector per row (TOAST again) | doubles the table at 10x-A | reject for this need |
| D. hosted search service | high: a second store synced from every message-mutating path (`cat csi-spl-api/src/go/spool-hub-api/internal/store/*_postgres.go \| grep -cE "UPDATE messages\|DELETE FROM messages"` -> 30, trunk 6f128452), isolation by an API filter we write, its outage is ours | ~$25..100 / env / month: 40..160% of today's env | a tier step | reject |
| E. in-process index in the hub | high: rebuilt from a full read of `messages` on every deploy (r1 section 4) | hub memory, the bill's dominant line | grows with data | reject |
| F. 0135 + the 512..1023 lane | none new | 0 | a scan: ~31.6k buffers today (prd, n=2) and r1's cold-cache arithmetic at 10x | keep as the FALLBACK path behind the probe |

## 3. Sizing

Dev t1, n=1 (c-001, dev hub 2.0.5, commit 0c9203ca, schema 0137): 13,026
messages, 1,018,536 lexeme rows, avg 78 / max 1,021 per message; database 98 MB,
`messages` 78 MB; 10 messages per 24 h (a thin copy). Prd: the same three reads
are with the active orchestrator; until they return, prd = 18.8k x 78 = ~1.47 M lexeme rows
**by arithmetic from the dev average**, i.e. side table ~160 MB, GIN ~30 MB
(the local 1 : 5 ratio).

| | now (arithmetic) | 10x-A | 10x-B |
|---|---|---|---|
| S1 GIN | ~30 MB | ~0.3 GB | ~0.3 GB total |
| A side table | ~160 MB | ~1.6 GB | ~1.6 GB total |

## 4. Rollout of S1, dev then prd

Every step is a named path (repo CLAUDE.md: nothing ad hoc).

| # | step | gate | rollback |
|---|---|---|---|
| 0 | **prove on dev Cloud SQL first**: the migration of step 1 on dev, then `EXPLAIN (ANALYZE, BUFFERS)` of the function body as the reader role shows the GIN; `btree_gin` available | if it fails: switch to option A, same test plan (section 5 marks the A-only tests) | `DROP` the function, policy, role, index |
| 1 | rdb `01NN_search_gin.sql`: `CREATE EXTENSION btree_gin`, the GIN on `(tenant_id, search_tsv)`, role, `FOR SELECT TO` policy, function, grants | owner go; orchestrator applies dev, then prd. The build runs inside the migrate transaction (no CONCURRENTLY, as 0122) and holds a SHARE lock on `messages`: **measure its time on dev** (dev t1 has 1.0 M lexeme rows, close to prd); if it is more than a few seconds on prd, ship the index as its own CONCURRENTLY step outside the migrate transaction | `DROP INDEX` |
| 2 | hub: probe the function like `hasSearchSig` (a trunk push rolls dev AND prd together; the migration may lag). Read path: positive text terms go through the candidate set; NOT-only / OR-only / no-text queries keep today's path and 0135 | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` on postgres | redeploy the previous tag |
| 3 | an env switch `SPOOL_HUB_SEARCH_INDEX=off` returns every query to today's path without a code deploy | flip on dev, then prd | flip off |
| 4 | prd benchmark (5.4) before and after, n >= 5 | owner reads it | step 3 |
| 5 | after two weeks green: decide on 0135 and the 512..1023 lane (search_sig and its trigger) | owner; a separate item | - |

No backfill: the GIN covers every existing row at build time, and edits,
deletes, expiry and archive reach it in the same transaction (same row).

Risks:

- **Deploy-order race**: covered by the probe (step 2) and the fallback path.
- **Index build lock** on prd (step 1): the one write stall in the rollout;
  measured on dev before prd, announced to the owner with its number.
- **Insert latency**: +34% median locally per 0122; measure the prd shape on
  dev (T7) before prd.
- **The privileged function**: SECURITY DEFINER with a pinned `search_path`,
  no tenant argument, owner NOLOGIN, EXECUTE to the runtime role only. Any later
  edit of it is a security change: T4 pins its definition.
- **Concurrent lane**: the queued 512..1023 search_sig lane edits
  `searchMessagesSQL` too; rebase, never hand-merge.
- **If step 0 fails (option A)**: an expiry purge through a FOREIGN KEY ... ON
  DELETE CASCADE has no `(tenant_id, msg_id)` index to use (the PK leads on
  term). LOCAL, n=1, 240k side rows: cascade delete of 50 messages 880 ms
  (17.6 ms each); a DELETE trigger deleting `term = ANY(lexemes of OLD.search_tsv)`
  through the PK: 500 messages 27.6 ms. So A has no FK, deletes by the row's own
  lexemes, and needs a chunked backfill and a per-tenant `complete_at` flag
  before its read path turns on.

## 5. Test plan (S1; A-only rows marked)

All store tests run on POSTGRES (deploy-gate b): `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.

### 5.1 Answer unchanged

| id | test | fails when |
|---|---|---|
| T1 | for a fixed corpus and every query form in search-v1 (word, phrase, prefix, AND, OR, NOT, mixed operators), the index path and the scan path return **the same rows in the same order** | the index drops or adds a row |
| T2 | the memory store and the postgres store agree (existing parity tests extended) | a new SQL form diverges |

### 5.2 Tenant isolation (owner question 3)

| id | test | fails when |
|---|---|---|
| T3 | two tenants share a unique word; as the hub runtime role (`NOBYPASSRLS`) tenant A gets only A's rows through the API, through the store, AND through a direct call of the function; with no scope the function returns 0 | any cross-tenant id at the SQL level |
| T4 | catalogue pin: the function is SECURITY DEFINER, has `search_path` set, takes no text tenant argument, its body references `app.tenant_id`; its owner is NOLOGIN and NOBYPASSRLS; EXECUTE is not granted to PUBLIC; the `USING (true)` policy is `FOR SELECT` and `TO` that role only; `messages` is still FORCE RLS | a later migration widens any of these |
| T5 | planted leak (the test can fail): in a rolled-back transaction, replace the function with one missing the tenant pin; T3's direct call must turn red, and the API-level T3 must stay green (the outer RLS still filters) | T3 is vacuous, or defence in depth is gone |

### 5.3 Lifecycle (owner question 4)

| id | event | expected | how fast |
|---|---|---|---|
| T6 | edit body | old-only words stop matching, new words match | same transaction |
| T7 | insert p50 / p95, 3 KB real-text bodies, n >= 20, with and without the index, on dev | within the budget spec.md sets | - |
| T8 | delete (moderation, merge drop, channel delete) | gone from results | same transaction |
| T9 | expiry | gone at `expires_at` (outer filter), before the sweep purges it | instant |
| T10 | archive / unarchive, move, topic merge | same rows as the scan path (T1 on the mutated corpus) | instant |
| T11 (A only) | half-backfilled tenant is served by the scan path | an incomplete tenant served by the index | - |
| T12 (A only) | orphan count 0 after T8..T9 | a delete path missed | - |

### 5.4 Performance (owner question 5; lesson 5)

- Local budget test seeded from **real-shaped text**: the owner's query words,
  one common word in ~30% of posts (prd: "example"), one rare word, posts of
  1024+ characters so TOAST is in play. Assert buffers, not ms.
- Plan-shape assertion: an exact-word query uses the GIN inside the function,
  never a Seq Scan on `messages`.
- Two tenants in the seed, one 10x the other: the small tenant's rare-word
  buffers must not grow with the big one (the btree_gin tenant column).
- `TestHiddenUnreadBufferBudget` must not move.
- **prd benchmark** (read-only, the orchestrator runs `do_spl_search_measure`):
  the owner's query "Example refactoring prompt (round 4)", a common-word query,
  a rare-word query, plus r1's prefix query and `from:`-only query; each cold
  and warm, n >= 5, before and after; report `shared read` blocks as well as ms
  (r1: ms vary with shared-core neighbours) and version / schema head / n per
  row. Cold is defined in the run note (fresh connection after idle), since the
  6d5bd334 AFTER-cold may have been partly warm.

Acceptance proposed to the author: p95 under 1 s cold for every benchmark row
at today's size, and the rare-word query's buffer count independent of the
tenant's message count; the 10x claim rests on that, not on extrapolated ms.

## 6. Questions for the owner (to c-002 via the author, as one list)

1. The GIN build on prd holds a SHARE lock on `messages` (writes wait) for its
   build time; the dev number comes first. Accept a few seconds of write stall
   in one migration, or require the CONCURRENTLY path?
2. Insert budget: what added p95 per send is acceptable for indexing (T7)?
3. Semantic search: is meaning-search a need at all? Option A answers exact and
   prefix only; C is a separate, costed decision.
