# 099 Topic head: panel opinion, seat claude-2 (read performance and plan stability)

Scope: spec v0.1 sections 3.1, 3.2 and 5.2 (plus 5.3 and the 9 risk rows they
touch), read side only. Base tree `ae42081c6` (origin/master on 2026-10-07).
Opinion only: no spec, task or source file is changed.

## 1. Verdict

**Accept with changes.** The head read is an ordered index scan with LIMIT in
every shape, and it returns the walk's rows (all 9 shapes, 20k and 200k
messages). But `Kinds` order breaks the oracle and the shadow compare as
written (F1), and the due-head merge belongs in Go, not in SQL (F2).

## 2. Evidence base (what I ran)

**prd, read only** (`ENV=prd SQL=... ./run -a do_spl_db_query`: operator
scope, a READ ONLY transaction rolled back, 2026-10-07 04:08Z, tenant t1, every
row of `messages`):

| measure | value |
|---|---|
| messages / topics / parts (channel or DM pair per topic) | 19 955 / 1 621 / 1 714 |
| parts per topic: max / p99 / topics with more than one part | 6 / 2 / 69 |
| topics with a DM part / with a channel and a DM part | 994 / 3 |
| lines per topic: max / p50 | 1 052 / 3 |
| distinct parties per part: max / p99; distinct kinds per part: max | 53 / 13; 5 |
| line TTL (`expires_at - received_at`): min / p50 / max | 29 d 03 h / 30 d / 30 d |
| lines expired but not swept / topics with a line expiring in the next 24 h | 0 / 0 |
| DM readers: DM topics HUM-10 is an end of; DM heads walked to fill a 50-row DM page | 587; 281 |
| DM ends in fewer than 50 DM topics (their DM page walks every DM head) | 485 of 489 |
| collation; distinct `task_id`s; places where uuid order and `task_id::text` order disagree | en_US.UTF8 (libc), pg 16.15; 1 871; **0** |

**Local** (postgres:16-alpine in docker; the app role is NOSUPERUSER
NOBYPASSRLS and owns the tables, as in `hub-pg.tst.sh`). Both head tables
were built as in spec 3.1/3.2, plus `dm_a`/`dm_b`, with ENABLE and FORCE RLS
and the two policies of 3.3. Data: `seedTopics(seed 0.42)` with its expired
rows deleted (the after-sweep state), heads backfilled in SQL, then ANALYZE.
Each statement ran through `queryTenantNoJIT`, i.e. under
`pgScopeTenantNoJIT`. The test file was temporary, never committed, and has
been deleted. n=20 per statement per shape, wall time at the client
(planning included), on a box under fleet load. Rows are compared with
`sameRows`. "raw" means `Kinds` is compared as the slice; "multiset" means
`Kinds` is sorted first.

| shape (limit 50) | 20k msgs, 1 666 topics: walk p50 / head p50 | 200k msgs, 16 666 topics: walk p50 / head p50 | raw | multiset |
|---|---|---|---|---|
| all, door off | 29.3 / 14.7 ms | 24.3 / 14.0 ms | differ | **equal** |
| all, reader HUM-1 (in c1) | 67.0 / 12.3 ms | 57.6 / 20.3 ms | differ | **equal** |
| dm=, reader HUM-1 | 65.3 / 14.1 ms | 43.5 / 16.0 ms | differ | **equal** |
| dm=, door off | 21.3 / 8.2 ms | 19.2 / 12.1 ms | differ | **equal** |
| channel=c1, reader HUM-1 | 39.9 / 16.7 ms | 26.6 / 14.6 ms | differ | **equal** |
| dm=, reader AGT-4 | 67.6 / 13.2 ms | 41.6 / 15.2 ms | differ | **equal** |
| agent=AGT-1@box-a | 78.4 / 15.1 ms | 47.4 / 16.7 ms | differ | **equal** |
| all, reader in no topic (0 rows) | 198.5 / 7.3 ms | **3 063 / 41.6 ms** | equal | equal |
| dm=, reader in no DM (0 rows) | 89.2 / 5.3 ms | **977 / 22.4 ms** | equal | equal |

