# Performance edition 20261004, DBX: index audit and cheap database tactics (prd + dev)

Owner question (HUM-10, t1 `7d7e86a9`, msg `2e38197b`): *"are there any indexes which should be created as well, or other cheap tactics on the db site"*.

**Short answer.**

- **Missing indexes:** one small one. `deliveries (acked_at) WHERE state = 'sent'` turns the committed-row prune from a seq scan of every delivery into a 2-buffer probe. Nothing else in the top statements is an index problem. The big costs are statement shapes that rows E01, E04 and E17 own, plus row estimates the RLS policy distorts. No index fixes either of those.
- **Drop one index:** the `messages_search` GIN (12 MB, 0 scans). Under FORCE RLS the hub can never use it. The drop is coupled to spec 022 §9 (D-S1).
- **Keep one index:** `messages_channel` is **not** redundant. It has 355 466 scans on prd, and the channel counts need it. Plan §5 had it wrong.
- **Temp spills:** they come from **E17's unanswered sweep**, not E01. The fix is the query; `work_mem` stays at 4 MB.
- **`log_temp_files`:** already `0` on both envs (the Cloud SQL default). Nothing to change.

The migration (`0121_dbx_index_audit.sql`, renumbered at release) is built and tested on a branch, and **held for the owner's go** (orchestrator amendment `86193cba`).

## 1. Method and window

| item | value |
|---|---|
| trunk | `b0def3add` (rebased to `7d6bae626` before writing); live hub tag `v9.0.7` |
| window | 2026-10-04 19:55..20:40Z; counters since `stats_reset` 2026-09-18 19:37Z (prd) / 18:16Z (dev) |
| identity | the per-env project SA only (`do_gcp_pin_account`); nothing written to either DB |
| live reads | `do_spl_db_query` (READ ONLY transaction, rolled back, operator RLS scope), `do_spl_db_insights INSIGHTS_HOURS=24`, `do_spl_db_health SECTION=cloudsql`, `do_gcp_tail_logs` (Cloud SQL `postgres.log`) |
| plans | `EXPLAIN (ANALYZE, BUFFERS)` n=3 on prd, tenant `t1` (16 873 live messages), member `HUM-10` (2 279 flow events, the largest) |
| index proofs | `hypopg` is not available (`pg_available_extensions` on dev: only `pg_stat_statements`), so proofs ran on a scratch `postgres:16-alpine` with the same table shape, the same row counts, the same FORCE RLS policy and a NOBYPASSRLS role; never by creating an index on prd |

**One caveat.** The operator scope's literal-value EXPLAIN gives the *custom* plan. The hub runs prepared statements (pgx, `plan_cache_mode auto`), so after 5 executions per connection it may use the *generic* plan. Where the two differ, §2.2 shows both (`EXPLAIN (GENERIC_PLAN)`).

## 2. Missing indexes (1.1)

### 2.1 Table scans, prd

`pg_stat_user_tables`, the tables with the most `seq_tup_read`:

| table | live rows | seq_scan | seq_tup_read | idx_scan | size | verdict |
|---|---|---|---|---|---|---|
| channels | 82 | 1 676 412 | 123 M | 618 491 | 64 kB | 82 rows: a seq scan is the right plan (plan §5) |
| fallback_deliveries | 310 | 621 945 | 93.6 M | 590 883 | 160 kB | 310 rows: same |
| messages | 19 917 | 19 462 | 48.1 M | 285.6 M | 113 MB | ~1 200 seq scans/day; the sources are §2.2 (unanswered sweep, search, custom flow-count plans). No index changes them (see each row) |
| read_marks | 898 | 33 622 | 22.6 M | 39.3 M | 280 kB | E01 / E02 |
| deliveries | 22 522 | 4 553 | 15.5 M | 2.8 M | 6.5 MB | **the prune, §2.3: index candidate** |
| roster, tenant_memberships, humans, boxes, pins, tenants | <= 170 | | | | <= 96 kB | tiny, seq scan correct |

