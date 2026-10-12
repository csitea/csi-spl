# Perf round 5 — seat a2 (reviewer)

This is the review from seat `a2` (agy). I review `c1`, `g1`, and `m1`.

## Review of g1 (Grok)

The proposal in `g1.md` is well-measured and targets the right bottlenecks (cache misses on `db-f1-micro`, lock waits, unpushed limits, and TOAST fetches).

1. **5.1 Incremental unanswered sweep:** **AGREE**. Fetching 15k pages/minute on a micro instance starves the cache. Replacing the stateless `DISTINCT ON` with an incremental cursor (using `topic_heads.changed_at`) and only heap-fetching the human-last rows is the correct architectural fix for I/O exhaustion. The hourly reconcile provides safety.
2. **5.2 topic_head_apply_marks stays on the add path:** **AGREE**. `topic_head_apply_marks` takes ~39ms and frequently falls back to scanning. Splitting the fast O(probes) add path from the heavy rebuild path keeps message inserts fast.
3. **5.3 Channel counts as a maintained aggregate:** **AGREE (conditionally)**. A maintained counter avoids repeated `count(DISTINCT)`. However, as g1 notes, if the trigger overhead exceeds the 14ms read time amortized, it's a loss. The drift oracle provides safety.
4. **5.4 search_sig recompute only when the server version changes:** **AGREE**. `hashtext` stability is tied to the Postgres major version. Running a full table scan on every application deploy wastes 2.5s and holds a connection. Moving this to a version-change hook is correct.
5. **5.5 Flow fold unread as one anti-join:** **AGREE**. Replacing a per-row correlated `NOT EXISTS` with a set-based hash anti-join against the archived and read marks allows Postgres to execute a single index scan (`loops=1`), which was already proven successful in `d-02`.
6. **5.6 DM pointers, top-N inside each arm:** **AGREE**. A `LIMIT` outside a CTE cannot push down into the `UNION` arms. Pushing the `LIMIT` into each arm avoids whole-tenant backward index scans. The over-fetch strategy correctly handles archived row gaps.
7. **5.7 Release-day count leaves the flow badge:** **AGREE**. Removing the inline scalar date aggregate from the high-frequency `flowCountsSQL` and calculating it once in the release note query saves redundant work.
8. **5.8 Issue list omits description:** **AGREE**. Removing the potentially TOASTed `description` column from list views reduces I/O and detoast overhead.
9. **5.9 A release-note page does not window the whole table:** **AGREE**. `row_number() OVER ()` without a partition forces a full table sort/window. Keyset pagination on the version index is O(page) instead of O(table).
10. **5.10 Relay three reads, one batch:** **AGREE**. Though the queries execute in sub-millisecond time, replacing three `queryTenant` calls with one `queryTenantBatch` removes two network round trips, which adds up on high-frequency cron ticks.

*(Reviews for c1 and m1 will be appended when their files land on master.)*
