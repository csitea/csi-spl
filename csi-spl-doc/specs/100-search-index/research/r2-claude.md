# 100 search index: reviewer r2 (claude, c-370)

Seat brief: the prd numbers (each with version / tree / n), the existing code
paths (rdb 0135 `search_sig`, the search queries), and the correctness of every
option.

Tree: `origin/master` at `6f128452` (code read there), after r1 (`ebfe1fbc`)
and r3 (`70d3386f`). Option labels follow r1 (S0..S5) and r3 (**A** = side
term table). Every claim is tagged **prd** (with its source), **local** (my
docker run, stated), **code** (file:line on that tree), **arithmetic** or
**unchecked**.

**Position: S1, with r1 and r3**, with the acceptance criteria of 3.3. Section 3.6
corrects one claim both notes make about pgvector.

## 1. The prd numbers and what each one proves

### 1.1 Relayed from t1 6d5bd334 (c-002, msg 565fff2e; all prd reads by c-001)

| # | claim | version / tree | n | status |
|---|---|---|---|---|
| P1 | 2 x 503 `search_budget`, hub dur 2018 / 2029 ms (budget then 2 s) | hub v1.7.5, Cloud Run log | 2 | demonstrated: the budget fired |
| P2 | msg_common 8.4 ms, msg_rare 4133.9 ms, msg_prefix_rare 65.8 ms; plan Index Scan Backward on `messages_received`, text as Filter | hub v1.7.5, schema pre-0135, `do_spl_search_measure` | 3 | demonstrated |
| P3 | t1 18,801 rows, 110 MB | `do_spl_db_query` 11:0xZ | 1 | a count, n=1 is enough |
| P4 | owner query 45.7k buffers, 4.1 s cold / 67 ms warm | Cloud SQL log + EXPLAIN | 1 each | suggested: one cold sample |
| P5 | BEFORE 3,252 ms cold / 132 warm -> AFTER 126 cold / 107 warm; 40.7k -> 31.6k buffers | hub 4ff91fbc1, schema 0135 | 2 each | **buffers demonstrated, ms ratio suggested**: AFTER-cold ran right after BEFORE (r1 challenge 2 agrees) |
| P6 | 3,275 / 3,275 long rows signed | prd 12:4xZ | 1 | a count |
| P7 | buckets <1024 chars 6,528 + 4,128 + 5,037 unsigned; 1024+ buckets 1,882 / 858 / 537; `pass_example_bit` 260 / 188 / 257; `pass_all_bits` 3 / 1 / 25 | proof2 12:48:54Z | 1 | a count |
| P8 | per-term check passes 705 of 3,277, all-words check 29 | schema 0135 | 1 | a count |

Not prd, and must not be quoted as prd: the 511 vs 6,784 buffers (local pg16),
the md5-seed 17x (local), the 4,435 -> 6,759 buffer budget
(`TestHiddenUnreadBufferBudget`, local). Dev, not prd: r3's lexeme counts
(dev t1 13,026 messages, 1,018,536 lexemes, avg 78 / max 1,021; dev hub 2.0.5,
0c9203ca, schema 0137, n=1).

### 1.2 What the plan shape in P2 means (code + prd plan)

The message section is `ORDER BY m.received_at DESC ... LIMIT n`
(`search_postgres.go:335,355`), served by `messages_received (tenant_id,
received_at)` (rdb 0022:17) walked backwards with the text match as a Filter.
The scan **stops when the page fills**. So the cost is the inverse of the
match rate: a common word fills 21 rows in the newest few hundred (8.4 ms, P2),
and a rare or absent word walks the whole tenant (4.1 s cold, P2/P4). The
slow query is the one that matches least. The benchmark has to include a
**zero-hit** word, because that is the true worst case. The owner's query
is close to it (29 candidates, P8).

### 1.3 Requested from c-001, pending (msg 575f8c4d on this task)

