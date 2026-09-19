# Spec 027: spool performance (hub, store, object store, WUI)

**Feature**: `specs/027-spool-performance` · **Created**: 2026-09-19 · **Lane**: CLE-3413 (ORC-PERF; orchestrates, lanes implement)
**Input**: the audit `/var/tmp/csi-spl.performance-analysis.html` (2026-09-19, not in git), re-measured on trunk in §3.

## 1. Why

Owner, 2026-09-19 (verbatim): "spawn a new orchestrator to start taking over on
the orchestration for the performance optimization - he should sleep first 15
minutes and than start item by item on this file
/var/tmp/csi-spl.performance-analysis.html spawning agents to implement the changes".

## 2. What the audit is, and is not

Every number in the audit ("4 conns saturate at ~100 msg/s", "3 ms -> 1,800 ms at
50k messages", "~80 ms argon2id", "~75 msg/s dispatch") is a **design estimate, n=0**:
no run, no tree and no harness is named. They are hypotheses. A lane first
reproduces a BEFORE number with its own harness, then reports version / tree / n
for before and after, measured the same way (FR-001).

## 3. Re-measurement on trunk (tree `8c9fc83`, 2026-09-19 ~16:55Z, static reads, n=1)

| # | audit claim | check | still true |
|---|---|---|---|
| 1 | pgx pool on defaults (`max(4, NumCPU)`) | `store/postgres.go:25` `pgxpool.New(ctx, dsn)`; `git grep -c MaxConns` on the store -> 0 | yes |
| 2 | 32 MiB upload read into RAM | `hub/rest.go:43` `io.ReadAll(http.MaxBytesReader(..., msg.MaxFileBytes))`; `msg/msg.go:42` 32 MiB. Also: `Blob.PrefixBytes` lists the tenant's whole file prefix on every new upload (quota) | yes, plus the prefix listing |
| 3 | ViewThreads CTE over every unexpired tenant message, `LIMIT` applied last | `store/view_postgres.go:56` `WITH m AS (`, `LIMIT $7` at :83 | yes |
| 4 | onSend: pin, tenant, has, count, blob exists, insert, enqueue in sequence | `hub/ws.go` :424 GetPin, :456 GetTenant, :465 HasMessage, :471 CountMessagesSince, :489 Blob.Exists, :558 InsertMessage, :563 Enqueue; no `(tenant_id, received_at)` index on `messages` (indexes in rdb `0001`, `0008`, `0020`) | yes |
| 5 | argon2id m=19456 t=2 on 1 vCPU | `auth/native_config.go:19` default 19456, :41 OWASP floor enforced in dev/prd; cnf `hub.cloud_run.cpu: "1"` | yes; the fix is an owner decision (D1) |
| 6 | LiveFeed not virtualised; whole-array recompute per message | `LiveFeed.vue:16` `<TransitionGroup>`; `stores/channel.ts:54,62` computed over `messages.value` | **mostly no** (re-measured 17:37Z, tree after CLE-3412): the DOM is already windowed. `channelView(..., {visible})` renders `WINDOW` = 50 rows and only grows by 50 on an explicit load-older click (`channel.ts:118,135`). The per-message recompute (`topLevel` + `rootsByTask` + `channelView`) costs p50 0.25 ms / p95 0.35 ms at 2k stored messages and p50 1.77 / p95 2.50 ms at 10k (node v20.20.2 on this box, synthetic messages, n=50 after 10 warm-ups). That is far under a 16 ms frame. **Dropped**: no lane. Revisit only with a measured browser trace showing a long task |
| P2a | SetRoster: one INSERT per agent | `store/postgres.go` SetRoster loop | yes |
| P2b | retention: one unbounded `DELETE FROM messages WHERE expires_at <= $1` | `store/postgres.go:353`; `messages_expires` leads with `tenant_id` | yes |
| P3b | multi-instance fanout (Redis/NATS, `max_instances > 1`) | cnf `max_instances: 1` | yes; architecture, owner decision (D2) |

None of the audit's items is already fixed on trunk.

**Correction to the audit's #1 remedy** (reported by CLE-3417 at 17:02Z, read live as the per-env SA, n=1 per env; relayed, not re-read by ORC-PERF): Cloud SQL `max_connections` = **25** on both dev and prd (`superuser_reserved_connections` 3, `cloudsqladmin` 2). The audit's `MaxConns = 30` does not fit. T010 sizes the pool to 8 and leaves the rest for operator sessions and the proxy.

**Correction to the audit's §1 matrix**: the Cloud SQL tier is `db-f1-micro` (shared vCPU, ~0.6 GB), not `db-custom-1-3840`. Check: `git grep -n 'tier' origin/master -- csi-spl-cnf/csi-spl/*/tf/040-cloud-sql-postgres.vars.tfvars` -> `tier = "db-f1-micro"` for dev and prd. The lane benchmarks run pg16 on a 16-core box over loopback, so they give RATIOS between variants, not production ceilings.

## 4. Requirements

- **FR-001** Every perf claim states the version/config, the tree/sha and n, with a before and an after number from the same harness. No "faster" without numbers.
- **FR-002** Behaviour does not change. The existing module tests stay green, and every lane adds CONTROLS: what must still be refused is still refused (RLS tenant isolation, pin revoke takes effect at once, quota, sha mismatch, size limit).
- **FR-003** csi-rel is canon. Firebase Hosting WUI + Cloud Run hub on domain mappings, no load balancer. Config goes cnf -> tpl-gen -> tfvars; infra runs as named actions / make in tf-runner; GCP only as the per-env SA.
- **FR-004** A change is done when it is deployed to dev and then prd and the deployed sha is verified (`/version`, `build.json`), not when CI is green. Hub rolls go through the deploy lane (CLE-3355).

## 5. Owner decisions (routed via CLE-00)

- **Stated bound, T040 pin/tenant cache (0a11fae)**: `GetPin` and `GetTenant` are cached in process. Every pins/tenants writer clears the entry after commit, so a revoke or billing change made through THIS process applies on the very next frame (control `TestSendPathCacheInvalidation`: revoke of to_box -> unpinned_box, unpaid -> 402, revoke of the sender -> refused, tenant A's pin never answers for tenant B). A write this process did not make (the other revision during a roll overlap, hand SQL) is seen within **5 s** (TTL, `TestHotCacheStalenessBound`).
- **Stated bound, T040 queue cap (5d711f8)**: the cap trim takes a per-(tenant, box) try-lock, so a box's queue can briefly exceed `QueueMaxPerBox`. Measured up to 64 rows over the cap after a c=50 burst (BenchmarkOnSend, n=5x4 cases, max), and 0-2 over at 16 workers (store test, n=10). The next send that takes the lock trims it back to the exact cap (`TestEnqueueConcurrentCap`). A blocking lock keeps the cap exact but drops one box to ~150-280 sends/s at c=50, so it was rejected.
- **D1 (item 5)**: argon2id CPU on 1 vCPU. Options: (a) `cpu: "2"` in cnf (about 2x the Cloud Run vCPU cost); (b) keep 1 vCPU and cap concurrent hashes in process with a semaphore (zero cost; logins queue instead of starving the WS loop); (c) lower the params (refused: the code enforces the OWASP floor). Recommendation: (b), measured first.
- **D3 (found by T040, not a perf item)**: the month quota is `COUNT(*)` of messages that still exist (`store/postgres.go:368`, `received_at >= period start`). Retention deletes #alerts after 7 days (cnf `SPOOL_HUB_RETENTION_ALERTS: "168h"`), so a tenant's usage for the month DROPS as its messages expire. T040 keeps that behaviour byte-identical (the counter decrements on delete, FR-002). Question for the owner: should the quota count messages *sent* in the period (monotonic)? Recommendation: yes, as a separate billing lane after T040. The counter then simply stops decrementing.
- **D4 (T020 follow-up)**: a hub crash between the tmp upload's finalize and its promote leaves an object under `tmp/<tenant>/`. Proposed: a bucket lifecycle rule (`matchesPrefix tmp/`, age 1 day) in the 050 terraform step via make/tf-runner. It needs the owner's go (terraform apply). Recommendation: yes.
- **Accepted T020 trade-offs** (measured, FR-001): GCS upload latency rises 169 -> 246 ms/upload (the server-side copy) in exchange for peak heap 605 -> 8 MiB over 8 concurrent 32 MiB uploads. A re-upload of bytes the tenant already holds, sent WITH `Content-Length` while the tenant is at quota, is now 429 from the pre-check (it was 201); without `Content-Length` it is unchanged.
- **D5 (the DB tier)**: every lane's absolute numbers come from a local pg16. Production runs on `db-f1-micro`, so the real ceiling is unknown and probably set by the tier, not by the code. Options: (a) keep f1-micro and first measure a real ceiling on dev with a named load-probe action against the dev hub after the T010-T040 rolls; (b) raise the tier (for example `db-custom-1-3840`, a monthly cost increase; `max_connections` and the pool rise with it). Recommendation: (a) now, and decide (b) on that number.
- **D6 (T030 follow-up)**: after 74e01d8 the thread page costs O(messages in the page window), not O(tenant). With fixed long threads (200k msgs / 2k threads = 100 msgs per thread) the viewer-filtered DM page is still 114 ms p95 vs 12 ms at 5k (n=30), because a sparse viewer walks ~33k rows. Closing that needs a thread summary table (insert + sweep hook + backfill). Recommendation: not now. Do it only if real tenants show long DM threads with a sparse viewer; measure that first with the D5 dev probe.
- **Accepted T030 trade-off**: at 5k messages the dm+viewer first page went 4.29 -> 8.03 ms p50 (8.74 -> 12.33 p95, n=30), in exchange for 200k/80k-thread pages at 600 -> 2.5 ms.
- **D2 (P3b)**: multi-instance fanout. Recommendation: not now. Revisit only once a measured single-instance ceiling is reached.

<!-- last-edit: 2026-09-19T17:45:49Z -->
