# ap-08: what a message insert costs, piece by piece (lab, 2026-10-06)

Row ap-08 of `refactor-round-api-perf-plan-2026-10-06.md` (section 4): prd
pays 46 / 86 ms per message insert (n=590 / 247 in 24 h). The panel asked for
a lab profile first, and a commit only if one piece costs >= 10 ms.

**Verdict: drop ap-08.** No piece reaches 10 ms. The biggest one is the
second parse of a long body (the `messages_search_sig` trigger): p50 1.95 ms,
p90 4.65 ms. The whole statement runs p50 3.3 / 5.1 / 8.9 ms (short / mid /
long body), far below prd's 46..86 ms, so most of prd's time is outside the
statement's own pieces. This lab cannot see that part (section 4).

## 1. Setup

| item | value |
|---|---|
| tree | `81aef63fe81f9c1de9e810c1f5e1dc882dfee558` (rdb migrations 0001..0141 applied, the head) |
| postgres | 16.15 (`postgres:16-alpine`, docker), `shared_buffers=256MB`, `synchronous_commit=on` |
| role | a non-superuser owner, NOBYPASSRLS, so FORCE RLS binds; tenant scope `app.tenant_id` |
| data | one tenant, 18 900 messages (prd t1: 18 931), 17.2 % with a body >= 1024 chars (prd: 3 274 of 18 931, 17.3 %), mean body 857 chars, real English text from the repo's docs; 2 500 topics, 10 channels, 3 750 flow_watches, 5 612 flow_events; 52 MB |
| statement | the hub's own `insertMessageOnly` SQL and `insertMessageArgs` parameters (a scratch copy of the store package called them, so no SQL was retyped) |
| message | a line in a private channel that mentions `@HUM-2`, in the topic with the most watchers, so `flowInsertCTE` writes watches and 3 events |
| run | `EXPLAIN (ANALYZE, BUFFERS, WAL)` in a transaction that is rolled back; `SET CONSTRAINTS ALL IMMEDIATE`, so the deferred `change_stamp` trigger is timed too |
| n | 20 per variant and body class, after 5 warm-up runs; variants run round-robin, so load drift hits all of them alike |
| box | 16 cores shared with the agent fleet: load average 143..172 during the run. Every number is inflated by that load, and a toggle delta under ~1 ms is noise |

Each run that drops something (a trigger, an index, a column) does it in the
same transaction, then makes one warm-up insert under a savepoint, then the
timed insert. Without that warm-up, the DDL throws away the cached foreign-key
and trigger plans, and the first pass of this lab read 7 ms of planning and a
1.3 ms FK check that were not real.

## 2. Pieces, read straight from the plan (ms, n=20 each)

The trigger rows and the `flowInsertCTE` row are EXPLAIN's own timings. They
are not differences between two runs.

| piece | short < 300 p50 / p90 | mid 300..1023 p50 / p90 | long >= 1024 p50 / p90 |
|---|---|---|---|
| whole statement (execution) | 3.26 / 5.13 | 5.13 / 7.27 | 8.94 / 12.92 |
| planning (per statement, uncached) | 1.55 / 1.94 | 1.63 / 3.14 | 1.72 / 2.74 |
| `flowInsertCTE`: flow_cand + flow_w + flow_e, plus their 3 FK checks | 1.37 / 2.13 | 1.82 / 3.85 | 1.71 / 3.41 |
| - of which the FK `flow_events -> messages` | 0.58 / 0.63 | 0.60 / 1.71 | 0.74 / 2.00 |
| `ins` node: heap row, 19 index entries, the `search_tsv` parse, the BEFORE triggers | 0.78 / 1.46 | 1.05 / 2.57 | 4.74 / 9.30 |
| row trigger `messages_search_sig` (the second parse plus the Bloom sig, long bodies only) | 0.02 / 0.02 | 0.02 / 0.03 | **1.95 / 4.65** |
| row trigger `messages_claim_defaults` | 0.12 / 0.22 | 0.12 / 0.19 | 0.11 / 0.13 |
| row trigger `change_stamp` (deferred; timed immediate) | 0.25 / 0.29 | 0.25 / 0.38 | 0.28 / 0.45 |
| statement trigger `message_period_counts_add` | 0.19 / 0.24 | 0.19 / 0.34 | 0.22 / 0.33 |
| FK `messages -> tenants` | 0.05 / 0.06 | 0.05 / 0.09 | 0.05 / 0.10 |
| `to_tsvector('spool_search', body)` alone (= the `search_tsv` parse) | 0.09 / 0.12 | 0.24 / 0.34 | 1.36 / 2.43 |
| that parse plus `spool_search_sig` alone (= the trigger's work) | 0.19 / 0.24 | 0.39 / 0.51 | 1.65 / 2.45 |

## 3. Pieces toggled off one at a time (statement execution p50, ms, n=20)

Index maintenance has no timing of its own in EXPLAIN, so it is read here as
a difference. With the base at 3.26 / 5.13 / 8.94 ms:

| variant | short | mid | long | reading |
|---|---|---|---|---|
| without the flow CTE | 1.37 | 1.86 | 6.07 | agrees with section 2 (~1.4..2.9 ms); its planning also drops from 1.55..1.72 to 0.43..0.52 ms |
| without trigger `messages_search_sig` | 5.15 | 3.64 | 6.57 | long: -2.4 ms, agrees with the trigger's 1.95 ms |
| without column `search_tsv` (the first parse) | 3.54 | 3.55 | 7.23 | long: -1.7 ms; the `ins` node drops 4.74 -> 3.05 ms |
| without trigger `messages_claim_defaults` | 3.37 | 4.62 | 8.87 | noise |
| without trigger `change_stamp` | 3.05 | 3.34 | 7.67 | noise to -1.8 ms |
| without trigger `message_period_counts_add` | 4.31 | 3.65 | 8.29 | noise |
| without index `messages_search_sig_todo` (the one search index left; 0122 dropped the GIN) | 3.14 | 4.81 | 8.06 | noise; WAL 8 729 -> 8 260 bytes |
| without all 18 secondary indexes (the pkey stays: ON CONFLICT needs it) | 4.17 | 4.10 | 7.79 | at most ~1 ms; buffers 28..48 -> 9..30 |

**The named suspect, a long body parsed twice:** the first parse (`search_tsv`)
costs ~1.4..1.7 ms and the second (the trigger) ~1.95 ms, together ~3.3 ms
p50. That is real, but it is a third of the 10 ms gate. Removing the second
parse saves at most ~2 ms, and only on the 17 % of inserts that are long.

## 4. What this lab cannot see

The lab statement takes 3..9 ms. prd's 46..86 ms is measured around the
whole send, and several costs are outside this lab's reach:

- the commit's WAL flush on Cloud SQL;
- the network round trip (the send is one pgx batch, so one round trip);
- the db-f1-micro shared core;
- the hub's own work around the call.

None of those is a statement piece that ap-08 could remove. If anyone wants
the server-side share on prd, the cheap read is `pg_stat_statements`
`mean_exec_time` for this INSERT. It is a read-only query for the
orchestrator, not a change, and it is not proposed here.

## 5. Not touched

- No code, migration or test changed. The only file is this report.
- Nothing ran against dev or prd.
- The lab container was removed after the run.
