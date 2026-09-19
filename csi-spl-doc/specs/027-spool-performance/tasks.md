# Tasks 027: spool performance, live lane table

ORC-PERF (CLE-3413) updates this table as lanes report. Numbers: `before -> after (harness, tree, n)`.

| id | item (spec §3) | lane | status | before -> after |
|---|---|---|---|---|
| T001 | spec 027 + re-measurement | CLE-3413 | done | n/a |
| T010 | #1 pool config + P2a roster multi-row + P2b chunked retention (`store/postgres.go`) | CLE-3417 | harness landed 434e269; Cloud SQL max_connections=25 (dev+prd) -> pool 8, not 30 | BEFORE pending |
| T020 | #2 streamed upload + prefix-bytes quota (`hub/rest.go`, `blob/`) | CLE-3418 | landed b199493 (harness 378dba8); streamed tmp + promote, quota cache TTL 1 min, no migration; CI watch, then roll via CLE-3355 | TestUploadHeapPerf (go1.25.1, 8x32 MiB concurrent, n=5, medians): GCS peak heap 605 -> 8 MiB; Dir heap 76.3 -> 0.22 MiB/upload; objects.list per new upload 1.00 -> 0.20; GCS latency 169 -> 246 ms/upload |
| T030 | #3 ViewThreads indexed page (`store/view_postgres.go` + rdb migration) | CLE-3419 | query rewrite (option a); owns the `(tenant_id, received_at)` index T040 also needs; ViewThread messages page has the same shape (in scope) | |
| T040 | #4 onSend path: pin/tenant cache with revoke invalidation, period count index/counter, blob exists (`hub/ws.go`) | CLE-3420 | BEFORE landed bc3720e; LIVE BUG: Enqueue cap UPDATE deadlocks (195/2000 sends -> 500 at 200k c=50), fixing in lane; index alone leaves the count at 19.8 ms at 200k -> trigger counter; Enqueue 5 rt -> 1 | BEFORE (BenchmarkOnSend, tree 2dfefe7, pg16.14, n=5x200, median): 10k c=1 76 sends/s p95 19.3 ms; 200k c=1 25.8/s p95 49.5 ms; 200k c=50 33.9/s p95 3277 ms, 80/1000 errors; 12 rt/send |
| T050 | #5 argon2id on 1 vCPU | — | owner decision D1, sent to CLE-00 16:53Z (recommend b) | |
| T060 | #6 LiveFeed virtualisation + incremental view (`LiveFeed.vue`, `stores/channel.ts`) | — | held until CLE-3412 lands; CLE-55 told | |
| T080 | D3 month quota counts expiring rows (spec §5) | — | owner decision D3, sent to CLE-00 | |
| T090 | D4 bucket lifecycle rule for `tmp/` leftovers (050, terraform) | — | owner decision D4, sent to CLE-00 | |
| T070 | P3b multi-instance fanout | — | owner decision D2, sent to CLE-00 16:53Z (recommend not now) | |

<!-- last-edit: 2026-09-19T17:12:58Z -->
