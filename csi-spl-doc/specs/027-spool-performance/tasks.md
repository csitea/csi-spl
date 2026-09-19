# Tasks 027: spool performance, live lane table

ORC-PERF (CLE-3413) updates this table as lanes report. Numbers: `before -> after (harness, tree, n)`.

| id | item (spec §3) | lane | status | before -> after |
|---|---|---|---|---|
| T001 | spec 027 + re-measurement | CLE-3413 | done | n/a |
| T010 | #1 pool config + P2a roster multi-row + P2b chunked retention (`store/postgres.go`) | CLE-3417 | spawned 16:52Z, BEFORE harness pending | |
| T020 | #2 streamed upload + prefix-bytes quota (`hub/rest.go`, `blob/`) | CLE-3418 | spawned 16:52Z, BEFORE harness pending | |
| T030 | #3 ViewThreads indexed page (`store/view_postgres.go` + rdb migration) | CLE-3419 | spawned 16:52Z, BEFORE harness pending | |
| T040 | #4 onSend path: pin/tenant cache with revoke invalidation, period count index/counter, blob exists (`hub/ws.go`) | CLE-3420 | spawned 16:52Z, BEFORE harness pending | |
| T050 | #5 argon2id on 1 vCPU | — | owner decision D1, sent to CLE-00 16:53Z (recommend b) | |
| T060 | #6 LiveFeed virtualisation + incremental view (`LiveFeed.vue`, `stores/channel.ts`) | — | held until CLE-3412 lands; CLE-55 told | |
| T070 | P3b multi-instance fanout | — | owner decision D2, sent to CLE-00 16:53Z (recommend not now) | |

<!-- last-edit: 2026-09-19T16:53:29Z -->
