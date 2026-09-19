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
| 6 | LiveFeed not virtualised; whole-array recompute per message | `LiveFeed.vue:16` `<TransitionGroup>`; `stores/channel.ts:54,62` computed over `messages.value` | yes; CLE-3412 is editing LiveFeed now |
| P2a | SetRoster: one INSERT per agent | `store/postgres.go` SetRoster loop | yes |
| P2b | retention: one unbounded `DELETE FROM messages WHERE expires_at <= $1` | `store/postgres.go:353`; `messages_expires` leads with `tenant_id` | yes |
| P3b | multi-instance fanout (Redis/NATS, `max_instances > 1`) | cnf `max_instances: 1` | yes; architecture, owner decision (D2) |

None of the audit's items is already fixed on trunk.

## 4. Requirements

- **FR-001** Every perf claim states the version/config, the tree/sha and n, with a before and an after number from the same harness. No "faster" without numbers.
- **FR-002** Behaviour does not change. The existing module tests stay green, and every lane adds CONTROLS: what must still be refused is still refused (RLS tenant isolation, pin revoke takes effect at once, quota, sha mismatch, size limit).
- **FR-003** csi-rel is canon. Firebase Hosting WUI + Cloud Run hub on domain mappings, no load balancer. Config goes cnf -> tpl-gen -> tfvars; infra runs as named actions / make in tf-runner; GCP only as the per-env SA.
- **FR-004** A change is done when it is deployed to dev and then prd and the deployed sha is verified (`/version`, `build.json`), not when CI is green. Hub rolls go through the deploy lane (CLE-3355).

## 5. Owner decisions (routed via CLE-00)

- **D1 (item 5)**: argon2id CPU on 1 vCPU. Options: (a) `cpu: "2"` in cnf (about 2x the Cloud Run vCPU cost); (b) keep 1 vCPU and cap concurrent hashes in process with a semaphore (zero cost; logins queue instead of starving the WS loop); (c) lower the params (refused: the code enforces the OWASP floor). Recommendation: (b), measured first.
- **D2 (P3b)**: multi-instance fanout. Recommendation: not now. Revisit only once a measured single-instance ceiling is reached.

<!-- last-edit: 2026-09-19T16:58:00Z -->
