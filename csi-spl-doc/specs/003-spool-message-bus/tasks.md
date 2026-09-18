# Tasks: Spool message bus (hub)

**Feature**: `specs/003-spool-message-bus` · **Spec**: `./spec.md` · **Plan**: `./plan.md` · **Ground rules**: `../README.md`

**Gate**: spec `002-box-agent-messaging` CLI + `v:1` schema exist (002 US1). Do not implement hub handlers against a forked JSON. OQ-01..15 are resolved (`spec.md` → **Resolved decisions**); OQ-16 (viewer door) blocks T033 only.

**Status vocabulary** (`../README.md` §2.3): **Implemented** (artifact verified, citation given) · **Partial** (what is missing is named) · **Planned** (nothing built). A checkbox is ticked only for Implemented.

**Verification run (2026-09-18, n=1)**: `bash csi-spl-api/src/bash/tests/run-all-tests.sh` on trunk `9f8f492` → `ALL csi-spl-api TESTS PASSED`, Postgres gate and GCS gate **not** skipped (docker `postgres:16-alpine`, `fake-gcs-server:1.52.2`). Test names cited below are in `csi-spl-api/src/go/spool-hub-api/internal/hub/hub_test.go`. Code shas: wire/store/blob + DDL + migrator `81121a0`; hub + hubclient + CLI `7905e35`; pin sync + flush `e2c7d8d`; pins REST `de33409`; 402/429 `343e833` (006).

## Format: `[ID] [P?] [Story] Description — Status`

