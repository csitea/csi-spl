# SPL-984: hub DB maintenance review, 2026-09-26

**Lane**: CLE-35019 · **Issue**: SPL-984 (epic 47) · **Spec**: 029 (this dir)
**Owner question** (topic 753931ff, 20:07-20:10Z): *"now that there is SOME data
in the postgres, is there any need to perform some kind of db optimizations and
maintenance activities ... Vacuuming etc. ... should we investigate the logs and
create some indexes?!"*

## 1. The short answer

- **Vacuum / analyze / wraparound: nothing to do.** Autovacuum keeps up on
  both envs; the transaction-id age is 0.08 % of the freeze ceiling.
- **One real performance defect, and it is a query plan, not a missing
  index.** The topic-list walk (`GET /v1/view/topics`, the lobby and the DM
  list) is **64 % of all database time on prd** and answers in **1.0-1.6 s**
  for the owner's t1 feed. The planner walks every older message of the tenant
  at every step instead of stopping at the first hit. An index alone does NOT
  fix it (measured); one session setting in the walk's existing scope batch
  does: **13x to 90x** faster in the lab (§4).
- **dev is 95 % bloat** (437 MB for ~17 MB of rows, left by the 400k-row
  search seed and purge of spec 022 §9). prd is not bloated.
- **Still blind to per-statement stats without Query Insights**:
  `pg_stat_statements` is not installed. Query Insights (on since 029 D1) is
  now readable with a named action (`do_spl_db_insights`, §2), which covers
  what we need without the restart.
- **No tier change is justified by these numbers** (prd CPU max 19 %, cache
  hit 100 %). The slow page is a plan, not the machine.

## 2. How this report is auditable

