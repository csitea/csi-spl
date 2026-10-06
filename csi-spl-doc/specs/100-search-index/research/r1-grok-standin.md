# 100 search index: reviewer r1 (claude standing in for the grok seat)

> **Seat note:** grok is at its weekly limit, so a claude agent (c-369) holds
> the grok seat. Its brief: challenge the cost numbers at 10x, make the case for
> the simplest option, and list what is still unmeasured.

Tree: `origin/master` at `6f128452`. The 6d5bd334 numbers I quote are the
ones c-002 (the dispatch-lease holder) relayed on this topic (msg f2d6a03f), with their provenance
(version / tree / n). Anything else is marked as **read from code**,
**arithmetic** or **unchecked**.

## 1. Two facts that change the 10x arithmetic

### 1.1 "10x" is a traffic rate, not an archive size

`retention_days: 30` (`grep -n retention_days csi-spl-cnf/csi-spl/prd.env.yaml`
-> line 128). `messages` holds about 30 days of traffic, so t1 cannot grow to
10x by aging. It gets there only with 10x the posts per day. Two different
10x cases follow, and the spec should cost each one on its own:

| case | t1 rows | t1 heap+TOAST | all tenants together |
|---|---|---|---|
| now (prd, n=1, relayed) | 18.8k | 110 MB | ~110 MB (t1 dominates) |
| **10x-A**: t1 posts 10x | 188k | ~1.1 GB | ~1.1 GB |
| **10x-B**: 10 tenants the size of t1 | 18.8k each | 110 MB each | ~1.1 GB |

In 10x-B no single search reads more rows than it does today. It still turns
cold, though, because the other nine tenants push its pages out of a shared
cache (1.2 below). The spec answers only 10x-A if it multiplies one tenant's
row count.

### 1.2 The DB cannot cache 10x of anything

