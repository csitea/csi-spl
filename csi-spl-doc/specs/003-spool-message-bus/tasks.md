# Tasks: Spool message bus (hub)

**Feature**: `specs/003-spool-message-bus` · **Spec**: `./spec.md` · **Plan**: `./plan.md`

**Gate**: spec `002-box-agent-messaging` CLI + `v:1` schema exist (002 US1). Do not implement hub handlers against a forked JSON. Tasks marked **⛔ OQ-nn** wait for that Open Question in `spec.md`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no unmet deps)
- **[US#]**: user story tag

## Phase 1: Setup

- [ ] T001 Add `internal/httpapp`, `internal/hub`, `internal/store` (tenant-native schema from `data-model.md`; sqlite/memory driver for tests; internal tenant id from cnf, no literal), `internal/objects`, and the box-side `internal/hubclient` packages, each with a test that compiles empty. `internal/{msg,sign,files,spool}` behaviour unchanged.
- [ ] T002 [P] Golden fixture loader for `contracts/http-v1.md` frames and REST bodies under `internal/hub/testdata/`.

## Phase 2: Foundational

- [ ] T003 Envelope canonicalise + sign + verify around the unchanged inner `v:1`, reusing 002 `internal/msg` canonical JSON and `internal/sign`; golden vector test. **⛔ OQ-03** (signed bytes when `to_box` is hub-filled).
- [ ] T004 [P] Fail-fast config: listen address, `$SPOOL_HUB_URL`, `$SPOOL_BOX_ID`, product domain, store DSN, bucket, queue TTL, pin refresh interval, `$SPOOL_MIRROR_LOCAL`. No hostname literals (`internal/config`, pas-psf pattern).
- [ ] T005 [P] Server harness in `internal/httpapp` + hub entrypoint: Fiber app, recover/request-ID/access-log middleware, `/healthz`, `/version`, `runUntilShutdown` graceful drain that also closes WS sockets.
- [ ] T006 [P] Tenant resolution from the request Host; unknown tenant → refuse; test two tenants on one process. Coordinate with 006 T002 (same behaviour, one implementation).

## Phase 3: User Story 1 — Cross-box send/recv over WS (P1) 🎯 MVP

- [ ] T007 [US1] CLI/MCP hub mode: `spool-send` gains `--to-box` / `to_box` and returns `delivery`. **⛔ OQ-01** (box API change) and **⛔ OQ-14** (inner `sig` in the 002 build).
- [ ] T008 [US1] WS hello: verify box `sig` against `(tenant, box_id)` pin; unknown → close; last hello wins (`internal/hub/ws.go`). Needs 004 pins.
- [ ] T009 [US1] Roster frame from the `$SPOOL_ROOT/*/` dir scan; duplicate id on one box → 409; re-announce on change.
- [ ] T010 [US1] Send frame: `from_box` == hello box, verify `sig`, resolve `to_box` (409 `ambiguous_to_box`), idempotent insert on `(tenant_id, msg_id)` (409 `conflict_msg`), push to a live socket → `delivery=sent`.
- [ ] T011 [US1] Box-side recv: frame → re-verify against the locally synced pin → write the inner `v:1` to `$SPOOL_ROOT/<to>/inbox/`; missing pin → refuse `78`.
- [ ] T012 [US1] Two-box test (`internal/testkit`): GRK-03@box-a → CLE-07@box-b → `result` back; unpinned box; tampered envelope; ambiguous `to`.

## Phase 4: User Story 2 — Files to object store (P1)

- [ ] T013 [US2] `POST /v1/files` with box proof stores `t/<tenant>/files/<sha256>` in `internal/objects` (local dir in tests). **⛔ OQ-10** (proof mechanism).
- [ ] T014 [US2] `GET /v1/files/{file_id}`: tenant-scoped capability, bytes or short-lived signed URL; never logs the URL; cross-tenant → 404.
- [ ] T015 [US2] CLI `spool-put-file` / `spool-get-file` use hub file routes when `$SPOOL_HUB_URL` is set; re-hash on get.
- [ ] T016 [US2] Round-trip test: put on box-a → send with `file_ids` → get on box-b; no bytes in any frame.

## Phase 5: User Story 3 — Offline receiver, hub-down sender (P1)

- [ ] T017 [US3] Hub queue: no live socket for `to_box` → `deliveries` row with TTL, `delivery=queued`; drain on next hello; expire after TTL. **⛔ OQ-13** (TTL default), **OQ-08** (ack model).
- [ ] T018 [US3] Dual-write per `contracts/flush.md`: same-box → local only (`delivery=local`) unless `$SPOOL_MIRROR_LOCAL`; illegal value fails fast.
- [ ] T019 [US3] Box-side flush of pending outbox: idempotent by `msg_id`, no re-sign, `ts` unchanged, 400 → stop with `78`, network/5xx → backoff. **⛔ OQ-09** (`delivery` value), **OQ-15** (package: this task vs 004 T010; do it once).
- [ ] T020 [US3] Tests: box-b offline → `queued` → reconnect → recv; hub stopped → same-box works, cross-box pending → hub up → flush delivers; TTL expiry.

## Phase 6: Production storage (P1, M1)

- [ ] T021 Postgres implementation of `internal/store` (migrations from `data-model.md`); the same test suite runs against sqlite/memory and a local Postgres container.
- [ ] T022 [P] GCS implementation of `internal/objects`, one bucket, tenant prefix; the bucket name comes from cnf.
- [ ] T023 [P] `csi-spl-iac` Cloud Run (min instances from cnf, default 1), Cloud SQL, GCS: tpl-gen + `terraform validate/plan` only, no apply without the owner's go. **⛔ OQ-05** (max instances / fan-out).

## Phase 7: User Story 4 — Live tail (P2, after M1)

- [ ] T024 [US4] Pick and implement the notify transport. **⛔ OQ-04**, **OQ-12**.
- [ ] T025 [US4] `spool tail` follows live when the hub is up and reads the store when down; test: two subscribers, one late subscriber catches up from the store, no bytes or tokens in payloads, no cross-tenant delivery.

## Phase 8: User Story 5 — Door (P3)

- [ ] T026 [US5] Test that the public hub runs with no GCP credentials on boxes and that every unauthenticated path (hello, envelope, file PUT) is refused.
- [ ] T027 [US5] Private-deploy IAM front: document in `csi-spl-iac`, IAM before box-key verify. **⛔ OQ-06**.

## Phase 9: User Story 6 — Adapter is another repo (P3)

- [ ] T028 [US6] State in `doc/md/SPEC-spool-box-api.md` that ysg-box MUST only shell these verbs; no code in ysg-box from this repo.

## Phase 10: Polish

- [ ] T029 Hygiene grep: no per-kind routes/frames, no private keys or signed URLs in logs, no baked hosts or tenant ids.
- [ ] T030 `go test ./...` and `bash csi-spl-api/src/bash/tests/run-all-tests.sh` green; box-API contract diff clean (`internal/{msg,sign,files,spool}` behaviour, CLI verbs, MCP tool names), except whatever OQ-01 explicitly allows.

## Traceability

| Requirement | Tasks |
|---|---|
| FR-001 endpoints | T005, T008–T010, T013, T014 |
| FR-002 CLI/MCP only door | T007, T015, T028 |
| FR-003 hello verify, last hello wins | T008, T012 |
| FR-004 envelope verify, `from_box` binding | T003, T010, T012 |
| FR-005 `to_box` resolution | T009, T010, T012 |
| FR-006 `sent` / `queued` | T010, T017, T020 |
| FR-007 files | T013–T016, T022 |
| FR-008 hub-down flush | T019, T020 |
| FR-009 same-box local, mirror flag | T018, T020 |
| FR-010 idempotent ingest | T010, T019, T021 |
| FR-011 notify hygiene | T024, T025 |
| FR-012 stateless | T005, T021, T022, T029 |
| FR-013 no per-kind | T029 |
| FR-014 no private keys | T003, T029 |
| FR-015 tenant everywhere | T006, T021, T022 |
| FR-016 IAM before box key | T027 |
| NFR-001 region / cnf | T004, T023 |
| NFR-002 error mapping | T012, T020 |
| NFR-003 no schema fork | T003, T030 |
| NFR-004 no Kafka / no NATS in M1 | T024 (after M1 only) |
| NFR-005 pas-psf harness | T004, T005 |
| NFR-006 limits | T013, T016 |

| Contract endpoint (`contracts/http-v1.md`) | FR |
|---|---|
| WS `/v1/ws` | FR-001, FR-003–FR-006 |
| `POST /v1/files` | FR-001, FR-007 |
| `GET /v1/files/{file_id}` | FR-001, FR-007 |
| `GET/POST/DELETE /v1/pins` | owned by 004 / 006 (hosted by FR-001) |
| `GET /healthz`, `GET /version` | FR-001 |

## Dependencies

002 US1 → T003+. 004 pins → T008. T003 → T010, T011, T019. US1 (T007–T012) gates US2, US3. T021/T022 can start once T010/T013 interfaces exist. US4 and US5 come after M1. US6 is documentation only here.

## Cross-spec duplicates to settle (not fixed here; the owners are 004 / 006)

- 003 T006 ≈ 006 T002 (tenant from Host).
- 003 T019 ≈ 004 T010 (flush), which is OQ-15.
- 006 T008–T010 still build `POST /v1/messages` / `POST /v1/recv` with per-agent keys, which OQ-02 would remove.
- 004 T003 pins `{id, pubkey}` per **agent** with an IAM door map, while trust-modes pins **boxes** with the tenant root.

## Implementation strategy

MVP of 003 = Milestone 1 = US1 + US2 + US3 on sqlite/memory, then Postgres + GCS (Phase 6). Live tail and IAM come after M1.

<!-- version: 0.2.0 · updated: 2026-09-18 · last-edit: 2026-09-18T17:24:00+03:00 -->
