# Spec 099 Seat agy-2 Opinion: Rollout, Operations and Owner Questions

## 1. Verdict
**accept with changes**: Rollout and operational safety lack critical guards — rebuild locking races with unseeded inserts, rollback level 2 cannot verify live hub status, shadow mode lacks reporting tooling and sufficient sample density, and workflow 45 / restore execution targets are ambiguous.

## 2. Findings

### 1. Concurrency race between rebuild and insert on unseeded topics
- **Spec section**: 4.4 (Concurrency) and 8.2 (Backfill).
- **What is wrong/missing**: Spec 4.4 states `topic_head_rebuild` uses `pg_advisory_xact_lock` when no head row exists, while `topic_head_add` uses `INSERT ... ON CONFLICT DO UPDATE`. However, `topic_head_add` does NOT acquire advisory locks. During initial backfill or when a new topic is created, an insert into an unseeded topic will NOT wait for a running rebuild. The rebuild snapshot can overwrite or omit the concurrent insert, causing lost updates. Additionally, 128-bit UUID `task_id` values cannot map cleanly to Postgres 64-bit advisory lock keys without hash collisions.
- **Evidence**: `spec.md:224-229` vs `spec.md:161-167`. In Postgres, `INSERT ... ON CONFLICT` only acquires table/row locks, completely ignoring `pg_advisory_xact_lock`.
- **Proposed change**: Eliminate advisory locks. Require `topic_head_rebuild` to insert a placeholder zero-row with `ON CONFLICT DO NOTHING`, then acquire `SELECT ... FOR UPDATE` on `(tenant_id, task_id)`. Both `add` and `rebuild` will serialize on the exact same row lock.

### 2. Rollback level 2 refusal rule cannot be checked by the action
- **Spec section**: 8 (Rollback Level 2) and tasks.md T006.
- **What is wrong/missing**: Spec 8 states `OP=disable do_spl_topic_head_triggers` "refuses unless the hub's live revision has the flag at off". But the hub exposes no endpoint or metric indicating whether `SPOOL_HUB_TOPIC_HEADS` is `off`.
- **Evidence**: `csi-spl-api/src/go/spool-hub-api/internal/hub/server.go:387-393` (`handleVersion`) returns only `version`, `commit`, `built_at`, and `schema_head`. `/healthz` returns static 200. Cloud Run configuration is only inspectable via authenticated `gcloud run services describe`.
- **Proposed change**: Expose `topic_heads: s.o.TopicHeadsMode` in `GET /version`. Update `spl-topic-head-triggers.func.sh` to curl `/version` on `api_fqdn` and verify `topic_heads == "off"` before disabling triggers.

### 3. Missing shadow reporting tool violates repo "nothing ad hoc" rule
- **Spec section**: 5.1 (Switch), 8.4 (Shadow rollout), and CLAUDE.md.
- **What is wrong/missing**: Spec 8.4 requires verifying "0 topic_head_mismatch lines, with the number of compared requests stated". The hub only logs mismatches, not compared counts, and no named action exists to query Cloud Logging. Operators would be forced to run ad hoc `gcloud logging` queries.
- **Evidence**: `CLAUDE.md:47-63` strictly mandates: "Nothing in the infrastructure should be run ad hoc... there should be a shell action wrapper for that". In `csi-spl-orc/src/bash/run/`, no tool reads topic head shadow logs.
- **Proposed change**: Add named action `orc/spl-topic-head-shadow-report.func.sh` (`do_spl_topic_head_shadow_report`). Have the hub periodically log sample counts (or expose a counter on `/version`), so the report can verify that samples actually ran and zero mismatches occurred.

### 4. Shadow sample rate (10%) provides inadequate verification on prd
- **Spec section**: 5.1 (Switch) and 8.4 (Rollout).
- **What is wrong/missing**: Default sampling of 1 in 10 (`SPOOL_HUB_TOPIC_HEADS_SAMPLE=10`) is too sparse for prd traffic.
- **Evidence**: `refactor-round-api-perf-plan-2026-10-06.md` section 3.1 shows `GET /v1/view/topics` received only 446 calls in 8.4 hours (~1 275/day). A 10% sample tests only ~127 requests in 24 hours, leaving rare query filters and edge cursors untested. Prd query rate is ~0.015 req/s.
- **Proposed change**: Set sample rate to 100% (`SAMPLE=1`) for the 24 h prd shadow window. The DB overhead of duplicating 0.015 req/s is negligible.