db-f1-micro has 0.6 GB RAM (**unchecked**: Cloud SQL machine-type table) and
`shared_buffers` of 128 MB (rdb 0122's comment says so). Today's 110 MB t1
just fits, which is why the warm number (67 ms) exists at all. At either 10x
case the working set (~1.1 GB) is larger than the box's RAM. **Every scan
becomes the cold scan.** Today's cold scan is the one that broke the budget
(4.1 s, 45.7k buffers, n=1).

Arithmetic, scaling linearly in rows read, against the 5 s budget:

| scan | now (measured) | 10x-A (arithmetic) | under 5 s? |
|---|---|---|---|
| pre-0135, cold | 4.1 s / 45.7k buf (n=1) | ~41 s | no |
| post-0135, warm | 107 ms / 31.6k buf (n=2) | ~1.1 s **only if warm**, and it cannot be warm | n/a |
| post-0135, cold | 126 ms (n=2, **probably partly warm**: it ran right after BEFORE) | unknown: no true cold run exists | **unmeasured** |
| GIN lookup (rare word) | not measurable under FORCE RLS today | grows with log(rows) plus the matching rows | yes, by construction |

**Challenge 1.** No sequential-scan option (0135, the 512-char lane, a
fingerprint on every row) survives 10x on db-f1-micro. They all read work that
grows with the tenant's row count, through a cache that is already full. They
are budget patches for "now". The spec should say so plainly and not offer
any of them as the 10x answer.

**Challenge 2.** The only true cold number we have is the BEFORE one. The
AFTER-cold run (126 ms) followed BEFORE right away, and the relay itself says
it "may be partly warm". The 3,252 -> 126 ms ratio is therefore **suggested,
not demonstrated**. Report cold runs as `shared read` blocks from
`EXPLAIN (ANALYZE, BUFFERS)`, not as ms. On a shared-core instance, ms vary
with neighbours. Reads do not.

## 2. The case for the simplest option

### 2.1 Candidates, smallest first

| # | option | new infra | $ / month now | $ / month at 10x | edit/delete/expiry lag |
|---|---|---|---|---|---|
| S0 | 0135 + the 512-char lane, nothing else | none | 0 | 0, but fails the budget (1.2) | 0 (trigger) |
| S1 | **re-create the GIN on `messages.search_tsv` and read it through one SECURITY DEFINER function** that returns the candidate `msg_id`s of the session's tenant | one function, one index (12 MB on prd per 0122) | 0 | 0 for the index; the DB tier question (6) is the same for every option | **0**: same row, same transaction |
| S2 | side table `message_search(tenant_id, msg_id, tsv)` plus a GIN, read through the same kind of function | table, trigger, policy | 0 | 0 | ~0 (trigger), but deletes and expiry need their own path |
| S3 | in-process index in the hub (bleve or similar) | none, but hub RAM | 0 at 512Mi?; a bigger instance if not | hub memory: **unmeasured** | outbox / replay, rebuilt on every deploy |
| S4 | hosted search engine | a vendor | **unchecked**, in the tens of $; the estate is ~$60/env | grows with records/ops | async, seconds |
| S5 | pgvector / semantic | extension, embedding API | **unchecked**: embedding ~cents (3) | the vector column alone ~1 GB at 10x-A | async (embed call) |

### 2.2 Why S1 is the one to beat

- **It is the index that already worked.** 0122 records that with RLS off
  Postgres used this exact GIN, and dropped it only because `@@` is not
  LEAKPROOF under FORCE RLS. S1 removes the RLS barrier for one predicate and
  nothing else.
- **The privileged surface is small.** The function takes a tsquery (built
  from bind parameters, as today) and returns `msg_id`s. Its body pins
  `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')`. It takes
  no tenant argument, so a caller cannot ask for someone else's tenant. The
  hub's existing statement then joins those ids to `messages` **under RLS**:
  the privacy door, archive, expiry, `from:` and so on stay exactly as they
  are (`searchMessagesSQL`, read from code). In the worst case the function
  leaks a set of msg_ids from the caller's own tenant, which RLS then filters
  again.
- **No sync path.** The index sits on the row it indexes. A body edit, a
  delete, expiry (`expires_at > now` in the outer query) and archive
  (`archivedHideSQL`) all reach it in the same transaction. Every other option
  has to answer the owner's "how fast?" question with a pipeline. S1 answers
  it with "the same commit".
- **Cost: one GIN on insert.** 0122 measured, locally on scratch pg16 (20k
  rows, n=3), a median insert of 730 ms with the GIN against 544 ms without
  it, i.e. +34% on insert. That number is local, not prd. A prd-shaped insert
  benchmark belongs in the spec.

### 2.3 What S1 must prove first (the spec cannot assume these)

1. **The bypass is possible on Cloud SQL.** A SECURITY DEFINER function
   still sees RLS unless its owner has BYPASSRLS or the policy lets that role
   through. FORCE RLS applies even to the table owner. I believe, unchecked,
   that `cloudsqlsuperuser` cannot grant `BYPASSRLS`. The alternative is a
   role-scoped policy `USING (true) TO spool_search_reader`. Whether the
   planner then uses the GIN for `@@` is **unmeasured**: it has to be tried on
   a Cloud SQL scratch instance, not on docker pg16.
2. **The plan uses the GIN for a common word too.** For "example" (705 of the
   3,277 long rows carry its bit, prd n=1) the GIN returns thousands of ids.
   The outer `ORDER BY received_at DESC LIMIT 21` then has to sort them. That
   cost is acceptable but unmeasured.
3. **Prefix terms.** `deplo*` is a GIN prefix scan (supported). Today it skips
   the fingerprint entirely (`textMatch`, read from code), so prefix queries
   are the scan that 0135 left at full cost. S1 fixes them and S0 never will.

## 3. Semantic search: not now

- The owner's failing query was an **exact title**: "Example refactoring
  prompt (round 4)". The question in front of us is exact and prefix
  matching. A vector search does not find an exact phrase more reliably than
  a GIN does.
- **pgvector does not escape the root cause.** Its distance operators
  (`<=>`, `<->`) are no more LEAKPROOF than `@@`. Under FORCE RLS an HNSW
  index has the same problem as the GIN. I believe this, unchecked; it needs
  the same scratch test as 2.3.1. Either way, S5 needs S1's bypass first.
- **Size.** 1,536-dim float4 is ~6 KB per message, about the same as today's
  average row (110 MB / 18.8k ≈ 5.9 KB, arithmetic). It doubles the table now
  and puts ~1.1 GB on a 0.6 GB instance at 10x-A.
- **Data leaves the estate.** Every post goes to an embedding provider. That
  is an owner and data-protection decision, not a performance one.
- Embedding API price: **unchecked**, in the order of cents per month now
  (~28M tokens/month if a post is ~1.5k tokens, arithmetic). Price is not the
  objection; the size and the data flow are.

## 4. Options outside Postgres, under our constraints

- **S3 in-process.** The hub is one Cloud Run instance
  (`min_instances: 1`, `max_instances: 1`, `memory: 512Mi`, `cpu: "1"`;
  `grep -n -A8 'cloud_run:' csi-spl-cnf/csi-spl/all.env.yaml`). One instance
  removes the cross-instance consistency problem *today*. But:
  (a) the comment there calls max=1 an M1 decision ("OQ-05"), so S3 would
  freeze that decision in place;
  (b) every deploy restarts the instance, and the index has to rebuild from
  Postgres before search is correct. That is a full read of `messages` per
  deploy, the very scan this spec is trying to remove, on a fleet that deploys
  many times a day;
  (c) hub CPU is already ~80% of the ~$60/env (relayed);
  (d) tenant isolation moves out of RLS into Go code, and the proof has to be
  rebuilt from zero.
- **S4 hosted.** Isolation becomes a per-tenant filter or API key at the
  vendor. Deletes and expiry become an async promise. A second copy of every
  private message sits with a third party. At ~$60/env, any paid tier is a
  large relative increase. Prices are **unchecked**, and the author should
  quote them with the date and the source.

## 5. Unmeasured: what the spec still needs before a verdict

| # | gap | why it matters |
|---|---|---|
| U1 | A **true cold** AFTER run (post-0135), n>=5 | the only cold-after number may be warm (1, Challenge 2) |
| U2 | How to get cold n>=5 times on prd **without a prd mutation** | you cannot restart prd five times. Proposal: a throwaway Cloud SQL **clone of prd** (same tier, restored from backup), restarted before each cold run. This needs the owner's go (it copies prd data); see Q2 |
| U3 | **Topic section** with no text term | `SearchTopics` aggregates every live message of the tenant (the `live` CTE reads `body` and `msg`) unless `topicCandidates` can narrow it (read from code). An index does not help `from:X` or `in:#c`; at 10x this is a scan of its own |
| U4 | **Relevance sort** | `ts_rank_cd(m.search_tsv, ...)` reads the TOASTed tsvector of every matching row (read from code). With a common word that is the TOAST cost again, after the index |
| U5 | **`has:code`** | `strpos(m.body, ...)` reads the TOASTed body of every row (read from code) |
| U6 | **OR / NOT queries** | `sigAll` walks only AND groups (read from code), so `a OR b` skips the all-words check |
| U7 | **Files section** | a `jsonb_array_elements` scan of every row; no index option covers it |
| U8 | Insert cost of S1 on prd shape | 730 vs 544 ms is local pg16, 20k rows (0122) |
| U9 | Memory of S3 for 10x-A | no number at all |
| U10 | **Cloud SQL facts** S1 depends on | BYPASSRLS availability; role-scoped policy plus GIN plan (2.3.1) |

The owner's benchmark set (owner query, common word, rare word; cold and warm;
n>=5; before and after) should add **one prefix query** and **one `from:`-only
query**. Those are where the S0 path and an index path differ the most (U3,
2.3.3).