| field | value |
|---|---|
| version / config | hub image `0.9.6` on dev and prd (cnf `env.hub.image.tag`); Postgres 16.15; Cloud SQL `db-f1-micro`, ZONAL, both envs |
| tree | measured from `7325032b`..`77f758ca` (the two actions below landed at `7cc954c7` and `77f758ca`) |
| role measured as | `spool_hub_rt` (the hub's runtime login) via the env SA; catalog reads in the operator RLS scope, timings in the TENANT scope |
| n | stated per number; one health pass per env at 2026-09-26T20:11:57Z; Postgres counters cover 8 d (stats_reset 2026-09-18) |

The commands, all read-only (csi-spl-orc):

```text
ENV=<env> ./run -a do_spl_db_health                                    # size, load, vacuum, structure, cloudsql
ENV=<env> INSIGHTS_HOURS=168 ./run -a do_spl_db_insights                # NEW: top statements from Query Insights
ENV=<env> TENANT_ID=t1 READER=<HUM-n> ./run -a do_spl_db_hot_measure    # NEW: p50/p95 of the hot statements
ENV=<env> SQL='<one SELECT>' ./run -a do_spl_db_query                   # per-tenant sizes (§3.2)
ENV=prd FORMAT=json FRESHNESS=3d FILTER='<requests to /view/>' ./run -a do_gcp_tail_logs   # csi-spl-iac, §3.5
```

## 3. What the measurement says

### 3.1 Size (do_spl_db_health, 20:11Z)

| | dev | prd |
|---|---|---|
| logical DB size | **437 MB** | 38 MB |
| disk used (platform, 24 h newest) | 575 MB (max 1.28 GB in the window) | 140 MB |
| disk quota | 10.46 GB | 10.46 GB |
| `messages` total / heap / indexes / toast | **425 MB / 133 MB / 280 MB / 13 MB** | 25 MB / 6 MB / 4.9 MB / 14 MB |
| `messages` rows | 3 957 | 3 853 |

dev carries ~17 MB of live message rows (§3.2) in a 425 MB relation: **~96 %
of `messages` on dev is dead space** left by the 022 §9 search seed (400k rows,
then purged). Autovacuum made that space reusable, but it never returns it to
the OS and never shrinks indexes. prd's `messages` is 25 MB for 17 MB of rows
plus indexes, i.e. healthy.

### 3.2 The largest tenants (do_spl_db_query, prd 20:27Z, dev 20:29Z, n=1)

| env | tenant | messages | deliveries | revisions | reactions | issues | msgs with files | row bytes | topics |
|---|---|---|---|---|---|---|---|---|---|
| prd | t1 | 3 732 | 3 919 | 196 | 10 | 985 | 39 | 17 MB | 288 |
| prd | e2e | 114 | 126 | 2 | 4 | 40 | 15 | 144 kB | 67 |
| prd | csi-rel | 55 | 55 | 5 | 1 | 12 | 1 | 152 kB | 7 |
| prd | leiden | 0 | 0 | 0 | 0 | 71 | 0 | 0 | 0 |
| dev | t1 | 3 995 | 4 203 | 19 | 5 | 33 | 53 | 17 MB | 316 |

Every other tenant (5 on prd, 14 on dev) is empty. Retention is 30 days on
messages (`expires_at - received_at` = 30 days on every row) and the oldest
message on both envs is from 2026-09-25, so nothing has aged out yet.

### 3.3 Vacuum, analyze, wraparound (do_spl_db_health, 20:11Z)

- Every autovacuum setting is the Postgres default (scale factor 0.2,
  threshold 50, 3 workers, naptime 60 s); no table has a `reloptions`
  override. `track_io_timing` is now **on** (it was off in 029 §3.5).
- The hot tables are vacuumed and analyzed hours apart: prd `deliveries`
  14 autovacuums, `message_period_counts` 56, `roster` 74, `messages` 3;
  last autovacuum on each is from today.
- Dead tuples: the highest absolute is prd `deliveries` **535** (11.7 %),
  then `messages` 91. The 60-86 % `dead_pct` rows are 3-40-row tables, and
  their dead tuples are **HOT updates in one 8 kB page** (029 §3.6: an alert
  must key on absolute dead tuples AND size).
- `deliveries` has 4 124 updates and **0 HOT updates** on prd: `UPDATE
  deliveries SET state` changes an indexed column, so HOT is impossible by
  construction. At 0.4 ms per call (§3.4) it does not matter at this size.
- Wraparound: `age(datfrozenxid)` **159 313 (prd) / 160 532 (dev)** against
  200 000 000 = **0.08 %**.
- True bloat (`pgstattuple`) is available but not installed; WAL size is still
  unreadable (`permission denied for function pg_ls_waldir`, 029 §6.4).

### 3.4 Query performance

**`pg_stat_statements` is NOT installed** (installed f, available t, both
envs). Query Insights IS on, and `do_spl_db_insights` reads it. prd, window
2026-09-19T20:14Z .. 2026-09-26T20:14Z (168 h): **245 statements, 298 703
calls, 224.6 s of DB time**. Top by total time:

| calls | total ms | mean ms | % | statement |
|---|---|---|---|---|
| 649 | 90 156 | 138.9 | **40.1 %** | topic walk, DM list (`viewTopicsSQL`, DM + Viewer + door + Roots + NoIssues) |
| 140 | 53 346 | 381.0 | **23.7 %** | topic walk, all topics (door + Roots + NoIssues) |
| 3 845 | 12 665 | 3.3 | 5.6 % | `INSERT INTO messages` |
| 884 | 6 559 | 7.4 | 2.9 % | the retention Sweep `DELETE FROM messages` |
| 2 | 5 195 | 2 597.6 | 2.3 % | an operator's ad-hoc json_agg dump |
| 399 + 486 + 220 | 12 063 | 9.5-12.1 | 5.4 % | three narrower walk variants (channel, peer, per_topic) |
| 933 | 4 112 | 4.4 | 1.8 % | channel summary (`GROUP BY channel`) |
| 751 | 2 937 | 3.9 | 1.3 % | `ListIssues` |

Everything else is sub-millisecond. The most-called statement is the RLS
scope `set_config` (123 738 calls, 0.01 ms).

**The two walk variants are 64 % of all database time.**

Hot statements timed directly, prd t1 as the owner's feed (`READER=HUM-10`,
5 channels), `do_spl_db_hot_measure`, 2026-09-26T20:32Z, n=10 each:

| statement | jit on p50 / p95 | **jit off p50 / p95** (the hub runs it jit off) |
|---|---|---|
| walk_all | 1 521 / 2 081 ms | **1 557 / 2 022 ms** |
| walk_dm | 1 071 / 1 470 ms | 7 of 10 samples > 10 s timeout (see note) |
| thread (biggest topic, 51 msgs) | 0.3 / 0.3 ms | 0.4 / 0.5 ms |
| channels | 2.8 / 3.7 ms | 2.3 / 4.0 ms |
| issues (985 rows) | 1.8 / 2.2 ms | 2.1 / 2.1 ms |
| file_door | 0.1 / 0.2 ms | 0.2 / 0.3 ms |

Note: the walk_dm timeouts did **not** reproduce: two re-runs at 20:41Z and
20:43Z (n=5 each, `force_custom_plan` and `force_generic_plan`) gave
964-1 146 ms p50 with 0 timeouts. They were seen once (n=10) and are not
explained; the shared-core tier (no CPU guarantee) is the obvious suspect.

dev t1 (`READER=HUM-4`), 20:48Z, n=5, jit off: walk_all **3 019 ms** p50 (the
bloated heap makes each step read more pages), walk_dm 128 ms.