Plan of the head read (20k, all, reader HUM-1, `EXPLAIN (ANALYZE, BUFFERS)`
under the same settings): `Limit` -> `Nested Loop Semi Join` ->
`Index Scan using topic_heads_last` (rows=219), plus a part probe on
`topic_head_parts_pkey` per head (loops=219). The page is done at 1.9 ms.
Execution takes 6.8 ms and planning 2.1 ms. The rest of the time is four
per-topic LATERAL reads of the parts (F8), and one top `Sort` of 50 rows
caused by my `MATERIALIZED` CTE. dm= takes `topic_heads_dm` (rows=169 for 50).
No Seq Scan, no Bitmap, no per-row sort over the tenant. The RLS policies
(two permissive, ORed) appear as a Filter, never as an Index Cond. So each
part probe is indexed only because it carries its own `tenant_id = $1`.

## 3. Findings (most severe first)

**F1. `Kinds` order: the oracle and the shadow both fail on every multi-kind
topic (spec 2, 5.1, 7.1).** Spec 2 says "order does not matter" because the
hub counts kinds (`hub/view.go:866`). But `TopicRow.Kinds` is "one per
message, oldest first" (`store/view.go:72`). `sameRows` compares
`fmt.Sprint(x.Kinds)` (`store/view_topics_test.go:141`), and the harness
compares `sameRows(head, walk)` (`topic_head_harness_test.go:495`). A head
holds `{kind: n}`, so it cannot rebuild line order. Measured above: 7 of 7
shapes with rows differ raw and are equal as a multiset. Spec 5.1's "compare
the rows' md5" would log a `topic_head_mismatch` on nearly every sampled
request, so Q3's "0 mismatches" could never pass. **Change for v1.0:** make
the contract counts. `TopicRow.Kinds` becomes `map[string]int`: the walk emits
`jsonb_object_agg(kind, n)` and the head emits the summed part counts. The
hub's `topicView` copies the map as it is, and the hub JSON stays
byte-identical (`kinds` is already a map). `sameRows` compares the maps.
Shadow compares the hub's JSON bytes for the row (the invariant tasks.md
already states), never the `TopicRow` md5. This can land first, walk-only (a
new T005a).

**F2. Due heads: run them as a second statement and merge in Go, not inside
the SQL (spec 5.3).** If due rows are merged in one statement, the walk key
of every due topic must be computed and the result sorted. A UNION plus
`ORDER BY` needs a Sort node, and `enable_sort = off` gives that Sort
`disable_cost`, which distorts the rest of the plan. **Change:** keep the
batch to one round trip with two statements:

- (a) The head walk, with `valid_until > $now` and `LIMIT n`.
- (b) Today's `listed()` + `summary()` (the `TaskIDs` path, which already
  applies every filter and the `before=` cursor). Its id source is
  `SELECT task_id FROM topic_heads WHERE tenant_id = $1 AND valid_until <= $now`
  instead of `unnest($n::uuid[])`.

Go then merges (a) and (b) by `(k DESC, task_id DESC)` and cuts at n. This
reuses tested code, needs no new SQL for the exact path, and costs nothing
when (b) is empty. For `channel=`, use the PART's `valid_until`: a line that
expired in another channel does not touch that list, so fewer heads are due.
Size: the TTL is a flat ~30 d and t1 takes ~690 lines a day
(19 955 / 29 d), so I estimate, unchecked, at most ~5 due topics in a 10-min
sweep window. **Today the branch has never run on prd**: 0 lines expire within
a day, so E20..E23 are its only proof until the data is ~29 days old. T009
must count the due set over a full day, not once.