| # | read | what it settles |
|---|---|---|
| R1 | `version()`, `rolbypassrls` of the hub login, db collation, `shared_buffers`, `gin_pending_list_limit`, `proleakproof` of `ts_match_vq` / `texteq` / `text_lt` / `text_ge`, available `vector` / `pg_trgm` / `btree_gin` | whether section 3's local proofs hold on Cloud SQL itself (also r3's open `btree_gin` check) |
| R2 | `messages` relpages, heap / TOAST / index size | the 10x baseline (0135 quotes heap 4,443 pages, n=3) |
| R3 | per tenant: rows, `sum(length(search_tsv))`, avg / max lexemes, long-row avg | replaces the dev-average arithmetic in r3 section 3 with prd |

They land here as a revision when c-001 answers. The position does not wait on
them.

## 2. The existing code paths, and whether each is correct

### 2.1 rdb 0135 `search_sig` (file `0135_messages_search_sig.sql`, commit 0940e8ecc)

1. **No false negatives, as written.** The trigger signs
   `to_tsvector('spool_search', NEW.body)`. That is the same expression as the
   stored `search_tsv` (rdb 0048:40). The backfill signs the stored
   `search_tsv` (`postgres.go:651`). Both give the same lexeme set, so the
   bits agree. The query mask is `spool_search_sig(to_tsvector(config,
   value))` (`search_postgres.go:102,136`). `plainto_tsquery` and
   `phraseto_tsquery` produce the same lexemes for the same config, so every
   lexeme the tsquery needs has its bit in the mask. Verdict: correct.
2. **Negation and OR are safe.** `textMatch` returns `false` only when `@@`
   would be false, so `NOT COALESCE(...)` stays exact (`:46-48,103`).
   `sigAll` walks only AND chains from the root and skips `Not` and `Or`
   (`:121-131`), so it never requires a word the row may lack. Prefix terms
   (non-phrase) are excluded from both (`:99,128`). A value with no lexemes
   gives a zero mask, and a zero mask passes every row. Verdict: correct.
3. **Edit path.** `BEFORE INSERT OR UPDATE OF body` re-signs, and a body
   shrunk under 1024 chars goes back to NULL (a candidate). The backfill
   `UPDATE ... SET search_sig` does not fire it (not `OF body`). Verdict:
   correct.
4. **Fill rate limits it, by arithmetic.** One hash per lexeme into 1024 bits:
   the share of bits set is `1 - e^(-n/1024)` for n distinct lexemes, so
   7.3% at the dev average of 78, 25.4% at 300, 62.3% at the dev max of
   1,021. A one-word query passes about that share of non-matching rows. P7
   fits this: the longest bucket passes the all-words check 25 of 537 times,
   against 3 of 1,882 in the shortest. The fingerprint thins out exactly on
   the long posts it is meant for.
5. **Silent-wrong risks (unchecked, no incident).** (a) `hashtext` is not
   documented as stable across Postgres major versions. A Cloud SQL major
   upgrade that changes it would turn stored bits into **false negatives**:
   rows silently missing, with no error. (b) A change to the `spool_search`
   config (unaccent rules) does not regenerate stored columns. Today that
   already skews `@@`, and the fingerprint would skew with it. As long as 0135
   stays as the fallback, one invariant query catches both, and belongs in the
   post-migrate / post-upgrade checks:
   `SELECT count(*) FROM messages WHERE search_sig IS NOT NULL AND search_sig <> spool_search_sig(search_tsv)` -> must be 0.
6. **Cost it cannot remove.** It is still the whole-tenant walk of 1.2. At 10x
   rows the heap is 10x, with or without the bits (r1 1.2).

### 2.2 Message section `searchMessagesSQL` (`search_postgres.go:319-357`)

- The text match and the fingerprint run row by row as Filters (1.2).
- Archive is `NOT EXISTS` on the same table at read time
  (`topic_archive_postgres.go:353-358`). Expiry is `m.expires_at > $now`
  (`:354`). Both are **read-time predicates**. Any option that keeps the final
  statement in Postgres gets archive and expiry with 0 lag, for free.
- Relevance sort runs `ts_rank_cd(m.search_tsv, ...)` on every match plus
  `OFFSET` paging (`:345-347`). That is a TOAST read per match before the
  LIMIT, so a common word with `sort=relevance` reads every matching long row,
  with or without S1. Unmeasured. Add it to the benchmark.