### 5. Workflow 45 daily verify execution target is ambiguous
- **Spec section**: 8.6 (Daily check), 9 (Risks), and tasks.md T007.
- **What is wrong/missing**: Spec 8.6 adds `do_spl_topic_head_verify` to `.github/workflows/45_db-backup.yml`. Running full tenant rebuild diffs against the live Cloud SQL instance during the daily backup window adds CPU load and risks contention.
- **Evidence**: `.github/workflows/45_db-backup.yml:165-168` runs `do_spl_db_backup_verify` against a throwaway local container (`spl-restorecheck-$ENV-$$`).
- **Proposed change**: Specify that `do_spl_topic_head_verify` in wf45 runs against the restored throwaway container, proving both backup/restore fidelity and topic head consistency with zero impact on live Cloud SQL.

### 6. `REBUILD=all` cursor mechanism is undefined
- **Spec section**: 8.2 (Backfill), 8 (Rollback re-enable), 9 (Restore path).
- **What is wrong/missing**: `topic_head_backfill(500)` finds topics with "no head". When `REBUILD=all` is triggered after trigger re-enable or disaster restore, all topics already have heads.
- **Evidence**: `spec.md:390-394` vs `spec.md:414-415, 421`.
- **Proposed change**: Specify `topic_head_backfill(chunk int, rebuild_all bool, cursor text)` so it can page through existing topics sequentially without truncating tables during live serving.

### 7. Shadow MD5 comparison must be on canonical view JSON
- **Spec section**: 5.1 (Switch).
- **What is wrong/missing**: Comparing raw `store.TopicRow` MD5 risks false mismatches due to unsorted `Parties` or synthesized `Kinds` maps.
- **Evidence**: `csi-spl-api/src/go/spool-hub-api/internal/hub/view.go:888` explicitly sorts `v.Participants` (`sort.Strings`). Raw slice order in `store.TopicRow.Parties` is nondeterministic across query shapes.
- **Proposed change**: Shadow mode must compute MD5 over canonicalized `viewTopic` JSON representations, ensuring user-facing semantics are verified.

### 8. Migration number 0138 is stale
- **Spec section**: 3 (The head, line 70) and tasks.md T002.
- **What is wrong/missing**: Spec reserves provisional number 0138.
- **Evidence**: `ls csi-spl-rdb/src/sql/postgres/spool-hub/` shows `0143_messages_search_index.sql` already merged on master.
- **Proposed change**: Renumber to `0144_topic_heads.sql`.

## 3. Answers to Owner Questions (Q1..Q8)

- **Q1 (Triggers vs Go writers)**: **Agree with proposal (Triggers)**. 14+ Go call sites exist; finding #2 in `test-results.md` showed `ArchiveChannel` was missed until test execution. In-database triggers ensure 100% coverage across cascades, manual psql, and future endpoints.
- **Q2 (Expiry lag vs exact)**: **Agree with proposal (Exact)**. Reading due heads via fallback preserves exact API contract. Bounded risk: retention sweep runs every 10 min, keeping due set small.
- **Q3 (Shadow before switch)**: **Change proposal**. Agree with shadow mode, but increase sampling from 1 in 10 to **100%** (`SAMPLE=1`) on prd. Require `do_spl_topic_head_shadow_report` to verify results.
- **Q4 (prd DDL and backfill go)**: **Agree with proposal**. Apply dev DDL, backfill, verify, and 24 h shadow first. Reduce backfill chunk size from 500 to 100 topics with `lock_timeout 5s`.
- **Q5 (List shapes vs `TaskIDs`)**: **Agree with proposal**. Switch all walk shapes at once, leave `TaskIDs` (`since=`) on direct range probes.
- **Q6 (Insert cost budget)**: **Agree with proposal**. Added p95 < 5 ms (n=20) at 200k rows gates the build; monitor Insights mean before/after.
- **Q7 (ap-03 and ap-09)**: **Agree with proposal (Drop both)**. Once heads are active, optimizing the deprecated recursive walk is redundant.
- **Q8 (Daily verify in workflow 45)**: **Agree with changes**. Run daily verify against the restored throwaway container in wf45 to avoid production DB overhead.

## 4. Tasks.md Adjustments

1. **T002**:
   - Renumber to `0144_topic_heads.sql`.
   - Implement `topic_head_rebuild` using placeholder row insertion + `SELECT FOR UPDATE` (no advisory locks).
   - Add cursor pagination to `topic_head_backfill` to support `REBUILD=all`.
2. **T005**:
   - Expose `topic_heads` mode on `GET /version` (enabling T006 refusal gate).
   - Compute shadow MD5 on canonical `viewTopic` JSON.
   - Hub must emit periodic shadow sample count logs / heartbeat.
3. **T006**:
   - Add named action `orc/spl-topic-head-shadow-report.func.sh` (+ `.tst.sh`).
   - Implement `do_spl_topic_head_triggers` refusal check by curling `/version`.
4. **T007**:
   - Target `do_spl_topic_head_verify` at the restored throwaway container in wf45.
   - Restrict `REBUILD=all` post-restore backfill in `spl-db-restore.func.sh` to `TARGET=env`.
