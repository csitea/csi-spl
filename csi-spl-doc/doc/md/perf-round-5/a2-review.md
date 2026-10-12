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

## Review of m1 (Mistral)

The proposal in `m1.md` correctly maps empirical evidence (Insights, route logs, and network dev logs) to architectural and design patterns.

1. **1. Flow counts: Seek on stored place/time:** **AGREE**. Applying CQRS and Covering Indexes converts an O(all events) scan into O(unread) by seeking on `place_key` and `cov_at`.
2. **2. Channel list: Filter archived lines by mark:** **AGREE**. Lazy Loading the archived lines only when a mark is missing stops unnecessary index/heap expansion for users who have read everything, yielding a solid measured gain (26ms to ~2ms).
3. **3. Messages autovacuum: Tune for index-only scans:** **AGREE**. Tuning the autovacuum insert scale factor/threshold ensures the visibility map is current, making index-only scans effective without falling back to heap fetches.
4. **4. Topic walk: Server-maintained topic summary:** **AGREE**. The Materialized Views approach (keeping a topic head row) drastically reduces the walk work.
5. **5. WUI: Fix channels GET per PUT (echo fix):** **AGREE**. Fixing idempotency on timestamp echoes is a direct logic win that prevents redundant `GET` requests per `PUT`.
6. **6. Message insert: Batch Flow event updates:** **AGREE**. Batch Processing the updates directly in the `WITH ins AS (INSERT ...)` CTE effectively reduces latency and WAL footprint.
7. **7. WS compression: Permessage-deflate:** **AGREE**. Enabling compression is an easy win, reducing WebSocket frame sizes substantially (707 B to ~166 B).
8. **8. Reconnect: Delta catch-up (`since=<cursor>`):** **AGREE**. Implementing Delta Sync for reconnects avoids ~44 KB per tab of redundant data transfer.
9. **9. Flow counts: Scope to tenant (JIT/generic plan):** **AGREE**. Query Plan Caching is aided by scoping to the tenant, preventing suboptimal generic plans or JIT overhead.
10. **10. Topic walk: Split archived OR into two probes:** **AGREE**. Splitting the `OR` condition into two `NOT EXISTS` probes resolves the planner's inability to use indexes on the `OR`, effectively avoiding the N+1 issue.

## Review of c1 (Claude)

The proposal in `c1.md` is highly data-driven, carefully tying practices to measured costs from `pg_stat_statements` under production bounds.

1. **4.1 Relay tick: each sweep at the cadence of its deadline:** **AGREE**. Polling every 5s for 120s deadlines oversamples and wastes pool slots. Aligning the poll cadence to the deadlines and batching reads per tenant effectively drops statements from 1.24M to ~0.25M per day, saving ~45s/day without affecting the user experience.
2. **4.2 Unanswered sweep reads changed topics only:** **AGREE**. Replacing a stateless `DISTINCT ON` with an incremental read of topics whose heads moved since the last sweep avoids massive cache misses (saving ~293s/day). The hourly full reconcile mitigates any expiry edge cases.
3. **4.3 `topic_head_apply_marks` keeps the add path O(probes):** **AGREE**. Segregating the fast incremental add path from the heavy rebuild path removes the ~39ms overhead per apply on the insert path.
4. **4.4 Channel GET: make the existing 304 gate reachable:** **AGREE**. Making the `If-None-Match` gate reachable by omitting the high-churn `deliveries` table from the view's stamp is a brilliant conditional read optimization. It avoids the ~126s/day cost of 6,840 GETs without the write-path penalty of building a counter.
5. **4.5 `search_sig` full compare off the per-deploy path:** **AGREE**. Shifting the 2.4s table scan from application deploy to Postgres version changes removes a severe connection pool stall.
6. **4.6 Flow fold: one anti-join:** **AGREE**. A set-based anti-join avoids the N+1 correlated `EXISTS` overhead that currently takes ~598ms on average.
7. **4.7 DM pointers: top-N per arm:** **AGREE**. Pushing the limit into each `UNION` arm prevents scanning the entire tenant backward. As noted, indexing `received_at` within the arm is necessary.
8. **4.8 Issue list without `description`:** **AGREE**. Excluding the potentially TOASTed `description` column eliminates unnecessary I/O overhead on the list view.
9. **4.9 Release-note page by keyset:** **AGREE**. Replacing the unpartitioned `row_number() OVER ()` window with keyset pagination limits the read to O(page) instead of O(table), capping the currently growing 54ms cost.
