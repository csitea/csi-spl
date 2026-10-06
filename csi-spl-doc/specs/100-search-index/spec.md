# 100 Search index: a message search that stays fast as a workspace grows

Version v0.1 (2026-10-06). Draft, doc only, **no consensus yet** (section 12).
Owner order: t1 2b25c535, msg 64a4990e (HUM-10). The lessons it carries come
from t1 6d5bd334. Spec panel: the author holds the pen, plus three reviewers.
**Seat note:** agy has no binary on the box this panel runs on, so a claude
agent (c-372) holds the pen. grok is at its weekly limit, so a claude agent
(c-369) holds the grok seat (r1). r2 (c-370) and r3 (c-371) are claude agents.
Research: `research/` (one file per seat, plus the author's scratch probe).

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`,
`store/` = `csi-spl-api/src/go/spool-hub-api/internal/store/`,
`hub/` = `csi-spl-api/src/go/spool-hub-api/internal/hub/`.

Every number carries **version / tree / n**. Where something is not measured,
the spec says **unmeasured**, **arithmetic** or **unchecked**.

## 1. The ask, in one paragraph

Design a search index that keeps `GET /v1/view/search` inside its 5 s budget
(search-v1 section 5.1) as workspaces grow. Weigh a vector database, an extra
index and an external engine, and recommend one. Answer the owner's five
questions (section 3). The full text is in the topic, and the build starts on
panel consensus.

## 2. What we know

### 2.1 From prd (relayed by c-002, provenance in the topic)

| fact | version / tree / n |
|---|---|
| The GIN on `messages.search_tsv` is never used: `messages` is FORCE RLS (rdb 0014) and `ts_match_vq` is not LEAKPROOF. rdb 0122 dropped it (prd `idx_scan 0`, 12 MB) | prd `pg_stat_user_indexes` since 2026-09-18 (0122 comment) |
| The owner's query: 45.7k buffers, 4.1 s cold / 67 ms warm | c-389, EXPLAIN on prd, n=1 each |
| t1 `messages`: 18 801 rows, 110 MB | prd, n=1 |
| After rdb 0135 (`search_sig`): 3 252 ms -> 126 ms, 40.7k -> 31.6k buffers, still a seq scan of 22k rows | prd, hub 4ff91fbc1, schema 0135, n=2. **AFTER-cold may be partly warm** (it ran right after BEFORE). The ratio is suggested, not demonstrated (r1, challenge 2) |
| One word at a time lets 705 of 3 277 signed rows through; all words together let 29 through | prd via c-001, schema 0135, n=1 |
| A signature on every row: hidden-unread budget 4 435 -> 6 759 buffers | `TestHiddenUnreadBufferBudget`, LOCAL pg16 only |
| Retention is 30 days (`grep -n retention_days csi-spl-cnf/csi-spl/prd.env.yaml` -> 128) | cnf on `ebfe1fbc` |

### 2.2 From the author's scratch probe (this spec)

`research/author-scratch-pg16.md`: PostgreSQL 16.15 in local docker (**not
Cloud SQL**), tree `ebfe1fbc`, 60k synthetic rows, n=1 per plan. It shows
which PLAN Postgres picks, not prd ratios.

| path (run as a non-owner runtime role) | plan | buffers |
|---|---|---|
| today: `search_tsv @@` on FORCE-RLS `messages` | Seq Scan | 1 578 |
| **S1**: SECURITY DEFINER owned by the table owner | seq scan (FORCE binds the owner as well) | 1 704 |
| **S1r**: SECURITY DEFINER owned by a NOLOGIN role that a `TO <role> USING (true)` policy lets through | **GIN** | 77 |
| **S2**: SECURITY DEFINER over a side table with RLS ENABLED, not FORCED | **GIN** | 65 |
| **B**: word table under FORCE RLS, btree `(word, tenant_id, msg_id)` | **Index Only Scan**, exact and prefix | 4 |

On 16.15, `texteq`, `text_lt` and `text_ge` are LEAKPROOF and `ts_match_vq` is
not (`pg_proc.proleakproof`). So a btree on a plain word column CAN serve a
query under FORCE RLS, and an operator on `tsvector` cannot.

**Correction to r1's S1 (research/r1-grok-standin.md section 2.2).** A definer
function owned by `spool_hub` does not get past FORCE RLS. The owner is bound
as well, and the hub runtime `spool_hub_rt` owns nothing since the 017 T029
owner split. S1 works only as **S1r**: a separate NOLOGIN role owns the
function, and one policy lets that role through. S1r needs no BYPASSRLS, which
answers r1's U10 in part. r1 asked for this to be proven on Cloud SQL, and
that check is still open as phase P0 (section 9).

## 3. The owner's questions, answered

### 3.1 Inside Postgres outside RLS, or outside Postgres?

**Inside Postgres, with one audited lift path (S1r).** The index the hub needs
already existed (the GIN that rdb 0122 dropped). The only obstacle is that RLS
will not use it. S1r removes that obstacle for one predicate in one function,
and the hub's statement stays under FORCE RLS for every row it returns.
Everything outside Postgres (sections 4.4 to 4.6) adds a copy of the data, a
sync path and an isolation story that has to be built again from zero.

### 3.2 Exact words or meaning?

**Exact and prefix words only.** The query that failed was an exact title.
The search-v1 grammar (`from:`, `in:`, phrases, `deplo*`) is lexical, and a
vector search answers none of it better than a GIN does.

Semantic search would also cost more than its price tag:

- a vector of 768 float4 is 3 KB per row (arithmetic), the same order as
  today's 5.9 KB average row. That is +56 MB now and +560 MB at 10x-A, on a
  0.6 GB instance (**unchecked** machine size);
- pgvector's distance operators are, I believe, unchecked, no more LEAKPROOF
  than `@@`, so they would need the same lift as S1r;
- every post would go to an embedding provider (owner question Q2).

Cost in section 4.

### 3.3 How does tenant isolation stay provable?

Two doors, each tested on its own (section 6):

1. The function's body pins `tenant_id = NULLIF(current_setting('app.tenant_id', true), '')`.
   It takes **no tenant argument**, and an unset scope returns zero rows.
2. The hub's outer statement reads `messages` under FORCE RLS, exactly as
   today, so any id the function returns for another tenant comes back as no
   row.

A leak needs both doors to fail. The test fails on a leak at door 1 even while
door 2 still hides it (T1).

### 3.4 How do edits, deletes, expiry and archive reach the index, and how fast?

**In the same transaction, so the lag is 0.** S1r indexes the column
`messages.search_tsv` itself, a stored generated column, so:

| event | path (read from code on `ebfe1fbc`) | reaches the index |
|---|---|---|
| post | `INSERT` into `messages` | same statement (GIN fastupdate: the pending list is searched too) |
| edit | `store/message_edit_postgres.go:129` `UPDATE messages SET body` | `search_tsv` regenerates, same statement |
| delete / merge / channel delete | `DELETE FROM messages` (`message_edit_postgres.go:166`, `message_merge_postgres.go:44`, `channels_postgres.go:114`) | same statement |
| expiry | the outer query keeps `m.expires_at > now`; the sweep's `DELETE` (`store/postgres.go:627`) removes the row | at once (filter), then the row |
| archive | `archivedHideSQL` in the outer query, plus `topic_archive_postgres.go:161` | at once (filter) |

S2 would need a trigger plus a cascade for each of these. B would need a
trigger that rewrites one row per word on every edit.

### 3.5 The prd benchmark

Section 8: five queries, cold and warm, n >= 5 each, before and after. The
primary metric is buffers (hit + read). Time is secondary.

## 4. Options compared

"10x" in r1's two shapes (r1 section 1.1). **10x-A**: t1 posts ten times as
much, giving 188k rows and about 1.1 GB. **10x-B**: ten workspaces the size of
t1. All sizes at 10x are linear arithmetic from the prd 1x figures. Every $
figure is **unchecked** unless it is marked otherwise.

| # | option | isolation | sync lag | messages row width | storage now -> 10x-A | $ / month now -> 10x | rare word, cold, 10x-A |
|---|---|---|---|---|---|---|---|
| S0 | 0135 + the 512-char lane (status quo) | unchanged | 0 | +128 B on signed rows | 0 | 0 -> 0 | scan of the whole tenant, ~10x today's buffers (arithmetic). Over budget cold (r1 section 1.2) |
| **S1r** | **GIN on `messages.search_tsv`, read through one definer function owned by NOLOGIN `spool_search_reader`** | 2 doors (3.3); a new role-scoped policy | **0** | unchanged | GIN 12 MB (prd, 0122) -> ~120 MB | ~0 (DB storage; the tier is fixed) | GIN pages + matching rows: grows with log(rows) + hits |
| S2 | side table `message_search` + GIN, RLS not forced | 2 doors; a new table | 0 (trigger) | unchanged | + a copy of `search_tsv` (scratch: side 20 MB for 23 MB of messages) | ~0 | as S1r |
| B | word table under FORCE RLS, btree on `word` | **no lift**: plain RLS + NULLIF policy | 0 (trigger, one row per word) | unchanged | scratch: 2x messages at ~4 words a row; real posts carry far more words: **unmeasured** | ~0 storage, a large write cost | ~4 buffers (scratch); no phrase positions (rechecked on `messages`) |
| S3 | in-process index in the hub | moves into Go code | rebuild on every deploy | n/a | hub RAM | hub CPU is ~80% of ~$60/env (relayed) | n/a |
| S4 | hosted engine | a vendor filter or key | async, seconds | n/a | vendor | a paid tier, tens of $ (**unchecked**) against ~$60/env | n/a |
| S5 | pgvector, semantic | needs S1r's lift as well | an async embedding call | +3 KB a row, or a side table | +56 MB -> +560 MB plus HNSW | an embedding API (**unchecked**, cents) | does not answer exact words |

### 4.1 Why S1r over S2

- Both lift RLS for one function.
- S2 also adds a table, a copy of every word index, and a trigger plus
  cascade for every row event.
- S1r reads the column that already exists and has nothing to keep in sync.

### 4.2 Why S1r over B

- B is the only option with no lift at all, and that is its whole case.
- It pays for it with one row per distinct word per message, rewritten on
  every edit. On real posts that is about 100+ rows a message (**unmeasured**;
  the scratch data has ~4).
- It cannot check a phrase without going back to `messages`.
- B is the fallback if the owner refuses any lift (Q1).

### 4.3 What S0 is now

0135 stays live as the fallback path while the hub probes for the S1r
function, the way `hasSearchSig` probes for the column. It is retired in phase
P5 after the prd benchmark is green.

### 4.4 to 4.6 Out of Postgres

S3 rebuilds from a full read of `messages` on every deploy, which is the scan
this spec removes. It would also lock in `max_instances: 1` (r1 section 4).

S4 and S5 send message text out of the estate (Q2). They make deletes and
expiry an async promise, and S4 doubles the estate's cost or more.

Rejected for now, on the size, data-flow and isolation grounds above, not on
price.

## 5. Recommendation

1. **S1r.** Bring back the GIN on `messages.search_tsv`. Read it only through
   `spool_search_page(...)`, a SECURITY DEFINER SQL function owned by the
   NOLOGIN role `spool_search_reader`, pinned to the session tenant. The hub's
   statement stays under FORCE RLS.
2. **No vector search and no external engine.** Revisit only when the owner
   states a need for search by meaning and says whether text may leave the
   estate.
3. **0135 is a fallback, then removed.** Hold the 512-char lane (Q5). Cost the
   DB tier as its own line item at 10x (Q4).

### 5.1 The function's shape

```sql
spool_search_page(q tsquery, viewer text, viewer_channels text[], public_channels text[],
                  lobby uuid, now timestamptz, after_at timestamptz, after_id text, lim int)
    RETURNS TABLE (msg_id uuid)
    LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public
```

- It applies every door the hub's statement applies today: tenant from the
  session, `expires_at`, the DM / channel read door (rdb 0028) and
  `archivedHideSQL`.
- It returns ids newest first, after the keyset, at most `lim`. Inside it,
  with no RLS barrier, the planner chooses the GIN for a rare word and the
  `messages_received` backward scan for a common one. Today's fast common-word
  path is kept: 8.4 ms on prd (v1.7.5, n=3).
- The hub's outer statement joins the ids to `messages` on
  `(tenant_id, msg_id)` and re-applies every door. A row that the function
  returns and the outer query drops is a bug, and T7 catches it.
- `q` is built in SQL from bind parameters exactly as today. All positive
  text terms are ANDed with `&&`, and `:*` is appended for a prefix. NOT
  terms and non-text operators stay in the outer statement.
- A query with no positive text term (`from:` only) keeps today's path.

### 5.2 Sections

| section | after S1r |
|---|---|
| messages | `spool_search_page` |
| topics | `topicCandidates` takes its task ids from the same function. The per-topic aggregate stays as it is; that is spec 099's topic head, out of scope here |
| relevance sort | ranks the newest 2 000 matches only (`lim` = 2 000) instead of every match, which bounds r1's U4 TOAST reads. A contract change: Q6 |
| files, `has:code` | unchanged, out of scope (r1 U5, U7) |

## 6. Tenant isolation: the tests that must fail on a leak

All on Postgres in `hub-pg.tst.sh`, as the runtime login (not BYPASSRLS).
Seed: tenants A and B, each with a shared word, a word only that tenant has,
and a DM between two other members.

| # | test | fails when |
|---|---|---|
| T1 | `spool_search_page` with scope A returns A's ids only; scope B returns B's only; scope unset or `''` returns 0 rows | the tenant pin is wrong or missing (door 1, on its own) |
| T2 | **control**, on a throwaway branch only (repo CLAUDE.md): delete the pin from the function; T1 must go red | T1 cannot see a leak |
| T3 | catalogue: `spool_search_reader` is NOLOGIN, has no members (`pg_auth_members`), owns exactly one function, holds column SELECT on `messages` only. The function has no tenant parameter, `prosecdef`, and a pinned `search_path` | the role can be logged into, joined or widened |
| T4 | the runtime login cannot `SET ROLE spool_search_reader` and cannot `ALTER` or `CREATE OR REPLACE` the function | the runtime can lift RLS for itself (017 FR-SEC-014 (e)) |
| T5 | `do_spl_db_rls_check`: the SECURITY DEFINER functions the runtime can EXECUTE are exactly `{spool_search_page}`. Any other one reports `liftable` | a second lift path appears unnoticed |
| T6 | `TestCrossTenant*` search cases run on the S1r path (the probe is on) as well as the 0135 path | door 2 regresses |
| T7 | for each seeded query, the function's ids for viewer V equal the hub's result ids (the doors agree) | the function shows the viewer a row the outer statement hides, or the reverse |

## 7. Index freshness

Section 3.4: 0 lag for every event. The GIN pending list (`fastupdate`) is
searched by every scan, so a new post is findable at commit. One unmeasured
cost: the GIN on insert. Locally it was 730 vs 544 ms per 20k inserts (rdb
0122, scratch pg16, n=3, so +34%). That is DB CPU on a fixed tier, so it adds
no $. It must be measured on the prd shape (r1 U8, P4).

## 8. The prd benchmark (owner's question 5)

Run by the orchestrator (c-001), read-only, with `do_spl_search_measure`
(`MEASURE_N=5`), on t1. Same five queries before (0135 path) and after (S1r):

| id | query |
|---|---|
| Q-owner | `Example refactoring prompt (round 4)` |
| Q-common | `example` |
| Q-rare | a word in 1..3 rows of t1, chosen by a read-only count before the run |
| Q-prefix | `refact*` (r1: 0135 never helps a prefix) |
| Q-from | `from:<a t1 member>` with no text (r1 U3; must not regress) |

**Metrics.**
- **Primary:** `shared hit` + `shared read` from `EXPLAIN (ANALYZE, BUFFERS)`.
  It does not depend on the cache or on neighbours, so it is the number that
  carries to 10x.
- Secondary: ms, with `read` and `hit` shown separately.
- A run is "cold" only if its `shared read` is > 0 on `messages` or the GIN,
  and is reported as such. A true cold run n>=5 needs a prd clone (Q3);
  without one, cold is "as found".

**Acceptance.**
- Q-owner, Q-rare and Q-prefix use at most 2 000 buffers, and their p95 is
  under 1 s.
- Q-common and Q-from use no more than 1.2x their BEFORE buffers.
- No 503 in n=5.
- The perf test in CI seeds the query's OWN common words (owner lesson 5).

## 9. Build plan (after consensus; an rdb file needs the owner's go to apply)

| phase | what | where |
|---|---|---|
| P0 | prove the S1r plan on Cloud SQL **dev**. The migration creates the NOLOGIN role (precedent: rdb 0126 creates `spool_public_export` NOLOGIN), hands it the function, and EXPLAIN shows the GIN as the runtime login | the migration from P1, on dev first |
| P1 | rdb 01NN: role, column grant, `CREATE POLICY search_reader_all ON messages TO spool_search_reader USING (true)` (no WITH CHECK, no write grant), `CREATE INDEX messages_search ... USING gin (search_tsv)`, the function. Grant EXECUTE to the runtime in `spool-hub-roles/runtime-grants.sql`. GIN build time on prd 110 MB: **unmeasured** (it holds a SHARE lock on messages); measure on scratch at prd size first | rdb, spool-hub-roles |
| P2 | hub: the function probe, as `hasSearchSig`. Messages section and `topicCandidates` through the function; the 0135 path stays as the fallback | store |
| P3 | T1..T7, plus a buffer-budget test seeded with real-shaped words | store, hub-pg |
| P4 | prd benchmark (section 8), dev then prd, by the orchestrator | read-only |
| P5 | retire 0135: drop the trigger, `search_sig` and `spool_search_sig`, which narrows the long rows by 128 B. Owner go | rdb |

## 10. Unmeasured, and who closes it

| # | gap | closed by |
|---|---|---|
| G1 | S1r's plan on Cloud SQL (16.15 docker only so far) | P0 |
| G2 | GIN build time and lock at prd size | P1, scratch |
| G3 | insert cost with the GIN on the prd shape | P4 |
| G4 | a true cold n>=5 | Q3 |
| G5 | B's real size (words per real post) | only if Q1 = no lift |
| G6 | 10x-B: a GIN on `search_tsv` alone also returns other tenants' matches before the tenant filter. `btree_gin` `(tenant_id, search_tsv)` would avoid it, if Cloud SQL allows the extension (**unchecked**) | P0 |

## 11. Questions for the owner (one list, to c-002)

- **Q1** Is one audited RLS lift acceptable, as spec 022 section 9's D-S1? It
  means a NOLOGIN role, one `USING (true)` policy for it, and one definer
  function. If not: option B, with no lift and a larger write cost.
- **Q2** May message text leave the GCP estate (an embedding provider, a
  hosted engine)? The panel recommends no, so S4 and S5 are out.
- **Q3** May the orchestrator make a throwaway Cloud SQL clone of prd, deleted
  the same day, for a true cold n>=5?
- **Q4** Which 10x is planned (one bigger workspace, or more workspaces)? Is a
  DB tier change acceptable as its own cost line?
- **Q5** Hold the queued 512-char signature lane, since S1r supersedes it?
- **Q6** Relevance sort ranks the newest 2 000 matches: is that acceptable?

## 12. Panel and consensus

| seat | agent | research | position on v0.1 |
|---|---|---|---|
| author (pen) | c-372 (claude for agy) | `research/author-scratch-pg16.md` | S1r |
| r1 (grok seat) | c-369 (claude for grok) | `research/r1-grok-standin.md` | S1, before the S1r correction: pending |
| r2 | c-370 (claude) | pending | pending |
| r3 | c-371 (claude) | pending | pending |

Consensus: **not yet.**

## 13. Changes

- v0.1 (2026-10-06): first draft. Takes in r1 (10x-A / 10x-B, cold as buffers,
  U1..U10, the benchmark's prefix and from: queries). Corrects S1 to S1r from
  the scratch probe.