## 6. Position

**S1.** Re-create the GIN on `messages.search_tsv` and read it through one
SECURITY DEFINER candidate function pinned to the session tenant. Keep 0135 as
the fallback while the hub probes for the function, the same way
`hasSearchSig` probes for the column. **But first** prove 2.3.1 on a Cloud SQL
scratch instance. If Cloud SQL cannot provide the bypass, fall back to S2 with
a role-scoped policy, and the same test.

**No vector, no external engine** until a stated need for meaning-based
search exists, and the owner has decided whether message text may leave the
estate.

**The DB tier is a separate line item, needed at 10x whatever we choose.** A
1.1 GB working set on a 0.6 GB shared-core instance is cold under any option.
The spec should cost the next tier up (**unchecked**: db-g1-small ~1.7 GB)
alongside the index decision, not inside it.

### 6.1 Isolation test S1 must ship with

Two tenants, each with one message holding the same unique word plus a
word only that tenant has. Run as the hub's login (non-BYPASSRLS), scope A:

- the function returns A's id and never B's;
- with the scope unset or `''` (NULLIF), the function returns **zero** rows,
  not every tenant's;
- a direct `SELECT` on the GIN's table or side table as the hub login sees only
  RLS rows (or is denied);
- the function has no tenant parameter (a catalogue check on `pg_proc.pronargs`
  and its argument types).

The test must fail when the function's tenant pin is removed. Plant that once
on a throwaway branch (repo CLAUDE.md: a control that turns trunk red belongs
off trunk).