**F3. A selective filter makes the head walk O(topics), not O(page) (spec
5.2, every shape).** The ordered scan stops at LIMIT only once enough heads
pass the door / agent= / viewer= / parent= / NoIssues EXISTS. On prd, 485 of
489 DM ends are in fewer than 50 DM topics, so their DM page walks all 994 DM
heads. Locally, a reader with no match reads every head: 41.6 ms at 16 666
topics, about 2.5 µs a head, against 3.06 s for today's walk. This is the
right trade for phase 1 (a 70x gain in the worst case, and linear in topics,
not messages). **Change:** v1.0 should state the bound ("worst page = one
pass over the tenant's heads"). T008 should add a worst-reader statement
(`walk_dm_head` for a reader in no DM). A per-end index
(`topic_head_ends (tenant_id, end_id, dm_last_at DESC, task_id DESC)`, one row
per DM end per topic) is a later option, used only if prd p95 asks for it.
Not in 0138.

**F4. `parent=` (and later `agent=`) wants "few rows by an index, then a small
sort", and `enable_sort = off` forbids that (spec 5.2, 9 "bad plan" row).**
Today `pgScopeTenantNoJIT` turns sort and bitmap scans off. The reason is the
recursive walk: a misestimate there is paid per step, up to 50 times
(`view_postgres.go:125-162`). The head read is not recursive, so a misestimate
costs at most one pass over the heads (F3). **Change:** add a partial index
`topic_head_parts (tenant_id, first_parent) WHERE first_parent IS NOT NULL`.
Give the head read its own batch header: tenant, `jit off`,
`plan_cache_mode = force_custom_plan`, and `enable_sort` LEFT ON. T005 then
A/Bs both headers per shape, n=20, at 20k and 200k. Unchecked: I did not run
parent= or the headers with sort on.

**F5. E28: the uuid indexes are right, but the SQL must order by the uuid
(spec 3.1, 9 tie-break row).** On prd, uuid order equals `task_id::text`
order: en_US.UTF8, n=1 871, 0 disagreements. That is expected: 32 lowercase
hex digits, dashes at fixed places, digits before a-f. **Change:** keep
`(…, task_id DESC)` on uuid, and write `ORDER BY k DESC, task_id DESC` (the
uuid; `::text` costs an Incremental Sort). Keep the cursor as today: `k <= $at`
as the index condition, plus `(k, task_id::text) < ($at, $task)` as a Filter.
A non-canonical `before` task id then never reaches a `::uuid` cast. Add one
test: the order-equality query on the test DB, plus the edge ids `0…`, `9…`,
`a…`, `f…`. Close the risk row.

**F6. Parties as `{"id@box": n}` makes "any box" a key-prefix scan (spec 3.2,
5.2 agent=/viewer=).** `viewer=` and agent without a box need "some key
`id@*`". `LIKE id || '@%'` treats `_` and `%` in an id as wildcards, and
`split_part(k, '@', 1)` breaks on an id containing `@` (I believe, unchecked,
that ids are `[A-Za-z0-9-]`, but no constraint says so). **Change:** nest as
`{id: {box: n}}`, so that viewer is `parties ? $id` and agent+box is
`parties -> $id ? $box`, both O(1) on a jsonb of at most 53 keys (prd). The
summary flattens the keys to `id || '@' || box`, `DISTINCT … ORDER BY`, under
the same collation as today's `array_agg(DISTINCT p ORDER BY p)`.

**F7. The door needs a DM part's two ends as columns, not inside `part` (spec
3.2).** **Change:** `dm_a`, `dm_b text NULL` (lesser and greater id),
CHECK `(channel IS NULL) = (dm_a IS NOT NULL)`. The door is then
`channel = ANY(pub) OR channel = ANY(mine) OR (channel IS NULL AND (dm_a = $r OR dm_b = $r))`,
one indexed probe per head (measured above). The per-line door equals the
per-part door because a part's channel and ends are fixed. Keep the `part`
text as the PK.