### 2.3 Topic section `SearchTopics` (`:411-463`)

- `live` reads `body` and `msg` of every row of the scoped tasks, and `t`
  does `array_agg(body ORDER BY ...)` (`:434-445`). An array cannot hold a
  TOAST pointer, so **`array_agg` detoasts every body it aggregates** to build
  the title. With a text term, `topicCandidates` narrows this to the tasks
  with a matching row (`:473-499`), but still to **all** rows of those tasks.
  Without one (`from:` only, OR, `-word`), it aggregates every live message
  of the tenant. No index option fixes this by itself; it is a title-column
  problem. Read from code, unmeasured. r1's U1 lists the symptom, and this is
  the mechanism.

### 2.4 Files section `SearchFiles` (`:359-409`)

- Text is `strpos` on the folded file name inside `files` jsonb, with no
  index and no fingerprint. It does not read `search_tsv`, so it is outside
  this spec, but it is the same whole-tenant walk. Unmeasured.

### 2.5 The budget is per statement, not per request (`hub/search.go:29,135,212-227`)

`statement_timeout` = 5 s per section statement. The sections (messages,
files, topics) run **in sequence** under one request context of budget + 1 s
= 6 s. A search that spends 3 s in each of two sections returns 503 with
neither statement past 5 s. The spec's "5 s budget" and its benchmark should
both be **per request** (`/v1/view/search`), not per statement.

## 3. Correctness of every option

Proofs marked local ran on `postgres:16-alpine` (16.15, `en_US.utf8`) and
`pgvector/pgvector:pg16` (vector 0.8.7) in throwaway docker, with policies
shaped like rdb 0014 (`tenant_scope` + `operator_scope`), FORCE RLS, a
non-bypass login, 60k rows / 3 tenants (30k for vector). They show **plan
shape**, n=1 each, and say nothing about Cloud SQL until R1 is back.

### 3.1 The rule, measured (local; agrees with r3 1)

| operator | function | LEAKPROOF (pg16) | index usable under FORCE RLS |
|---|---|---|---|
| tsvector `@@` | `ts_match_vq` | f | **no**: Bitmap on the pkey (tenant only), `@@` as Filter, GIN unused |
| text `=` | `texteq` | t | **yes**: Index Only Scan, `lexeme = ...` in Index Cond |
| text `<` / `>=` | `text_lt` / `text_ge` | t | **yes**: prefix as a range, both bounds in Index Cond |
| text `^@` | `starts_with` | t | no index use under `en_US.utf8`; use the range form |
| bit `&` | `bitand` | f | n/a (0135 filters only) |
| array `&&` / `@>` | `arrayoverlap` / `arraycontains` | f | no |
| vector `<->` `<=>` `<#>` | `l2_distance` ... | f | as WHERE: **no**; as `ORDER BY ... LIMIT`: **yes** (3.6) |

### 3.2 S0: 0135 + the 512-char lane

Correct (2.1). Fails 10x by construction (r1 1.2). Keep it as the fallback
whatever wins, behind its catalogue probe (`hasSearchSig`, `:294-300`).

### 3.3 S1: GIN on `search_tsv` read through one SECURITY DEFINER function

**Precondition: proven local, twice, independently.** r3 (1.2) and I (same
day, separate containers, n=1 each) got the same result. No BYPASSRLS is
needed. A NOLOGIN role `spool_search_reader` with `CREATE POLICY ... TO
spool_search_reader USING (true)` and `GRANT SELECT` owns a `LANGUAGE sql
STABLE SECURITY DEFINER` function whose body pins `tenant_id =
NULLIF(current_setting('app.tenant_id', true), '')`. The plan inside it is a
Bitmap Index Scan on the GIN with `@@` in Index Cond. Called by the hub-shaped
role, it returns only the scoped tenant's ids, and with an empty scope it
returns 0. On Cloud SQL, unchecked: whether the migration user can `ALTER
FUNCTION ... OWNER TO spool_search_reader` (pg16 needs it to hold that role's
membership). Prove it on **dev** before prd (r3 step 0).