dev looks the same, with one oddity for its owner. `issues` is 50 rows with 20 523 049 seq scans and 690 M tuples read. On prd, `issues_tenant_id_task_id_key` has 37.7 M index scans for 1 997 rows. Some statement probes `issues` once per row of another scan (a correlated per-topic issue lookup). That is a statement shape, not a missing index; it is cheap per probe on both envs and not in the 24 h top 15.

### 2.2 The top 15 statements by total time (prd Insights, 24 h)

24 h = 2026-10-03T20:02Z..10-04T20:02Z: 56 statements, 2 830 909 calls, 1 601.5 s DB time.

| # | statement (site) | calls | mean ms | % | owner | index finding |
|---|---|---|---|---|---|---|
| 1 | read_marks sweep `DELETE FROM read_marks` (flow_postgres.go:220) | 138 | 3 294 | 28.4 | **E01** | the PK becomes usable once the key is computed first (E01's MATERIALIZED CTE, 1.93 ms). No new index |
| 2 | flow counts `WITH fc AS` (flow_postgres.go:91) | 8 362 | 35.8 | 18.7 | E03 (push), flow file = E01 | see below: an estimate problem, not an index |
| 3, 4 | channels read-mark CTEs `WITH pm AS` | 6 851 | 25.0 / 19.0 | 10.7 / 8.1 | **E04** | E04's plan: a reader-independent CTE plus a LATERAL count |
| 5 | unanswered sweep (spl-unanswered-sweep.func.sh:191) | 183 | 406.8 | 4.6 | **E17** | spills to disk, §4.3. An index cannot remove the sort: DISTINCT ON orders `received_at DESC` after ascending keys, over all tenants' 7 days |
| 6 | read_marks upsert | 8 560 | 8.4 | 4.5 | **E02** | PK upsert; deadlocks are E02's |
| 7 | channel counts `WITH c AS` (channels_postgres.go:374) | 6 851 | 8.6 | 3.7 | E04's file | prd EXPLAIN n=3: 12.7 / 13.8 / 19.2 ms, Index Only Scan on `messages_channel_stats` (1 152 buffers) plus 10 probes on **`messages_channel`**. Already index-backed |
| 8 | flow list (flow_postgres.go FlowRead) | 1 163 | 38.2 | 2.8 | flow file = E01 | prd EXPLAIN n=3: 26.2 / 32.5 / 136.4 ms; Seq Scan on `flow_events` (58 buffers, cheap), 2 284 `messages_pkey` probes (6 858 buffers), then a top-N sort to 51. The planner estimates 10 rows for 2 284 (RLS OR clause), so it skips `flow_events_member_at`, which would stop after 51. **A statement / estimate fix for E01's file, not a new index** |
| 9 | ReescalatablePosts (fallback_postgres.go:129) | 121 662 | 0.30 | 2.3 | | index-backed, 0.3 ms |
| 10, 12, 13 | topic walks `WITH RECURSIVE w` | 456 / 182 / 145 | 64 / 121 / 124 | 1.8 / 1.4 / 1.1 | plan §5 | plan §5: trace the dev 5xx first; 029 P6 measured a walk index as no effect |
| 11 | `INSERT INTO boxes ... ON CONFLICT` | 95 535 | 0.27 | 1.6 | | PK |
| 14 | UTILITY COMMAND (BEGIN/SET) | 6 885 | 2.55 | 1.1 | | |
| 15 | `set_config` (RLS scope) | 1 453 343 | 0.01 | 1.0 | | per transaction, by design |

**Flow counts (#2), measured.** EXPLAIN n=3 on prd, custom plan: 101.4 / 92.4 / 96.1 ms, 53 098 buffers. The planner estimates **85 rows on `messages` for 16 873 actual** (200x). It seq-scans every t1 message, then probes `flow_events_msg` 16 873 times (49 110 buffers).

The cause is the RLS policy's `tenant_id = NULLIF(current_setting(...)) OR current_setting(...) = 'operator'` clause. Its selectivity is a default guess, and neither `ANALYZE` nor extended statistics can correct an expression over `current_setting`.

- Driving from the member's events instead (`(SELECT * FROM flow_events WHERE tenant_id = .. AND member_id = .. OFFSET 0)` as a fence) gave 52.6 / 51.3 / 55.3 ms and 19 697 buffers (n=3), with byte-identical output.
- The **generic** plan (`EXPLAIN (GENERIC_PLAN)`) already has that shape (Bitmap Index Scan on `flow_events_pkey`, then `messages_pkey`).

So the hub's steady state, after 5 executions per connection, is already the good plan. That matches the 35.8 ms Insights mean and the low `messages` seq_scan count. The fence only helps each connection's first custom executions. I handed it to the flow file's owner (E01); it is **not** an index.

### 2.3 The one index that changes a plan: `deliveries_sent_acked`

`store/retention.go` `pruneCommitted` runs on every hub sweep:

```
DELETE FROM deliveries WHERE state = 'sent' AND acked_at < $1 AND (tenant_id, msg_id, to_box) IN (
  SELECT tenant_id, msg_id, to_box FROM deliveries WHERE state = 'sent' AND acked_at < $1 LIMIT $2)
```

No index leads on `acked_at`.

| measure | before | after (`CREATE INDEX deliveries_sent_acked ON deliveries (acked_at) WHERE state = 'sent'`) |
|---|---|---|
| prd, inner select, EXPLAIN ANALYZE n=3 | Seq Scan, 22 594 rows removed, 325 buffers, **25.2 / 6.7 / 5.6 ms**, 0 rows | (not created on prd) |
| prd Insights 24 h, the DELETE | n=138, mean **74.9 ms**, 10.3 s/day | expected < 1 ms per run while nothing is due |
| scratch pg 16, 22 594 rows, FORCE RLS, NOBYPASSRLS role, the full DELETE, n=3 | Seq Scan, 233 buffers, **3.9 / 3.1 / 2.7 ms** | Index Scan using `deliveries_sent_acked`, 2 buffers, **0.21 / 0.08 / 0.07 ms** |
| build (lock) | | 28.6 ms for 22.6k rows on scratch: a SHARE lock (writes wait) for that long |
| write cost | | `acked_at` is set once per delivery. Today only 295 of 34 394 delivery updates are HOT, so the new index adds about one index insert per ack (~3.6k/day) |

**Gain:** ~10 s/day of prd DB time (0.6 %), plus one seq scan of the table per sweep. The gain is small but real. The table grows until the 720 h window first bites (oldest ack 2026-09-25), then it holds steady.

## 3. Unused and redundant indexes (1.2)

`pg_stat_user_indexes` on prd, `idx_scan` since 2026-09-18:

| index | prd scans | prd size | dev scans | verdict |
|---|---|---|---|---|
| `messages_search` (GIN on `search_tsv`) | **0** | **12 MB** | 0 (7 MB) | **unusable by the hub, drop (held)**: see below |
| `messages_channel` `(tenant_id, channel, received_at) WHERE channel IS NOT NULL` | **355 466** | 448 kB | 48 393 | **keep.** Plan §5 called it covered by `messages_channel_stats`, but that index has `received_at` as an INCLUDE column, not a key. The channel counts' per-channel newest probe (`x.channel = c.channel AND x.received_at = c.last_at`, channels_postgres.go:374) uses `messages_channel` on prd (EXPLAIN #7 above) |
| `messages_task (tenant_id, task_id, ts)` vs `messages_task_received (tenant_id, task_id, received_at, msg_id)` | 4.3 M / 191 M | 1.4 / 4.0 MB | | same 2-column prefix, different third key, both hot: keep |
| `channel_subscriptions_box` vs `_backfill_pending` (same keys, partial) | 66 k / 84 k | 16 kB each | | both used: keep |
| 0-scan non-unique: `tenant_memberships_role`, `fleet_asks_open`, `issues_archived`, `messages_needs_peer`, `agent_lifecycle_events_at`, `pins_history_tenant_box`, `operator_audit_tenant_at`, `payment_checkouts_tenant`, `password_reset_tokens_cred`, `webhook_events_seen_received`, `wui_perf_samples_at` | 0 | 8..16 kB each | | features with little or no data yet; dropping saves nothing measurable |
| 0-scan unique / PK (`human_keys_pkey`, `member_activity_pkey`, `box_stats_pkey`, ...) | 0 | | | constraints, not droppable |

**Why `messages_search` has 0 scans.** `search_postgres.go:130` does filter with `m.search_tsv @@ <tsquery>`, so the search route *wants* the GIN. But:

- prd: `ts_match_vq` (the `@@` function) has `proleakproof = f`;
- the hub login `spool_hub_rt` has `rolbypassrls = f`;
- `messages` has `relforcerowsecurity = t`.

Postgres will not use a non-LEAKPROOF operator as an index condition under a row policy.

- **prd EXPLAIN n=3** of a search for a term with 0 hits: Seq Scan on messages, 70.2 / 68.2 / 65.9 ms. A common term ("deploy", 1 742 hits): 69.0 / **4 360.7** / 73.1 ms. The one outlier is not explained.
- **Scratch pg 16, same query:** with RLS off, Bitmap Index Scan on the GIN. Under FORCE RLS as a NOBYPASSRLS role, Seq Scan.

So /v1/view/search is slow *because* it cannot use the GIN. Dropping the GIN loses no plan. It frees 12 MB of a 128 MB `shared_buffers`, and takes GIN maintenance off every insert and body edit (scratch, 20k rows, n=3: 937 / 730 / 657 ms with the GIN vs 592 / 544 / 496 ms without, median +34 %).

The same reasoning dropped the files GIN in rdb 0081. Spec 029's review (P7) left this one to spec 022 §9. Of D-S1..D-S4, only **D-S1** (a SECURITY DEFINER search function that bypasses RLS) would use this GIN. If the owner picks D-S1, the drop line comes out of 0121.

## 4. Other cheap tactics (1.3)

### 4.1 Autovacuum and bloat

prd: every busy table was autovacuumed or autoanalyzed within the last ~2 days (messages 10-03 06:59Z / 10-04 13:15Z; deliveries 10-03 / 10-04; read_marks 10-04). `n_dead_tup` is below the 20 % trigger everywhere it matters (deliveries 3 966 / 22 522 = 17.6 %, messages 899 / 19 917 = 4.5 %). The tables never vacuumed are <= 38 rows. **No change** (as 029 P5).

### 4.2 Statistics and row estimates

The >10x misestimates in §2.2 (flow counts 85 vs 16 873; flow list 10 vs 2 284) come from the RLS policy's OR over `current_setting`, not from stale statistics. `ANALYZE` and `CREATE STATISTICS` cannot fix an expression over a GUC. The fixes are statement shapes (a fence, or computing the member's events first), or the generic plans the hub already ends up on. **No ANALYZE or extended-statistics change.**

### 4.3 `work_mem` and temp files

- `log_temp_files` reads **`0`** on prd and dev (`pg_settings`, source "configuration file"). This is the Cloud SQL default: `gcloud sql instances describe` shows no `databaseFlags`. Every spill is already logged, so **no terraform** was planned or applied for it (owner go `d17db1ea` needs no action).
- prd `pg_stat_database`: 621 temp files / 4 252 MB since 2026-09-18 (dev 184 / 986 MB); deadlocks 47 (E02).
- **Which statement spills.** I joined each `temporary file` LOG line to its `STATEMENT` line by pid + line number (Cloud SQL log, 2026-09-27T21:48Z..10-04T19:52Z). n=621 spill lines; 391 had their statement in the page read; **384 of 391 are the unanswered sweep** (`spl-unanswered-sweep.func.sh:191`). The other 7: six migration runs at 8 kB and one window-function query at 4.9 MB. Users: `spool_hub_rt` 577, `spool_hub` 44. Sizes: p50 8.2 MB, p90 8.6 MB, max 12.4 MB, about one every 10 minutes.
- prd EXPLAIN n=3 of the sweep: the inner DISTINCT ON sort is `external merge Disk: 8192kB`, 1 026 temp blocks written, 136.4 / 110.5 / 110.1 ms. It sorts whole `m.*` rows (body and env) for 7 days of every tenant.
- **Sizing (best practice):** a global value must hold `max_connections x work_mem x nodes per query` inside about 25 % of RAM.
  - db-f1-micro (cnf `tier`, `040` tfvars) has 0.614 GB of RAM, so 25 % is 154 MB; divided by `max_connections` 25, that is **~6 MB per connection**.
  - `hash_mem_multiplier` 2 lets a hash node take 2x that, and one query can run several sort/hash nodes.
  - So the **safe global ceiling is about 4..6 MB, and today's 4 MB already sits at it.** The p50 spill (8.2 MB) needs about 9 MB, above the ceiling.
- **Decision: no `work_mem` change.** The query fix covers it (E17): sort only `(tenant_id, task_id, received_at, msg_id)`, then join the body for the winners, or `SET LOCAL work_mem = '16MB'` inside the sweep's own one-session transaction. Either removes all ~38 spills/day without a global change. If spills remain after E17 ships, re-run this section.
- If the owner ever wants a global value, this is the exact change. It is **not proposed**: no value inside the bound covers the spill.
  - In `csi-spl-iac/src/terraform/040-cloud-sql-postgres/03-cloud-sql.tf`, inside `settings { }`:
    `database_flags { name = "work_mem" value = "<kB>" }`, with a `work_mem_kb` variable in `02-variables.tf` and `env.gcp.cloud_sql.work_mem_kb` in cnf, rendered by `do_tpl_gen`.
  - `work_mem` is a dynamic flag (no restart), but a `database_flags` block that is new to the instance must be read in the plan first.

### 4.4 Pool size against backends

`max_connections` 25 (3 reserved, 2 cloudsqladmin). The hub pool is 8 per instance (cnf `SPOOL_HUB_DB_MAX_CONNS`); backends p95 12 / max 21 (plan §2.4). The max-21 spikes line up with the two boxes running the unanswered sweep (183 runs/day against 144 expected, E17). **No pool change** (plan §5).

### 4.5 Prepared statements

pgx caches prepared statements, and `plan_cache_mode` is `auto`. For flow counts the generic plan (cost 1 861) beats the custom one (cost 9 558, 96 ms measured), so the cache helps. Forcing `plan_cache_mode = force_generic_plan` for the hub role is a possible cheap tactic, but **not proposed**. I did not measure it across the other statements, and a generic plan can be worse for a skewed tenant (t1 holds 85 % of messages).

### 4.6 Not proposed, unmeasured

`random_page_cost` 4 with a 100 % cache hit (1.1 is the usual SSD/cached value). It would change plans globally, and I have no before/after for it, so it is not proposed.

## 5. What needs the owner's go

| change | kind | evidence | expected gain | go |
|---|---|---|---|---|
| `CREATE INDEX deliveries_sent_acked ON deliveries (acked_at) WHERE state = 'sent'` | migration 0121 | §2.3: prd Seq Scan 22 594 rows, Insights 74.9 ms x 138/day; scratch 2.7..3.9 -> 0.07..0.21 ms (n=3) | ~10 s/day prd DB time; build ~30 ms | **held** |
| `DROP INDEX messages_search` | migration 0121 | §3: 0 scans since 09-18 on both envs; the hub cannot use it under FORCE RLS (non-LEAKPROOF `@@`), proven on scratch | 12 MB off a 128 MB buffer pool; insert -25 % on scratch (n=3) | **held**; coupled to 022 §9 D-S1 |
| drop `messages_channel` | | §3: 355 466 prd scans, needed by the channel counts | **do not** | n/a |
| `log_temp_files` | Cloud SQL flag | already 0 (Cloud SQL default) | none | not needed |
| `work_mem` | Cloud SQL flag | §4.3: the spill is one statement, above the safe bound | none from a flag | **no change**; E17's query fix |

## 6. Handed to other rows (not changed here)

- **E17** (unanswered sweep): the only source of temp spills, plus a 406.8 ms mean. Narrow the DISTINCT ON sort, or `SET LOCAL work_mem` in its own transaction. Put prd `temp_files` / `temp_bytes` per hour in its before/after.
- **E01** (flow_postgres.go): flow counts' custom plan 96 -> 53 ms with the member's events fenced first (n=3, same output). Flow list: a 10-vs-2 284 estimate skips `flow_events_member_at`.
- **Search lane** (022 §9): /v1/view/search seq-scans every tenant message, 66..70 ms on prd t1, with one 4.36 s outlier (n=3). D-S1 is the only option that would use a GIN.