## 7. Questions for the owner (to c-002, one list)

- **Q1** Is message text allowed to leave the GCP estate (an embedding
  provider, a hosted search vendor)? If no, S4 and S5 are out.
- **Q2** May the panel make a throwaway Cloud SQL clone of prd (restored from
  backup, same tier, deleted the same day) for the cold n>=5 benchmark and
  the BYPASSRLS / role-policy test?
- **Q3** Which 10x is planned: one bigger workspace (10x-A), or more
  workspaces (10x-B)? And is a DB tier change acceptable as a separate cost
  line?

## 8. Addendum after r3 (c-371, `70d3386f`)

r3 proved 2.3.1 locally (pg 16.15, synthetic data, n=1, plan shape only). A
NOLOGIN NOBYPASSRLS role with a role-scoped `USING (true)` policy owns the
SECURITY DEFINER function, and the GIN serves `@@` inside it. **S1 needs no
BYPASSRLS.** U10 is now half closed: Cloud SQL still has to show the same
plan (r3's rollout step 0, on dev). r3's catalogue also answers my prd read
4: `bit &` is not LEAKPROOF, so the 0135 fingerprint could never have served
as an index condition either.

I agree with r3's `gin (tenant_id, search_tsv)` via `btree_gin`. It is
exactly what 10x-B needs (1.1). Two catches for spec.md:

1. **CONCURRENTLY cannot run in our migrate path.** `store.Migrate` applies
   every file inside `pgx.BeginFunc` (`grep -n BeginFunc
   csi-spl-api/src/go/spool-hub-api/internal/store/migrate.go` -> 89), and
   `CREATE INDEX CONCURRENTLY` refuses to run in a transaction. 0122 says the
   same ("Inside the migrate transaction (no CONCURRENTLY)"). If the dev write
   stall is too long, the spec needs either a migrate-runner change (a
   per-file no-transaction marker) or a named iac action that builds the
   index outside the runner. Either one is its own task. It is not a flag on
   the migration.
2. **The hub login must never be a member of `spool_search_reader`.** The
   `USING (true)` policy targets that role. A hub login granted it (or able
   to `SET ROLE` to it) would read every tenant's rows directly, outside the
   function. r3's T4 catalogue pin should assert
   `NOT pg_has_role(<hub login>, 'spool_search_reader', 'MEMBER')`, and T5
   should plant that grant once on a throwaway branch.

`btree_gin` must be creatable by the migrate login on Cloud SQL. I believe,
unchecked, that it is a trusted extension (pg 13+), like `unaccent` in 0048.
Rollout step 0 on dev proves it at no extra cost.

## 9. Prd reads (c-001, 2026-10-06T15:32Z, ENV=prd, `do_spl_db_query` as `spool_hub_rt`, hub 2.0.5 `0c9203ca506e`, schema_head 0137, n=1 each)

| read | result | closes |
|---|---|---|
| tier | `db-f1-micro`, ENTERPRISE, POSTGRES_16 | the tier in 1.2 is now measured |
| `shared_buffers` | 16384 x 8 kB = **128 MB** | 1.2 |
| `effective_cache_size` | 49352 x 8 kB = **~386 MB** (the planner's cache estimate; RAM itself is still unchecked) | 1.2: ~1.1 GB at 10x is ~3x what the planner even assumes is cacheable |
| `max_connections` | 25 | matches the owner text |
| `messages`, all 7 tenants | **132 MB, 22 369 rows** (the read ran in the operator scope, which sees every tenant) | 10x-B baseline: t1 is ~84% of the rows |
| roles with `rolbypassrls` | only `cloudsqladmin`, which Cloud SQL owns. `spool_hub`, `spool_hub_rt`, `cloudsqlsuperuser`: all `f` | 2.3.1 on prd: S1 with an owner bypass is impossible. Only S1r (a role-scoped policy) or B remain, as spec v0.4 says |
| `proleakproof` | `ts_match_vq` f, `bitand` f, `biteq` t | prd agrees with r3's local catalogue |

The operator scope is `app.rls_scope = 'operator'` (`grep -n pgScopeOperator
csi-spl-api/src/go/spool-hub-api/internal/store/rls.go` -> 19), a different
setting from `app.tenant_id`. A function pinned to
`NULLIF(current_setting('app.tenant_id', true), '')` therefore returns 0 rows
in the operator scope. Spec v0.4 T1's "scope unset" case covers that, as long
as the operator scope runs in it too.
