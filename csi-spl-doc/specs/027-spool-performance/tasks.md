# Tasks 027: spool performance, live lane table

ORC-PERF (CLE-3413) updates this table as lanes report. Numbers: `before -> after (harness, tree, n)`.

| id | item (spec §3) | lane | status | before -> after |
|---|---|---|---|---|
| T001 | spec 027 + re-measurement | CLE-3413 | done | n/a |
| T010 | #1 pool config + P2a roster multi-row + P2b chunked retention (`store/postgres.go`) | CLE-3417 | pool landed 398b374 (ParseConfig; DSN wins; env SPOOL_HUB_DB_MAX_CONNS=8/MIN 2/idle 5m via cnf); roster + sweep next; roll after those | BenchmarkSendPath (InsertMessage+Enqueue, -cpu 1, 4000 sends x5, pg16.14 loopback, tree 434e269, median): pool 4 -> 8 at c=50: 484 -> 991 sends/s, p95 133 -> 55 ms; at c=200: 484 -> 909/s, p95 459 -> 280 ms; 0 errors. Ratios only (not Cloud SQL f1-micro) |
| T020 | #2 streamed upload + prefix-bytes quota (`hub/rest.go`, `blob/`) | CLE-3418 | landed b199493, CI 10 green (run 35457316444); roll requested from CLE-3355 17:16Z (no migration, no 030); dev file probe after the roll | TestUploadHeapPerf (go1.25.1, 8x32 MiB concurrent, n=5, medians): GCS peak heap 605 -> 8 MiB; Dir heap 76.3 -> 0.22 MiB/upload; objects.list per new upload 1.00 -> 0.20; GCS latency 169 -> 246 ms/upload |
| T030 | #3 ViewThreads indexed page (`store/view_postgres.go` + rdb migration) | CLE-3419 | query rewrite (option a); owns the `(tenant_id, received_at)` index T040 also needs; ViewThread messages page has the same shape (in scope) | |
| T040 | #4 onSend path: pin/tenant cache with revoke invalidation, period count index/counter, blob exists (`hub/ws.go`) | CLE-3420 | BEFORE landed bc3720e; LIVE BUG: Enqueue cap UPDATE deadlocks (195/2000 sends -> 500 at 200k c=50), FIXED 5d711f8 (per-(tenant,box) try advisory lock, Enqueue 5 rt -> 1; control TestEnqueueConcurrentCap 40P01 3/3 old, pass 3/3 new, n=3; overshoot bound asked); index alone leaves the count at 19.8 ms at 200k -> statement-level trigger counter (pending) | BEFORE (BenchmarkOnSend, tree 2dfefe7, pg16.14, n=5x200, median): 10k c=1 76 sends/s p95 19.3 ms; 200k c=1 25.8/s p95 49.5 ms; 200k c=50 33.9/s p95 3277 ms, 80/1000 errors; 12 rt/send |
| T050 | #5 argon2id on 1 vCPU | — | owner decision D1, sent to CLE-00 16:53Z (recommend b) | |
| T060 | #6 LiveFeed virtualisation + incremental view (`LiveFeed.vue`, `stores/channel.ts`) | — | held until CLE-3412 lands; CLE-55 told | |
| T080 | D3 month quota counts expiring rows (spec §5) | — | owner decision D3, sent to CLE-00 | |
| T090 | D4 bucket lifecycle rule for `tmp/` leftovers (050, terraform) | — | owner decision D4, sent to CLE-00 | |
| T100 | D5 Cloud SQL tier f1-micro: real ceiling unknown (dev load probe, then tier) | — | owner decision D5, sent to CLE-00 | |
| T070 | P3b multi-instance fanout | — | owner decision D2, sent to CLE-00 16:53Z (recommend not now) | |

<!-- last-edit: 2026-09-19T17:19:39Z -->