### 3.5 What users see (Cloud Run request logs, prd, 14:42-20:42Z, n=3 000 requests)

| path | n | p50 ms | p95 ms | max ms |
|---|---|---|---|---|
| `/v1/view/topics` | 53 | 36 | **1 782** | **2 554** |
| `/v1/view/topics?dm=true` | 289 | 30 | **1 038** | **2 364** |
| `/v1/view/topics?per_topic` | 174 | 32 | 157 | 406 |
| `/v1/view/topics/{id}` (thread) | 773 | 15 | 31 | 113 |
| `/v1/view/issues` | 402 | 14 | 50 | 115 |
| `/v1/view/channels` | 282 | 15 | 42 | 249 |

Every other view endpoint is under 160 ms at p95. The p50s are low because
most reads are small tenants and filtered lists; the **tail is the t1 feed**.

### 3.6 Connections and instance

- `max_connections` 25 (3 superuser-reserved). prd platform `num_backends`
  24 h max **16** (n=5 756 samples); at 20:11Z: 11 `spool_hub_rt`
  (10 idle, 1 active), 3 `cloudsqladmin`, 5 background. Two hub instances x
  pool 8 = 16 is the ceiling the pool was sized for (027 T010). No waits, no
  locks, no idle-in-transaction, 0 deadlocks, 0 temp files on prd.
- `shared_buffers` 128 MB, `work_mem` 4 MB, `effective_cache_size` 385 MB:
  the tier's defaults; prd's 38 MB DB is fully resident (cache hit 100.00 %,
  189 reads vs 105.8 M hits in 8 d).
- CPU 24 h: prd 8.5-19 %, dev 8.1-45 % (n=1 439 one-minute samples).
- `statement_timeout = 0`, `idle_in_transaction_session_timeout = 0`
  (029 D3, still open), `log_min_duration_statement = -1`.

### 3.7 Backups (spec 029)

Cloud SQL automated backups: the last 7 runs SUCCESSFUL on both envs, PITR on,
7 days of logs. The daily off-instance export (workflow `45_db-backup.yml`):
**5 of the last 6 runs green**; 2026-09-24T05:26Z failed on both envs and its
job log has expired (`gh api .../logs` → 404 BlobNotFound), and every run
since is green.

## 4. Root cause of the slow list, and what fixes it

`viewTopicsSQL` walks the tenant newest-first, one `ORDER BY received_at
DESC, task_id::text DESC LIMIT 1` step per topic, keeping a row only when four
or five boolean probes pass (latest in its topic, the read door, a root topic,
not an issue, and since SPL-983 not archived). The design relies on the
planner stopping at the first row that passes.

The plan on prd (`MEASURE_PLANS=1`, 20:33Z) shows it does not: each recursive
step is a **Bitmap Heap Scan of every older t1 message** (`rows=3488` per
step), all probes on each one, then a top-N sort, for **171 832 probe loops
and 659 747 buffer hits per page of 51 topics**. With the probes each rated at
1/2 the step's estimate is `rows=1`, so LIMIT 1 looks no cheaper than reading
everything, and the bitmap path wins the cost race. The cost grows with
tenant size times topic count, so it gets **superlinearly** worse.

Lab: the newest dev dump (`spool-20260926T092319Z`, 2 343 messages) restored
into a throwaway `postgres:16-alpine` (16.15), timed as `spool_hub_rt` in the
tenant scope with `do_spl_db_hot_measure`'s own script, jit off, n=5 each,
2026-09-26T20:50-21:00Z. Then the same at **5x** (t1 = 11 715 messages,
1 120 topics):

| variant | walk_all 1x | walk_dm 1x | walk_all 5x | walk_dm 5x |
|---|---|---|---|---|
| today (the plan above) | 158 ms | 12 ms | **1 977 ms** | 26 ms |
| + index `(tenant_id, received_at DESC, (task_id::text) DESC)` | 150 ms | 20 ms | 1 968 ms | 38 ms |
| **`enable_bitmapscan = off` in the walk's scope batch** | **33 ms** | 16 ms | **21.5 ms** | 37 ms |
| both | 11.6 ms | 10.6 ms | 7.9 ms | 27 ms |

- **The index alone does nothing**: the planner still chooses the bitmap
  path (the "add an index" instinct is wrong here, measured).
- **`enable_bitmapscan=off` for that one statement** turns each step into an
  ordered backward index scan that stops at the first passing row:
  **92x at 5x data**, and flat as the tenant grows. It is the same pattern
  as the `jit=off` the walk already sets in `pgScopeTenantNoJIT`, and it is
  `SET LOCAL`-scoped to that one implicit transaction, so no other statement
  is affected.
- The extra index buys another ~2.7x on walk_all, but every INSERT into
  `messages` pays for it (13 indexes today), and walk_dm did not improve.
  **Not proposed now**; revisit above ~50k messages per tenant.