- **[P]**: parallelizable (different files, no unmet deps)
- **[US#]**: user story tag

## Phase 1: Setup

- [x] T001 Add `internal/hub` (server), `internal/store` (memory + Postgres), `internal/blob` (local dir + GCS), `internal/wire` (frames + envelope, both sides) and the box-side `internal/hubclient`. `internal/{msg,sign,files,spool}` behaviour unchanged. — **Implemented** `81121a0`, `7905e35`; `ls csi-spl-api/src/go/spool-hub-api/internal` lists all five.
- [x] T001a Schema DDL in `csi-spl-rdb/src/sql/postgres/spool-hub/NNNN_<name>.sql` (plain, ordered, forward-only) materialising `data-model.md`. — **Implemented**; `ls …/spool-hub/ -> 0001_hub_core.sql 0002_channels.sql 0003_payment.sql`.
- [x] T001b `spool migrate --db <dsn> --sql-dir <dir>`: filename order, one transaction each, tracked in `spool_schema_migrations` (filename + sha256; a changed applied file is a hard error); re-run is a no-op. — **Implemented**; `hub-pg.tst.sh` → `spool migrate applies 3 file(s); re-run is a no-op`. Invoked in the cloud by `do_spl_db_bootstrap` (`9f8f492`, 007 lane).
- [x] T002 [P] Golden vectors for the envelope and hello signing payloads. — **Implemented**; `internal/wire/wire_test.go`.

## Phase 2: Foundational

- [x] T003 Envelope canonicalise + sign + verify around the unchanged inner `v:1`: `sig` over `jq -cS '{from_box,to_box,msg}'` with `to_box` present (OQ-03a). — **Implemented** `81121a0`; golden vectors in `wire_test.go`.
- [x] T004 [P] Fail-fast config (listen, `$SPOOL_HUB_URL`, `$SPOOL_BOX_ID`, product domain, DSN, bucket, queue TTL/cap, retention, `SPOOL_HUB_ALLOW_TEXT_ONLY_WHEN_FILE_MISSING` default false, pin refresh, `$SPOOL_MIRROR_LOCAL`). No hostname literals. — **Implemented**; `grep -n 'AllowTextOnly' internal/config/config.go -> envDefault:"false"`.
- [x] T005 [P] Server harness + `spool serve` on `net/http` (`coder/websocket`), recover/request-ID/access-log middleware, `/healthz`, `/version`, graceful drain closing WS `1001`. — **Implemented** `7905e35`. See T032 for the Cloud Run health path.
- [x] T006 [P] Tenant from the request Host; unknown → `404 unknown_tenant`; two tenants on one process. — **Implemented**; `TestFilesRoundTripAndTenantIsolation`. Resolution semantics owned by 006.

## Phase 3: User Story 1 — Cross-box send/recv over WS (P1) 🎯 MVP

- [x] T007 [US1] CLI/MCP hub mode (OQ-01, additive): `--to-box` / `to_box`, `delivery` ∈ `local|sent|queued|pending`; local mode byte-for-byte 002. — **Implemented**; e2e + `spool-smoke.tst.sh` green.
- [x] T008 [US1] WS hello challenge-response (OQ-03b): nonce, `{box_id,nonce,ts}`, ±300 s, `4401`/`4408`, `role=box` last hello wins `4409`, `role=cli` never evicts. — **Implemented**; `TestHelloNonceAcceptAndReplayReject`, `TestLastHelloWinsOnlyForBoxRole`.
- [x] T009 [US1] Roster: announce on `role=box` hello, `roster` frame, `roster_duplicate` 409, persisted, cached in `$SPOOL_ROOT/.hub/roster.json`. — **Implemented** `7905e35`.
- [x] T010 [US1] Send frame: `from_box` binding, `sig`, sender-resolved `to_box` (`ambiguous_to_box` 409 / `missing_to_box` 400), `to_box` pinned, file refs held (OQ-11), idempotent `(tenant_id, msg_id)`, live push → `sent`. — **Implemented**; `TestCrossBoxSendRecvAndResult`, `TestTamperedAndAmbiguousAndMissingPin`.
- [x] T011 [US1] Box-side recv: re-verify against the local pin, write inner `v:1` to the inbox; missing pin / bad sig → `78`. — **Implemented**; `TestTamperedAndAmbiguousAndMissingPin`.
- [x] T012 [US1] Two-box tests (result back, unpinned, nonce replay, tampered, ambiguous, missing pin). — **Implemented**; the tests above + e2e `unpinned box refused at hello (exit 78)`, `kind=result crossed back`.

## Phase 4: User Story 2 — Files to object store (P1)

- [x] T013 [US2] `POST /v1/files` with the WS-issued upload token (OQ-10), `t/<tenant>/files/<sha256>`; no token → `401 door`. — **Implemented**; `grep -c '"door"' internal/hub/rest.go -> 2`.
- [x] T014 [US2] `GET /v1/files/{file_id}` tenant-scoped capability; cross-tenant 404. — **Implemented**; `TestFilesRoundTripAndTenantIsolation`.
- [x] T015 [US2] CLI uploads referenced blobs before the envelope; receiver fetches missing blobs and re-hashes. — **Implemented** `7905e35`.
- [x] T016 [US2] Round-trip test; no bytes in frames; `missing_file` 400 by default. — **Implemented**; `TestFilesRoundTripAndTenantIsolation`.

## Phase 5: User Story 3 — Offline receiver, hub-down sender (P1)

- [x] T017 [US3] Hub queue: `deliveries` row, 7 d TTL, cap 1,000, `queued`, drain on `role=box` hello, expire; no ack (OQ-08). — **Implemented**; `TestOfflineQueueAndHubDownFlush`, e2e `offline receiver: delivery=queued, drained on hello`.
- [x] T018 [US3] Dual-write per `contracts/flush.md`: same-box → `local` unless `$SPOOL_MIRROR_LOCAL`; illegal value fails fast. — **Implemented** for default + fail-fast (`internal/config` `Mirror()`, `internal/hubclient/flush.go`).
- [ ] T018a [US3] Test the mirror-**on** path (`SPOOL_MIRROR_LOCAL=1`: same-box send is written locally **and** hub-sent; `delivery` reported as `local`). — **Planned**; `grep -ci mirror internal/hub/hub_test.go internal/hubclient/flush_test.go -> 0, 0`. (FR-009 stays Partial until this lands.)
- [x] T019 [US3] Box-side flush in `internal/hubclient` (OQ-15): `.hub/pending/`, idempotent, no re-sign, `ts` unchanged, `.hub/rejected/` + `78`, backoff; hub unreachable → `pending`, exit 0. — **Implemented** `e2c7d8d`; e2e `hub down: cross-box delivery=pending (exit 0)`, `hub back: flush sent the pending envelope`.
- [x] T019a [US3] Reconnect (OQ-05): `spool hub-run` backoff 1 s → 30 s + jitter, re-hello, re-announce, re-sync pins, flush; stop on `4409`. `spool hub-sync` one-shot. — **Implemented**; e2e `hub-run reconnected and received it`.
- [x] T020 [US3] Tests: offline → queued → recv; hub stopped → same-box works, cross-box pending → flush; TTL expiry. — **Implemented**; `TestOfflineQueueAndHubDownFlush` + e2e.

## Phase 6: Production storage and cloud (P1, M1)

- [x] T021 Postgres `internal/store`; contract suite on memory and a temp Postgres (`SPOOL_TEST_PG_DSN`). — **Implemented**; `hub-pg.tst.sh` → `internal/store + internal/hub suites green against Postgres`.
- [x] T021a Retention sweep: queued TTL + cap → `expired`; messages purged per tier. — **Implemented**; `grep -n 'Store.Sweep' internal/hub/server.go -> 142` (periodic in `serve`).
- [x] T022 [P] GCS `internal/blob`, one bucket, tenant prefix, bucket from cnf. — **Implemented**; `hub-gcs.tst.sh` → `ALL HUB GCS CHECKS PASSED`.
- [ ] T023 [P] **Infra lane (007)**, cited not owned: Cloud Run `max-instances=1`, min 1 (cnf), Cloud SQL, GCS, per `../README.md` §6. — **Partial**: dev — `csi-spl-hub-dev` Ready, `spool-hub:0.1.0`, scale 1/1, DSN secret v1, `spool` DB (integrator measurement 2026-09-18 ~19:00Z, n=1; `gcloud run services describe … --account=$GCP_ACCOUNT` re-checked here). Missing: dev LB + cert + DNS (step 10); **all of prd** (Cloud Run/SQL APIs `SERVICE_DISABLED`). Deploy jobs in `20_hub-build-deploy.yml` are skipped until WIF repo vars exist (008 / tf `017`).

## Phase 7: User Story 4 — Live tail (P2)

- [x] T024 [US4] Tail over the existing WS (OQ-04): `tail{task_id,follow}` → `tail_msg`… `tail_end`, live with `follow`; tenant-scoped; no NATS/SSE (OQ-12). — **Implemented**; `TestTailStoredAndFollow`, e2e `hub-tail returns the 4-message thread`.
- [x] T025 [US4] Test: ordered stored thread, follower sees new send, no bytes, no cross-tenant. — **Implemented**; `TestTailStoredAndFollow`.

## Phase 8: User Story 5 — Door (P3)

- [x] T026 [US5] Hub runs with no GCP credentials on boxes; every unauthenticated path (hello, envelope, file PUT) refused. — **Implemented**; e2e runs boxes with no GCP credentials; `TestTamperedAndAmbiguousAndMissingPin`, `door` 401.
- ~~T027~~ Private-deploy IAM front: **dropped from M1** (OQ-06). `boxes.iam_principal` reserved (`0001_hub_core.sql`).

## Phase 9: User Story 6 — Adapter is another repo (P3)

- [ ] T028 [US6] State in `doc/md/SPEC-spool-box-api.md` that ysg-box MUST only shell the spool verbs; no code in ysg-box from this repo. — **Planned**; `grep -c 'MUST only shell' csi-spl-doc/doc/md/SPEC-spool-box-api.md -> 0`. (Edits a shared narrative doc: integrator's call whether this lane or the integrator lands it.)

## Phase 10: User Story 7 — Read-only viewer API for the WUI (P2, M3 dependency)

All **Planned**; contract `contracts/view-v1.md`. Code tasks for a code lane, not this docs lane.

- [ ] T031 [US7] `internal/store`: read-only queries `ListThreads(tenant, before, limit, channel, agent)`, `ThreadMessages(tenant, task_id, after, limit)` (envelope bytes + delivery states), `ListChannels(tenant)`; memory + Postgres drivers; contract-suite cases proving `deliveries` is unchanged by every read (FR-019). Add DDL `0004_view_indexes.sql` only if `EXPLAIN` on Postgres shows the thread list needs an index beyond `messages_task` (e.g. `(tenant_id, received_at)`). — **Planned**.
- [ ] T032 [P] Health path reachable on Cloud Run (FR-023): add `GET /v1/health` (same body as `/healthz`), keep `/healthz`; ask 007 to point the LB health check at it. — **Planned**.
- [ ] T033 [US7] View-token door (FR-020, **blocked on OQ-16**): verify `jq -cS '{exp,scope,tenant}'` against `tenants.root_pubkey`, Host tenant match, `exp ≤ now + hub.view_token_max_ttl` (cnf, 12 h); `401 view_door`; redact `Authorization` in access logs. CLI verb `spool hub-view-token --ttl`. Golden vector in `internal/wire`. — **Planned**.
- [ ] T034 [US7] Handlers `GET /v1/view/{roster,channels,threads,threads/{task_id}}` per `contracts/view-v1.md` §4 (opaque cursors, `bad_cursor`, limit clamp 200, `405` on non-GET, `online` from the live socket map). — **Planned**.
- [ ] T035 [US7] CORS (FR-021): cnf `hub.view_cors_origins` (no default, never `*`), preflight `204`, only on `/v1/view/*` + `GET /v1/files/{id}`; the cnf key is published to 007 for `csi-spl-cnf`. — **Planned**.
- [ ] T036 [US7] Tests: US7 acceptance 1–5; cross-tenant 404; queued message still drains after a read; no token/URL in logs; e2e step in `hub-e2e.tst.sh` reading a thread with a minted view token. — **Planned**.

## Phase 11: Polish

- [x] T029 Hygiene grep: no per-kind routes/frames, no private keys, tokens or signed URLs in logs, no baked hosts or tenant ids. — **Implemented**; `TestPinCLIPublishesAndHygiene` + the CI `distribution-hygiene` sweep.
- [x] T030 `go test ./...` and `run-all-tests.sh` green; box-API diff clean except additive `to_box` / `delivery` (OQ-01). — **Implemented**; verification run above.

**Dropped** (OQ-02): every REST message-dialect task (`POST/GET /v1/messages`, `POST /v1/recv`). None remains in 003. The viewer API (Phase 10) is read-only and is **not** a revival of them (`contracts/view-v1.md` §0).

## Traceability

| Requirement | Tasks | Status |
|---|---|---|
| FR-001 endpoints | T005, T008–T010, T013, T014 | Implemented |
| FR-002 CLI/MCP only door | T007, T015, T028 | Implemented (T028 doc Planned) |
| FR-003 hello nonce, last hello wins | T008, T012 | Implemented |
| FR-004 envelope verify, `from_box` binding | T003, T010, T012 | Implemented |
| FR-005 sender-resolved `to_box` | T009, T010, T012 | Implemented |
| FR-006 `sent` / `queued` | T010, T017, T020 | Implemented |
| FR-007 files, upload token | T013–T016, T022 | Implemented |
| FR-008 hub-down flush, `pending` | T019, T020 | Implemented |
| FR-009 same-box local, mirror flag | T018, T018a, T020 | Partial |
| FR-010 idempotent ingest | T010, T019, T021 | Implemented |
| FR-011 notify hygiene | T024, T025 | Implemented (M1 tail) |
| FR-012 stateless | T005, T021, T022, T029 | Implemented |
| FR-013 no per-kind | T029 | Implemented |
| FR-014 no private keys | T003, T029 | Implemented |
| FR-015 tenant everywhere | T006, T021, T022 | Implemented |
| FR-016 no IAM in M1 | T026 | Implemented |
| FR-017 max-instances=1, reconnect | T019a, T023 | Partial (prd) |
| FR-018 viewer API | T031, T034 | Planned |
| FR-019 reads never mutate | T031, T036 | Planned |
| FR-020 view-token door | T033 | Planned (OQ-16) |
| FR-021 CORS allow-list | T035 | Planned |
| FR-022 viewer tenant-scoped, bytes-as-stored | T031, T034, T036 | Planned |
| FR-023 Cloud Run-safe health path | T032 | Planned |
| NFR-001 region / cnf | T004, T023 | Implemented (dev) |
| NFR-002 error mapping | T012, T020 | Implemented |
| NFR-003 no schema fork | T003, T030 | Implemented |
| NFR-004 no Kafka / no NATS in M1 | T024 | Implemented |
| NFR-005 pas-psf harness | T004, T005 | Implemented |
| NFR-006 limits | T013, T016, T021a, T034 | Implemented (viewer limits Planned) |

| Contract endpoint | FR | Status |
|---|---|---|
| WS `/v1/ws` (`contracts/http-v1.md` §2) | FR-001, FR-003–FR-006 | Implemented |
| `POST /v1/files` | FR-001, FR-007 | Implemented |
| `GET /v1/files/{file_id}` | FR-001, FR-007 | Implemented |
| `GET/POST/DELETE /v1/pins` | owned by 004 / 006 (hosted by FR-001) | Implemented (`de33409`) |
| `GET /healthz`, `GET /version` | FR-001 | Implemented (see FR-023 for Cloud Run) |
| `GET /v1/health` | FR-023 | Planned |
| `GET /v1/view/*` (`contracts/view-v1.md`) | FR-018–FR-022 | Planned |

## Dependencies

002 US1 → T003+. T001a → T001b → T021. Pins (004) → T008. T003 → T010, T011, T019. US1 gates US2, US3. T023 belongs to 007 in the order of `../README.md` §6. T031 → T034 → T036; T033 waits on OQ-16; T035 needs 007 to carry the cnf key. 005 (WUI) depends on T034–T035.

## Cross-spec seams (cite, do not fix here)

- 003 T006 ≈ 006 T002 (tenant from Host): one implementation, semantics owned by 006.
- 003 T019 ≈ 004 T010 (flush): decided (OQ-15) — box-side `internal/hubclient`.
- 006 T008–T010 must be WebSocket, not `POST /v1/messages` / `POST /v1/recv` (OQ-02).
- 005 WUI client still calls `/v1/messages` and `/v1/channels` (`contracts/view-v1.md` §7): 005 rebases its read path onto `/v1/view/*`.
- 007: LB health check path (T032), `hub.view_cors_origins` / `hub.view_token_max_ttl` cnf keys (T033, T035), prd rollout (T023).

## Implementation strategy

M1 of 003 = US1 + US2 + US3 + the WS tail of US4 — Implemented and green on Postgres + GCS; what remains for M1 is the cloud rollout (007) and the pipeline deploy (008). US7 is the next 003 code slice, due before 005 (M3) starts on real data.

<!-- version: 0.4.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:05:00Z -->