Correctness conditions the spec must write as acceptance criteria:
1. **Isolation lives in one WHERE.** `USING (true)` makes that role see every
   tenant. The function body's tenant pin is then the only tenant check inside
   the privileged surface, and the outer statement's RLS is the second (r1
   2.2, r3 1.2). The hub login must **not** be a member of
   `spool_search_reader`, or it could `SET ROLE` and read every tenant. Gate,
   as a test: `pg_has_role(<hub login>, 'spool_search_reader', 'MEMBER')` is
   false.
2. **Candidates only for positive AND'ed text terms**, the same walk as
   `sigAll` (2.1.2). For OR / NOT-only queries the outer statement keeps
   today's path. A candidate set never replaces `cond()`. The outer `@@`
   stays, so phrase positions (the GIN stores none, rechecked on the
   candidates only) and the `COALESCE` / `NOT` semantics stay exact. Prefix
   terms CAN use it (`'deplo':*` is a GIN prefix scan), which fixes the one
   query class 0135 never helped (`:99`).
3. **Fresh in the same transaction.** With GIN `fastupdate` the new entries go
   to the pending list, which every scan reads, so inserts and edits are
   visible at commit. Deletes and expiry leave dead GIN entries until vacuum.
   The heap recheck and the outer `expires_at` drop them. Lag 0 (agrees with
   r1). A large pending list slows scans until autovacuum merges it: worth
   one line in r3's ops checks (`gin_pending_list_limit`, R1).
4. **Declare `ROWS`** on the SETOF function (default estimate 1000), or the
   outer plan is guessed. SECURITY DEFINER is never inlined, which is
   intended: inlining would bring back the caller's RLS.
5. **r3's `(tenant_id, search_tsv)` GIN via `btree_gin`** keeps a common word
   from paying for other tenants' postings. It is a cost fix, not a
   correctness one: the pin in the WHERE is what isolates either way.
6. **Owner question, not a reviewer's.** This adds the first policy that
   deliberately lets a role see all tenants. Constraint 6 says "tenant
   isolation is by RLS". S1 makes one function an exception to that, and only
   the owner can accept it.

Verdict: correct if 1-4 hold.

### 3.4 S2: side table + GIN

A side table that carries the owner-required RLS policy has **the same problem
as `messages`**: its `@@` cannot use its GIN (3.1). So S2 helps only when it is
read through S1's definer and role, and then it is S1 plus a sync path and a
second copy of the tsvector. Verdict: correct if built, dominated by S1. Drop it.

### 3.5 A: side term table, btree, RLS-native (r3's fallback)