## 5. Best practice for this app's shape (append-heavy chat + RLS per tenant)

| practice | applies? | why, with the number |
|---|---|---|
| Rely on autovacuum; tune per table only when a big table lags ([PG 16 §25.1](https://www.postgresql.org/docs/16/routine-vacuuming.html)) | **yes, no tuning** | every hot table vacuumed today; largest dead count 535 rows |
| Manual `VACUUM` / `ANALYZE` cron | no | autovacuum + autoanalyze ran within the last hours on every busy table |
| `VACUUM FULL` / `pg_repack` after a mass delete | **dev only** | dev `messages` 425 MB for ~17 MB of rows; prd has no mass delete |
| `REINDEX` | only as part of the dev compaction | prd index sizes are proportional to rows |
| Wraparound monitoring | watch only | 0.08 % of the ceiling |
| Per-statement stats (`pg_stat_statements` or Query Insights) ([Cloud SQL Query Insights](https://cloud.google.com/sql/docs/postgres/using-query-insights)) | **yes, done via Insights** | `do_spl_db_insights`; pg_stat_statements needs a restarting flag ([Cloud SQL flags](https://cloud.google.com/sql/docs/postgres/flags)) |
| `statement_timeout` / `idle_in_transaction_session_timeout` ceilings ([PG 16 §20.11](https://www.postgresql.org/docs/16/runtime-config-client.html)) | **yes** | both 0 today; the longest hub statement in 7 d is 2.6 s |
| Index every RLS / tenant access path ([PG 16 §5.8](https://www.postgresql.org/docs/16/ddl-rowsecurity.html)) | already true | every `tenant_id` table has an index leading on it (0 rows missing) |
| GIN full-text / jsonb indexes under FORCE RLS | **no effect** | `@@` and `@>` are not LEAKPROOF, so the planner cannot use them under a policy (022 §9); `messages_search` 0 scans in 8 d |
| Partitioning `messages` | no | 3.9k rows; revisit near 10 M (029 §3.7) |
| Planner hints for fragile LIMIT walks ([PG 16 §20.7](https://www.postgresql.org/docs/16/runtime-config-query.html)) | **yes, one statement** | §4: 1 557 ms → ~20-35 ms class |
| Bigger tier / HA ([Cloud SQL SLA](https://cloud.google.com/sql/sla) excludes shared-core) | not for performance | prd CPU max 19 %; SLA/HA stays 029 D5, a cost decision |

## 6. Proposal (owner's standing go, topic 753931ff, 20:1xZ: "do them all whenever you can")

| # | change | why (evidence) | risk | rollback |
|---|---|---|---|---|
| P1 | The topic walk's scope batch sets `enable_bitmapscan=off` (next to its `jit=off`), hub store code + a plan-shape test | 64 % of prd DB time; `/view/topics` p95 1.78 s; lab 1 977 → 21.5 ms at 5x | a different plan for ONE statement; measured faster at 1x and 5x on both shapes | revert the one line; hub redeploy |
| P2 | `ALTER ROLE spool_hub_rt SET statement_timeout = '30s'`, `idle_in_transaction_session_timeout = '60s'` in `runtime-grants.sql` (re-applied after every migrate) | both 0 today (029 D3); hub's longest statement in 7 d 2.6 s | a legit >30 s statement as the runtime login fails; seed/purge already `SET statement_timeout = 0` | `ALTER ROLE ... RESET` both; re-run bootstrap |
| P3 | dev only: compact `messages` (`VACUUM FULL` + `ANALYZE`) as the owner login, via a named orc action | dev 425 MB for ~17 MB of rows; walk 3.0 s on dev vs 1.5 s prd | an ACCESS EXCLUSIVE lock on dev `messages` for the duration (seconds at this size) | none needed: the operation only removes dead space |
| P4 | Keep Query Insights as the statement-stats source; `pg_stat_statements` stays deferred (029 D2) | Insights gives calls + mean per statement (§3.4) without a restart | none | n/a |
| P5 | No autovacuum tuning, no reloptions, no partitioning, no tier change | §3.3, §3.6 | none | n/a |
| P6 | No new walk index now | the index alone: 158 → 150 ms (no effect); with P1: extra 2.7x only at 5x, costs every INSERT | n/a | n/a |
| P7 | `messages_search` GIN (32 MB dev / 2.8 MB prd, 0 scans): leave for 022 §9 D-S1..D-S4 | never usable under FORCE RLS; dropping it is the search lane's decision | n/a | n/a |

## 7. Applied

Filled in as each change lands (dev first, then prd, with before/after).

<!-- last-edit: 2026-09-26T21:05:00Z -->
