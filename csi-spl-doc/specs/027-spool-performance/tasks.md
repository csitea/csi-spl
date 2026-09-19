# Tasks 027: spool performance, live lane table

ORC-PERF (CLE-3413) updates this table as lanes report. Numbers: `before -> after (harness, tree, n)`.

| id | item (spec §3) | lane | status | before -> after |
|---|---|---|---|---|
| T001 | spec 027 + re-measurement | CLE-3413 | done | n/a |
| T010 | #1 pool config + P2a roster multi-row + P2b chunked retention (`store/postgres.go`) | CLE-3417 | pool landed 398b374 (ParseConfig; DSN wins; env SPOOL_HUB_DB_MAX_CONNS=8/MIN 2/idle 5m via cnf); roster landed 58bbeb9 (BenchmarkSetRoster50 10.45 -> 4.15 ms/op, n=5, tree 398b374); sweep next; roll after those | BenchmarkSendPath (InsertMessage+Enqueue, -cpu 1, 4000 sends x5, pg16.14 loopback, tree 434e269, median): pool 4 -> 8 at c=50: 484 -> 991 sends/s, p95 133 -> 55 ms; at c=200: 484 -> 909/s, p95 459 -> 280 ms; 0 errors. Ratios only (not Cloud SQL f1-micro) |
| T020 | #2 streamed upload + prefix-bytes quota (`hub/rest.go`, `blob/`) | CLE-3418 | landed b199493 + 5e21974 (GCS PutReader race, 20 ci-cd red on b1f1a18, fixed by the lane); roll 0.1.13 requested with both shas (no migration, no 030); dev file probe after the roll | TestUploadHeapPerf (go1.25.1, 8x32 MiB concurrent, n=5, medians): GCS peak heap 605 -> 8 MiB; Dir heap 76.3 -> 0.22 MiB/upload; objects.list per new upload 1.00 -> 0.20; GCS latency 169 -> 246 ms/upload |
| T030 | #3 ViewThreads indexed page (`store/view_postgres.go` + rdb migration) | CLE-3419 | landed 74e01d8 + rdb 0022 (3 indexes); oracle test 128 filter combos x every page byte-identical; ViewThread uuid lookup; roll requested (0022 before the image) | TestViewThreadsPerf (pg16.14, tree 2dfefe7 before/after, limit 51, n=30, p50/p95 ms): 50k/2k all-roots 117.9/127.8 -> 5.3/8.0; 200k/2k all-roots 454/459 -> 17.8/31.8; 200k/80k all-roots 600/614 -> 2.5/4.7; 200k/2k dm+viewer 134/143 -> 110/114 (see D6); 5k dm+viewer 4.3/8.7 -> 8.0/12.3; ViewThread 200k 55-80 -> 0.2-0.3 ms (n=3). Audit "3 -> 1,800 ms at 50k": refuted in size (measured 118 ms), confirmed in shape (linear) |
| T040 | #4 onSend path: pin/tenant cache with revoke invalidation, period count index/counter, blob exists (`hub/ws.go`) | CLE-3420 | landed 5d711f8 (deadlock), 1cd82d1 (rdb 0023 period counter, statement-level triggers, backfill exact on 211k), ca31dba (quota reads the counter), ed6f2b4 (overshoot test); try-lock kept (blocking lock: c=50 ~150-280 sends/s); cap overshoot measured up to 64 rows at c=50 (n=5x4), trimmed back by the next send; roll requested now (0023 before the image); pin/tenant cache + blob Exists next | BenchmarkOnSend (pg16.14, RLS role, trunk pool 16 on the 16-CPU box, n=5x200, median), 2dfefe7 -> b9f233c: 10k c=1 76 -> 167 sends/s, p95 19.3 -> 9.1 ms; 200k c=1 25.8 -> 176/s, p95 49.5 -> 8.3 ms; 200k c=50 33.9 -> 2291/s, p95 3277 -> 31 ms, errors 80 -> 0 of 1000; 200k/2 files c=50 24.3 -> 1750/s, errors 115 -> 0; rt/send 12 -> 7 |
| T050 | #5 argon2id on 1 vCPU | — | owner decision D1, sent to CLE-00 16:53Z (recommend b) | |
| T060 | #6 LiveFeed virtualisation + incremental view (`LiveFeed.vue`, `stores/channel.ts`) | — | held until CLE-3412 lands; CLE-55 told | |
| T080 | D3 month quota counts expiring rows (spec §5) | — | owner decision D3, sent to CLE-00 | |
| T090 | D4 bucket lifecycle rule for `tmp/` leftovers (050, terraform) | — | owner decision D4, sent to CLE-00 | |
| T100 | D5 Cloud SQL tier f1-micro: real ceiling unknown (dev load probe, then tier) | — | owner decision D5, sent to CLE-00 | |
| T110 | D6 thread summary table for long sparse-viewer DM threads | — | owner decision D6 (recommend not now) | |
| T070 | P3b multi-instance fanout | — | owner decision D2, sent to CLE-00 16:53Z (recommend not now) | |

<!-- last-edit: 2026-09-19T17:31:29Z -->