Agree with r3 1.1. I proved it separately (local, n=1): `lexeme =` and a
prefix range run as Index Cond under FORCE RLS. Correctness conditions r3
does not state:
1. **The term column must be `COLLATE "C"`.** Under a linguistic collation
   (my container was `en_US.utf8`; prd's is pending, R1) a `[p, p_next)`
   range is not guaranteed to be exactly the strings that start with p,
   because the collation orders by more than bytes. In C collation it is
   exact.
2. **Computing `p_next`** (increment the last character) is wrong for a
   prefix ending in the highest code point. Use `term >= p AND term < p ||
   chr(1114111)` or handle that case.
3. **Edits** must delete and re-insert the message's terms in the body-edit
   trigger. A delete needs `ON DELETE CASCADE` (or the trigger). Expiry and
   archive stay read-time in the outer statement.

Verdict: correct with 1-3, and isolation needs no exception. The price is
r3's (1.4x `messages` now, ~1.5 GB at 10x-A). It is the right fallback.

### 3.6 S5 / C: pgvector (corrects r1 3 and r3 2)

Both notes say pgvector "needs S1's bypass first" because `<=>` is not
LEAKPROOF. **Measured local (vector 0.8.7, n=1): that is only half true.**
The operators are not LEAKPROOF (`l2_distance`, `cosine_distance`,
`vector_negative_inner_product`: all `f`), so a distance threshold in WHERE
cannot use HNSW under RLS (Bitmap on the pkey, distance as Filter). But
`ORDER BY emb <-> $q LIMIT 10` **did** use the HNSW index under FORCE RLS
(Index Scan using `e_hnsw`, `Order By: emb <-> ...`), because an ORDER BY is
not a qual. The tenant check then runs as a Filter **after** the index. HNSW
hands back `hnsw.ef_search` (default 40) candidates from all tenants, and the
filter keeps only the caller's share, so with many tenants a page comes back
short or empty: a **recall** bug, not a leak. pgvector 0.8's
`hnsw.iterative_scan` exists for this; unmeasured here.

This does not change the verdict. KNN always returns the nearest rows, even
when nothing matches, and has no notion of a phrase, a negation or an exact
word. It cannot answer the owner's failing query (an exact title) more
correctly than `@@`, it would change the search-v1 contract (which promises
matches), and data leaves the estate for embedding. Reject, as r1 and r3 do.
The corrected reason is semantics plus recall, not leakproofness.

### 3.7 S3 in-process and S4 hosted engine

Both move the index out of RLS, so isolation becomes application code. Both
are correct only under one pattern, which the spec should make mandatory for
any index outside Postgres: **the index proposes, Postgres disposes.** The
engine returns candidate `msg_id`s for the session tenant. The final statement
is today's, under RLS, with `cond()`, the privacy door, expiry and archive.

Then:
- a leak in the engine can surface no row, because RLS refilters;
- a stale engine (lagging insert or edit) gives **false negatives only**,
  never a deleted, expired or archived row;
- edits, deletes and expiry need no engine-side delete to be correct, only
  for size.

What remains: lag on insert and edit, rebuild per deploy (r1 4), and for S4
data leaving the estate plus r3's 30 mutating statements to sync. Verdict:
correct with the pattern. Rejected on cost and lag, as r1 and r3 do.

## 4. The isolation test that fails on a cross-workspace leak

Whatever is built, one store test on Postgres (not the memory store), in the
existing pg16 harness:

1. Two tenants, each with a message containing the same unique word, plus one
   word that **only** tenant B has.
2. As the hub login with scope A: search the shared word, which must return
   exactly A's id. Search B's private word, which must return 0 rows **and**
   the candidate function itself must return 0 ids (not only the outer
   statement). That catches a leak inside the privileged surface before RLS
   hides it (r3's existence oracle).
3. Scope empty (`app.tenant_id = ''`) and scope unset: 0 ids (NULLIF).
4. `pg_has_role(current_user, 'spool_search_reader', 'MEMBER')` is false.
5. **Control (must fail):** a variant of the function without the tenant
   pin, installed in the test schema, must make step 2 fail. A test that
   cannot fail proves nothing.

## 5. Position

**S1, with 3.3.1-3.3.5 as acceptance criteria, and 3.3.6 as an owner
question.** S0 stays as the fallback behind its probe. A is plan B if the owner
refuses an all-tenant role or dev Cloud SQL refuses the ownership transfer. No
pgvector. S3 and S4 only under the 3.7 pattern, and not now.

Also in this spec, separate from the index: the topic section's
`array_agg(body)` (2.3) and the per-request budget (2.5). S1 fixes neither.

### 5.1 Benchmark set (the owner's list, plus the worst cases the code shows)

On prd, read-only via c-001, per request and per statement, report `shared
read` / `shared hit` blocks (not only ms, r1 challenge 2), n >= 5 each: owner
query; one common word; one rare word; **one zero-hit word** (1.2); one prefix
term (bypasses 0135, `:99`); `from:` only (topic section, no candidates, 2.3);
the common word with `sort=relevance` (2.2). "Cold" on Cloud SQL cannot be
forced (no cache drop), so report the first sample after an idle gap
separately from the rest, and say which it is.

### 5.2 Question for the owner (to c-002 as one list, via the author)

1. S1 needs one Postgres role with `USING (true)` on `messages`, reachable only
   through one SECURITY DEFINER function that pins the session tenant. Is that
   exception to "isolation is by RLS" acceptable? If not, A (RLS-native, ~5x
   the GIN's size per r3) is the alternative.