**F8. Read the parts once per topic (spec 5.2 summary).** My sketch used four
LATERALs (count, kinds, parties, first), each re-reading the topic's parts:
4 x 50 index probes, about 5 of the 6.8 ms. **Change:** one LATERAL over the
topic's parts in the message filters and the door, computing all four in one
pass (`sum(n)`, a `jsonb_each` sum over `array_agg(kinds)`, the flattened
parties, and `first_*` by `(first_at, first_msg_id::text)`). Do not
`MATERIALIZED` the walk CTE, so the outer query keeps its order. Estimate
(unchecked): about 3 ms execution for a 50-row page.

**F9. jsonb vs normalized counters: jsonb (spec 3.2).** prd: 1.06 parts a
topic, at most 5 kinds and 53 parties per part, so the jsonb stays small and
inline (I believe under the 2 kB TOAST threshold, unchecked). The parties
aggregate costs about 0.02 ms a topic locally. A normalized
`(…, party, n)` table pays off only if agent= becomes a driving index (F3/F4),
and today it is not. Write side, noted only: every insert moves the indexed
`last_at`, so head and part updates are never HOT and touch 3 + 1 indexes.
At ~690 inserts a day on t1 this is not a cost; 7.5 measures it.

**F10. The channel list must probe the topic row (spec 5.2).** The walk runs
on `topic_head_parts_ch`, but the archived hide is topic-level. **Change:**
add a PK probe of `topic_heads` per walked part (`card_archived`,
`archived_rows`, lobby). This is cheap, measured in the channel shape above.

## 4. Owner questions (spec section 10)

| # | answer | why |
|---|---|---|
| Q1 triggers | agree | Neutral for the read. 0103 shows the shape works here. |
| Q2 exact | agree, built as F2 | The exact path is today's tested `listed()`; it costs nothing when nothing is due. |
| Q3 shadow | agree, with **change** | Compare the hub JSON (F1). Sample **1 in 1** for the 24 h, not 1 in 10: at ~1 270 topic lists a day (n=446 in 8.4 h), 1 in 10 compares only ~127. The head read adds ~7 ms to a request that already pays the walk. State n compared. |
| Q4 prd go after dev | agree | |
| Q5 TaskIDs stays | agree | It is already one probe per topic, and F2 reuses it for due heads. |
| Q6 < 5 ms p95 added | agree | Inserts are ~690 a day on t1, so the budget guards latency, not throughput. |
| Q7 drop ap-03 / ap-09 | agree, once `on` | Keep them parked (not deleted) until `on` holds 24 h, because `off` is rollback level 1. |
| Q8 daily verify | agree | |

## 5. tasks.md: add, split, reorder

1. **New T005a (first, needs no head): `Kinds` as counts.** This covers
   `TopicRow`, `summary()`, the hub's `topicView`, `sameRows`, and the memory
   store. Proof: hub JSON byte-identical (the existing hub view tests). It
   unblocks F1 for T005 and the shadow.
2. **T001 text:** "and `oracleTopicsSQL`" becomes "and `refTopicsSQL`"
   (test-results 1.2 item 1 already says so).
3. **T002:** add `dm_a`/`dm_b` (F7), nested parties (F6), the `first_parent`
   partial index (F4), and a part-level `valid_until` (F2).
4. **T005:** the due branch as F2 (two statements, Go merge); one LATERAL (F8);
   the head read's own batch header with an n=20 A/B of `enable_sort` per
   shape at 20k and 200k (F4); order by uuid (F5); and a uuid-vs-text order
   test (F5).
5. **T008:** add a worst-reader statement (a reader in no DM) and a
   `parent=` statement beside `walk_dm_head` / `walk_all_head` (F3, F4).
6. **T009:** count the due set across a full day (hourly), not once; report
   the worst-reader p95 next to HUM-10's.
